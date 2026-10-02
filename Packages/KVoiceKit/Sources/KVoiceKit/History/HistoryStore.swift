import Foundation
import SwiftData

/// One dictation in the history.
public struct HistoryRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var duration: TimeInterval
    public var modeID: UUID?
    public var modeName: String
    /// Engine display name ("Apple Speech", "Whisper Base", ...).
    public var engine: String
    /// AI provider and model, or nil for plain dictation.
    public var provider: String?
    public var rawTranscript: String
    public var formattedText: String
    /// The recording's file name inside `HistoryStore.recordingsDirectory`,
    /// or nil when audio is not kept.
    public var audioFileName: String?

    public init(
        id: UUID = UUID(),
        date: Date = .now,
        duration: TimeInterval,
        modeID: UUID? = nil,
        modeName: String,
        engine: String,
        provider: String? = nil,
        rawTranscript: String,
        formattedText: String,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.duration = duration
        self.modeID = modeID
        self.modeName = modeName
        self.engine = engine
        self.provider = provider
        self.rawTranscript = rawTranscript
        self.formattedText = formattedText
        self.audioFileName = audioFileName
    }
}

@Model
final class HistoryEntry {
    @Attribute(.unique) var id: UUID
    var date: Date
    var duration: Double
    var modeID: UUID?
    var modeName: String
    var engine: String
    var provider: String?
    var rawTranscript: String
    var formattedText: String
    var audioFileName: String?

    init(_ record: HistoryRecord) {
        id = record.id
        date = record.date
        duration = record.duration
        modeID = record.modeID
        modeName = record.modeName
        engine = record.engine
        provider = record.provider
        rawTranscript = record.rawTranscript
        formattedText = record.formattedText
        audioFileName = record.audioFileName
    }

    var record: HistoryRecord {
        HistoryRecord(
            id: id, date: date, duration: duration, modeID: modeID, modeName: modeName,
            engine: engine, provider: provider, rawTranscript: rawTranscript,
            formattedText: formattedText, audioFileName: audioFileName
        )
    }
}

/// The dictation history: a SwiftData store plus a folder of recordings,
/// both in the App Group container.
public actor HistoryStore: ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor
    /// Where recordings are written and kept.
    public nonisolated let recordingsDirectory: URL

    /// - Parameters:
    ///   - directory: Parent folder for `History.store` and `Recordings/`
    ///     (App Group storage by default).
    ///   - inMemory: Keep the database in memory (previews).
    public init(directory: URL? = nil, inMemory: Bool = false) throws {
        let directory = directory ?? AppGroup.storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recordings = directory.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let configuration = inMemory
            ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: directory.appending(path: "History.store"))
        let container = try ModelContainer(for: HistoryEntry.self, configurations: configuration)
        self.modelContainer = container
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.recordingsDirectory = recordings
    }

    /// A fresh file URL for the next recording.
    public nonisolated func newRecordingURL() -> URL {
        recordingsDirectory.appending(path: "\(UUID().uuidString).wav")
    }

    /// The full URL of a record's audio, if it is still on disk.
    public nonisolated func audioURL(for record: HistoryRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = recordingsDirectory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func add(_ record: HistoryRecord) throws {
        modelContext.insert(HistoryEntry(record))
        try modelContext.save()
    }

    /// Replaces the stored record with the same identifier.
    public func update(_ record: HistoryRecord) throws {
        guard let entry = try entry(id: record.id) else { return }
        entry.date = record.date
        entry.duration = record.duration
        entry.modeID = record.modeID
        entry.modeName = record.modeName
        entry.engine = record.engine
        entry.provider = record.provider
        entry.rawTranscript = record.rawTranscript
        entry.formattedText = record.formattedText
        entry.audioFileName = record.audioFileName
        try modelContext.save()
    }

    public func record(id: UUID) throws -> HistoryRecord? {
        try entry(id: id)?.record
    }

    /// Newest first.
    public func all(limit: Int? = nil) throws -> [HistoryRecord] {
        var descriptor = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.record)
    }

    /// Case- and diacritic-insensitive search over the raw transcript and
    /// the formatted text, newest first. An empty query returns everything.
    public func search(_ query: String) throws -> [HistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try all() }
        let descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate {
                $0.rawTranscript.localizedStandardContains(trimmed)
                    || $0.formattedText.localizedStandardContains(trimmed)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(\.record)
    }

    public func delete(id: UUID) throws {
        guard let entry = try entry(id: id) else { return }
        removeAudio(named: entry.audioFileName)
        modelContext.delete(entry)
        try modelContext.save()
    }

    public func deleteAll() throws {
        for entry in try modelContext.fetch(FetchDescriptor<HistoryEntry>()) {
            removeAudio(named: entry.audioFileName)
            modelContext.delete(entry)
        }
        try modelContext.save()
    }

    /// Deletes records older than the policy allows and, when audio is not
    /// kept, every stored recording. Returns the number of records deleted.
    @discardableResult
    public func applyRetention(_ policy: RetentionPolicy, now: Date = .now) throws -> Int {
        var deleted = 0
        if let maximumAge = policy.period.maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            let expired = try modelContext.fetch(FetchDescriptor<HistoryEntry>(
                predicate: #Predicate { $0.date < cutoff }
            ))
            for entry in expired {
                removeAudio(named: entry.audioFileName)
                modelContext.delete(entry)
            }
            deleted = expired.count
        }
        if !policy.keepsAudio {
            let withAudio = try modelContext.fetch(FetchDescriptor<HistoryEntry>(
                predicate: #Predicate { $0.audioFileName != nil }
            ))
            for entry in withAudio {
                removeAudio(named: entry.audioFileName)
                entry.audioFileName = nil
            }
        }
        try modelContext.save()
        removeOrphanedRecordings()
        return deleted
    }

    private func entry(id: UUID) throws -> HistoryEntry? {
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func removeAudio(named name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: recordingsDirectory.appending(path: name))
    }

    /// Recordings no record points at (an interrupted dictation), older than
    /// an hour so an in-progress recording is never touched.
    private func removeOrphanedRecordings() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let referenced = Set(((try? modelContext.fetch(FetchDescriptor<HistoryEntry>())) ?? []).compactMap(\.audioFileName))
        let cutoff = Date.now.addingTimeInterval(-3600)
        for file in files where !referenced.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
