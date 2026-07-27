// Voice input for the composer (design: "Voice input.dc.html"). Speech does
// the recognition, AVAudioEngine feeds it raw mic buffers. Shared across both
// providers the same way V2AttachmentStore is — one controller instance per
// composer, not a global singleton, so two tabs dictating at once (unlikely
// but possible) never fight over one AVAudioEngine.
//
// Two interaction modes, per the design:
//   • push-to-talk — hold the mic (or hold ⌥); RELEASE sends the turn.
//   • hands-free  — tap the mic to start, tap again to stop; lands in the
//                   composer for review (you hit ⏎), never auto-sends.
// Recognised words stream into a live CAPTION STRIP above the composer, not
// into the draft — the draft only takes the text once dictation finishes, so
// a half-heard partial never clobbers what you typed. A "barge-in" (starting
// voice while the agent is working) interrupts the running turn so your
// correction becomes the next message.
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
/// re-render ONLY the tiny caption dot — never the whole composer or even the
/// caption strip's words. The dictation controller holds this as a plain
/// `let`, so its own objectWillChange stays low-frequency (state transitions
/// only), honouring the "don't fan out high-frequency @Published" rule in
/// PERFORMANCE.md.
final class V2MicLevel: ObservableObject {
    /// Smoothed 0…1 amplitude. 0 when idle.
    @Published var level: Float = 0
}

/// A System Settings privacy pane to deep-link to when a permission is off.
/// Microphone and Speech Recognition are DIFFERENT toggles — sending someone
/// to the wrong one is the crux of the "I can't find where to allow it"
/// confusion, so the denial state tracks which pane it means.
enum V2PrivacyPane {
    case microphone, speechRecognition

    var settingsURL: URL {
        let anchor = self == .microphone ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    }
}

@MainActor
final class V2DictationController: ObservableObject {
    /// How the current (or most recent) session was initiated — decides what
    /// finishing does: PTT release sends, hands-free lands for review.
    enum Mode { case pushToTalk, handsFree }

    enum State: Equatable {
        case idle
        case requestingPermission
        /// Recording. `mode` says push-to-talk vs hands-free.
        case listening
        /// The brief window after the user stops, while the recogniser turns
        /// the last audio into a final transcript ("cleaning up what you
        /// said…").
        case transcribing
        /// Microphone access denied — banner + button open the Microphone
        /// pane of System Settings.
        case micDenied
        /// Speech Recognition access denied — a SEPARATE toggle from the mic
        /// (the classic confusion); opens the Speech Recognition pane.
        case speechDenied
        /// No recognizer for this locale, or the engine failed to start.
        case unavailable
        /// Stopped, but nothing was recognised (silence / bad input).
        case noSpeech
        /// Recognition errored out (e.g. the connection dropped).
        case failed

        var isDenied: Bool { self == .micDenied || self == .speechDenied }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var mode: Mode = .handsFree
    /// The spoken text so far THIS session (finalised segments + the live
    /// partial), shown in the caption strip. Never includes the pre-existing
    /// draft; that's composed back in only when the text lands.
    @Published private(set) var caption: String = ""
    /// True when this session began by interrupting a working turn — used to
    /// label the caption ("interrupted · …") and to keep barge-in from
    /// auto-sending into a session that's still tearing its turn down.
    @Published private(set) var didInterrupt = false

    /// Live mic amplitude, on a separate object so its high-frequency updates
    /// only re-render the caption dot. See V2MicLevel.
    let mic = V2MicLevel()

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// The live tap → request bridge. Persists across request rotations so a
    /// long rant continues seamlessly past the recognizer's ~1-minute server
    /// cap and past every natural pause (each of which the recognizer reports
    /// as a `final`).
    private var requestBox: V2SpeechRequestBox?
    private var task: SFSpeechRecognitionTask?

