import Foundation

/// Who owns the microphone and what KVoice is doing, shared by the app, the
/// keyboard and the widgets through the App Group (`activity.json`).
///
/// It is the single authority for every entry point: the keyboard mic, the
/// app's record button, `DictateIntent` (Siri, widget, Control Center) and
/// the Action Button shortcut. Only the app writes it, through
/// `DictationActivityReducer`. Every non-idle phase carries a lease; an
/// expired lease reads as idle, so a cancelled shortcut or a killed app can
/// never leave it stuck. See `Docs/DictationStates.md`.
public struct DictationActivity: Codable, Sendable, Hashable {
    /// Who holds the microphone while recording.
    public enum Owner: String, Codable, Sendable, Hashable {
        /// KVoice records with its own audio engine.
        case app
        /// The Shortcuts app records (Record Audio) between Begin Dictation
        /// and Transcribe Audio.
        case shortcut
    }

    /// The entry point that started a dictation.
    public enum Source: String, Codable, Sendable, Hashable {
        case keyboard
        /// The record button in the app.
        case app
        /// `DictateIntent`: Siri, a widget or Control Center.
        case intent
        /// The Action Button / Shortcuts flow.
        case shortcut
    }

    public enum Stage: String, Codable, Sendable, Hashable {
        case transcribing
        case formatting
    }

    public enum Phase: Codable, Sendable, Hashable {
        case idle
        /// The app keeps its input engine running for keyboard commands.
        case standby(expiresAt: Date)
        case recording(owner: Owner, source: Source, startedAt: Date)
        case processing(stage: Stage, jobID: UUID)
        case delivered(jobID: UUID)
        case failed(jobID: UUID, message: String)

        public var isIdle: Bool { self == .idle }

        /// The microphone owner while recording.
        public var recordingOwner: Owner? {
            if case .recording(let owner, _, _) = self { return owner }
            return nil
        }
    }

    public var id: UUID
    public var phase: Phase
    public var modeID: UUID?
    /// Accepted processing jobs, oldest (the running one) first.
    public var jobs: [UUID]
    /// When the phase lapses to idle; nil only for `idle`.
    public var leaseExpiresAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        phase: Phase = .idle,
        modeID: UUID? = nil,
        jobs: [UUID] = [],
        leaseExpiresAt: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.phase = phase
        self.modeID = modeID
        self.jobs = jobs
        self.leaseExpiresAt = leaseExpiresAt
        self.updatedAt = updatedAt
    }

    /// Lease lengths.
    public enum Lease {
        /// The app renews it while it records; a killed app lapses quickly.
        public static let appRecording: TimeInterval = 120
        /// Long enough for a spoken note in the Record Audio panel.
        public static let shortcutRecording: TimeInterval = 15 * 60
        /// Renewed while a job runs.
        public static let processing: TimeInterval = 60
        /// A finished result is shown (and insertable) this long.
        public static let result: TimeInterval = HandoffRequest.maximumAge
        /// How often the app renews a running lease.
        public static let renewInterval: TimeInterval = 15
    }

    /// Whether the phase still holds (always true for idle).
    public func isLeaseValid(now: Date) -> Bool {
        if phase.isIdle { return true }
        guard let leaseExpiresAt else { return false }
        return leaseExpiresAt > now
    }

    /// The phase as every reader must see it: an expired lease is idle.
    public func effectivePhase(now: Date) -> Phase {
        isLeaseValid(now: now) ? phase : .idle
    }

    /// The legacy "app takes keyboard commands" view of this record.
    public func appState(now: Date) -> HandoffAppState {
        if case .standby(let expiresAt) = effectivePhase(now: now) {
            return HandoffAppState(isListeningForCommands: true, updatedAt: updatedAt, expiresAt: expiresAt)
        }
        return HandoffAppState(isListeningForCommands: false, updatedAt: updatedAt)
    }

    // MARK: Entry-point views

    /// What the keyboard mic does in the current phase.
    public enum KeyboardRoute: Sendable, Hashable {
        /// Write a `HandoffRequest` and open the app.
        case openApp
        /// Send `HandoffCommand(.start)` to the app in standby.
        case command
        /// Stop the app's recording with this session id.
        case stop(UUID)
        /// The mic is disabled; show the message.
        case blocked(String)
    }

    public enum Message {
        public static let shortcutRecordingKeyboard = "Recording with the Action Button — tap Stop in the recording panel"
        public static let shortcutRecordingApp = "Recording with the Action Button"
        public static let busy = "KVoice is still working on the previous dictation."
        public static let transcribing = "Transcribing…"
        public static let formatting = "Formatting…"
    }

    public func keyboardRoute(now: Date) -> KeyboardRoute {
        switch effectivePhase(now: now) {
        case .idle, .delivered, .failed:
            return .openApp
        case .standby:
            return .command
        case .recording(.app, _, _):
            return .stop(id)
        case .recording(.shortcut, _, _):
            return .blocked(Message.shortcutRecordingKeyboard)
        case .processing(.transcribing, _):
            return .blocked(Message.transcribing)
        case .processing(.formatting, _):
            return .blocked(Message.formatting)
        }
    }
}

/// When the keyboard was last on screen (`keyboard.json`). Written by the
/// keyboard about every 2 s while visible with Full Access.
public struct KeyboardPresence: Codable, Sendable, Hashable {
    public var keyboardVisibleAt: Date?

    public init(keyboardVisibleAt: Date?) {
        self.keyboardVisibleAt = keyboardVisibleAt
    }

    public static let heartbeatInterval: TimeInterval = 2
    /// The keyboard counts as visible while the heartbeat is this fresh.
    public static let visibleWindow: TimeInterval = 5

    public func isVisible(now: Date) -> Bool {
        guard let keyboardVisibleAt else { return false }
        let age = now.timeIntervalSince(keyboardVisibleAt)
        return age >= -1 && age < Self.visibleWindow
    }
}

/// Whether a finished dictation should be typed by the KVoice keyboard.
public enum KeyboardInsertion: Sendable, Hashable {
    /// Leave the result unconsumed: the keyboard types it once.
    case insert
    /// The keyboard is not on screen: write the result already consumed.
    case keyboardNotVisible
    /// The device is locked: insertion is not applicable.
    case notApplicableLocked

    /// - Parameters:
    ///   - source: Where the dictation started. Keyboard sessions are always
    ///     left for the keyboard (it adopts them when it comes back).
    ///   - presence: The keyboard heartbeat.
    ///   - isDeviceLocked: Protected data is unavailable.
    public static func decide(
        source: DictationActivity.Source,
        presence: KeyboardPresence?,
        isDeviceLocked: Bool,
        now: Date
    ) -> KeyboardInsertion {
        if isDeviceLocked { return .notApplicableLocked }
        if source == .keyboard { return .insert }
        return presence?.isVisible(now: now) == true ? .insert : .keyboardNotVisible
    }

    /// The `consumed` flag to write with the result.
    public var writesConsumed: Bool { self != .insert }
}

/// The decision taken when the audio session is interrupted while
/// recording.
public enum InterruptionSalvage {
    /// Recordings at least this long are processed, shorter ones cancelled.
    public static let minimumDuration: TimeInterval = 1

    public static func shouldProcess(recordedDuration: TimeInterval) -> Bool {
        recordedDuration >= minimumDuration
    }
}
