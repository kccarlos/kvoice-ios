import Foundation
import Testing
@testable import KVoiceCore

/// Every row of `Docs/DictationStates.md`.
@Suite struct DictationActivityTests {
    typealias Reducer = DictationActivityReducer
    typealias Lease = DictationActivity.Lease

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let modeA = UUID()
    let modeB = UUID()

    func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Fixtures for each phase

    func idle() -> Reducer { Reducer() }

    func standby(until seconds: TimeInterval = 300) -> Reducer {
        var reducer = Reducer()
        _ = reducer.handle(.standbyStarted(until: at(seconds), now: t0))
        return reducer
    }

    func appRecording(source: DictationActivity.Source = .app, session: Int = 1) -> Reducer {
        var reducer = Reducer()
        _ = reducer.handle(.startAppRecording(sessionID: id(session), source: source, modeID: modeA, now: t0))
        return reducer
    }

    func shortcutRecording(id n: Int = 7) -> Reducer {
        var reducer = Reducer()
        _ = reducer.handle(.beginShortcut(newID: id(n), modeID: modeA, now: t0))
        return reducer
    }

    func processing(job n: Int = 9) -> Reducer {
        var reducer = Reducer()
        _ = reducer.handle(.transcribeRequested(newJobID: id(n), modeID: modeA, now: t0))
        return reducer
    }

    func delivered() -> Reducer {
        var reducer = processing()
        _ = reducer.handle(.jobFinished(jobID: id(9), failure: nil, standbyUntil: nil, now: t0))
        return reducer
    }

    // MARK: Leases

    @Test func everyNonIdlePhaseHasALeaseAndLapsesToIdle() {
        for (reducer, lease) in [
            (standby(until: 300), 300.0),
            (appRecording(), Lease.appRecording),
            (shortcutRecording(), Lease.shortcutRecording),
            (processing(), Lease.processing),
            (delivered(), Lease.result)
        ] {
            let activity = reducer.activity
            #expect(activity.leaseExpiresAt == at(lease))
            #expect(!activity.effectivePhase(now: at(lease - 1)).isIdle)
            #expect(activity.effectivePhase(now: at(lease)) == .idle)
        }
        #expect(idle().activity.leaseExpiresAt == nil)
        #expect(idle().activity.effectivePhase(now: t0) == .idle)
    }

    @Test func shortcutLeaseIsAboutFifteenMinutes() {
        #expect(Lease.shortcutRecording == 15 * 60)
    }

    @Test func renewingExtendsOnlyAppRecordingAndProcessing() {
        var recording = appRecording()
        _ = recording.handle(.renewLease(now: at(100)))
        #expect(recording.activity.leaseExpiresAt == at(100 + Lease.appRecording))

        var job = processing()
        _ = job.handle(.renewLease(now: at(50)))
        #expect(job.activity.leaseExpiresAt == at(50 + Lease.processing))

        var shortcut = shortcutRecording()
        _ = shortcut.handle(.renewLease(now: at(100)))
        #expect(shortcut.activity.leaseExpiresAt == at(Lease.shortcutRecording))

        // A lapsed lease is not revived.
        var lapsed = appRecording()
        _ = lapsed.handle(.renewLease(now: at(Lease.appRecording + 1)))
        #expect(lapsed.activity.effectivePhase(now: at(Lease.appRecording + 1)) == .idle)
    }

    // MARK: Begin Dictation

    @Test func beginFromIdleRecordsWithAShortcutLease() {
        var reducer = idle()
        #expect(reducer.handle(.beginShortcut(newID: id(7), modeID: modeB, now: t0)) == [.gate(.record)])
        #expect(reducer.activity.phase == .recording(owner: .shortcut, source: .shortcut, startedAt: t0))
        #expect(reducer.activity.id == id(7))
        #expect(reducer.activity.modeID == modeB)
        #expect(reducer.activity.leaseExpiresAt == at(Lease.shortcutRecording))
    }

    @Test func beginFromDeliveredOrFailedRecords() {
        var done = delivered()
        #expect(done.handle(.beginShortcut(newID: id(7), modeID: nil, now: at(1))) == [.gate(.record)])

        var failed = processing()
        _ = failed.handle(.jobFinished(jobID: id(9), failure: "Nope", standbyUntil: nil, now: t0))
        #expect(failed.activity.phase == .failed(jobID: id(9), message: "Nope"))
        #expect(failed.handle(.beginShortcut(newID: id(7), modeID: nil, now: at(1))) == [.gate(.record)])
    }

