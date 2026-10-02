import Foundation
import KVoiceKit
import Observation

/// The app side of the keyboard handoff.
///
/// 1. The keyboard writes a `HandoffRequest` and opens
///    `kvoice://dictate?session=<id>`. The app starts recording in the
///    request's mode and shows a compact "swipe back" screen.
/// 2. Every pipeline phase is written to the `HandoffResult` for that
///    session; on `.done` the result carries the text for the keyboard to
///    insert.
/// 3. After a keyboard dictation the input engine stays running for the
///    keep-alive window (standby) and `HandoffAppState` says so, so the
///    keyboard can send `HandoffCommand`s (start/stop/cancel) without
///    opening the app.
@MainActor
@Observable
final class HandoffCoordinator {
    /// The keyboard session being recorded or processed.
    private(set) var sessionID: UUID?
    /// The mode of the latest keyboard session (shown after it ends).
    private(set) var sessionMode: Mode?
    /// Show the compact recording screen.
    var isPresentingRecorder = false
    /// When standby ends, while the app listens for keyboard commands.
    private(set) var standbyUntil: Date?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let mailbox: DictationHandoff
    @ObservationIgnored private var lastCommand: HandoffCommand?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFailure: String?

    init(model: AppModel, mailbox: DictationHandoff = DictationHandoff()) {
        self.model = model
        self.mailbox = mailbox
    }

    var isStandingBy: Bool { standbyUntil != nil }

    /// A previous run may have left "listening" behind.
    func appLaunched() {
        writeAppState(listening: false)
    }

    func appWillTerminate() {
        if let sessionID, model.pipeline.isBusy {
            write(HandoffResult(sessionID: sessionID, status: .failed, errorMessage: "KVoice was closed."))
        }
        writeAppState(listening: false)
    }

    // MARK: URL entry point

    /// Handles `kvoice://dictate[?session=…|?mode=…]`. Returns false for
    /// other URLs.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard DictationHandoff.isDictationURL(url) else { return false }
        if let session = DictationHandoff.sessionID(from: url) {
            guard let request = mailbox.readRequest(), request.sessionID == session, !request.isExpired() else {
                write(HandoffResult(
                    sessionID: session, status: .failed,
                    errorMessage: "That dictation request expired. Try again from the keyboard."
                ))
                return true
            }
            mailbox.clearRequest()
            Task { await begin(session: session, modeID: request.modeID, presentsRecorder: true) }
        } else {
            // App-initiated (widget, Control Center, Shortcuts).
            model.selectedTab = .home
            let modeID = DictationHandoff.modeID(from: url)
            Task { await model.startDictation(modeID: modeID) }
        }
        return true
    }

    // MARK: Keyboard commands

    /// Reads and runs the latest `HandoffCommand` (after its Darwin
    /// notification; posts can coalesce, so only the newest file matters).
    func handleCommand() {
        guard let command = mailbox.readCommand(), !command.isExpired(), command != lastCommand else { return }
        lastCommand = command
        switch command.action {
        case .start:
            Task { await begin(session: command.sessionID, modeID: command.modeID, presentsRecorder: false) }
        case .stop:
            guard command.sessionID == sessionID, model.pipeline.isRecording else { return }
            Task { try? await model.pipeline.stopAndProcess() }
        case .cancel:
            guard command.sessionID == sessionID else { return }
            model.pipeline.cancel()
        }
    }

    private func begin(session: UUID, modeID: UUID?, presentsRecorder: Bool) async {
        let pipeline = model.pipeline
        if pipeline.isBusy {
            if let current = sessionID, current != session, pipeline.isRecording {
                // The keyboard moved on: drop the old session.
                pipeline.cancel()
            } else {
                write(HandoffResult(
                    sessionID: session, status: .failed,
                    errorMessage: "KVoice is still working on the previous dictation."
                ))
                return
            }
        }
        sessionID = session
        pendingFailure = nil
        if presentsRecorder { isPresentingRecorder = true }
        let mode = modeID.flatMap(model.modes.mode(id:)) ?? model.modes.activeMode
        sessionMode = mode
        let recorder = model.recorder
        recorder.deactivatesSessionOnStop = false
        recorder.keepsEngineRunning = AppPreferences.keepAliveMinutes > 0
        expiryTask?.cancel()
        // Failures surface through the phase handler.
        try? await pipeline.startRecording(mode: mode)
    }

    // MARK: Pipeline progress

    /// Set before cancelling a recording that failed (interruption), so the
    /// keyboard sees a failure rather than a cancellation.
    func recordingWillFail(message: String) {
        pendingFailure = message
    }

    func phaseChanged(_ phase: DictationPhase, result: DictationResult?) {
        guard let sessionID else { return }
        switch phase {
        case .recording:
            write(HandoffResult(sessionID: sessionID, status: .recording))
        case .transcribing:
            write(HandoffResult(sessionID: sessionID, status: .transcribing))
        case .formatting:
            write(HandoffResult(sessionID: sessionID, status: .formatting))
        case .done:
            write(HandoffResult(sessionID: sessionID, status: .done, text: result?.text ?? ""))
            finishSession()
        case .failed(let error):
            write(HandoffResult(
                sessionID: sessionID, status: .failed,
                errorMessage: pendingFailure ?? error.localizedDescription
            ))
            finishSession()
        case .idle:
            if let pendingFailure {
                write(HandoffResult(sessionID: sessionID, status: .failed, errorMessage: pendingFailure))
            } else {
                write(HandoffResult(sessionID: sessionID, status: .cancelled))
            }
            finishSession()
        }
    }

    private func finishSession() {
        sessionID = nil
        pendingFailure = nil
        startOrExtendStandby()
    }

    // MARK: Standby

    private func startOrExtendStandby() {
        let minutes = AppPreferences.keepAliveMinutes
        guard minutes > 0, model.recorder.isEngineRunning else {
            endStandby()
            return
        }
        let until = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        standbyUntil = until
        writeAppState(listening: true, expiresAt: until)
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            guard !Task.isCancelled, let self else { return }
            if self.model.pipeline.isBusy { return } // finishSession extends it again.
            self.endStandby()
        }
    }

    /// Stops listening for keyboard commands and releases the microphone.
    func endStandby() {
        expiryTask?.cancel()
        expiryTask = nil
        let wasStandingBy = standbyUntil != nil
        standbyUntil = nil
        if !model.pipeline.isRecording {
            model.recorder.endStandby()
        } else {
            model.recorder.keepsEngineRunning = false
        }
        if wasStandingBy || mailbox.readAppState()?.isListeningForCommands == true {
            writeAppState(listening: false)
        }
    }

    // MARK: Mailbox

    private func write(_ result: HandoffResult) {
        try? mailbox.writeResult(result)
    }

    private func writeAppState(listening: Bool, expiresAt: Date? = nil) {
        try? mailbox.writeAppState(HandoffAppState(isListeningForCommands: listening, expiresAt: expiresAt))
    }
}
