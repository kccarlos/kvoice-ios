import Foundation
import Testing

/// Each vendor SDK is imported by exactly one adapter file.
@Suite struct VendorBoundaryTests {
    static let sources = URL(filePath: #filePath)
        .deletingLastPathComponent() // KVoiceKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // KVoiceKit
        .appending(path: "Sources/KVoiceKit")

    static func files(importing module: String) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var matches: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "import \(module)" }) {
                matches.append(url.lastPathComponent)
            }
        }
        return matches
    }

    @Test(arguments: [
        ("FoundationModels", "AppleIntelligenceFormatter.swift"),
        ("Speech", "AppleSpeechEngine.swift"),
        ("WhisperKit", "WhisperKitEngine.swift")
    ])
    func oneFileImportsVendor(module: String, file: String) throws {
        try #require(FileManager.default.fileExists(atPath: Self.sources.path), "sources not reachable from the test host")
        #expect(try Self.files(importing: module) == [file])
    }
}
