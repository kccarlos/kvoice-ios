import Foundation

/// The keyboard's side of a handoff session as a pure state machine.
///
/// The keyboard extension feeds it events (taps, mailbox snapshots, clock
/// ticks) and performs the returned `Effect`s (write the mailbox, open the
/// app, type text). Time and session identifiers come in with the events,
/// so every transition is deterministic and unit-tested.
///
/// The keyboard instance is usually torn down while KVoice is in front, so
/// a fresh instance rebuilds its state from the mailbox
/// (`mailboxChanged`) rather than from memory.
public struct KeyboardDictation: Sendable, Equatable {
    /// How a session was started.
    public enum Route: Sendable, Equatable {
        /// `HandoffRequest` written and `kvoice://dictate?session=` opened.
        case openedApp
        /// `HandoffCommand(.start)` sent to the app in standby.
        case command
    }

    public enum Phase: Sendable, Equatable {
        case idle
        /// Waiting for the app to pick up the session.
        case waitingForApp(UUID, route: Route, since: Date)
        case recording(UUID)
        /// Stop sent; waiting for the app to start transcribing.
        case stopping(UUID, since: Date)
        case transcribing(UUID)
        case formatting(UUID)
        /// The last session's text was typed.
        case inserted
        case failed(String)
        case cancelled

        /// The session in flight, if any.
        public var sessionID: UUID? {
            switch self {
            case .waitingForApp(let id, _, _), .recording(let id), .stopping(let id, _),
                 .transcribing(let id), .formatting(let id):
                id
            case .idle, .inserted, .failed, .cancelled:
                nil
            }
        }

        public var isActive: Bool { sessionID != nil }
    }

    public enum Event: Sendable, Equatable {
        /// The mic button. `newSessionID` is used if this starts a session.
        case micTapped(newSessionID: UUID, modeID: UUID, appAcceptsCommands: Bool, now: Date)
        case cancelTapped(now: Date)
        /// A fresh read of the mailbox (after a Darwin notification, or when
        /// the keyboard appears). `requestPending` is true when `request.json`
        /// still holds this result's session: the app has not opened it yet.
        case mailboxChanged(result: HandoffResult?, requestPending: Bool, now: Date)
        /// Opening the app failed (the system refused the URL).
        case openFailed(UUID)
        case tick(now: Date)
        /// Undo the last insertion; `contextBeforeInput` is the text before
        /// the cursor.
        case undoTapped(contextBeforeInput: String?)
        /// The user typed or deleted: the last insertion is no longer undoable.
        case userEdited
    }

    public enum Haptic: Sendable, Equatable { case start, stop }

    public enum Effect: Sendable, Equatable {
        /// Write `request.json` (resets `result.json`) and open the app.
        case sendRequest(HandoffRequest)
        /// Open `kvoice://dictate?session=` again for a pending request.
        case openApp(UUID)
        case sendCommand(HandoffCommand)
        /// Type `text`, then mark the session's result consumed.
        case insert(String, sessionID: UUID)
        /// Mark a result consumed without typing (empty text).
        case markConsumed(UUID)
        case deleteBackward(count: Int)
        case haptic(Haptic)
    }

    // MARK: Timing

    /// How long the app has to clear `request.json` after it was opened.
    public static let openTimeout: TimeInterval = 8
    /// How long the app in standby has to answer a `start` command.
    public static let commandTimeout: TimeInterval = 5
    /// How long the app has to start transcribing after `stop`.
    public static let stopTimeout: TimeInterval = 10
    /// A fresh keyboard adopts an unfinished session updated this recently.
    public static let adoptWindow: TimeInterval = 30 * 60
    /// A fresh keyboard types an unconsumed result finished this recently
    /// (the same window the app accepts requests in).
    public static let insertWindow: TimeInterval = HandoffRequest.maximumAge

    // MARK: Messages

