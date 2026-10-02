import Foundation

/// The record of downloaded models: model id → folder path relative to the
/// models directory. Paths are recorded from what the downloader returned,
/// never guessed from the repository's naming.
struct WhisperModelManifest: Codable, Sendable, Equatable {
    var installed: [String: String] = [:]

    static let fileName = "installed-models.json"

    static func load(from directory: URL) -> WhisperModelManifest {
        guard let data = try? Data(contentsOf: directory.appending(path: fileName)),
              let manifest = try? JSONDecoder().decode(WhisperModelManifest.self, from: data) else {
            return WhisperModelManifest()
        }
        return manifest
    }

    func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }
}