    /// The draft as it stood when dictation started — never mutated during a
    /// session; dictated text is composed on top of it when it lands.
    private var dictationBase = ""
    /// Finalised segments accumulated this session (across rotations). The
    /// live partial from the current request is appended after this.
    private var committed = ""
    /// Set when the user finishes; the next `final` then finalises instead of
    /// rotating into a new request.
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
    /// rotation can't cascade into spurious extra rotations. The finish
    /// safety-timer also gates on it so a stale timer can't finalise twice.
    private var generation = 0
    /// Observes AVAudioEngine I/O reconfiguration (e.g. the input device
    /// changes when you plug in AirPods). The engine stops feeding buffers on
    /// such a change; without handling it the meter freezes and words silently
    /// stop landing. We finish the session cleanly instead.
    private var configObserver: NSObjectProtocol?

    /// Called with the full draft text (pre-dictation base + everything
    /// spoken) when dictation finishes with real speech. The composer owns
    /// `draft`; this controller never touches it directly.
    var onUpdate: ((String) -> Void)?
    /// Push-to-talk's release-to-send: fired after `onUpdate` lands the text,
    /// only for a normal (non-barge-in) PTT session. The composer wires this
    /// to its send action.
    var onSubmit: (() -> Void)?
    /// Whether the agent is currently working — the composer supplies this so
    /// starting voice mid-turn can interrupt (barge-in).
    var canBargeIn: (() -> Bool)?
    /// Interrupt the running turn (the composer wires `session.interrupt`).
    var onBargeIn: (() -> Void)?

    init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    var isListening: Bool { state == .listening }
    /// The error states that surface a banner above the composer.
    var showsErrorBanner: Bool { state.isDenied || state == .noSpeech || state == .failed }
    /// Which System Settings pane the current denial points at (nil unless
    /// we're in a denied state).
    var deniedPane: V2PrivacyPane? {
        switch state {
        case .micDenied:    return .microphone
        case .speechDenied: return .speechRecognition
        default:            return nil
        }
    }

    // MARK: - Gestures (called by the mic button and the ⌥ accelerator)

    /// A quick tap: hands-free. Toggles listening on/off.
    func tap(currentDraft: String) {
        switch state {
        case .listening:
            finish()
        case .requestingPermission, .transcribing:
            break   // busy — ignore
        default:
            start(mode: .handsFree, currentDraft: currentDraft)
        }
    }

    /// Press-and-hold began (mic held, or ⌥ held alone): push-to-talk.
    func holdStart(currentDraft: String) {
        guard state == .idle || state == .noSpeech || state == .failed else { return }
        start(mode: .pushToTalk, currentDraft: currentDraft)
    }

    /// Press-and-hold released: finish a push-to-talk session (release-to-send).
    func holdEnd() {
        guard state == .listening, mode == .pushToTalk else { return }
        finish()
    }

    /// The error-banner "try again" / "retry" action — listen again, reusing
    /// the current draft as the base.
    func retry(currentDraft: String) {
        guard state == .noSpeech || state == .failed else { return }
        start(mode: .handsFree, currentDraft: currentDraft)
    }

    // MARK: - Lifecycle

