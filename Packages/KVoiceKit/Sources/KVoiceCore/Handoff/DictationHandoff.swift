import Foundation

/// A dictation the keyboard asked the app to run.
public struct HandoffRequest: Codable, Sendable, Hashable {
    public var sessionID: UUID
    public var createdAt: Date
    /// The mode active in the keyboard when it asked.
    public var modeID: UUID

    public init(sessionID: UUID = UUID(), createdAt: Date = .now, modeID: UUID) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.modeID = modeID
    }

    /// Requests older than this are ignored (the user moved on).
    public static let maximumAge: TimeInterval = 120

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Self.maximumAge
    }
}

/// A command the keyboard sends to an app that is already running (FR-4).
public struct HandoffCommand: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable, Hashable {
        case start
        case stop
        case cancel
    }

    public var action: Action
    public var sessionID: UUID
    public var modeID: UUID?
    public var createdAt: Date

    public init(action: Action, sessionID: UUID, modeID: UUID? = nil, createdAt: Date = .now) {
        self.action = action
        self.sessionID = sessionID
        self.modeID = modeID
        self.createdAt = createdAt
    }

    /// Commands older than this are ignored (a stale file from an earlier run).
    public static let maximumAge: TimeInterval = 30

    public func isExpired(now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) > Self.maximumAge
    }
}

/// The app's progress on a handoff session, read by the keyboard.
public struct HandoffResult: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case recording
        case transcribing
        case formatting
        case done
        case failed
        case cancelled

        public var isFinal: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public var sessionID: UUID
    public var status: Status
    /// Final text when `status == .done`.
    public var text: String?
    /// User-presentable message when `status == .failed`.
    public var errorMessage: String?
    public var updatedAt: Date
    /// Set once the keyboard has inserted the text, so it is never typed twice.
    public var consumed: Bool

    public init(
        sessionID: UUID,
        status: Status,
        text: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = .now,
        consumed: Bool = false
    ) {
        self.sessionID = sessionID
        self.status = status
        self.text = text
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
        self.consumed = consumed
    }
}

/// Whether the app can take keyboard commands without being opened.
public struct HandoffAppState: Codable, Sendable, Hashable {
    /// The app is alive in the background with an active audio session and
    /// will react to `HandoffCommand`s.
    public var isListeningForCommands: Bool
    public var updatedAt: Date
    /// When the app stops listening on its own (the keep-alive window ends).
    /// A file left behind by a terminated app reads as unavailable after it.
    public var expiresAt: Date?

    public init(isListeningForCommands: Bool, updatedAt: Date = .now, expiresAt: Date? = nil) {
        self.isListeningForCommands = isListeningForCommands
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }

    /// Whether the keyboard can send a `HandoffCommand` instead of opening
    /// the app.
    public func acceptsCommands(now: Date = .now) -> Bool {
        guard isListeningForCommands else { return false }
        guard let expiresAt else { return true }
        return expiresAt > now
    }
}

/// File-based mailbox in the App Group between the keyboard and the app.
///
/// The keyboard cannot use the microphone, so it writes a `HandoffRequest`
/// and opens the app (`kvoice://dictate?session=...`); when the app is
/// already recording in the background it writes a `HandoffCommand`
/// instead. The app reports progress in a `HandoffResult`. Every write posts
/// the matching Darwin notification.
public struct DictationHandoff: Sendable {
    public let directory: URL
    private let notifies: Bool

    public init(directory: URL? = nil, postsNotifications: Bool = true) {
        self.directory = directory ?? AppGroup.storageDirectory.appending(path: "Handoff", directoryHint: .isDirectory)
        self.notifies = postsNotifications
    }

    static let requestFile = "request.json"
    static let commandFile = "command.json"
    static let resultFile = "result.json"
    static let appStateFile = "app-state.json"

    /// The URL the keyboard opens to hand a session to the app.
    public static func dictationURL(sessionID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = "kvoice"
        components.host = "dictate"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID.uuidString)]
        return components.url!
    }

    /// `kvoice://dictate` without a session: start a dictation in the app
    /// itself (widgets, Control Center, Shortcuts). `modeID` selects a mode.
    public static func appDictationURL(modeID: UUID? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "kvoice"
        components.host = "dictate"
        if let modeID {
            components.queryItems = [URLQueryItem(name: "mode", value: modeID.uuidString)]
        }
        return components.url!
    }

    /// Whether a URL is any `kvoice://dictate` URL.
    public static func isDictationURL(_ url: URL) -> Bool {
        url.scheme == "kvoice" && url.host == "dictate"
    }

    /// The mode identifier in a `kvoice://dictate?mode=` URL.
    public static func modeID(from url: URL) -> UUID? {
        guard isDictationURL(url),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "mode" })?.value else { return nil }
        return UUID(uuidString: value)
    }

    /// The session identifier in a `kvoice://dictate?session=` URL.
    public static func sessionID(from url: URL) -> UUID? {
        guard url.scheme == "kvoice", url.host == "dictate",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "session" })?.value else { return nil }
        return UUID(uuidString: value)
    }

    // MARK: Keyboard side

    public func writeRequest(_ request: HandoffRequest) throws {
        try write(request, to: Self.requestFile)
        try write(HandoffResult(sessionID: request.sessionID, status: .recording), to: Self.resultFile)
        post(.handoffRequest)
    }

    public func writeCommand(_ command: HandoffCommand) throws {
        try write(command, to: Self.commandFile)
        post(.handoffCommand)
    }

    public func readResult() -> HandoffResult? {
        read(HandoffResult.self, from: Self.resultFile)
    }

    /// Marks the result inserted so a second keyboard instance won't type it.
    public func markResultConsumed(sessionID: UUID) throws {
        guard var result = readResult(), result.sessionID == sessionID else { return }
        result.consumed = true
        try write(result, to: Self.resultFile)
    }

    public func readAppState() -> HandoffAppState? {
        read(HandoffAppState.self, from: Self.appStateFile)
    }

    // MARK: App side

    public func readRequest() -> HandoffRequest? {
        read(HandoffRequest.self, from: Self.requestFile)
    }

    public func readCommand() -> HandoffCommand? {
        read(HandoffCommand.self, from: Self.commandFile)
    }

    public func clearRequest() {
        try? FileManager.default.removeItem(at: directory.appending(path: Self.requestFile))
    }

    public func writeResult(_ result: HandoffResult) throws {
        try write(result, to: Self.resultFile)
        post(.handoffResult)
    }

    public func writeAppState(_ state: HandoffAppState) throws {
        try write(state, to: Self.appStateFile)
        post(.handoffAppState)
    }

    // MARK: Coding

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func write(_ value: some Encodable, to file: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(value).write(to: directory.appending(path: file), options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: file)) else { return nil }
        return try? Self.decoder().decode(type, from: data)
    }

    private func post(_ name: DarwinNotificationName) {
        if notifies { DarwinNotifications.post(name) }
    }
}
