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
    let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
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
    private var task: SFSpeechRecognitionTask?
    /// The draft text as it stood the moment dictation started — every
    /// partial result REPLACES the dictated tail rather than appending to
    /// it, since SFSpeechRecognitionResult.bestTranscription is always the
    /// full accumulated utterance, not a delta.
    private var draftBeforeDictation = ""
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
        draftBeforeDictation = currentDraft
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
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }
        // A stale tap from a session that ended uncleanly (engine start
        // threw, or the app never got a matching stop) would otherwise crash
        // the next installTap with "tap already installed."
        audioEngine.inputNode.removeTap(onBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device recognition when this Mac supports it — audio
        // never leaves the machine, matching the diagnostics work's local-
        // first posture. Falls back to Apple's server-based recognizer
        // automatically when unsupported (older hardware, some locales).
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        let requestBox = V2SpeechRequestBox(request)
        let tapState = V2AudioTapState()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            requestBox.request.append(buffer)
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
            state = .unavailable
            return
        }

        startedAt = Date()
        state = .listening
        // Results also arrive on an arbitrary queue, so this callback must
        // not inherit the controller's main-actor isolation either.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Carry only Sendable values over the queue boundary. Neither
            // SFSpeechRecognitionResult nor NSError is safe to capture in
            // the main-actor closure directly.
            let transcript = result?.bestTranscription.formattedString
            let shouldTeardown = error != nil || result?.isFinal == true
            DispatchQueue.main.async {
                guard let self else { return }
                if let transcript {
                    self.deliver(transcript)
                }
                if shouldTeardown {
                    self.teardown()
                }
            }
        }
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

    private func deliver(_ transcript: String) {
        guard !transcript.isEmpty else {
            onUpdate?(draftBeforeDictation)
            return
        }
        let joined = draftBeforeDictation.isEmpty ? transcript : draftBeforeDictation + " " + transcript
        onUpdate?(joined)
    }

    func stop() {
        request?.endAudio()
        // endAudio() lets the recognizer finish honestly (last partial
        // becomes final) rather than snapping the socket shut mid-word;
        // teardown() itself runs from the recognitionTask completion once
        // that final result lands, not from here.
    }

    private func teardown() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        request = nil
        task?.cancel()
        task = nil
        mic.level = 0
        startedAt = nil
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
