import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@MainActor
@Suite struct DictationPipelineTests {
    let directory: TempDirectory
    let history: HistoryStore
    let recorder = StubRecorder()

    init() throws {
        directory = try TempDirectory()
        history = try HistoryStore(directory: directory.url)
    }

    func makePipeline(
        transcript: String = "um hello world",
        engineError: TranscriptionError? = nil,
        formatterError: ProviderError? = nil,
        settings: Settings = Settings()
    ) -> DictationPipeline {
        DictationPipeline(
            recorder: recorder,
            engines: StubEngines(engine: StubEngine(text: transcript, error: engineError)),
            formatters: StubFormatters(formatter: StubFormatter(error: formatterError)),
            history: history,
            settings: { settings }
        )
    }

    @Test func aiModeRecordsTranscribesFormatsAndSaves() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline()
        var phases: [DictationPhase] = []
        pipeline.phaseHandler = { phases.append($0) }

        try await pipeline.startRecording(mode: .email)
        #expect(pipeline.phase == .recording)
        let result = try await pipeline.stopAndProcess()

        #expect(result.text == "FORMATTED: um hello world")
        #expect(result.record.rawTranscript == "um hello world")
        #expect(result.record.modeName == "Email")
        #expect(result.record.engine == "Apple Speech")
        #expect(result.record.provider == "Apple Intelligence")
        #expect(result.formattingError == nil)
        #expect(phases == [.recording, .transcribing, .formatting, .done])

        let saved = try await history.all()
        #expect(saved == [result.record])
        #expect(history.audioURL(for: result.record) != nil, "audio kept by default")
    }

    @Test func plainDictationSkipsAI() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline(formatterError: .unauthorized)
        try await pipeline.startRecording(mode: .dictation)
        let result = try await pipeline.stopAndProcess()
        #expect(result.text == "um hello world")
        #expect(result.record.provider == nil)
        #expect(result.formattingError == nil)
    }

    @Test func formattingFailureFallsBackToTranscript() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline(formatterError: .missingAPIKey(.openAI))
        try await pipeline.startRecording(mode: .cleanUp)
        let result = try await pipeline.stopAndProcess()
        #expect(result.text == "um hello world")
        #expect(result.formattingError == .missingAPIKey(.openAI))
        #expect(pipeline.phase == .done)
    }

    @Test func silentRecordingIsRejectedBeforeTranscription() async throws {
        defer { directory.cleanUp() }
        recorder.peakDBFS = -50
        let pipeline = makePipeline()
        try await pipeline.startRecording(mode: .cleanUp)
        await #expect(throws: DictationError.noSpeech) { try await pipeline.stopAndProcess() }
        #expect(pipeline.phase == .failed(.noSpeech))
        #expect(try await history.all().isEmpty)
    }

    @Test func quietStockPhraseIsRejected() async throws {
        defer { directory.cleanUp() }
        recorder.peakDBFS = -35
        let pipeline = makePipeline(transcript: "Thank you.")
        try await pipeline.startRecording(mode: .dictation)
        await #expect(throws: DictationError.noSpeech) { try await pipeline.stopAndProcess() }
    }

    @Test func engineErrorsAreTyped() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline(engineError: .modelNotInstalled("Base"))
        try await pipeline.startRecording(mode: .dictation)
        do {
            try await pipeline.stopAndProcess()
            Issue.record("expected an error")
        } catch let error as DictationError {
            #expect(error == .transcriptionFailed("Download the Base model in Settings first."))
            #expect(error.errorDescription == "Download the Base model in Settings first.")
        }
    }

    @Test func notKeepingAudioDeletesTheRecording() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline(settings: Settings(retention: RetentionPolicy(keepsAudio: false)))
        try await pipeline.startRecording(mode: .dictation)
        let result = try await pipeline.stopAndProcess()
        #expect(result.record.audioFileName == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: history.recordingsDirectory.path)
        #expect(leftovers.isEmpty)
    }

    @Test func stopWithoutStartAndDoubleStartFail() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline()
        await #expect(throws: DictationError.notRecording) { try await pipeline.stopAndProcess() }
        try await pipeline.startRecording(mode: .dictation)
        await #expect(throws: DictationError.alreadyRecording) { try await pipeline.startRecording(mode: .dictation) }
        pipeline.cancel()
        #expect(pipeline.phase == .idle)
        #expect(!pipeline.isRecording)
    }

    @Test func reformatUsesModeProvider() async throws {
        defer { directory.cleanUp() }
        let pipeline = makePipeline()
        #expect(try await pipeline.reformat("raw", mode: .notes) == "FORMATTED: raw")
        #expect(try await pipeline.reformat("raw", mode: .dictation) == "raw")
    }
}