    @Test func beginFromStandbyEndsStandbyThenRecords() {
        var reducer = standby()
        #expect(reducer.handle(.beginShortcut(newID: id(7), modeID: modeA, now: at(10))) == [.endStandby, .gate(.record)])
        #expect(reducer.activity.phase.recordingOwner == .shortcut)
        #expect(!reducer.activity.appState(now: at(10)).acceptsCommands(now: at(10)))
    }

    @Test func beginWhileTheAppRecordsStopsAndProcessesIt() {
        var reducer = appRecording(source: .keyboard)
        let effects = reducer.handle(.beginShortcut(newID: id(7), modeID: modeA, now: at(5)))
        #expect(effects == [.processAppRecording(jobID: id(1)), .gate(.stoppedExisting)])
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(1)))
        #expect(reducer.activity.jobs == [id(1)])
    }

    @Test func actionButtonTogglesTheAppRecording() {
        // Press 1 while the app records: stop. The job finishes. Press 2: record.
        var reducer = appRecording()
        #expect(reducer.handle(.beginShortcut(newID: id(7), modeID: nil, now: at(5))).contains(.gate(.stoppedExisting)))
        _ = reducer.handle(.jobFinished(jobID: id(1), failure: nil, standbyUntil: nil, now: at(8)))
        #expect(reducer.activity.phase == .delivered(jobID: id(1)))
        #expect(reducer.handle(.beginShortcut(newID: id(8), modeID: nil, now: at(9))) == [.gate(.record)])
    }

    @Test func beginWhileTheShortcutRecordsIsAlreadyRecording() {
        var reducer = shortcutRecording()
        let before = reducer.activity
        #expect(reducer.handle(.beginShortcut(newID: id(8), modeID: modeB, now: at(60))) == [.gate(.alreadyRecording)])
        #expect(reducer.activity == before)
    }

    @Test func staleShortcutLeaseIsTreatedAsIdle() {
        var reducer = shortcutRecording()
        let later = at(Lease.shortcutRecording + 1)
        #expect(reducer.activity.effectivePhase(now: later) == .idle)
        #expect(reducer.handle(.beginShortcut(newID: id(8), modeID: modeB, now: later)) == [.gate(.record)])
        #expect(reducer.activity.id == id(8))
        #expect(reducer.activity.leaseExpiresAt == later.addingTimeInterval(Lease.shortcutRecording))
    }

    @Test func beginWhileProcessingRecordsAndTheJobQueues() {
        var reducer = processing(job: 9)
        #expect(reducer.handle(.beginShortcut(newID: id(7), modeID: modeA, now: at(2))) == [.gate(.record)])
        #expect(reducer.activity.phase.recordingOwner == .shortcut)
        #expect(reducer.activity.jobs == [id(9)])

        // The old job finishes while the shortcut records: the mic owner stays.
        _ = reducer.handle(.jobFinished(jobID: id(9), failure: nil, standbyUntil: nil, now: at(4)))
        #expect(reducer.activity.phase.recordingOwner == .shortcut)
        #expect(reducer.activity.jobs.isEmpty)
    }

    @Test func previewGateChangesNothing() {
        let reducer = appRecording()
        #expect(reducer.previewGate(now: at(1)) == .stoppedExisting)
        #expect(reducer.activity == appRecording().activity)
        #expect(shortcutRecording().previewGate(now: at(1)) == .alreadyRecording)
        #expect(idle().previewGate(now: t0) == .record)
    }

    // MARK: Transcribe Audio

    @Test func gatedTranscribeTakesTheRunsIdAndClearsTheShortcutRecording() {
        var reducer = shortcutRecording(id: 7)
        let effects = reducer.handle(.transcribeRequested(newJobID: id(99), modeID: nil, now: at(30)))
        #expect(effects == [.runJob(jobID: id(7), modeID: modeA, gated: true)])
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(7)))
        #expect(reducer.activity.leaseExpiresAt == at(30 + Lease.processing))
    }

    @Test func gatedTranscribeModeParameterWinsOverBegin() {
        var reducer = shortcutRecording(id: 7)
        #expect(reducer.handle(.transcribeRequested(newJobID: id(99), modeID: modeB, now: at(30)))
            == [.runJob(jobID: id(7), modeID: modeB, gated: true)])
    }

    @Test func ungatedTranscribeIsAJobOfItsOwn() {
        for start in [idle(), delivered(), standby()] {
            var reducer = start
            #expect(reducer.handle(.transcribeRequested(newJobID: id(5), modeID: modeB, now: at(1)))
                == [.runJob(jobID: id(5), modeID: modeB, gated: false)])
            #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(5)))
            #expect(reducer.activity.id == id(5))
        }
        // A lapsed shortcut lease is not a gated run.
        var stale = shortcutRecording(id: 7)
        let later = at(Lease.shortcutRecording + 5)
        #expect(stale.handle(.transcribeRequested(newJobID: id(5), modeID: nil, now: later))
            == [.runJob(jobID: id(5), modeID: nil, gated: false)])
    }

    @Test func transcribeWhileTheAppRecordsQueuesBehindTheMicOwner() {
        var reducer = appRecording()
        _ = reducer.handle(.transcribeRequested(newJobID: id(5), modeID: nil, now: at(1)))
        #expect(reducer.activity.phase.recordingOwner == .app)
        #expect(reducer.activity.jobs == [id(5)])
        // Stopping queues the app's job behind it.
        #expect(reducer.handle(.stopAppRecording(now: at(2))) == [.processAppRecording(jobID: id(1))])
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(5)))
        #expect(reducer.activity.jobs == [id(5), id(1)])
    }

    @Test func processingQueueRunsInOrder() {
        var reducer = processing(job: 1)
        _ = reducer.handle(.transcribeRequested(newJobID: id(2), modeID: nil, now: at(1)))
        _ = reducer.handle(.transcribeRequested(newJobID: id(3), modeID: nil, now: at(2)))
        #expect(reducer.activity.jobs == [id(1), id(2), id(3)])
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(1)))

        _ = reducer.handle(.jobStage(jobID: id(1), stage: .formatting, now: at(3)))
        #expect(reducer.activity.phase == .processing(stage: .formatting, jobID: id(1)))
        // A stage of a queued job does not take over the display.
        _ = reducer.handle(.jobStage(jobID: id(3), stage: .formatting, now: at(3)))
        #expect(reducer.activity.phase == .processing(stage: .formatting, jobID: id(1)))

        _ = reducer.handle(.jobFinished(jobID: id(1), failure: nil, standbyUntil: nil, now: at(4)))
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(2)))
        _ = reducer.handle(.jobFinished(jobID: id(2), failure: "x", standbyUntil: nil, now: at(5)))
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(3)))
        _ = reducer.handle(.jobFinished(jobID: id(3), failure: nil, standbyUntil: nil, now: at(6)))
        #expect(reducer.activity.phase == .delivered(jobID: id(3)))
        #expect(reducer.activity.jobs.isEmpty)
        #expect(reducer.activity.leaseExpiresAt == at(6 + Lease.result))
    }

    @Test func finishedJobReturnsToStandbyWhenTheAppKeepsListening() {
        var reducer = appRecording(source: .keyboard)
        _ = reducer.handle(.stopAppRecording(now: at(3)))
        _ = reducer.handle(.jobFinished(jobID: id(1), failure: nil, standbyUntil: at(303), now: at(5)))
        #expect(reducer.activity.phase == .standby(expiresAt: at(303)))
        #expect(reducer.activity.keyboardRoute(now: at(6)) == .command)
    }

    @Test func resumedJobNeverAdoptsTheShortcutRun() {
        var reducer = shortcutRecording(id: 7)
        #expect(reducer.handle(.jobQueued(jobID: id(4), modeID: nil, now: at(1)))
            == [.runJob(jobID: id(4), modeID: nil, gated: false)])
        #expect(reducer.activity.phase.recordingOwner == .shortcut)
        #expect(reducer.activity.id == id(7))
    }

    // MARK: App record button, DictateIntent, keyboard requests

    @Test func appStartsFromIdleStandbyAndResults() {
        for start in [idle(), standby(), delivered()] {
            var reducer = start
            #expect(reducer.handle(.startAppRecording(sessionID: id(3), source: .intent, modeID: modeB, now: at(1)))
                == [.startRecording(sessionID: id(3))])
            #expect(reducer.activity.phase == .recording(owner: .app, source: .intent, startedAt: at(1)))
            #expect(reducer.activity.modeID == modeB)
        }
    }

    @Test func appDoesNotStartWhileTheShortcutOwnsTheMic() {
        var reducer = shortcutRecording()
        let before = reducer.activity
        for source in [DictationActivity.Source.app, .intent, .keyboard] {
            #expect(reducer.handle(.startAppRecording(sessionID: id(3), source: source, modeID: nil, now: at(1)))
                == [.rejectStart(.shortcutOwnsMic)])
        }
        #expect(reducer.activity == before)
        #expect(DictationActivityReducer.StartRejection.shortcutOwnsMic.message == "Recording with the Action Button")
    }

    @Test func appDoesNotStartWhileProcessingOrRecording() {
        var job = processing()
        #expect(job.handle(.startAppRecording(sessionID: id(3), source: .app, modeID: nil, now: at(1))) == [.rejectStart(.busy)])
        var recording = appRecording(source: .app)
        #expect(recording.handle(.startAppRecording(sessionID: id(3), source: .intent, modeID: nil, now: at(1)))
            == [.rejectStart(.alreadyRecording)])
    }

    @Test func aNewKeyboardSessionReplacesTheOldOne() {
        var reducer = appRecording(source: .keyboard, session: 1)
        #expect(reducer.handle(.startAppRecording(sessionID: id(2), source: .keyboard, modeID: nil, now: at(1)))
            == [.cancelRecording, .startRecording(sessionID: id(2))])
        #expect(reducer.activity.id == id(2))
        // The same session twice is not a new one.
        #expect(reducer.handle(.startAppRecording(sessionID: id(2), source: .keyboard, modeID: nil, now: at(2)))
            == [.rejectStart(.alreadyRecording)])
    }

    @Test func stopAndCancelOfTheAppRecording() {
        var stopped = appRecording()
        #expect(stopped.handle(.stopAppRecording(now: at(4))) == [.processAppRecording(jobID: id(1))])
        #expect(stopped.handle(.stopAppRecording(now: at(4))).isEmpty, "nothing left to stop")

        var cancelled = appRecording()
        _ = cancelled.handle(.appRecordingCancelled(standbyUntil: nil, now: at(2)))
        #expect(cancelled.activity.phase == .idle)

        var cancelledInStandby = appRecording(source: .keyboard)
        _ = cancelledInStandby.handle(.appRecordingCancelled(standbyUntil: at(300), now: at(2)))
        #expect(cancelledInStandby.activity.phase == .standby(expiresAt: at(300)))

        var failedStart = appRecording()
        _ = failedStart.handle(.appRecordingFailed(sessionID: id(1), message: "No microphone", now: at(1)))
        #expect(failedStart.activity.phase == .failed(jobID: id(1), message: "No microphone"))
    }

    // MARK: Interruptions

    @Test func interruptionProcessesASecondOrMore() {
        var reducer = appRecording()
        #expect(reducer.handle(.audioInterrupted(recordedDuration: 1.0, now: at(2))) == [.processAppRecording(jobID: id(1))])
        #expect(reducer.activity.phase == .processing(stage: .transcribing, jobID: id(1)))
    }

    @Test func interruptionCancelsUnderASecond() {
        var reducer = appRecording()
        #expect(reducer.handle(.audioInterrupted(recordedDuration: 0.99, now: at(1))) == [.cancelRecording])
        #expect(reducer.activity.phase == .idle)
    }

    @Test func interruptionEndsStandbyQuietly() {
        var reducer = standby()
        #expect(reducer.handle(.audioInterrupted(recordedDuration: 0, now: at(1))) == [.endStandby])
        #expect(reducer.activity.phase == .idle)
    }

    @Test func interruptionLeavesOtherPhasesAlone() {
        for start in [idle(), shortcutRecording(), processing(), delivered()] {
            var reducer = start
            #expect(reducer.handle(.audioInterrupted(recordedDuration: 5, now: at(1))).isEmpty)
            #expect(reducer.activity == start.activity)
        }
    }

    @Test func salvageThreshold() {
        #expect(InterruptionSalvage.shouldProcess(recordedDuration: 1))
        #expect(InterruptionSalvage.shouldProcess(recordedDuration: 12))
        #expect(!InterruptionSalvage.shouldProcess(recordedDuration: 0.5))
        #expect(!InterruptionSalvage.shouldProcess(recordedDuration: 0))
    }

    // MARK: Launch, standby, reset

    @Test func launchDropsWhatTheOldProcessOwned() {
        for start in [standby(), appRecording(), processing()] {
            var reducer = start
            _ = reducer.handle(.launched(now: at(1)))
            #expect(reducer.activity.phase == .idle)
            #expect(reducer.activity.jobs.isEmpty)
        }
        var shortcut = shortcutRecording()
        _ = shortcut.handle(.launched(now: at(1)))
        #expect(shortcut.activity.phase.recordingOwner == .shortcut, "Shortcuts still owns the mic")

        var done = delivered()
        _ = done.handle(.launched(now: at(1)))
        #expect(done.activity.phase == .delivered(jobID: id(9)))
    }

    @Test func standbyStartsOnlyWhenNothingElseRuns() {
        var reducer = idle()
        _ = reducer.handle(.standbyStarted(until: at(60), now: t0))
        #expect(reducer.activity.phase == .standby(expiresAt: at(60)))
        _ = reducer.handle(.standbyEnded(now: at(1)))
        #expect(reducer.activity.phase == .idle)

        var recording = shortcutRecording()
        _ = recording.handle(.standbyStarted(until: at(60), now: t0))
        #expect(recording.activity.phase.recordingOwner == .shortcut)
    }

    @Test func resetClearsAnAbandonedShortcut() {
        var reducer = shortcutRecording()
        _ = reducer.handle(.resetShortcut(now: at(30)))
        #expect(reducer.activity.phase == .idle)
        #expect(reducer.handle(.beginShortcut(newID: id(8), modeID: nil, now: at(31))) == [.gate(.record)])
    }

    // MARK: Entry-point views

    @Test func keyboardRouteForEveryPhase() {
        #expect(idle().activity.keyboardRoute(now: t0) == .openApp)
        #expect(delivered().activity.keyboardRoute(now: at(1)) == .openApp)
        #expect(standby().activity.keyboardRoute(now: at(1)) == .command)
        #expect(standby(until: 10).activity.keyboardRoute(now: at(11)) == .openApp, "expired standby")
        #expect(appRecording().activity.keyboardRoute(now: at(1)) == .stop(id(1)))
        #expect(shortcutRecording().activity.keyboardRoute(now: at(1))
            == .blocked("Recording with the Action Button — tap Stop in the recording panel"))
        #expect(shortcutRecording().activity.keyboardRoute(now: at(Lease.shortcutRecording)) == .openApp)
        #expect(processing().activity.keyboardRoute(now: at(1)) == .blocked("Transcribing…"))
        var formatting = processing()
        _ = formatting.handle(.jobStage(jobID: id(9), stage: .formatting, now: at(1)))
        #expect(formatting.activity.keyboardRoute(now: at(2)) == .blocked("Formatting…"))
    }

    @Test func appStateIsAProjectionOfStandby() {
        let listening = standby(until: 120).activity.appState(now: at(1))
        #expect(listening.isListeningForCommands)
        #expect(listening.expiresAt == at(120))
        #expect(listening.acceptsCommands(now: at(1)))
        #expect(!standby(until: 120).activity.appState(now: at(121)).isListeningForCommands)
        #expect(!appRecording().activity.appState(now: at(1)).isListeningForCommands)
    }

    @Test func gateOutcomeRawValuesMatchTheIntentEnum() {
        // DictationGateOutcome (the App Intents enum) maps by raw value.
        #expect(Reducer.GateOutcome.allCases.map(\.rawValue) == ["record", "stoppedExisting", "alreadyRecording"])
        for outcome in Reducer.GateOutcome.allCases {
            #expect(!outcome.dialog.isEmpty && outcome.dialog.count <= 90)
        }
    }

    @Test func activityRoundTripsThroughTheMailbox() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let handoff = DictationHandoff(directory: directory.url, postsNotifications: false)
        var reducer = standby(until: 300)
        try handoff.writeActivity(reducer.activity, now: at(1))
        #expect(handoff.readActivity() == reducer.activity)
        #expect(handoff.readAppState()?.acceptsCommands(now: at(1)) == true)

        _ = reducer.handle(.beginShortcut(newID: id(7), modeID: modeA, now: at(2)))
        try handoff.writeActivity(reducer.activity, now: at(2))
        #expect(handoff.readActivity() == reducer.activity)
        #expect(handoff.readAppState()?.isListeningForCommands == false, "the projection follows the record")
    }
}
