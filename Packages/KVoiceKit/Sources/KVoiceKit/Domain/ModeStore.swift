import Foundation
import Observation

/// The user's modes, persisted as JSON in the App Group container, and the
/// active mode, persisted in App Group defaults so the app and the keyboard
/// share both. Every change posts a Darwin notification so the other
/// process can call `reload()`.
@MainActor
@Observable
public final class ModeStore {
    public enum StoreError: Error, Equatable, LocalizedError {
        case notFound
        case emptyName

        public var errorDescription: String? {
            switch self {
            case .notFound: "That mode no longer exists."
            case .emptyName: "A mode needs a name."
            }
        }
    }

    public private(set) var modes: [Mode]
    public private(set) var activeModeID: UUID

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifies: Bool

    static let activeModeKey = "activeModeID"
    static let fileName = "modes.json"

    /// - Parameters:
    ///   - directory: Where `modes.json` lives (App Group container by default).
    ///   - defaults: Where the active mode identifier lives.
    ///   - postsNotifications: Post Darwin notifications on change.
    public init(
        directory: URL? = nil,
        defaults: UserDefaults = AppGroup.defaults,
        postsNotifications: Bool = true
    ) {
        let directory = directory ?? AppGroup.storageDirectory
        self.fileURL = directory.appending(path: Self.fileName)
        self.defaults = defaults
        self.notifies = postsNotifications
        self.modes = Mode.builtIns
        self.activeModeID = Mode.BuiltInID.dictation
        reload()
    }

    /// The active mode, falling back to the first mode if the stored
    /// identifier no longer exists.
    public var activeMode: Mode {
        modes.first { $0.id == activeModeID } ?? modes.first ?? .dictation
    }

    public func mode(id: UUID) -> Mode? {
        modes.first { $0.id == id }
    }

    /// Re-reads modes and the active selection from disk (for example after
    /// the other process posted `DarwinNotificationName.modesChanged`).
    public func reload() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Mode].self, from: data),
           !decoded.isEmpty {
            modes = decoded
        } else {
            modes = Mode.builtIns
        }
        if let raw = defaults.string(forKey: Self.activeModeKey),
           let id = UUID(uuidString: raw),
           modes.contains(where: { $0.id == id }) {
            activeModeID = id
        } else {
            activeModeID = modes.first?.id ?? Mode.BuiltInID.dictation
        }
    }

    public func setActiveMode(id: UUID) throws {
        guard modes.contains(where: { $0.id == id }) else { throw StoreError.notFound }
        activeModeID = id
        defaults.set(id.uuidString, forKey: Self.activeModeKey)
        post(.activeModeChanged)
    }

    /// Adds a new mode, or replaces the mode with the same identifier.
    public func save(_ mode: Mode) throws {
        guard !mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyName
        }
        if let index = modes.firstIndex(where: { $0.id == mode.id }) {
            modes[index] = mode
        } else {
            modes.append(mode)
        }
        try persist()
    }

    /// Deletes a mode. Deleting the active mode activates the first
    /// remaining one. The last mode cannot be deleted.
    public func delete(id: UUID) throws {
        guard let index = modes.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        guard modes.count > 1 else { return }
        modes.remove(at: index)
        try persist()
        if activeModeID == id, let first = modes.first {
            try setActiveMode(id: first.id)
        }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        let moving = source.filter { modes.indices.contains($0) }.map { modes[$0] }
        let insertion = destination - source.filter { $0 < destination }.count
        var remaining = modes.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: min(max(insertion, 0), remaining.count))
        modes = remaining
        try persist()
    }

    /// Restores the shipped built-ins (keeps custom modes).
    public func resetBuiltIns() throws {
        let custom = modes.filter { !$0.isBuiltIn }
        modes = Mode.builtIns + custom
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(modes).write(to: fileURL, options: .atomic)
        post(.modesChanged)
    }

    private func post(_ name: DarwinNotificationName) {
        guard notifies else { return }
        DarwinNotifications.post(name)
    }
}
