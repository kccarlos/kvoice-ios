import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@Suite struct CloudTranscriptionTests {
    let configuration = CloudTranscriptionConfiguration(provider: .groq)

    func engine(_ transport: StubTransport, model: String? = nil) -> CloudTranscriptionEngine {
        var configuration = configuration
        if let model { configuration.model = model }
        return CloudTranscriptionEngine(configuration: configuration, apiKey: "gk", transport: transport, boundary: "BOUNDARY")
    }

    @Test func buildsMultipartTranscriptionRequest() throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46])
        let request = TranscriptionRequest(audioURL: URL(filePath: "/tmp/clip.wav"), language: "de-DE")
        let sent = try engine(StubTransport(json: "{}")).makeRequest(for: request, audio: audio)

        #expect(sent.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer gk")

        var expected = Data()
        expected.append(Data("""
        --BOUNDARY\r
        Content-Disposition: form-data; name="model"\r
        \r
        whisper-large-v3-turbo\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="response_format"\r
        \r
        json\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="language"\r
        \r
        de\r
        --BOUNDARY\r
        Content-Disposition: form-data; name="file"; filename="clip.wav"\r
        Content-Type: audio/wav\r
        \r

        """.utf8))
        expected.append(audio)
        expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))
        #expect(sent.httpBody == expected)
    }

    @Test func whisperModelsTranslateNatively() throws {
        let request = TranscriptionRequest(audioURL: URL(filePath: "/tmp/a.m4a"), language: "fr", translateToEnglish: true)
        let sent = try engine(StubTransport(json: "{}")).makeRequest(for: request, audio: Data())
        #expect(sent.url?.path == "/openai/v1/audio/translations")
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains("name=\"language\""))
        #expect(body.contains("Content-Type: audio/mp4"))

        let gpt = try engine(StubTransport(json: "{}"), model: "gpt-4o-transcribe").makeRequest(for: request, audio: Data())
        #expect(gpt.url?.path == "/openai/v1/audio/transcriptions")
    }

    @Test func transcribesFileAndParsesText() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let url = directory.url.appending(path: "clip.wav")
        try AudioFile.writeWAV(Signal.tone(seconds: 0.5), to: url)
        let transport = StubTransport(json: #"{"text":" Hello there. "}"#)
        let result = try await engine(transport).transcribe(TranscriptionRequest(audioURL: url))
        #expect(result.text == "Hello there.")
        #expect(transport.requests.count == 1)
    }

    @Test func emptyTextIsNoSpeech() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let url = directory.url.appending(path: "clip.wav")
        try AudioFile.writeWAV(Signal.tone(seconds: 0.2), to: url)
        await #expect(throws: TranscriptionError.noSpeech) {
            try await engine(StubTransport(json: #"{"text":""}"#)).transcribe(TranscriptionRequest(audioURL: url))
        }
    }

    @Test func factoryNeedsKeyForCloud() {
        let factory = TranscriptionEngineFactory(
            secrets: InMemorySecretStore(),
            whisperModels: WhisperModelManager(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
            transport: StubTransport(json: "{}")
        )
        #expect(throws: ProviderError.missingAPIKey(.openAI)) {
            try factory.engine(for: .cloud(CloudTranscriptionConfiguration(provider: .openAI)))
        }
        #expect((try? factory.engine(for: .appleSpeech)) is AppleSpeechEngine)
        #expect((try? factory.engine(for: .whisper("small"))).flatMap { ($0 as? WhisperModelEngine)?.model } == .small)
    }

    @Test func languageCodeStripsRegion() {
        #expect(TranscriptionRequest(audioURL: URL(filePath: "/a"), language: "pt-BR").languageCode == "pt")
        #expect(TranscriptionRequest(audioURL: URL(filePath: "/a"), language: nil).languageCode == nil)
    }
}

@Suite struct SpeechGateTests {
    @Test func peakLevels() {
        #expect(SpeechGate.peakLevelDBFS(of: Signal.silence(seconds: 1)) == SpeechGate.silenceFloorDBFS)
        #expect(abs(SpeechGate.peakLevelDBFS(of: [0.5, -1, .nan]) - 0) < 0.001)
        #expect(abs(SpeechGate.peakLevelDBFS(of: [0.1]) - -20) < 0.01)
    }

