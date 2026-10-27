import Foundation
import Synchronization

/// A small ring buffer of diagnostics for on-device debugging, stored in the
/// App Group (`Diagnostics/log.jsonl`). Log lengths and flags only, never
/// transcripts or keys.
public final class DiagnosticsLog: Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var date: Date
        public var category: String
        public var message: String

        public init(date: Date = .now, category: String, message: String) {
            self.date = date
            self.category = category
            self.message = message
        }
    }

    public static let capacity = 200

    public static let shared = DiagnosticsLog()

    private let fileURL: URL
    private let lock = Mutex<Void>(())

    public init(directory: URL = AppGroup.storageDirectory) {
        fileURL = directory
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
            .appending(path: "log.jsonl")
    }

    public func append(category: String, _ message: String, date: Date = .now) {
        lock.withLock { _ in
            var entries = Self.load(fileURL)
            entries.append(Entry(date: date, category: category, message: message))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
            write(entries)
        }
    }

    /// Oldest first.
    public func read() -> [Entry] {
        lock.withLock { _ in Self.load(fileURL) }
    }

    public func clear() {
        lock.withLock { _ in try? FileManager.default.removeItem(at: fileURL) }
    }

    private static func load(_ url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(Entry.self, from: Data($0))
        }
    }

    private func write(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? AppGroup.createProtectedDirectory(at: fileURL.deletingLastPathComponent())
        try? data.write(to: fileURL, options: AppGroup.fileWriteOptions)
    }
}
