import Foundation
import KVoiceKit
import Observation
import UIKit

/// The app side of the keyboard handoff, and the one writer of the shared
/// `DictationActivity` (who owns the microphone).
///
/// Every entry point goes through `DictationActivityReducer` here: keyboard
/// requests and commands, the record button and `DictateIntent` (through
/// `AppModel`), Begin Dictation and Transcribe Audio, the audio session and
/// the job queue. See `Docs/DictationStates.md`.
///
/// 1. The keyboard writes a `HandoffRequest` and opens
///    `kvoice://dictate?session=<id>`. The app starts recording in the
///    request's mode and shows a compact "swipe back" screen.
/// 2. Every pipeline phase is written to the `HandoffResult` for that
///    session; on `.done` the result carries the text for the keyboard to
///    insert.
/// 3. After a keyboard dictation the input engine stays running for the
///    keep-alive window (standby), so the keyboard can send
///    `HandoffCommand`s (start/stop/cancel) without opening the app.
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
    /// The shared activity as last written.
    private(set) var activity: DictationActivity

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let mailbox: DictationHandoff
    @ObservationIgnored private var reducer: DictationActivityReducer
    @ObservationIgnored private var lastCommand: HandoffCommand?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var leaseTask: Task<Void, Never>?
    /// The job id of the app's own recording being processed.
    @ObservationIgnored private var appJobID: UUID?
    /// Where the app's current recording came from.
    @ObservationIgnored private var appSource: DictationActivity.Source = .app

    init(model: AppModel, mailbox: DictationHandoff = DictationHandoff()) {
        self.model = model
        self.mailbox = mailbox
        let stored = mailbox.readActivity() ?? DictationActivity(updatedAt: .distantPast)
        self.reducer = DictationActivityReducer(activity: stored)
        self.activity = stored
    }

    var isStandingBy: Bool { standbyUntil != nil }

    /// Phases a previous process owned are gone; a shortcut's lease stays.
    func appLaunched() {
        send(.launched(now: .now))
        startLeaseRenewal()
    }

    func appWillTerminate() {
        if let sessionID, model.pipeline.isBusy {
            write(HandoffResult(sessionID: sessionID, status: .failed, errorMessage: "KVoice was closed."))
        }
        // Same as the next launch: nothing this process owned survives.
        send(.launched(now: .now))
    }

    // MARK: Activity

    @discardableResult
    func send(_ event: DictationActivityReducer.Event) -> [DictationActivityReducer.Effect] {
        let effects = reducer.handle(event)
        if reducer.activity != activity {
            activity = reducer.activity
            try? mailbox.writeActivity(activity)
        }
        return effects
    }

    /// The phase now, read through its lease.
    var effectivePhase: DictationActivity.Phase { activity.effectivePhase(now: .now) }

    /// What Begin Dictation would answer, without changing anything.
    func previewGate() -> DictationActivityReducer.GateOutcome {
        reducer.previewGate(now: .now)
    }

    /// Reset an abandoned Action Button recording.
    func resetShortcut() {
        send(.resetShortcut(now: .now))
    }

    /// Keeps the lease of a recording or job alive while this process works.
    private func startLeaseRenewal() {
        leaseTask?.cancel()
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DictationActivity.Lease.renewInterval))
                guard let self else { return }
                self.send(.renewLease(now: .now))
            }
        }
    }

    // MARK: Begin Dictation (Action Button shortcut)

    func beginShortcut(modeID: UUID?) -> DictationActivityReducer.GateOutcome {
        var outcome = DictationActivityReducer.GateOutcome.record
        let mode = modeID ?? model.modes.activeModeID
        for effect in send(.beginShortcut(newID: UUID(), modeID: mode, now: .now)) {
            switch effect {
            case .gate(let gate):
                outcome = gate
            case .endStandby:
                endStandby()
            case .processAppRecording(let jobID):
                processAppRecording(jobID: jobID)
            default:
                break
            }
        }
        return outcome
    }

    // MARK: App recordings (record button, DictateIntent)

    /// Asks to record from the app. Returns a message when it may not.
    func requestAppRecording(source: DictationActivity.Source, mode: Mode) async -> String? {
        for effect in send(.startAppRecording(sessionID: UUID(), source: source, modeID: mode.id, now: .now)) {
            switch effect {
            case .rejectStart(let rejection):
                return rejection.message
            case .startRecording:
                appSource = source
                appJobID = nil
                let recorder = model.recorder
                recorder.deactivatesSessionOnStop = !isStandingBy
                do {
                    try await model.pipeline.startRecording(mode: mode)
                } catch {
                    return nil // Reported through the phase handler.
                }
            default:
                break
            }
        }
        return nil
    }

    /// Stop tapped anywhere: process the app's recording and return its
    /// result once processed.
    @discardableResult
    func stopAppRecording() async -> DictationResult? {
        var jobID: UUID?
        for case .processAppRecording(let id) in send(.stopAppRecording(now: .now)) { jobID = id }
        guard model.pipeline.isRecording else { return nil }
        appJobID = jobID ?? activity.id
        return try? await model.withBackgroundTime("Finish dictation") {
            try await self.model.pipeline.stopAndProcess()
        }
    }

    private func processAppRecording(jobID: UUID) {
        guard model.pipeline.isRecording else { return }
        appJobID = jobID
        Task {
            _ = try? await model.withBackgroundTime("Finish dictation") {
                try await self.model.pipeline.stopAndProcess()
            }
        }
    }

    // MARK: Audio interruptions

    /// The microphone was taken away (call, Siri, another app, route loss,
    /// media reset). A recording of at least 1 s is processed; a shorter
    /// one is cancelled. Standby ends quietly.
    func audioInterrupted() {
        let pipeline = model.pipeline
        let duration = pipeline.recordedDuration
        let effects = send(.audioInterrupted(recordedDuration: duration, now: .now))
        var handled = false
        for effect in effects {
            switch effect {
            case .processAppRecording(let jobID):
                handled = true
                processAppRecording(jobID: jobID)
            case .cancelRecording:
                handled = true
                pipeline.cancel()
            default:
                break
            }
        }
        if !handled, pipeline.isRecording {
            // The record and the recorder disagree (a lapsed lease): apply
            // the same salvage rule directly.
            if InterruptionSalvage.shouldProcess(recordedDuration: duration) {
                processAppRecording(jobID: activity.id)
            } else {
                pipeline.cancel()
            }
        }
        endStandby()
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
            Task { await model.startDictation(modeID: modeID, source: .intent) }
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
            guard adoptForKeyboard(command.sessionID), model.pipeline.isRecording else { return }
            Task { await stopAppRecording() }
        case .cancel:
            guard adoptForKeyboard(command.sessionID) else { return }
            model.pipeline.cancel()
        }
    }

    /// Whether a keyboard command targets the current recording: the
    /// keyboard's own session, or (stop from the keyboard mic) a recording
    /// started in the app, which the keyboard then follows.
    private func adoptForKeyboard(_ session: UUID) -> Bool {
        if session == sessionID { return true }
        guard sessionID == nil, session == activity.id,
              activity.effectivePhase(now: .now).recordingOwner == .app else { return false }
        sessionID = session
        sessionMode = model.pipeline.recordingMode
        appSource = .keyboard
        return true
    }

    private func begin(session: UUID, modeID: UUID?, presentsRecorder: Bool) async {
        let pipeline = model.pipeline
        // The same session twice (the URL and a command): already running.
        if session == sessionID, pipeline.isBusy { return }
        if let current = sessionID, current != session, pipeline.isRecording {
            // The keyboard moved on: drop the old session first.
            pipeline.cancel()
        }
        let mode = modeID.flatMap(model.modes.mode(id:)) ?? model.modes.activeMode
        for effect in send(.startAppRecording(sessionID: session, source: .keyboard, modeID: mode.id, now: .now)) {
            switch effect {
            case .rejectStart(let rejection):
                write(HandoffResult(sessionID: session, status: .failed, errorMessage: rejection.message))
                return
            case .cancelRecording:
                pipeline.cancel()
            case .startRecording:
                sessionID = session
                appSource = .keyboard
                appJobID = nil
                if presentsRecorder { isPresentingRecorder = true }
                sessionMode = mode
                let recorder = model.recorder
                recorder.deactivatesSessionOnStop = false
                recorder.keepsEngineRunning = AppPreferences.keepAliveMinutes > 0
                expiryTask?.cancel()
                // Failures surface through the phase handler.
                try? await pipeline.startRecording(mode: mode)
            default:
                break
            }
        }
    }

    // MARK: Pipeline progress

    func phaseChanged(_ phase: DictationPhase, result: DictationResult?) {
        if let sessionID { writeKeyboardProgress(phase, result: result, session: sessionID) }
        let now = Date.now
        switch phase {
        case .recording:
            break
        case .transcribing:
            if let appJobID { send(.jobStage(jobID: appJobID, stage: .transcribing, now: now)) }
        case .formatting:
            if let appJobID { send(.jobStage(jobID: appJobID, stage: .formatting, now: now)) }
        case .done:
            let jobID = appJobID ?? activity.id
            if sessionID == nil, let result {
                deliver(text: result.text, jobID: jobID, source: appSource)
            }
            finish(jobID: jobID, failure: nil)
        case .failed(let error):
            if let appJobID {
                finish(jobID: appJobID, failure: error.localizedDescription)
            } else {
                // The recorder could not start.
                send(.appRecordingFailed(sessionID: activity.id, message: error.localizedDescription, now: now))
                finishSession()
            }
        case .idle:
            if let appJobID {
                finish(jobID: appJobID, failure: DictationError.cancelled.localizedDescription)
            } else {
                finishSession()
                send(.appRecordingCancelled(standbyUntil: standbyUntil, now: now))
            }
        }
    }

    /// Mirrors pipeline phases into the keyboard session's `HandoffResult`.
    private func writeKeyboardProgress(_ phase: DictationPhase, result: DictationResult?, session: UUID) {
        switch phase {
        case .recording:
            write(HandoffResult(sessionID: session, status: .recording))
        case .transcribing:
            write(HandoffResult(sessionID: session, status: .transcribing))
        case .formatting:
            write(HandoffResult(sessionID: session, status: .formatting))
        case .done:
            write(HandoffResult(sessionID: session, status: .done, text: result?.text ?? ""))
        case .failed(let error):
            write(HandoffResult(sessionID: session, status: .failed, errorMessage: error.localizedDescription))
        case .idle:
            write(HandoffResult(sessionID: session, status: .cancelled))
        }
    }

    private func finish(jobID: UUID, failure: String?) {
        appJobID = nil
        finishSession()
        send(.jobFinished(jobID: jobID, failure: failure, standbyUntil: standbyUntil, now: .now))
    }

    private func finishSession() {
        let wasKeyboardSession = sessionID != nil
        sessionID = nil
        if wasKeyboardSession {
            startOrExtendStandby()
        }
    }

    // MARK: Results for the keyboard

    /// Offers a finished non-keyboard dictation to the KVoice keyboard: it
    /// is typed only when the keyboard is on screen now and the device is
    /// unlocked; otherwise nothing is written, so a keyboard opened later
    /// never types it.
    @discardableResult
    func deliver(text: String, jobID: UUID, source: DictationActivity.Source) -> KeyboardInsertion {
        let insertion = KeyboardInsertion.decide(
            source: source,
            presence: mailbox.readKeyboardPresence(),
            isDeviceLocked: !UIApplication.shared.isProtectedDataAvailable,
            now: .now
        )
        if insertion == .insert {
            write(HandoffResult(sessionID: jobID, status: .done, text: text))
        }
        return insertion
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
        send(.standbyStarted(until: until, now: .now))
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
        standbyUntil = nil
        if !model.pipeline.isRecording {
            model.recorder.endStandby()
        } else {
            model.recorder.keepsEngineRunning = false
        }
        send(.standbyEnded(now: .now))
    }

    // MARK: Mailbox

    private func write(_ result: HandoffResult) {
        try? mailbox.writeResult(result)
    }
}
