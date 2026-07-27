// Push-to-toggle dictation for the composer: Speech framework does the
// recognition, AVAudioEngine feeds it raw mic buffers. Shared across both
// providers the same way V2AttachmentStore is — one controller instance per
// composer, not a global singleton, so two tabs dictating at once (unlikely
// but possible) never fight over one AVAudioEngine.
//
// Sandbox is off for this app (Work.entitlements) so no sandbox entitlement
// is needed for mic access — just the two Info.plist usage strings
// (NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription) and
// the standard TCC prompts, requested lazily on first use, never at launch.

import AVFoundation
import AppKit
import Foundation
import Speech
import SwiftUI

/// Speech explicitly expects its audio-buffer request to be fed from the
/// audio-engine tap's real-time callback. The request is otherwise owned and
/// torn down on the main actor; this box confines that one framework-sanctioned
/// cross-thread use to a small, documented boundary.
private final class V2SpeechRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    /// Feed a buffer to whatever request is current. Called from the audio
    /// thread; the lock guards the pointer swap done on the main actor when
    /// dictation rotates to a fresh request for long-form continuation.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r.append(buffer)
    }

    /// Point the tap at a new request without disturbing the running engine.
    func swap(_ newRequest: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock(); request = newRequest; lock.unlock()
    }
}

/// Per-tap scratch state touched ONLY from the single serial audio-render
/// thread, so a plain non-atomic counter is safe. Used to throttle how often
/// the mic level is pushed to the main actor (~every 3rd buffer ≈ 14 fps)
/// instead of on every ~1024-frame callback.
private final class V2AudioTapState: @unchecked Sendable {
    var counter: Int = 0
}

/// The live mic level, on its OWN observable object so the ~14 fps updates
/// re-render ONLY the tiny meter view — never the whole composer. The
/// dictation controller holds this as a plain `let`, so its own
/// objectWillChange stays low-frequency (state transitions only), honouring
/// the "don't fan out high-frequency @Published" rule in PERFORMANCE.md.
final class V2MicLevel: ObservableObject {
    /// Smoothed 0…1 amplitude. 0 when idle.
    @Published var level: Float = 0
}