    private func start(mode: Mode, currentDraft: String) {
        guard state != .listening, state != .requestingPermission, state != .transcribing else { return }
        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable
            return
        }
        // Barge-in: starting voice while the agent is working interrupts it so
        // your correction becomes the next turn instead of racing the stream.
        didInterrupt = false
        if canBargeIn?() == true {
            didInterrupt = true
            onBargeIn?()
        }
        self.mode = mode
        dictationBase = currentDraft
        caption = ""
        state = .requestingPermission
        // Request the MICROPHONE first. This is the call that registers the
        // app in System Settings ▸ Privacy ▸ Microphone, so it fires even when
        // Speech Recognition turns out to be the real blocker. (Asking for
        // Speech first — as this did before — meant a denied/blocked Speech
        // grant returned early and the mic was NEVER requested: the app never
        // appeared in the mic list, and the "off" banner pointed at the wrong
        // pane.) Speech authorization follows only once the mic is granted.
        //
        // TCC/AVFoundation invoke these completions on their own queues, and
        // the closures must be explicitly @Sendable: otherwise Swift 6
        // inherits this class's @MainActor isolation at closure creation and
        // traps BEFORE the body runs when called off-main. Hop to main inside.
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .micDenied
                    return
                }
                self.requestSpeechAuthorization()
            }
        }
    }

    private func requestSpeechAuthorization() {
        // Bail if the session was cancelled while the mic prompt was up.
        guard state == .requestingPermission else { return }
        SFSpeechRecognizer.requestAuthorization { @Sendable [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authStatus == .authorized else {
                    self.state = .speechDenied
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
        // A stale tap from a session that ended uncleanly (engine start threw,
        // or the app never got a matching stop) would otherwise crash the next
        // installTap with "tap already installed."
        audioEngine.inputNode.removeTap(onBus: 0)

        committed = ""
        stopping = false
        errorStreak = 0
        useOnDevice = false
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
        // Guard the tap format. A 0 Hz / 0-channel format (input device not
        // ready, or mic access still settling right after the grant) makes
        // installTap throw an Objective-C exception — which Swift CANNOT catch,
        // so it takes the whole app down. This was a real crash-and-lose-work
        // path; fail soft to .unavailable instead of installing a bad tap.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            self.requestBox = nil
            state = .unavailable
            return
        }
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
                self.finish()
            }
        }

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
        guard state == .listening || state == .transcribing, gen == generation else { return }

        if let t = transcript, !t.isEmpty {
            errorStreak = 0
            if isFinal {
                commit(t)
                caption = Self.joined("", committed)
            } else {
                caption = Self.joined("", committed, t)
            }
        }

        if errored {
            handleError()
            return
        }
        if isFinal {
            // A `final` is a SEGMENT boundary (a pause, or the ~1-min server
            // cap), NOT the end of dictation — rotate into a fresh request and
            // keep listening. Only a user stop (`stopping`) finalises.
            if stopping { finalize() } else { rotate() }
        }
    }

    /// Start a fresh request under the still-running engine so dictation
    /// continues seamlessly.
    private func rotate() {
        guard let box = requestBox, state == .listening else { finalize(); return }
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
        if stopping {
            // The user already finished — land whatever we captured, or fail.
            finalize()
            return
        }
        // One benign segment-boundary error is fine to rotate through; a
        // second consecutive one means recognition is actually failing.
        if errorStreak >= 2 {
            teardownEngine()
            resetScratch()
            caption = ""
            state = .failed
        } else {
            rotate()
        }
    }

    /// User finished (PTT release, hands-free tap-to-stop, or a mid-session
    /// route change). Ask the recogniser to close honestly (last partial →
    /// final) rather than snapping the socket shut mid-word; the final lands
    /// in handleResult, which finalises because `stopping` is set.
    private func finish() {
        guard state == .listening else { return }
        stopping = true
        state = .transcribing
        request?.endAudio()
        // Safety net: if that closing `final` never arrives (a wedged task),
        // don't strand the UI in .transcribing forever — finalise what we have.
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.state == .transcribing, self.generation == gen else { return }
            self.finalize()
        }
    }

    /// End of a session: land the text (or surface "no speech"), then decide
    /// send vs review. Idempotent via the state guard — the closing final and
    /// the safety timer can both call it; only the first wins.
    private func finalize() {
        guard state == .transcribing || state == .listening else { return }
        let hadSpeech = !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ptt = mode == .pushToTalk
        let interrupted = didInterrupt
        teardownEngine()
        caption = ""

        guard hadSpeech else {
            resetScratch()
            state = .noSpeech
            return
        }

        onUpdate?(Self.joined(dictationBase, committed))
        resetScratch()
        state = .idle
        // Release-to-send — but NOT for a barge-in: the interrupted turn is
        // still tearing down, so canSend would be false and the send would
        // silently drop. Barge-in lands the correction for review instead.
        if ptt && !interrupted {
            onSubmit?()
        }
    }

    private func commit(_ segment: String) {
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        committed = committed.isEmpty ? s : committed + " " + s
    }

    /// Join `base` with each following piece without doubling spaces or
    /// clobbering the base's trailing whitespace/newline. Shared by the draft
    /// composition (base + spoken) and the caption (spoken only, base "").
    private static func joined(_ base: String, _ pieces: String...) -> String {
        var out = base
        for piece in pieces {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty else { continue }
            if out.isEmpty {
                out = p
            } else if out.hasSuffix(" ") || out.hasSuffix("\n") {
                out += p
            } else {
                out += " " + p
            }
        }
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
    /// dot from strobing on every frame.
    private func ingestLevel(_ rms: Float) {
        guard state == .listening else { return }
        let scaled = min(1, rms * 14)
        mic.level = mic.level * 0.55 + scaled * 0.45
    }

    /// Hard-stop immediately, without waiting for a closing `final`. Used when
    /// the composer sends: the draft already holds everything spoken, and we
    /// must not let a late transcript repopulate the field after it's cleared.
    func cancel() {
        guard state == .listening || state == .requestingPermission || state == .transcribing else { return }
        stopping = true
        teardownEngine()
        resetScratch()
        caption = ""
        state = .idle
    }

    /// Legacy name kept for one external caller path; folds into cancel.
    func stop() { cancel() }

    /// Stop audio + recognition, but leave `state`/scratch to the caller.
    private func teardownEngine() {
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
    }

    private func resetScratch() {
        committed = ""
        stopping = false
        errorStreak = 0
        triedOnDeviceFallback = false
        useOnDevice = false
        didInterrupt = false
    }
}