    public enum Message {
        public static let appDidNotOpen = "KVoice didn't open. Tap to try again."
        public static let appDidNotRespond = "KVoice didn't respond. Tap to try again."
        public static let stopNotAnswered = "KVoice isn't responding. Open KVoice to finish."
        public static let noSpeech = "No speech detected."
        public static let failed = "Dictation failed."
    }

    // MARK: State

    public private(set) var phase: Phase = .idle
    /// The exact text typed by the last insertion (what Undo removes).
    public private(set) var lastInsertion: String?
    /// After a command went unanswered, the next start opens the app even
    /// if `app-state.json` claims standby (a killed app leaves it behind).
    public private(set) var distrustsStandby = false
    /// Sessions this keyboard finished or abandoned: never adopted again.
    private var settledSessions: [UUID] = []

    public init() {}

    // MARK: Reducer

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .micTapped(newSessionID, modeID, appAcceptsCommands, now):
            return micTapped(newSessionID: newSessionID, modeID: modeID, appAcceptsCommands: appAcceptsCommands, now: now)

        case .cancelTapped(let now):
            guard let session = phase.sessionID else { return [] }
            settle(session)
            phase = .cancelled
            return [.sendCommand(HandoffCommand(action: .cancel, sessionID: session, createdAt: now))]

        case let .mailboxChanged(result, requestPending, now):
            return mailboxChanged(result, requestPending: requestPending, now: now)

        case .openFailed(let session):
            guard case .waitingForApp(session, .openedApp, _) = phase else { return [] }
            settle(session)
            phase = .failed(Message.appDidNotOpen)
            return []

        case .tick(let now):
            return tick(now: now)

        case .undoTapped(let context):
            guard let text = lastInsertion else { return [] }
            lastInsertion = nil
            guard let count = Self.undoDeletionCount(inserted: text, contextBeforeInput: context) else { return [] }
            if phase == .inserted { phase = .idle }
            return [.deleteBackward(count: count)]

