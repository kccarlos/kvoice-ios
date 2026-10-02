import Foundation

/// The transitions of `DictationActivity` as a pure reducer.
///
/// The app feeds it events from every entry point (keyboard requests and
/// commands, the record button, App Intents, the audio session, the job
/// queue) and performs the returned effects. Time and identifiers come in
/// with the events, so every row of `Docs/DictationStates.md` is
/// deterministic and unit-tested. Every transition first reads the phase
/// through its lease (`effectivePhase`).
public struct DictationActivityReducer: Sendable, Equatable {
    /// What Begin Dictation tells the shortcut.
    public enum GateOutcome: String, Codable, Sendable, Hashable, CaseIterable {
        /// Record now (Record Audio, then Transcribe Audio).
        case record
        /// The app's recording was stopped and is being processed; the
        /// shortcut ends without recording (the Action Button toggles).
        case stoppedExisting
        /// An Action Button recording is already in progress.
        case alreadyRecording

        /// The short dialog shown with the outcome.
        public var dialog: String {
            switch self {
            case .record: "Recording. Tap Stop when you're done."
            case .stoppedExisting: "Stopped. KVoice is finishing your dictation."
            case .alreadyRecording: "Already recording with the Action Button. Tap Stop in the recording panel."
            }
        }
    }

    /// Why the app may not start recording.
    public enum StartRejection: Sendable, Hashable {
        /// Shortcuts' Record Audio owns the microphone.
        case shortcutOwnsMic
        case alreadyRecording
        /// A job is being processed.
        case busy

        public var message: String {
            switch self {
            case .shortcutOwnsMic: DictationActivity.Message.shortcutRecordingApp
            case .alreadyRecording: "KVoice is already recording."
            case .busy: DictationActivity.Message.busy
            }
        }
    }

    public enum Event: Sendable, Hashable {
        /// A new app process started: phases owned by the previous process
        /// are gone.
        case launched(now: Date)
        /// Begin Dictation. `modeID` is the mode the dictation will use.
        case beginShortcut(newID: UUID, modeID: UUID?, now: Date)
        /// The keyboard (request or command), the record button or
        /// `DictateIntent` wants the app to record.
        case startAppRecording(sessionID: UUID, source: DictationActivity.Source, modeID: UUID?, now: Date)
        /// The recorder could not start.
        case appRecordingFailed(sessionID: UUID, message: String, now: Date)
        /// Stop tapped (keyboard, app, intent): process the recording.
        case stopAppRecording(now: Date)
        /// The app's recording was discarded. `standbyUntil` is set when the
        /// engine keeps running for the keyboard.
        case appRecordingCancelled(standbyUntil: Date?, now: Date)
        /// The audio session was interrupted or the engine stopped.
        case audioInterrupted(recordedDuration: TimeInterval, now: Date)
        /// Transcribe Audio received a file. It joins the gated shortcut run
        /// if there is one, otherwise it is an ungated job with `newJobID`.
        /// `modeID` is the intent's Mode parameter (it wins over Begin's).
        case transcribeRequested(newJobID: UUID, modeID: UUID?, now: Date)
        /// A job that belongs to no entry point (a pending history record
        /// resumed at launch).
        case jobQueued(jobID: UUID, modeID: UUID?, now: Date)
        case jobStage(jobID: UUID, stage: DictationActivity.Stage, now: Date)
        /// `failure` is nil when the job delivered text. `standbyUntil` is
        /// set when the app keeps listening for the keyboard afterwards.
        case jobFinished(jobID: UUID, failure: String?, standbyUntil: Date?, now: Date)
        case standbyStarted(until: Date, now: Date)
        case standbyEnded(now: Date)
        /// The owner is alive: extend a recording(.app) or processing lease.
        case renewLease(now: Date)
        /// Manual reset of an abandoned Action Button recording.
        case resetShortcut(now: Date)
    }

    public enum Effect: Sendable, Hashable {
        /// Answer Begin Dictation.
        case gate(GateOutcome)
        /// Stop the standby engine and deactivate the audio session.
        case endStandby
        /// Discard the app's current recording (no result).
        case cancelRecording
        /// Start recording for this session.
        case startRecording(sessionID: UUID)
        case rejectStart(StartRejection)
        /// Stop the app's recorder and queue its audio as job `jobID`.
        case processAppRecording(jobID: UUID)
        /// Run a Transcribe Audio job. `gated` is true when Begin Dictation
        /// prepared it.
        case runJob(jobID: UUID, modeID: UUID?, gated: Bool)
    }

    public private(set) var activity: DictationActivity

    public init(activity: DictationActivity = DictationActivity(updatedAt: .distantPast)) {
        self.activity = activity
    }