// MARK: - Mic button

/// The composer's mic control. Rectilinear (the app stays sharp-cornered; the
/// design's round button is the mechanic, not the geometry). A quick tap
/// toggles hands-free dictation; a press-and-hold is push-to-talk that sends
/// on release. Denied/unavailable stay tappable and deep-link to System
/// Settings instead of dead-ending on a greyed button.
struct V2ComposerDictationButton: View {
    @Environment(\.v2) private var v2
    @ObservedObject var controller: V2DictationController
    let enabled: Bool
    let onTap: () -> Void
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void

    /// Below this, a press counts as a tap; at or beyond it, a hold (PTT).
    private static let holdThreshold: TimeInterval = 0.2

    @State private var pressing = false
    @State private var engaged = false
    @State private var pressGen = 0

    private var isBlocked: Bool { controller.state.isDenied || controller.state == .unavailable }
    private var isActive: Bool { controller.state == .listening }

    var body: some View {
        control
            .help(helpText)
            .animation(.easeOut(duration: 0.16), value: controller.state)
    }

    // Branch by state so there's never a DragGesture and a tap gesture layered
    // on the same view (they race in SwiftUI): blocked → a plain Settings
    // button; interactive → the press/hold gesture; disabled → inert + dimmed.
    @ViewBuilder
    private var control: some View {
        if isBlocked {
            Button(action: openPrivacySettings) { micShape }
                .buttonStyle(.plain)
        } else if enabled {
            micShape
                .contentShape(Rectangle())
                .gesture(pressGesture)
        } else {
            micShape.opacity(0.4)
        }
    }

    private var micShape: some View {
        Image(systemName: isBlocked ? "mic.slash" : "mic")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(iconColor)
            .frame(width: 32, height: 32)
            .background(isActive ? v2.del : Color.clear)
            .overlay(Rectangle().stroke(borderColor, lineWidth: 1))
    }

    private var iconColor: Color {
        if isActive { return v2.card }
        if isBlocked { return v2.del.opacity(0.85) }
        return v2.mute
    }

    private var borderColor: Color {
        if isActive { return v2.del }
        if isBlocked { return v2.del.opacity(0.5) }
        return v2.line2
    }