        case .userEdited:
            lastInsertion = nil
            return []
        }
    }

    private mutating func micTapped(newSessionID: UUID, modeID: UUID, appAcceptsCommands: Bool, now: Date) -> [Effect] {
        switch phase {
        case .idle, .inserted, .failed, .cancelled:
            lastInsertion = nil
            if appAcceptsCommands && !distrustsStandby {
                phase = .waitingForApp(newSessionID, route: .command, since: now)
                return [
                    .sendCommand(HandoffCommand(action: .start, sessionID: newSessionID, modeID: modeID, createdAt: now)),
                    .haptic(.start)
                ]
            }
            distrustsStandby = false
            phase = .waitingForApp(newSessionID, route: .openedApp, since: now)
            return [.sendRequest(HandoffRequest(sessionID: newSessionID, createdAt: now, modeID: modeID)), .haptic(.start)]

        case .waitingForApp(let session, .openedApp, _):
            // The open may have been swallowed; try again (the request stays
            // valid for two minutes).
            phase = .waitingForApp(session, route: .openedApp, since: now)
            return [.openApp(session)]

        case .recording(let session):
            phase = .stopping(session, since: now)
            return [.sendCommand(HandoffCommand(action: .stop, sessionID: session, createdAt: now)), .haptic(.stop)]

        case .waitingForApp(_, .command, _), .stopping, .transcribing, .formatting:
            // A stop before the app started recording would be ignored.
            return []
        }
    }

    private mutating func mailboxChanged(_ result: HandoffResult?, requestPending: Bool, now: Date) -> [Effect] {
        guard let result, !settledSessions.contains(result.sessionID) else { return [] }
        if let session = phase.sessionID {
            // Results of other sessions are stale.
            guard result.sessionID == session else { return [] }
            return apply(result, requestPending: requestPending)
        }
        // No session in flight: adopt one a previous keyboard instance started.
        let age = now.timeIntervalSince(result.updatedAt)
        switch result.status {
        case .recording, .transcribing, .formatting:
            guard age <= Self.adoptWindow else { return [] }
            phase = .waitingForApp(result.sessionID, route: .openedApp, since: result.updatedAt)
            return apply(result, requestPending: requestPending)
        case .done:
            guard !result.consumed, age <= Self.insertWindow else { return [] }
            phase = .recording(result.sessionID)
            return apply(result, requestPending: requestPending)
        case .failed, .cancelled:
            return []
        }
    }

    /// Applies a result for the session in flight.
    private mutating func apply(_ result: HandoffResult, requestPending: Bool) -> [Effect] {
        let session = result.sessionID
        switch result.status {
        case .recording:
            switch phase {
            case .waitingForApp(_, .openedApp, _):
                // `writeRequest` pre-sets `recording`; only a cleared request
                // means the app really started.
                if !requestPending { phase = .recording(session) }
            case .waitingForApp(_, .command, _):
                phase = .recording(session)
            default:
                break // Already recording, or stop sent and not yet seen.
            }
            return []
        case .transcribing:
            phase = .transcribing(session)
            return []
        case .formatting:
            phase = .formatting(session)
            return []
        case .done:
            settle(session)
            if result.consumed {
                // Another keyboard instance typed it.
                phase = .inserted
                return []
            }
            let text = result.text ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .failed(Message.noSpeech)
                return [.markConsumed(session)]
            }
            phase = .inserted
            return [.insert(text, sessionID: session)]
        case .failed:
            settle(session)
            let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            phase = .failed(message.isEmpty ? Message.failed : message)
            return []
        case .cancelled:
            settle(session)
            phase = .cancelled
            return []
        }
    }

    private mutating func tick(now: Date) -> [Effect] {
        switch phase {
        case let .waitingForApp(session, .openedApp, since) where now.timeIntervalSince(since) > Self.openTimeout:
            settle(session)
            phase = .failed(Message.appDidNotOpen)
        case let .waitingForApp(session, .command, since) where now.timeIntervalSince(since) > Self.commandTimeout:
            settle(session)
            distrustsStandby = true
            phase = .failed(Message.appDidNotRespond)
        case let .stopping(session, since) where now.timeIntervalSince(since) > Self.stopTimeout:
            settle(session)
            distrustsStandby = true
            phase = .failed(Message.stopNotAnswered)
            // Don't leave a recording running behind the user's back.
            return [.sendCommand(HandoffCommand(action: .cancel, sessionID: session, createdAt: now))]
        default:
            break
        }
        return []
    }

    /// Records what the keyboard actually typed for `insert` (it may add a
    /// leading space), so Undo removes exactly that.
    public mutating func didInsert(_ typed: String) {
        lastInsertion = typed
    }

    private mutating func settle(_ session: UUID) {
        settledSessions.append(session)
        if settledSessions.count > 16 { settledSessions.removeFirst() }
    }

    // MARK: Text helpers

    /// The text to type for a dictation: a leading space is added when the
    /// cursor follows a word, so dictations don't run into existing text.
    public static func insertionText(for text: String, contextBeforeInput: String?) -> String {
        guard let last = contextBeforeInput?.last, let first = text.first else { return text }
        if last.isWhitespace || first.isWhitespace { return text }
        if ",.;:!?)]}%".contains(first) { return text }
        if "([{\"'“‘/-".contains(last) { return text }
        return " " + text
    }

    /// How many characters Undo deletes, or nil when the text before the
    /// cursor no longer ends with the insertion.
    ///
    /// `documentContextBeforeInput` can be truncated by the host (often to
    /// the current paragraph), so a context that is itself a long-enough
    /// tail of the insertion also counts.
    public static func undoDeletionCount(inserted: String, contextBeforeInput context: String?) -> Int? {
        guard !inserted.isEmpty, let context, !context.isEmpty else { return nil }
        if context.hasSuffix(inserted) { return inserted.count }
        if context.count >= minimumTruncatedContext, inserted.hasSuffix(context) { return inserted.count }
        return nil
    }

    /// The shortest truncated context trusted to identify an insertion.
    static let minimumTruncatedContext = 12
}
