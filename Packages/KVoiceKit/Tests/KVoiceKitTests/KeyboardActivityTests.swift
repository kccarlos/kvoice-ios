import Foundation
import Testing
@testable import KVoiceCore

/// The keyboard against the shared activity, and exactly-once insertion
/// across shortcut and keyboard results.
@Suite struct KeyboardActivityTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let mode = Mode.BuiltInID.dictation

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func activity(_ build: (inout DictationActivityReducer) -> Void) -> DictationActivity {
        var reducer = DictationActivityReducer()
        build(&reducer)
        return reducer.activity
    }

    // MARK: Mic gating

    @Test func shortcutRecordingDisablesTheMic() {
        let shared = activity { _ = $0.handle(.beginShortcut(newID: UUID(), modeID: nil, now: t0)) }
        var machine = KeyboardDictation()
        _ = machine.handle(.activityChanged(shared, now: at(1)))
        #expect(machine.external == .blocked(DictationActivity.Message.shortcutRecordingKeyboard))
        #expect(machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: false, now: at(2))).isEmpty)
        #expect(machine.phase == .idle)

        // Lease lapses: the mic works again.
        _ = machine.handle(.activityChanged(shared, now: at(DictationActivity.Lease.shortcutRecording + 1)))
        #expect(machine.external == .none)
        #expect(!machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: false, now: at(2))).isEmpty)
    }

    @Test func processingDisablesTheMicAndShowsTheStage() {
        let job = UUID()
        let shared = activity {
            _ = $0.handle(.transcribeRequested(newJobID: job, modeID: nil, now: t0))
            _ = $0.handle(.jobStage(jobID: job, stage: .formatting, now: t0))
        }
        var machine = KeyboardDictation()
        _ = machine.handle(.activityChanged(shared, now: at(1)))
        #expect(machine.external == .blocked("Formatting…"))
        #expect(machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: true, now: at(1))).isEmpty)
    }

    @Test func micStopsARecordingStartedInTheAppAndFollowsIt() {
        let appSession = UUID()
        let shared = activity {
            _ = $0.handle(.startAppRecording(sessionID: appSession, source: .app, modeID: nil, now: t0))
        }
        var machine = KeyboardDictation()
        _ = machine.handle(.activityChanged(shared, now: at(1)))
        #expect(machine.external == .appRecording(appSession))
        let effects = machine.handle(.micTapped(newSessionID: UUID(), modeID: mode, appAcceptsCommands: false, now: at(2)))
        #expect(effects == [
            .sendCommand(HandoffCommand(action: .stop, sessionID: appSession, createdAt: at(2))),
            .haptic(.stop)
        ])
        #expect(machine.phase == .stopping(appSession, since: at(2)))
        // The app adopts it as a keyboard session and reports progress.
        _ = machine.handle(.mailboxChanged(
            result: HandoffResult(sessionID: appSession, status: .transcribing, updatedAt: at(3)),
            requestPending: false, now: at(3)
        ))
        #expect(machine.phase == .transcribing(appSession))
        let done = machine.handle(.mailboxChanged(
            result: HandoffResult(sessionID: appSession, status: .done, text: "Hello", updatedAt: at(4)),
            requestPending: false, now: at(4)
        ))
        #expect(done == [.insert("Hello", sessionID: appSession)])
    }

    @Test func ownSessionIsNotExternal() {
        let session = UUID()
        var machine = KeyboardDictation()
        _ = machine.handle(.micTapped(newSessionID: session, modeID: mode, appAcceptsCommands: true, now: t0))
        let shared = activity { _ = $0.handle(.startAppRecording(sessionID: session, source: .keyboard, modeID: nil, now: t0)) }
        _ = machine.handle(.activityChanged(shared, now: at(1)))
        #expect(machine.external == .none)
    }

    @Test func standbyRoutesToCommandAndIdleOpensTheApp() {
        let standby = activity { _ = $0.handle(.standbyStarted(until: at(300), now: t0)) }
        #expect(standby.keyboardRoute(now: at(1)) == .command)
        var machine = KeyboardDictation()
        _ = machine.handle(.activityChanged(standby, now: at(1)))
        #expect(machine.external == .none)
        #expect(DictationActivity(updatedAt: t0).keyboardRoute(now: at(1)) == .openApp)
    }

    // MARK: Presence and insertion policy

    @Test func heartbeatIsFreshForFiveSeconds() {
        let presence = KeyboardPresence(keyboardVisibleAt: t0)
        #expect(presence.isVisible(now: at(0)))
        #expect(presence.isVisible(now: at(4.9)))
        #expect(!presence.isVisible(now: at(5)))
        #expect(!KeyboardPresence(keyboardVisibleAt: nil).isVisible(now: t0))
        #expect(KeyboardPresence.heartbeatInterval == 2)
    }

    @Test func insertionPolicy() {
        let visible = KeyboardPresence(keyboardVisibleAt: t0)
        let stale = KeyboardPresence(keyboardVisibleAt: at(-30))
        #expect(KeyboardInsertion.decide(source: .shortcut, presence: visible, isDeviceLocked: false, now: at(1)) == .insert)
        #expect(KeyboardInsertion.decide(source: .shortcut, presence: stale, isDeviceLocked: false, now: at(1)) == .keyboardNotVisible)
        #expect(KeyboardInsertion.decide(source: .shortcut, presence: nil, isDeviceLocked: false, now: at(1)) == .keyboardNotVisible)
        #expect(KeyboardInsertion.decide(source: .shortcut, presence: visible, isDeviceLocked: true, now: at(1)) == .notApplicableLocked)
        #expect(KeyboardInsertion.decide(source: .app, presence: stale, isDeviceLocked: false, now: at(1)) == .keyboardNotVisible)
        // Keyboard sessions are always left for the keyboard to adopt.
        #expect(KeyboardInsertion.decide(source: .keyboard, presence: nil, isDeviceLocked: false, now: at(1)) == .insert)
        #expect(KeyboardInsertion.notApplicableLocked.writesConsumed)
        #expect(!KeyboardInsertion.insert.writesConsumed)
    }

    @Test func presenceRoundTripsWithoutNotification() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let handoff = DictationHandoff(directory: directory.url, postsNotifications: false)
        try handoff.writeKeyboardPresence(t0)
        #expect(handoff.readKeyboardPresence()?.isVisible(now: at(1)) == true)
        try handoff.writeKeyboardPresence(nil)
        #expect(handoff.readKeyboardPresence()?.isVisible(now: at(1)) == false)
    }

    // MARK: Exactly-once insertion

    /// Runs a keyboard instance against a real mailbox, typing into `text`.
    struct KeyboardInstance {
        var machine = KeyboardDictation()
        var text = ""
        let handoff: DictationHandoff

        mutating func perform(_ effects: [KeyboardDictation.Effect]) throws {
            for effect in effects {
                switch effect {
                case let .insert(value, session):
                    text += value
                    try handoff.markResultConsumed(sessionID: session)
                case .markConsumed(let session):
                    try handoff.markResultConsumed(sessionID: session)
                case .sendRequest(let request):
                    try handoff.writeRequest(request)
                case .sendCommand(let command):
                    try handoff.writeCommand(command)
                default:
                    break
                }
            }
        }

        /// A Darwin notification (or `activate`): read the mailbox.
        mutating func readMailbox(now: Date) throws {
            let result = handoff.readResult()
            let pending = result.map { handoff.readRequest()?.sessionID == $0.sessionID } ?? false
            try perform(machine.handle(.mailboxChanged(result: result, requestPending: pending, now: now)))
        }
    }

    /// What the app does when a job finishes: write the result only for a
    /// keyboard that should type it.
    func deliver(_ text: String, jobID: UUID, source: DictationActivity.Source, handoff: DictationHandoff, now: Date) throws {
        let insertion = KeyboardInsertion.decide(
            source: source, presence: handoff.readKeyboardPresence(), isDeviceLocked: false, now: now
        )
        if insertion == .insert {
            try handoff.writeResult(HandoffResult(sessionID: jobID, status: .done, text: text, updatedAt: now))
        }
    }

    @Test func shortcutAndKeyboardResultsAreEachInsertedExactlyOnce() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let handoff = DictationHandoff(directory: directory.url, postsNotifications: false)
        var first = KeyboardInstance(handoff: handoff)

        // 1. A shortcut job finishes while the keyboard is visible.
        try handoff.writeKeyboardPresence(at(0))
        try deliver("Shortcut text.", jobID: UUID(), source: .shortcut, handoff: handoff, now: at(1))
        try first.readMailbox(now: at(1))
        try first.readMailbox(now: at(1.5)) // A coalesced duplicate notification.
        #expect(first.text == "Shortcut text.")
        // A fresh keyboard instance (the old one was torn down) types nothing.
        var second = KeyboardInstance(handoff: handoff)
        try second.readMailbox(now: at(2))
        #expect(second.text.isEmpty)

        // 2. A keyboard-originated dictation right after.
        let session = UUID()
        try first.perform(first.machine.handle(.micTapped(newSessionID: session, modeID: mode, appAcceptsCommands: false, now: at(3))))
        handoff.clearRequest() // The app opened it.
        try handoff.writeResult(HandoffResult(sessionID: session, status: .recording, updatedAt: at(4)))
        try first.readMailbox(now: at(4))
        try handoff.writeResult(HandoffResult(sessionID: session, status: .done, text: " Keyboard text.", updatedAt: at(6)))
        try first.readMailbox(now: at(6))
        try second.readMailbox(now: at(6))
        try first.readMailbox(now: at(7))
        #expect(first.text + second.text == "Shortcut text. Keyboard text.")

        // 3. A shortcut result while no keyboard is visible is never typed,
        //    even by a keyboard that appears within the insert window.
        try handoff.writeKeyboardPresence(nil)
        try deliver("Not typed.", jobID: UUID(), source: .shortcut, handoff: handoff, now: at(8))
        var third = KeyboardInstance(handoff: handoff)
        try third.readMailbox(now: at(9))
        #expect(third.text.isEmpty)
        #expect(handoff.readResult()?.consumed == true)
    }

    @Test func aFreshKeyboardTypesAnUnconsumedShortcutResultOnce() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let handoff = DictationHandoff(directory: directory.url, postsNotifications: false)
        try handoff.writeKeyboardPresence(at(0))
        try deliver("Once.", jobID: UUID(), source: .shortcut, handoff: handoff, now: at(1))
        // Two keyboard instances race to read it.
        var a = KeyboardInstance(handoff: handoff)
        var b = KeyboardInstance(handoff: handoff)
        try a.readMailbox(now: at(2))
        try b.readMailbox(now: at(2))
        #expect(a.text + b.text == "Once.")
    }
}