    // A single drag (minimumDistance 0) is the press: it fires onChanged the
    // instant the mouse goes down and onEnded on release. A short timer
    // promotes a sustained press to a hold; a release before that is a tap.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard enabled, !isBlocked, !pressing else { return }
                pressing = true
                engaged = false
                pressGen += 1
                let gen = pressGen
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold) {
                    guard pressing, pressGen == gen, !engaged else { return }
                    engaged = true
                    onHoldStart()
                }
            }
            .onEnded { _ in
                guard pressing else { return }
                pressing = false
                if engaged {
                    engaged = false
                    onHoldEnd()
                } else {
                    // Released before the hold threshold → a tap.
                    onTap()
                }
            }
    }

    private func openPrivacySettings() {
        // Open the pane for whichever permission is actually off (mic vs
        // speech), defaulting to Microphone if we're here for another reason.
        NSWorkspace.shared.open((controller.deniedPane ?? .microphone).settingsURL)
    }

    private var helpText: String {
        switch controller.state {
        case .listening:
            return controller.mode == .pushToTalk ? "Release to send" : "Tap to stop dictating"
        case .transcribing:      return "Transcribing…"
        case .micDenied:         return "Microphone access is off — click to open System Settings ▸ Microphone"
        case .speechDenied:      return "Speech Recognition is off — click to open System Settings ▸ Speech Recognition"
        case .unavailable:       return "Dictation isn't available right now — click to check System Settings"
        case .requestingPermission: return "Waiting for permission…"
        case .noSpeech, .failed, .idle:
            return "Tap to dictate hands-free · hold (or hold ⌥) to push-to-talk"
        }
    }
}

// MARK: - Live caption strip

/// The recording caption above the composer (design: "Voice input.dc.html").
/// Shows the words as they land plus a voice-reactive dot and a blinking
/// caret, with a hint that reflects how to finish. Words live in the draft
/// only after finishing; this strip is the live surface until then.
struct V2VoiceCaptionStrip: View {
    @Environment(\.v2) private var v2
    @ObservedObject var controller: V2DictationController

