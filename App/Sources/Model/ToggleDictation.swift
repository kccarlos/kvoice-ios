import Foundation
import KVoiceKit
import UIKit

/// Toggle Dictation (Action Button, Control, Live Activity Stop): one press
/// starts, the next stops and returns the text. See `Docs/DictationStates.md`.
extension AppModel {
    private static let log = DiagnosticsLog.shared

    /// - Parameters:
    ///   - modeID: The intent's Mode parameter.
    ///   - isForeground: The intent runs in the foreground.
    ///   - continueInForeground: Asks the system to bring KVoice to the
    ///     front with a reason (throws when declined).
    /// - Returns: The text when stopping; `""` when starting.
    func toggleDictation(
        modeID: UUID?,
        isForeground: Bool,
        continueInForeground: @MainActor (String) async throws -> Void
    ) async throws -> String {
        switch handoff.activity.toggleRoute(now: .now) {
        case .start:
            try await startToggleDictation(
                modeID: modeID, isForeground: isForeground, continueInForeground: continueInForeground
            )
            return ""
        case .stop:
            return try await stopToggleDictation(isForeground: isForeground, continueInForeground: continueInForeground)
        case .blocked(let message):
            Self.log.append(category: "intent", "blocked")
            throw AudioJobError.failed(message)
        }
    }

    // MARK: Start

    private func startToggleDictation(
        modeID: UUID?,
        isForeground: Bool,
        continueInForeground: @MainActor (String) async throws -> Void
    ) async throws {
        let strategy = ToggleStartStrategy.current()
        let foreground = isForeground || UIApplication.shared.applicationState == .active
        Self.log.append(category: "intent", "start fg=\(foreground) strategy=\(strategy.rawValue)")

        // 1. The Live Activity comes first, before any other await: audio
        // recording intents must start one, and a request needs the app to
        // still count as the target. Modes are not reloaded yet, so the name
        // may be stale; the first update corrects it.
        var sessionID = UUID()
        let early = modeID.flatMap(modes.mode(id:)) ?? modes.activeMode
        liveActivity.start(sessionID: sessionID, modeName: early.name, modeIcon: early.icon)

        // 2. Then reload and start the recorder.
        modes.reload()
        settings.reload()
        if let modeID, modes.mode(id: modeID) != nil {
            try? modes.setActiveMode(id: modeID)
        }
        let mode = modes.activeMode
        var rejection = await handoff.requestAppRecording(source: .actionButton, mode: mode, sessionID: sessionID)
        var started = pipeline.isRecording
        Self.log.append(category: "intent", "recorder started=\(started) rejected=\(rejection != nil)")

        // 3. Fallback: the microphone could not start in the background.
        if rejection == nil, !started, !foreground {
            liveActivity.end(sessionID: sessionID)
            Self.log.append(category: "intent", "fallback.foreground")
            do {
                try await continueInForeground("Start dictating in KVoice?")
            } catch {
                Self.log.append(category: "intent", "fallback.declined")
                throw AudioJobError.failed("Dictation did not start. Open KVoice to try again.")
            }
            sessionID = UUID()
            liveActivity.start(sessionID: sessionID, modeName: mode.name, modeIcon: mode.icon)
            rejection = await handoff.requestAppRecording(source: .actionButton, mode: mode, sessionID: sessionID)
            started = pipeline.isRecording
            Self.log.append(category: "intent", "fallback started=\(started) rejected=\(rejection != nil)")
        }

        guard started else {
            liveActivity.end(sessionID: sessionID)
            if case .failed(let error) = pipeline.phase {
                throw AudioJobError.failed(error.localizedDescription)
            }
            throw AudioJobError.failed(rejection ?? "Dictation did not start.")
        }

        // 4. `holdUntilStopped` keeps `perform` running while the recording
        // lasts, in case iOS only lends the microphone to a running intent.
        if strategy == .holdUntilStopped {
            let deadline = Date.now.addingTimeInterval(10 * 60)
            while Date.now < deadline, !Task.isCancelled, isRecordingToggleSession(sessionID) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            Self.log.append(category: "intent", "hold ended cancelled=\(Task.isCancelled)")
        }
    }

    private func isRecordingToggleSession(_ sessionID: UUID) -> Bool {
        handoff.activity.id == sessionID && handoff.effectivePhase.recordingOwner == .app
    }

    // MARK: Stop

    private func stopToggleDictation(
        isForeground: Bool,
        continueInForeground: @MainActor (String) async throws -> Void
    ) async throws -> String {
        let foreground = isForeground || UIApplication.shared.applicationState == .active
        let duration = pipeline.recordedDuration
        Self.log.append(category: "intent", "stop fg=\(foreground) seconds=\(Int(duration))")

        if !foreground {
            let mode = pipeline.recordingMode ?? modes.activeMode
            let selection = settings.settings.engine(for: mode)
            let whisperLoaded = await engineFactory.isWhisperModelLoaded(selection)
            let speechInstalled = AppleSpeechEngine.isAvailable
                ? await AppleSpeechEngine.assetStatus(language: mode.language) == .installed
                : false
            let plan = BackgroundBudget.plan(BackgroundBudget.Inputs(
                engine: selection.kind,
                audioDuration: duration,
                whisperModelLoaded: whisperLoaded,
                appleSpeechInstalled: speechInstalled,
                usesAI: mode.usesAI,
                isForeground: false
            ))
            Self.log.append(category: "intent", "budget plan=\(plan)")
            if plan == .continueInForeground {
                do {
                    try await continueInForeground("Finish this dictation in KVoice?")
                } catch {
                    // The recording keeps running; press again to retry.
                    Self.log.append(category: "intent", "stop.declined")
                    throw AudioJobError.failed("Still recording. Press again, or open KVoice to finish.")
                }
            }
        }

        let result = await handoff.stopAppRecording()
        guard let text = result?.text, !text.isEmpty else {
            if case .failed(let error) = pipeline.phase {
                Self.log.append(category: "intent", "stop failed")
                throw AudioJobError.failed(error.localizedDescription)
            }
            Self.log.append(category: "intent", "stop noSpeech")
            throw AudioJobError.noSpeech
        }

        // The clipboard may refuse a background write; the changeCount tells.
        let board = UIPasteboard.general
        let before = board.changeCount
        board.string = text
        Self.log.append(
            category: "intent",
            "stop done chars=\(text.count) pasteboardAdvanced=\(board.changeCount != before)"
        )
        return text
    }
}