@MainActor
final class V2DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case listening
        /// Either permission was ever denied — surfaced distinctly so the
        /// button can point at System Settings instead of silently no-op'ing
        /// on the next tap.
        case denied
        /// No recognizer for this locale, or the engine failed to start.
        case unavailable
    }

    @Published private(set) var state: State = .idle
    /// When the current listening session began — drives the elapsed readout
    /// in the meter via a TimelineView (no per-second @Published churn).
    @Published private(set) var startedAt: Date?

    /// Live mic amplitude, on a separate object so its high-frequency updates
    /// only re-render the meter. See V2MicLevel.
    let mic = V2MicLevel()

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// The live tap → request bridge. Persists across request rotations so a
    /// long rant continues seamlessly past the recognizer's ~1-minute
    /// server cap and past every natural pause (each of which the recognizer
    /// reports as a `final`).
    private var requestBox: V2SpeechRequestBox?
    private var task: SFSpeechRecognitionTask?

    /// The draft as it stood when dictation started — never mutated during a
    /// session; dictated text is composed on top of it.
    private var dictationBase = ""
    /// Finalised segments accumulated this session (across rotations). The
    /// live partial from the current request is appended after this.
    private var committed = ""
    /// Set when the user taps stop; the next `final` then tears down instead
    /// of rotating into a new request.
    private var stopping = false
    /// Guards the rotate-on-error path from looping if recognition is truly
    /// failing (vs. a benign segment-boundary error).
    private var errorStreak = 0
    /// Session-scoped fallback: if server recognition errors before producing
    /// anything (e.g. offline), retry once on-device so a rant isn't lost.
    private var useOnDevice = false
    private var triedOnDeviceFallback = false
    /// Bumped on every request rotation. A cancelled task can still deliver a
    /// trailing (cancellation) callback after we've moved on; gating on this
    /// makes handleResult ignore anything but the current request's task, so a
    /// rotation can't cascade into spurious extra rotations.
    private var generation = 0
    /// Observes AVAudioEngine I/O reconfiguration (e.g. the input device
    /// changes when you plug in AirPods). The engine stops feeding buffers on
    /// such a change; without handling it the meter freezes and words silently
    /// stop landing. We finish the session cleanly instead.
    private var configObserver: NSObjectProtocol?
    /// Called on every partial and final result with the draft text dictation
    /// should now show. The composer owns `draft`; this controller never
    /// touches it directly, so it stays agnostic of which composer holds it.
    var onUpdate: ((String) -> Void)?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    var isListening: Bool { state == .listening }

    func toggle(currentDraft: String) {
        if state == .listening {
            stop()
        } else {
            start(currentDraft: currentDraft)
        }
    }

    private func start(currentDraft: String) {
        guard state != .listening, state != .requestingPermission else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }
        dictationBase = currentDraft
        state = .requestingPermission
        // TCC invokes this completion on its own XPC queue. The closure must
        // be explicitly @Sendable: otherwise Swift 6 inherits this class's
        // @MainActor isolation at closure creation and traps BEFORE its body
        // runs when TCC calls it off-main. Once inside, hop to the main queue
        // to touch the controller's UI-facing state.
        SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authStatus == .authorized else {
                    self.state = .denied
                    return
                }
                self.requestMicrophoneAccess()
            }
        }
    }

    private func requestMicrophoneAccess() {
        // Same @Sendable boundary as the TCC callback above: AVFoundation
        // does not promise a main-actor callback.
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .denied
                    return
                }
                self.beginListening()
            }
        }
    }

    private func beginListening() {
        // If the session was cancelled while the permission prompt was up,
        // don't quietly start the engine anyway.
        guard state == .requestingPermission else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }
        // A stale tap from a session that ended uncleanly (engine start
        // threw, or the app never got a matching stop) would otherwise crash
        // the next installTap with "tap already installed."
        audioEngine.inputNode.removeTap(onBus: 0)

        committed = ""
        stopping = false
        errorStreak = 0
        triedOnDeviceFallback = false

        // The engine + tap are set up ONCE and feed the box; the recognition
        // request underneath rotates for long-form continuation.
        let first = makeRequest()
        let box = V2SpeechRequestBox(first)
        self.requestBox = box
        self.request = first
        let tapState = V2AudioTapState()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            box.append(buffer)
            // Cheap RMS on the audio thread; hop to main only every ~3rd
            // buffer to drive the level meter without flooding the runloop.
            let rms = V2DictationController.rms(of: buffer)
            tapState.counter &+= 1
            if tapState.counter % 3 == 0 {
                DispatchQueue.main.async { self?.ingestLevel(rms) }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.request = nil
            self.requestBox = nil
            state = .unavailable
            return
        }

        // If the audio route reconfigures mid-session, the engine halts — end
        // cleanly (text kept) rather than leaving a frozen meter.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .listening else { return }
                self.stopping = true
                self.teardown()
            }
        }

        startedAt = Date()
        state = .listening
        startTask(for: first)
    }

    /// Build a recognition request. Server-based by default (materially more
    /// accurate, and free — Apple only rate-limits it, which long-form
    /// rotation stays under); `useOnDevice` flips it after an offline
    /// fallback. Punctuation on so a rant reads like prose, not a run-on.
    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if useOnDevice, recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        return request
    }

    private func startTask(for request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer else { return }
        generation &+= 1
        let gen = generation
        task?.cancel()
        // Results arrive on an arbitrary queue; keep this @Sendable and carry
        // only Sendable values over the hop to the main actor.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let errored = error != nil
            DispatchQueue.main.async {
                self?.handleResult(generation: gen, transcript: transcript, isFinal: isFinal, errored: errored)
            }
        }
    }

    private func handleResult(generation gen: Int, transcript: String?, isFinal: Bool, errored: Bool) {
        guard state == .listening, gen == generation else { return }

        if let t = transcript, !t.isEmpty {
            errorStreak = 0
            if isFinal {
                commit(t)
                onUpdate?(composed(partial: ""))
            } else {
                onUpdate?(composed(partial: t))
            }
        }

        if errored {
            handleError()
            return
        }
        if isFinal {
            // A `final` is a SEGMENT boundary (a pause, or the ~1-min server
            // cap), NOT the end of dictation — rotate into a fresh request and
            // keep listening. Only a user stop ends it.
            if stopping { teardown() } else { rotate() }
        }
    }

    /// Start a fresh request under the still-running engine so dictation
    /// continues seamlessly.
    private func rotate() {
        guard let box = requestBox, state == .listening else { teardown(); return }
        let next = makeRequest()
        box.swap(next)
        self.request = next
        startTask(for: next)
    }

    private func handleError() {
        // Offline / server unreachable before we've captured anything → fall
        // back to on-device once and keep going, so the rant isn't lost.
        if committed.isEmpty, !triedOnDeviceFallback, !useOnDevice,
           recognizer?.supportsOnDeviceRecognition == true, !stopping {
            triedOnDeviceFallback = true
            useOnDevice = true
            rotate()
            return
        }
        errorStreak += 1
        // One benign segment-boundary error is fine to rotate through; a
        // second consecutive one means recognition is actually failing.
        if stopping || errorStreak >= 2 {
            teardown()
        } else {
            rotate()
        }
    }

    private func commit(_ segment: String) {
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        committed = committed.isEmpty ? s : committed + " " + s
    }

    /// Compose the visible draft: the pre-dictation base, then every
    /// finalised segment, then the live partial — joined without doubling
    /// spaces or clobbering the user's original text.
    private func composed(partial: String) -> String {
        var out = dictationBase
        func append(_ piece: String) {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { return }
            if out.isEmpty {
                out = p
            } else if out.hasSuffix(" ") || out.hasSuffix("\n") {
                out += p
            } else {
                out += " " + p
            }
        }
        append(committed)
        append(partial)
        return out
    }

    /// Root-mean-square amplitude of a mic buffer's first channel. Pure math,
    /// safe to call off the main actor from the tap.
    nonisolated static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n {
            let s = channel[i]
            sum += s * s
        }
        return (sum / Float(n)).squareRoot()
    }

    /// Map raw RMS to a smoothed 0…1 display level. Speech RMS sits around
    /// 0.02–0.15, so a gain lifts it into a lively range; the EMA keeps the
    /// bars from strobing on every frame.
    private func ingestLevel(_ rms: Float) {
        guard state == .listening else { return }
        let scaled = min(1, rms * 14)
        mic.level = mic.level * 0.55 + scaled * 0.45
    }

    /// Hard-stop immediately, without waiting for a closing `final`. Used when
    /// the composer sends: the draft already holds everything spoken, and we
    /// must not let a late transcript repopulate the field after it's cleared.
    func cancel() {
        guard state == .listening || state == .requestingPermission else { return }
        stopping = true
        teardown()
    }

    func stop() {
        guard state == .listening else { return }
        stopping = true
        // endAudio() lets the recognizer finish honestly (last partial becomes
        // final) rather than snapping the socket shut mid-word; the final then
        // lands in handleResult, which tears down because `stopping` is set.
        request?.endAudio()
        // Safety net: if that closing `final` never arrives (a wedged task),
        // don't strand the UI in .listening forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.stopping, self.state == .listening else { return }
            self.teardown()
        }
    }

    private func teardown() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        requestBox = nil
        mic.level = 0
        startedAt = nil
        stopping = false
        committed = ""
        if state == .listening || state == .requestingPermission { state = .idle }
    }
}

