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
import Foundation
import Speech
import SwiftUI

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
        // Plain GCD, not `Task { @MainActor in }`: this completion handler
        // is TCC's own XPC reply callback, not a Swift-concurrency-aware
        // context — hopping back to the main actor via structured
        // concurrency here hits a hard runtime trap (verified via crash
        // report, 2026-07-22: swift_task_isCurrentExecutorWithFlagsImpl →
        // dispatch_assert_queue_fail, instantly, on every call). DispatchQueue
        // makes no isolation assumption about the calling thread, so it's
        // safe regardless of which queue TCC actually calls back on.
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authStatus == .authorized else {
                    self.state = .denied
                    return
                }
                self.requestMicrophoneAccess(recognizer: recognizer)
            }
        }
    }

    private func requestMicrophoneAccess(recognizer: SFSpeechRecognizer) {
        // Same reasoning as requestAuthorization above — AVCaptureDevice's
        // completion handler is not guaranteed to land on the main thread.
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .denied
                    return
                }
                self.beginListening(recognizer: recognizer)
            }
        }
    }

    private func beginListening(recognizer: SFSpeechRecognizer) {
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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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

        state = .listening
        // Same reasoning as the two requests above — SFSpeechRecognitionTask's
        // result handler is documented to be called back on an arbitrary
        // queue, not guaranteed to be the main thread.
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.deliver(result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    self.teardown()
                }
            }
        }
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
        if state == .listening || state == .requestingPermission { state = .idle }
    }
}

struct V2ComposerDictationButton: View {
    @Environment(\.v2) private var v2
    @ObservedObject var controller: V2DictationController
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: controller.state == .listening ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(iconColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(
                    Rectangle().stroke(
                        controller.state == .listening ? v2.del.opacity(0.6) : v2.line2,
                        lineWidth: 1
                    )
                )
                .background(controller.state == .listening ? v2.delBg : Color.clear)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .disabled(!enabled || controller.state == .requestingPermission)
    }

    private var iconColor: Color {
        switch controller.state {
        case .listening: return v2.del
        case .denied, .unavailable: return v2.mute.opacity(0.5)
        default: return v2.mute
        }
    }

    private var helpText: String {
        switch controller.state {
        case .listening: return "Stop dictating"
        case .denied: return "Dictation needs microphone and speech-recognition access — check System Settings → Privacy & Security"
        case .unavailable: return "Dictation isn't available right now"
        case .requestingPermission: return "Waiting for permission…"
        case .idle: return "Dictate (speech-to-text)"
        }
    }
}