    var body: some View {
        HStack(spacing: 9) {
            V2CaptionPulseDot(mic: controller.mic, recording: controller.state == .listening)
            HStack(spacing: 5) {
                Text(controller.caption.isEmpty ? "listening…" : controller.caption)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(controller.caption.isEmpty ? v2.faint : v2.ink)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if controller.state == .listening {
                    V2BlinkingCaret()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(hint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(v2.delBg)
        .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: controller.caption)
    }

    private var hint: String {
        if controller.state == .transcribing { return "transcribing…" }
        let prefix = controller.didInterrupt ? "interrupted · " : ""
        return prefix + (controller.mode == .pushToTalk ? "release to send" : "tap mic to stop")
    }
}

/// The caption's recording dot, sized/faded by live mic amplitude. Its OWN
/// view so the ~14 fps mic updates re-render only this 7pt circle, never the
/// caption words beside it (PERFORMANCE.md: scope high-frequency observation).
struct V2CaptionPulseDot: View {
    @Environment(\.v2) private var v2
    @ObservedObject var mic: V2MicLevel
    let recording: Bool

    var body: some View {
        let level = CGFloat(min(1, max(0, mic.level)))
        Circle()
            .fill(v2.del)
            .frame(width: 7, height: 7)
            .opacity(recording ? Double(0.35 + 0.65 * level) : 0.5)
            .scaleEffect(recording ? 0.85 + 0.5 * level : 1)
            .animation(.linear(duration: 0.09), value: mic.level)
    }
}

/// A soft blinking caret at the end of the live caption.
struct V2BlinkingCaret: View {
    @Environment(\.v2) private var v2
    @State private var dim = false

    var body: some View {
        Rectangle()
            .fill(v2.del)
            .frame(width: 2, height: 13)
            .opacity(dim ? 0 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Error banner

/// The denied / no-speech / failed banner above the composer, each with a
/// single actionable button (open settings / try again / retry).
struct V2VoiceErrorBanner: View {
    @Environment(\.v2) private var v2
    @ObservedObject var controller: V2DictationController
    /// Fired by the action button; the composer dispatches on the state
    /// (denied → System Settings, else → retry with the current draft).
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(icon)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(v2.del)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onAction) {
                Text(actionLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.del)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(v2.delBg)
        .overlay(Rectangle().stroke(v2.del, lineWidth: 1))
    }

    private var icon: String {
        switch controller.state {
        case .micDenied, .speechDenied: return "⊘"
        case .noSpeech: return "…"
        default:        return "✗"
        }
    }

    private var text: String {
        switch controller.state {
        case .micDenied:
            return "Microphone access is off for Atelier — turn it on to dictate."
        case .speechDenied:
            return "Speech Recognition is off for Atelier — it turns your voice into text (a separate toggle from the mic)."
        case .noSpeech:
            return "Didn't catch anything — check your mic input, or just type instead."
        default:
            return "Couldn't transcribe that — the connection may have dropped."
        }
    }

    private var actionLabel: String {
        switch controller.state {
        case .micDenied, .speechDenied: return "open system settings"
        case .noSpeech: return "try again"
        default:        return "retry"
        }
    }
}

// MARK: - ⌥ push-to-talk accelerator

/// Hold ⌥ (Option) alone to push-to-talk, per the design's "hold ⌥ to talk".
/// Deliberately conservative so it never eats ⌥+key text navigation (⌥←/→,
/// ⌥⌫): it only engages when Option is held ALONE past a short threshold with
/// no other key pressed, and aborts the instant any key or extra modifier
/// arrives. Local NSEvent monitors fire only while this app is active, and the
/// composer installs/removes them on appear/disappear — so exactly one is live.
struct V2OptionPushToTalk: ViewModifier {
    let enabled: Bool
    let engage: () -> Void
    let release: () -> Void

    @State private var coordinator = V2OptionPTTCoordinator()

    func body(content: Content) -> some View {
        content
            .onAppear {
                coordinator.engage = engage
                coordinator.release = release
                coordinator.enabled = enabled
                coordinator.install()
            }
            .onDisappear { coordinator.uninstall() }
            .onChange(of: enabled) { _, on in
                coordinator.enabled = on
                if !on { coordinator.cancel() }
            }
    }
}

/// Reference-type state for the ⌥ monitor — NSEvent monitor closures are
/// long-lived and must see live mutable state, which a value-type ViewModifier
/// can't provide. Held via @State so it persists across the composer's
/// re-renders and is created once.
@MainActor
final class V2OptionPTTCoordinator {
    var engage: () -> Void = {}
    var release: () -> Void = {}
    var enabled = false

    private static let armDelay: TimeInterval = 0.2
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var armed = false
    private var engaged = false
    private var armGen = 0

    func install() {
        guard flagsMonitor == nil, keyMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // A key pressed while merely armed means it's an ⌥+key shortcut,
            // not push-to-talk — abort before we ever start recording.
            if let self, self.armed, !self.engaged { self.disarm() }
            return event
        }
    }

    func uninstall() {
        cancel()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor); self.flagsMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    /// Enabled turned off (or the view is going away): stop cleanly, releasing
    /// if we were mid-hold so dictation doesn't dangle.
    func cancel() {
        if engaged { engaged = false; release() }
        disarm()
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags
        let optionOnly = flags.contains(.option)
            && flags.intersection([.command, .control, .shift]).isEmpty

        if optionOnly {
            guard enabled, !armed, !engaged else { return }
            // Arm, then engage only if Option is still down (alone) after the
            // delay and no key interrupted — avoids false starts on shortcuts.
            armed = true
            armGen &+= 1
            let gen = armGen
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.armDelay) { [weak self] in
                guard let self, self.armed, !self.engaged, self.armGen == gen, self.enabled else { return }
                self.armed = false
                self.engaged = true
                self.engage()
            }
        } else if !flags.contains(.option) {
            // Option released.
            if engaged {
                engaged = false
                release()
            } else {
                disarm()
            }
        } else {
            // Option + another modifier → a shortcut, not talk.
            disarm()
        }
    }

    private func disarm() {
        armed = false
        armGen &+= 1
    }
}