struct V2ComposerDictationButton: View {
    @Environment(\.v2) private var v2
    @ObservedObject var controller: V2DictationController
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: handleTap) {
            content
                .padding(.horizontal, controller.state == .listening ? 9 : 8)
                .padding(.vertical, 6)
                .overlay(
                    Rectangle().stroke(
                        controller.state == .listening ? v2.del.opacity(0.6) : v2.line2,
                        lineWidth: 1
                    )
                )
                .background(controller.state == .listening ? v2.delBg : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        // Only the brief permission round-trip is non-interactive. Denied /
        // unavailable stay tappable so the tap can open System Settings
        // instead of dead-ending on a greyed button.
        .disabled(!enabled || controller.state == .requestingPermission)
        .animation(.easeOut(duration: 0.16), value: controller.state)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .listening:
            // Live, unmistakable "I'm hearing you": pulsing dot + real
            // waveform driven by the mic level + elapsed time.
            HStack(spacing: 7) {
                V2PulseDot(size: 6, color: v2.del)
                V2MicLevelMeter(mic: controller.mic)
                if let started = controller.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text(Self.elapsed(since: started, now: ctx.date))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(v2.del)
                            .monospacedDigit()
                    }
                }
            }
        case .requestingPermission:
            // Breathing, not dead-grey, so the tap clearly registered.
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(v2.ink)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
        case .denied, .unavailable:
            Image(systemName: "mic.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(v2.del.opacity(0.85))
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(v2.mute)
        }
    }

    private func handleTap() {
        switch controller.state {
        case .denied, .unavailable:
            openPrivacySettings()
        default:
            action()
        }
    }

    /// Deep-links to the Microphone pane of System Settings → Privacy so a
    /// denied mic is one tap from fixable, not a silent no-op.
    private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var helpText: String {
        switch controller.state {
        case .listening: return "Stop dictating"
        case .denied: return "Microphone or speech access is off — click to open System Settings → Privacy"
        case .unavailable: return "Dictation isn't available right now — click to check System Settings"
        case .requestingPermission: return "Waiting for permission…"
        case .idle: return "Dictate (speech-to-text)"
        }
    }
}

/// A compact live waveform: a short scrolling history of the mic level. Only
/// this view observes V2MicLevel, so its ~14 fps refresh never touches the
/// composer around it. Sharp bars, per the app's rectilinear language.
struct V2MicLevelMeter: View {
    @Environment(\.v2) private var v2
    @ObservedObject var mic: V2MicLevel
    private static let barCount = 9
    @State private var bars: [CGFloat] = Array(repeating: 0.06, count: 9)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { i in
                Rectangle()
                    .fill(v2.del)
                    .frame(width: 2.5, height: 3 + bars[i] * 13)
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.09), value: bars)
        .onChange(of: mic.level) { _, level in
            var next = bars
            next.removeFirst()
            next.append(CGFloat(min(1, max(0, level))))
            bars = next
        }
    }
}
