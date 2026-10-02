import Foundation
import Testing

/// Each vendor SDK is imported by exactly one adapter file.
@Suite struct VendorBoundaryTests {
    static let package = URL(filePath: #filePath)
        .deletingLastPathComponent() // KVoiceKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // KVoiceKit
    static let sources = package.appending(path: "Sources/KVoiceKit")
    static let coreSources = package.appending(path: "Sources/KVoiceCore")

    static func files(importing module: String, in directory: URL = sources) throws -> [String] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
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

    /// KVoiceCore is linked by the keyboard extension, which has a tight
    /// memory limit: it must not pull in audio, ML or persistence frameworks.
    @Test(arguments: ["WhisperKit", "Speech", "FoundationModels", "AVFoundation", "SwiftData", "CoreML"])
    func coreImportsNoHeavyFramework(module: String) throws {
        try #require(FileManager.default.fileExists(atPath: Self.coreSources.path), "sources not reachable from the test host")
        #expect(try Self.files(importing: module, in: Self.coreSources).isEmpty)
    }
}
