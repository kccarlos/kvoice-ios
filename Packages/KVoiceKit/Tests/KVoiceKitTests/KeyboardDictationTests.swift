import Foundation
import Testing
@testable import KVoiceCore

@Suite struct KeyboardDictationTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let session = UUID()
    let mode = Mode.BuiltInID.email

    func result(_ status: HandoffResult.Status, session: UUID? = nil, text: String? = nil,
                error: String? = nil, at offset: TimeInterval = 1, consumed: Bool = false) -> HandoffResult {
        HandoffResult(sessionID: session ?? self.session, status: status, text: text, errorMessage: error,
                      updatedAt: t0.addingTimeInterval(offset), consumed: consumed)
    }

    func started(viaCommand: Bool) -> KeyboardDictation {
        var machine = KeyboardDictation()
        _ = machine.handle(.micTapped(newSessionID: session, modeID: mode, appAcceptsCommands: viaCommand, now: t0))
        return machine
    }

    // MARK: Start

    @Test func startOpensAppWhenNotInStandby() {
        var machine = KeyboardDictation()
        let effects = machine.handle(.micTapped(newSessionID: session, modeID: mode, appAcceptsCommands: false, now: t0))
        #expect(effects == [.sendRequest(HandoffRequest(sessionID: session, createdAt: t0, modeID: mode)), .haptic(.start)])
        #expect(machine.phase == .waitingForApp(session, route: .openedApp, since: t0))
    }

    @Test func startSendsCommandInStandby() {
        var machine = KeyboardDictation()
        let effects = machine.handle(.micTapped(newSessionID: session, modeID: mode, appAcceptsCommands: true, now: t0))
        #expect(effects == [
            .sendCommand(HandoffCommand(action: .start, sessionID: session, modeID: mode, createdAt: t0)),
            .haptic(.start)
        ])
        #expect(machine.phase == .waitingForApp(session, route: .command, since: t0))
        // The app answers with `recording` for the new session.
        _ = machine.handle(.mailboxChanged(result: result(.recording), requestPending: false, now: t0))
        #expect(machine.phase == .recording(session))
    }

    // MARK: Pending

    @Test func presetRecordingIsPendingUntilRequestIsCleared() {
        var machine = started(viaCommand: false)
        // `writeRequest` pre-set `recording`; the request is still there.
        _ = machine.handle(.mailboxChanged(result: result(.recording, at: 0), requestPending: true, now: t0))
        #expect(machine.phase == .waitingForApp(session, route: .openedApp, since: t0))
        _ = machine.handle(.mailboxChanged(result: result(.recording), requestPending: false, now: t0))
        #expect(machine.phase == .recording(session))
    }

    @Test func pendingOpenTimesOut() {
        var machine = started(viaCommand: false)
        _ = machine.handle(.tick(now: t0.addingTimeInterval(KeyboardDictation.openTimeout - 1)))
        #expect(machine.phase.isActive)
        _ = machine.handle(.tick(now: t0.addingTimeInterval(KeyboardDictation.openTimeout + 1)))
        #expect(machine.phase == .failed(KeyboardDictation.Message.appDidNotOpen))
        // A late answer for the abandoned session is ignored.
        _ = machine.handle(.mailboxChanged(result: result(.recording, at: 20), requestPending: false, now: t0.addingTimeInterval(20)))
        #expect(machine.phase == .failed(KeyboardDictation.Message.appDidNotOpen))
    }

    @Test func tapWhilePendingReopensApp() {
        var machine = started(viaCommand: false)
        let later = t0.addingTimeInterval(3)
        let effects = machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: false, now: later))
        #expect(effects == [.openApp(session)])
        #expect(machine.phase == .waitingForApp(session, route: .openedApp, since: later))
    }

    @Test func refusedOpenFails() {
        var machine = started(viaCommand: false)
        _ = machine.handle(.openFailed(session))
        #expect(machine.phase == .failed(KeyboardDictation.Message.appDidNotOpen))
    }

    @Test func unansweredCommandFallsBackToOpeningTheApp() {
        var machine = started(viaCommand: true)
        _ = machine.handle(.tick(now: t0.addingTimeInterval(KeyboardDictation.commandTimeout + 1)))
        #expect(machine.phase == .failed(KeyboardDictation.Message.appDidNotRespond))
        #expect(machine.distrustsStandby)
        // app-state.json still claims standby, but the next start opens the app.
        let next = UUID()
        let effects = machine.handle(.micTapped(newSessionID: next, modeID: mode, appAcceptsCommands: true, now: t0.addingTimeInterval(10)))
        #expect(effects.first == .sendRequest(HandoffRequest(sessionID: next, createdAt: t0.addingTimeInterval(10), modeID: mode)))
        #expect(!machine.distrustsStandby)
    }

    // MARK: Stop and progress

    @Test func stopThenDoneInsertsOnce() {
        var machine = started(viaCommand: true)
        _ = machine.handle(.mailboxChanged(result: result(.recording), requestPending: false, now: t0))
        let stop = machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: true, now: t0.addingTimeInterval(5)))
        #expect(stop == [.sendCommand(HandoffCommand(action: .stop, sessionID: session, createdAt: t0.addingTimeInterval(5))), .haptic(.stop)])
        #expect(machine.phase == .stopping(session, since: t0.addingTimeInterval(5)))
        // A stale `recording` does not undo the stop.
        _ = machine.handle(.mailboxChanged(result: result(.recording), requestPending: false, now: t0.addingTimeInterval(5)))
        #expect(machine.phase == .stopping(session, since: t0.addingTimeInterval(5)))
        // Taps while processing do nothing.
        #expect(machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: true, now: t0.addingTimeInterval(6))).isEmpty)

        _ = machine.handle(.mailboxChanged(result: result(.transcribing, at: 6), requestPending: false, now: t0))
        #expect(machine.phase == .transcribing(session))
        _ = machine.handle(.mailboxChanged(result: result(.formatting, at: 7), requestPending: false, now: t0))
        #expect(machine.phase == .formatting(session))

        let done = result(.done, text: "Hello there.", at: 8)
        #expect(machine.handle(.mailboxChanged(result: done, requestPending: false, now: t0)) == [.insert("Hello there.", sessionID: session)])
        #expect(machine.phase == .inserted)
        // Darwin posts coalesce and repeat: the same result never types twice.
        #expect(machine.handle(.mailboxChanged(result: done, requestPending: false, now: t0)).isEmpty)
        var consumed = done
        consumed.consumed = true
        #expect(machine.handle(.mailboxChanged(result: consumed, requestPending: false, now: t0)).isEmpty)
    }

    @Test func tapWhileCommandStartIsPendingDoesNotStop() {
        var machine = started(viaCommand: true)
        #expect(machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: true, now: t0)).isEmpty)
        #expect(machine.phase == .waitingForApp(session, route: .command, since: t0))
    }

    @Test func unansweredStopFailsAndCancels() {
        var machine = started(viaCommand: true)
        _ = machine.handle(.mailboxChanged(result: result(.recording), requestPending: false, now: t0))
        _ = machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: true, now: t0))
        let now = t0.addingTimeInterval(KeyboardDictation.stopTimeout + 1)
        #expect(machine.handle(.tick(now: now)) == [.sendCommand(HandoffCommand(action: .cancel, sessionID: session, createdAt: now))])
        #expect(machine.phase == .failed(KeyboardDictation.Message.stopNotAnswered))
    }

    @Test func emptyTextIsNotTypedButConsumed() {
        var machine = started(viaCommand: true)
        let effects = machine.handle(.mailboxChanged(result: result(.done, text: "  "), requestPending: false, now: t0))
        #expect(effects == [.markConsumed(session)])
        #expect(machine.phase == .failed(KeyboardDictation.Message.noSpeech))
    }

    @Test func doneConsumedElsewhereIsNotTyped() {
        var machine = started(viaCommand: true)
        #expect(machine.handle(.mailboxChanged(result: result(.done, text: "Hi", consumed: true), requestPending: false, now: t0)).isEmpty)
        #expect(machine.phase == .inserted)
    }

    @Test func failureShowsAppMessage() {
        var machine = started(viaCommand: false)
        _ = machine.handle(.mailboxChanged(
            result: result(.failed, error: "KVoice is still working on the previous dictation."),
            requestPending: false, now: t0
        ))
        #expect(machine.phase == .failed("KVoice is still working on the previous dictation."))

        var other = started(viaCommand: false)
        _ = other.handle(.mailboxChanged(result: result(.failed), requestPending: false, now: t0))
        #expect(other.phase == .failed(KeyboardDictation.Message.failed))
    }

    @Test func cancelledByApp() {
        var machine = started(viaCommand: true)
        _ = machine.handle(.mailboxChanged(result: result(.cancelled), requestPending: false, now: t0))
        #expect(machine.phase == .cancelled)
    }

    @Test func cancelFromKeyboard() {
        var machine = started(viaCommand: true)
        _ = machine.handle(.mailboxChanged(result: result(.recording), requestPending: false, now: t0))
        #expect(machine.handle(.cancelTapped(now: t0)) == [.sendCommand(HandoffCommand(action: .cancel, sessionID: session, createdAt: t0))])
        #expect(machine.phase == .cancelled)
        // The app's late `done` for the cancelled session is not typed.
        #expect(machine.handle(.mailboxChanged(result: result(.done, text: "late"), requestPending: false, now: t0)).isEmpty)
        #expect(machine.handle(.cancelTapped(now: t0)).isEmpty)
    }

    @Test func cancelWhileWaitingForApp() {
        var machine = started(viaCommand: false)
        #expect(machine.handle(.cancelTapped(now: t0)) == [.sendCommand(HandoffCommand(action: .cancel, sessionID: session, createdAt: t0))])
        #expect(machine.phase == .cancelled)
        _ = machine.handle(.tick(now: t0.addingTimeInterval(60)))
        #expect(machine.phase == .cancelled)
    }

    // MARK: Fresh keyboard instance

    @Test func freshKeyboardAdoptsBackgroundRecording() {
        var machine = KeyboardDictation()
        // The user swiped back from KVoice, which keeps recording.
        _ = machine.handle(.mailboxChanged(result: result(.recording, at: 0), requestPending: false, now: t0.addingTimeInterval(20)))
        #expect(machine.phase == .recording(session))
        let effects = machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: true, now: t0.addingTimeInterval(30)))
        #expect(effects.first == .sendCommand(HandoffCommand(action: .stop, sessionID: session, createdAt: t0.addingTimeInterval(30))))
    }

    @Test func freshKeyboardWithUnopenedRequestTimesOut() {
        var machine = KeyboardDictation()
        _ = machine.handle(.mailboxChanged(result: result(.recording, at: 0), requestPending: true, now: t0.addingTimeInterval(1)))
        #expect(machine.phase == .waitingForApp(session, route: .openedApp, since: t0))
        _ = machine.handle(.tick(now: t0.addingTimeInterval(30)))
        #expect(machine.phase == .failed(KeyboardDictation.Message.appDidNotOpen))
    }

    @Test func freshKeyboardTypesRecentUnconsumedResult() {
        var machine = KeyboardDictation()
        let done = result(.done, text: "From the app", at: 0)
        #expect(machine.handle(.mailboxChanged(result: done, requestPending: false, now: t0.addingTimeInterval(30))) == [.insert("From the app", sessionID: session)])
        #expect(machine.phase == .inserted)
    }

    @Test func freshKeyboardIgnoresOldOrFinishedResults() {
        var machine = KeyboardDictation()
        let late = t0.addingTimeInterval(KeyboardDictation.insertWindow + 1)
        #expect(machine.handle(.mailboxChanged(result: result(.done, text: "old", at: 0), requestPending: false, now: late)).isEmpty)
        #expect(machine.handle(.mailboxChanged(result: result(.done, text: "x", at: 0, consumed: true), requestPending: false, now: t0)).isEmpty)
        #expect(machine.handle(.mailboxChanged(result: result(.failed, at: 0), requestPending: false, now: t0)).isEmpty)
        #expect(machine.handle(.mailboxChanged(result: result(.cancelled, at: 0), requestPending: false, now: t0)).isEmpty)
        let veryLate = t0.addingTimeInterval(KeyboardDictation.adoptWindow + 1)
        _ = machine.handle(.mailboxChanged(result: result(.recording, at: 0), requestPending: false, now: veryLate))
        #expect(machine.phase == .idle)
    }

    // MARK: Undo

    @Test func undoDeletesTheInsertion() {
        var machine = started(viaCommand: true)
        _ = machine.handle(.mailboxChanged(result: result(.done, text: "Hello"), requestPending: false, now: t0))
        machine.didInsert(" Hello")
        #expect(machine.lastInsertion == " Hello")
        #expect(machine.handle(.undoTapped(contextBeforeInput: "Say Hello")) == [.deleteBackward(count: 6)])
        #expect(machine.lastInsertion == nil)
        #expect(machine.phase == .idle)
        #expect(machine.handle(.undoTapped(contextBeforeInput: "Say Hello")).isEmpty)
    }

    @Test func undoRefusedAfterEdits() {
        var machine = KeyboardDictation()
        machine.didInsert("Hello")
        #expect(machine.handle(.undoTapped(contextBeforeInput: "Hello there")).isEmpty)
        #expect(machine.lastInsertion == nil)

        machine.didInsert("Hello")
        _ = machine.handle(.userEdited)
        #expect(machine.handle(.undoTapped(contextBeforeInput: "Hello")).isEmpty)
    }

    @Test func undoDeletionCount() {
        typealias K = KeyboardDictation
        #expect(K.undoDeletionCount(inserted: "Hi 👋🏽", contextBeforeInput: "Well, Hi 👋🏽") == 4)
        #expect(K.undoDeletionCount(inserted: "Hello", contextBeforeInput: "Hello!") == nil)
        #expect(K.undoDeletionCount(inserted: "Hello", contextBeforeInput: nil) == nil)
        #expect(K.undoDeletionCount(inserted: "Hello", contextBeforeInput: "") == nil)
        // The host truncated the context to the last paragraph.
        let text = "First paragraph.\nSecond paragraph is here."
        #expect(K.undoDeletionCount(inserted: text, contextBeforeInput: "Second paragraph is here.") == text.count)
        // A short tail is not enough to be sure.
        #expect(K.undoDeletionCount(inserted: text, contextBeforeInput: "here.") == nil)
    }

    @Test func insertionSpacing() {
        typealias K = KeyboardDictation
        #expect(K.insertionText(for: "world", contextBeforeInput: "Hello") == " world")
        #expect(K.insertionText(for: "world", contextBeforeInput: "Hello ") == "world")
        #expect(K.insertionText(for: "world", contextBeforeInput: nil) == "world")
        #expect(K.insertionText(for: "world", contextBeforeInput: "Line\n") == "world")
        #expect(K.insertionText(for: ", then", contextBeforeInput: "Hello") == ", then")
        #expect(K.insertionText(for: "quote", contextBeforeInput: "say (") == "quote")
    }
}
