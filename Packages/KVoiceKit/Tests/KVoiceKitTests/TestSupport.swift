import Foundation
import Synchronization
@testable import KVoiceKit

/// A fresh temporary directory, removed by `cleanUp()`.
struct TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "KVoiceKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A unique, isolated UserDefaults suite.
struct TestDefaults {
    let name = "KVoiceKitTests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

/// Records requests and answers with a canned response. No network.
final class StubTransport: HTTPTransport {
    private let state: Mutex<[URLRequest]> = Mutex([])
    let status: Int
    let body: Data

    init(status: Int = 200, json: String) {
        self.status = status
        self.body = Data(json.utf8)
    }

    var requests: [URLRequest] { state.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body, response)
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
    }
}

/// Synthesised 16 kHz audio.
enum Signal {
    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// A sine at `amplitude` (0.5 ≈ -6 dBFS).
    static func tone(seconds: Double, amplitude: Float = 0.5, frequency: Float = 440) -> [Float] {
        (0..<Int(seconds * 16_000)).map { index in
            amplitude * sin(2 * .pi * frequency * Float(index) / 16_000)
        }
    }
}

// MARK: - Pipeline doubles

@MainActor
final class StubRecorder: AudioRecording {
    var isRecording = false
    var levelHandler: ((Float) -> Void)?
    var peakDBFS: Float = -10
    var samples: [Float] = Signal.tone(seconds: 2)
    private var url: URL?

    func start(writingTo url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        isRecording = true
    }

    func stop() async throws -> Recording {
        guard let url else { throw RecordingError.notRecording }
        try AudioFile.writeWAV(samples, to: url)
        isRecording = false
        return Recording(url: url, duration: Double(samples.count) / 16_000, peakDBFS: peakDBFS)
    }

    func cancel() {
        isRecording = false
    }
}

struct StubEngine: TranscriptionEngine {
    var text: String
    var error: TranscriptionError?

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if let error { throw error }
        return TranscriptionResult(text: text)
    }
}

struct StubEngines: TranscriptionEngineProviding {
    var engine: StubEngine
    func engine(for selection: TranscriptionEngineSelection) throws -> any TranscriptionEngine { engine }
}

struct StubFormatter: TextFormatter {
    var error: ProviderError?
    func format(_ request: FormatRequest) async throws -> String {
        if let error { throw error }
        return "FORMATTED: " + request.transcript
    }
}

struct StubFormatters: TextFormatterProviding {
    var formatter: StubFormatter
    func makeFormatter(for configuration: ProviderConfiguration) throws -> any TextFormatter { formatter }
}