    // MARK: Reducer

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .launched(let now):
            return launched(now: now)
        case let .beginShortcut(newID, modeID, now):
            return beginShortcut(newID: newID, modeID: modeID, now: now)
        case let .startAppRecording(sessionID, source, modeID, now):
            return startAppRecording(sessionID: sessionID, source: source, modeID: modeID, now: now)
        case let .appRecordingFailed(sessionID, message, now):
            guard activity.id == sessionID, activity.effectivePhase(now: now).recordingOwner == .app else { return [] }
            settle(failure: message, jobID: sessionID, standbyUntil: nil, now: now)
            return []
        case .stopAppRecording(let now):
            guard activity.effectivePhase(now: now).recordingOwner == .app else { return [] }
            return [queueAppRecording(now: now)]
        case let .appRecordingCancelled(standbyUntil, now):
            guard activity.effectivePhase(now: now).recordingOwner == .app else { return [] }
            afterRecording(standbyUntil: standbyUntil, now: now)
            return []
        case let .audioInterrupted(duration, now):
            return audioInterrupted(recordedDuration: duration, now: now)
        case let .transcribeRequested(newJobID, modeID, now):
            return transcribeRequested(newJobID: newJobID, modeID: modeID, now: now)
        case let .jobQueued(jobID, modeID, now):
            enqueue(jobID, modeID: modeID, now: now)
            return [.runJob(jobID: jobID, modeID: modeID, gated: false)]
        case let .jobStage(jobID, stage, now):
            guard case .processing(_, jobID) = activity.effectivePhase(now: now) else { return [] }
            set(.processing(stage: stage, jobID: jobID), lease: DictationActivity.Lease.processing, now: now)
            return []
        case let .jobFinished(jobID, failure, standbyUntil, now):
            jobFinished(jobID: jobID, failure: failure, standbyUntil: standbyUntil, now: now)
            return []
        case let .standbyStarted(until, now):
            switch activity.effectivePhase(now: now) {
            case .idle, .delivered, .failed, .standby:
                set(.standby(expiresAt: until), leaseUntil: until, now: now)
            case .recording, .processing:
                break
            }
            return []
        case .standbyEnded(let now):
            guard case .standby = activity.effectivePhase(now: now) else { return [] }
            set(.idle, leaseUntil: nil, now: now)
            return []
        case .renewLease(let now):
            switch activity.effectivePhase(now: now) {
            case .recording(.app, _, _):
                activity.leaseExpiresAt = now.addingTimeInterval(DictationActivity.Lease.appRecording)
                activity.updatedAt = now
            case .processing:
                activity.leaseExpiresAt = now.addingTimeInterval(DictationActivity.Lease.processing)
                activity.updatedAt = now
            default:
                break
            }
            return []
        case .resetShortcut(let now):
            guard activity.effectivePhase(now: now).recordingOwner == .shortcut else { return [] }
            afterRecording(standbyUntil: nil, now: now)
            return []
        }
    }

    /// What Begin Dictation would answer now, without changing anything
    /// (the setup screen's Test button).
    public func previewGate(now: Date) -> GateOutcome {
        var copy = self
        for case .gate(let outcome) in copy.handle(.beginShortcut(newID: UUID(), modeID: nil, now: now)) {
            return outcome
        }
        return .record
    }

    // MARK: Transitions

    private mutating func launched(now: Date) -> [Effect] {
        activity.jobs = []
        switch activity.effectivePhase(now: now) {
        case .standby, .recording(.app, _, _), .processing:
            set(.idle, leaseUntil: nil, now: now)
        case .idle:
            if !activity.phase.isIdle { set(.idle, leaseUntil: nil, now: now) }
        case .recording(.shortcut, _, _), .delivered, .failed:
            break
        }
        return []
    }

    private mutating func beginShortcut(newID: UUID, modeID: UUID?, now: Date) -> [Effect] {
        switch activity.effectivePhase(now: now) {
        case .idle, .delivered, .failed, .processing:
            startShortcutRecording(newID: newID, modeID: modeID, now: now)
            return [.gate(.record)]
        case .standby:
            startShortcutRecording(newID: newID, modeID: modeID, now: now)
            return [.endStandby, .gate(.record)]
        case .recording(.app, _, _):
            return [queueAppRecording(now: now), .gate(.stoppedExisting)]
        case .recording(.shortcut, _, _):
            return [.gate(.alreadyRecording)]
        }
    }

    private mutating func startShortcutRecording(newID: UUID, modeID: UUID?, now: Date) {
        activity.id = newID
        activity.modeID = modeID
        set(
            .recording(owner: .shortcut, source: .shortcut, startedAt: now),
            lease: DictationActivity.Lease.shortcutRecording, now: now
        )
    }

    private mutating func startAppRecording(
        sessionID: UUID, source: DictationActivity.Source, modeID: UUID?, now: Date
    ) -> [Effect] {
        switch activity.effectivePhase(now: now) {
        case .idle, .delivered, .failed, .standby:
            beginAppRecording(sessionID: sessionID, source: source, modeID: modeID, now: now)
            return [.startRecording(sessionID: sessionID)]
        case .recording(.app, let current, _):
            // The keyboard moved on to a new session: drop the old one.
            guard source == .keyboard, current == .keyboard, activity.id != sessionID else {
                return [.rejectStart(.alreadyRecording)]
            }
            beginAppRecording(sessionID: sessionID, source: source, modeID: modeID, now: now)
            return [.cancelRecording, .startRecording(sessionID: sessionID)]
        case .recording(.shortcut, _, _):
            return [.rejectStart(.shortcutOwnsMic)]
        case .processing:
            return [.rejectStart(.busy)]
        }
    }

    private mutating func beginAppRecording(
        sessionID: UUID, source: DictationActivity.Source, modeID: UUID?, now: Date
    ) {
        activity.id = sessionID
        activity.modeID = modeID
        set(
            .recording(owner: .app, source: source, startedAt: now),
            lease: DictationActivity.Lease.appRecording, now: now
        )
    }

    /// recording(.app) → its audio becomes a job.
    private mutating func queueAppRecording(now: Date) -> Effect {
        let jobID = activity.id
        activity.jobs.append(jobID)
        showRunningJob(now: now)
        return .processAppRecording(jobID: jobID)
    }

    private mutating func audioInterrupted(recordedDuration: TimeInterval, now: Date) -> [Effect] {
        switch activity.effectivePhase(now: now) {
        case .recording(.app, _, _):
            if InterruptionSalvage.shouldProcess(recordedDuration: recordedDuration) {
                return [queueAppRecording(now: now)]
            }
            afterRecording(standbyUntil: nil, now: now)
            return [.cancelRecording]
        case .standby:
            set(.idle, leaseUntil: nil, now: now)
            return [.endStandby]
        default:
            return []
        }
    }

    private mutating func transcribeRequested(newJobID: UUID, modeID: UUID?, now: Date) -> [Effect] {
        if activity.effectivePhase(now: now).recordingOwner == .shortcut {
            // The gated run: Record Audio finished, so Shortcuts no longer
            // owns the microphone.
            let jobID = activity.id
            let mode = modeID ?? activity.modeID
            activity.jobs.append(jobID)
            showRunningJob(now: now)
            return [.runJob(jobID: jobID, modeID: mode, gated: true)]
        }
        enqueue(newJobID, modeID: modeID, now: now)
        return [.runJob(jobID: newJobID, modeID: modeID, gated: false)]
    }

    /// Adds a job; the phase shows it unless a recording owns the
    /// microphone or another job runs.
    private mutating func enqueue(_ jobID: UUID, modeID: UUID?, now: Date) {
        activity.jobs.append(jobID)
        switch activity.effectivePhase(now: now) {
        case .recording:
            activity.updatedAt = now
        case .processing:
            activity.updatedAt = now
        case .idle, .standby, .delivered, .failed:
            activity.id = jobID
            activity.modeID = modeID
            showRunningJob(now: now)
        }
    }

    private mutating func jobFinished(jobID: UUID, failure: String?, standbyUntil: Date?, now: Date) {
        activity.jobs.removeAll { $0 == jobID }
        if case .recording = activity.effectivePhase(now: now) {
            // The microphone owner stays; the result goes out on its own.
            activity.updatedAt = now
            return
        }
        settle(failure: failure, jobID: jobID, standbyUntil: standbyUntil, now: now)
    }

    /// After a recording ends without a job: the next job, standby or idle.
    private mutating func afterRecording(standbyUntil: Date?, now: Date) {
        if !activity.jobs.isEmpty {
            showRunningJob(now: now)
        } else if let standbyUntil, standbyUntil > now {
            set(.standby(expiresAt: standbyUntil), leaseUntil: standbyUntil, now: now)
        } else {
            set(.idle, leaseUntil: nil, now: now)
        }
    }

    /// A job ended: the next job, standby, or the result.
    private mutating func settle(failure: String?, jobID: UUID, standbyUntil: Date?, now: Date) {
        if !activity.jobs.isEmpty {
            showRunningJob(now: now)
        } else if let standbyUntil, standbyUntil > now {
            set(.standby(expiresAt: standbyUntil), leaseUntil: standbyUntil, now: now)
        } else if let failure {
            activity.id = jobID
            set(.failed(jobID: jobID, message: failure), lease: DictationActivity.Lease.result, now: now)
        } else {
            activity.id = jobID
            set(.delivered(jobID: jobID), lease: DictationActivity.Lease.result, now: now)
        }
    }

    /// processing(transcribing) for the oldest job, unless it is already
    /// shown.
    private mutating func showRunningJob(now: Date) {
        guard let running = activity.jobs.first else { return }
        if case .processing(_, running) = activity.effectivePhase(now: now) {
            activity.updatedAt = now
            return
        }
        set(.processing(stage: .transcribing, jobID: running), lease: DictationActivity.Lease.processing, now: now)
    }

    private mutating func set(_ phase: DictationActivity.Phase, lease: TimeInterval, now: Date) {
        set(phase, leaseUntil: now.addingTimeInterval(lease), now: now)
    }

    private mutating func set(_ phase: DictationActivity.Phase, leaseUntil: Date?, now: Date) {
        activity.phase = phase
        activity.leaseExpiresAt = phase.isIdle ? nil : leaseUntil
        activity.updatedAt = now
    }
}