    @Test func silenceThresholdIsMinus45() {
        #expect(SpeechGate.isSilent(peakDBFS: -45))
        #expect(!SpeechGate.isSilent(peakDBFS: -44.9))
        #expect(SpeechGate.isSilent(Signal.tone(seconds: 1, amplitude: 0.005))) // ≈ -46 dBFS
        #expect(!SpeechGate.isSilent(Signal.tone(seconds: 1, amplitude: 0.1)))
    }

    @Test func stockPhrasesRejectedOnlyWhenQuiet() {
        #expect(SpeechGate.isLikelyHallucination("Thank you.", peakDBFS: -30))
        #expect(SpeechGate.isLikelyHallucination(" thanks for watching! ", peakDBFS: -28))
        #expect(!SpeechGate.isLikelyHallucination("Thank you.", peakDBFS: -12), "a spoken thank-you is kept")
        #expect(!SpeechGate.isLikelyHallucination("Thank you for the report.", peakDBFS: -40))
        #expect(SpeechGate.isLikelyHallucination("", peakDBFS: -40))
    }

    @Test func trailingSilenceIsTrimmedKeepingPointFourSeconds() {
        let samples = Signal.tone(seconds: 2) + Signal.silence(seconds: 3)
        let keep = SpeechGate.trailingSilenceTrimmedCount(of: samples)
        #expect(keep == Int(2.4 * 16_000))
    }

    @Test func shortRecordingsAreNotTrimmed() {
        let samples = Signal.tone(seconds: 0.2) + Signal.silence(seconds: 0.7)
        #expect(SpeechGate.trailingSilenceTrimmedCount(of: samples) == samples.count)
        // Trimming never goes below one second.
        let longer = Signal.tone(seconds: 0.2) + Signal.silence(seconds: 2)
        #expect(SpeechGate.trailingSilenceTrimmedCount(of: longer) == 16_000)
    }

    @Test func shortClipsArePaddedTo1Point5Seconds() {
        let padded = ShortClipPadding.applied(to: Signal.tone(seconds: 0.5))
        #expect(padded.count == 24_000)
        #expect(padded[8_000...].allSatisfy { $0 == 0 })
        let long = Signal.tone(seconds: 2)
        #expect(ShortClipPadding.applied(to: long) == long)
    }

    @Test func whisperInputGatesSilenceThenTrimsAndPads() throws {
        #expect(throws: TranscriptionError.noSpeech) {
            try WhisperInput.prepare(Signal.silence(seconds: 2) + Signal.tone(seconds: 1, amplitude: 0.003))
        }
        let short = try WhisperInput.prepare(Signal.tone(seconds: 0.6))
        #expect(short.samples.count == ShortClipPadding.minimumSampleCount)
        #expect(short.peakDBFS > -10)
        let trailing = try WhisperInput.prepare(Signal.tone(seconds: 3) + Signal.silence(seconds: 4))
        #expect(trailing.samples.count == Int(3.4 * 16_000))
    }

    @Test func wavRoundTripAt16kHzMono() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let url = directory.url.appending(path: "tone.wav")
        let tone = Signal.tone(seconds: 1, amplitude: 0.25)
        try AudioFile.writeWAV(tone, to: url)
        let read = try AudioFile.readSamples(from: url)
        #expect(read.count == tone.count)
        #expect(abs(SpeechGate.peakLevelDBFS(of: read) - SpeechGate.peakLevelDBFS(of: tone)) < 0.1)
        #expect(abs(AudioFile.duration(of: url) - 1) < 0.001)
    }

    @Test func whisperCatalog() {
        #expect(WhisperModel.all.map(\.id) == ["tiny", "base", "small", "large-v3-turbo"])
        #expect(WhisperModel.model(id: "large-v3-turbo")?.variant.hasPrefix("openai_whisper-large-v3") == true)
    }

    @Test func modelManagerReportsNothingInstalledInEmptyDirectory() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let manager = WhisperModelManager(directory: directory.url)
        #expect(await manager.installedModelIDs().isEmpty)
        #expect(await !manager.isInstalled(.tiny))
        #expect(WhisperModelManager.relativePath(
            of: directory.url.appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny"),
            in: directory.url
        ) == "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny")
    }
}
