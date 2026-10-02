import AVFoundation
import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

// MARK: - Background budget

@Suite struct BackgroundBudgetTests {
    func inputs(
        _ engine: TranscriptionEngineSelection.Kind,
        duration: TimeInterval = 10,
        whisperLoaded: Bool = true,
        speechInstalled: Bool = true,
        usesAI: Bool = false,
        foreground: Bool = false
    ) -> BackgroundBudget.Inputs {
        BackgroundBudget.Inputs(
            engine: engine, audioDuration: duration, whisperModelLoaded: whisperLoaded,
            appleSpeechInstalled: speechInstalled, usesAI: usesAI, isForeground: foreground
        )
    }

    @Test func shortClipsRunWithTheSelectedEngine() {
        #expect(BackgroundBudget.plan(inputs(.appleSpeech)) == .runSelected)
        #expect(BackgroundBudget.plan(inputs(.whisper)) == .runSelected)
        #expect(BackgroundBudget.plan(inputs(.cloud, usesAI: true)) == .runSelected)
    }

    @Test func unloadedWhisperFallsBackToAppleSpeech() {
        #expect(BackgroundBudget.plan(inputs(.whisper, whisperLoaded: false)) == .useAppleSpeech)
    }

    @Test func longAudioMovesWhisperToAppleSpeech() {
        #expect(BackgroundBudget.plan(inputs(.whisper, duration: 61)) == .useAppleSpeech)
        #expect(BackgroundBudget.plan(inputs(.whisper, duration: 60)) == .runSelected)
    }

    @Test func withoutSpeechAssetsTheJobContinuesInTheForeground() {
        #expect(BackgroundBudget.plan(inputs(.whisper, whisperLoaded: false, speechInstalled: false)) == .continueInForeground)
        // Apple Speech itself would download its assets first.
        #expect(BackgroundBudget.plan(inputs(.appleSpeech, speechInstalled: false)) == .continueInForeground)
    }

    @Test func overBudgetEvenForAppleSpeechContinuesInTheForeground() {
        // 1 + 0.1 × 300 = 31 s > 25 s.
        #expect(BackgroundBudget.plan(inputs(.appleSpeech, duration: 300)) == .continueInForeground)
        #expect(BackgroundBudget.plan(inputs(.cloud, duration: 300)) == .continueInForeground)
        // Formatting tips a borderline clip over.
        #expect(BackgroundBudget.plan(inputs(.appleSpeech, duration: 200)) == .runSelected)
        #expect(BackgroundBudget.plan(inputs(.appleSpeech, duration: 200, usesAI: true)) == .continueInForeground)
    }

    @Test func cloudOverBudgetFallsBackToAppleSpeech() {
        // Cloud 3 + 0.1 × 190 + 6 = 28 s; Apple Speech 1 + 19 + 6 = 26 s: still over.
        #expect(BackgroundBudget.plan(inputs(.cloud, duration: 190, usesAI: true)) == .continueInForeground)
        // Cloud 3 + 22 = 25 s fits exactly.
        #expect(BackgroundBudget.plan(inputs(.cloud, duration: 220)) == .runSelected)
        #expect(BackgroundBudget.plan(inputs(.cloud, duration: 225)) == .useAppleSpeech)
    }

    @Test func foregroundHasNoBudget() {
        #expect(BackgroundBudget.plan(inputs(.whisper, duration: 900, whisperLoaded: false, speechInstalled: false, foreground: true)) == .runSelected)
    }
}

// MARK: - Audio conversion

@Suite struct AudioConversionTests {
    /// Writes an AAC m4a like the Record Audio action does (44.1 kHz
    /// stereo), generated here so no binary fixture is committed.
    static func writeM4A(_ url: URL, seconds: Double, amplitude: Float, sampleRate: Double = 44_100) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let data = try #require(buffer.floatChannelData)[channel]
            for index in 0..<Int(frames) {
                data[index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    @Test func m4aConvertsTo16kHzMonoWAV() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let source = directory.url.appending(path: "Recording.m4a")
        try Self.writeM4A(source, seconds: 2, amplitude: 0.5)
        let wav = directory.url.appending(path: "out.wav")

        let recording = try AudioFile.convertToProcessingWAV(from: source, to: wav)

        #expect(abs(recording.duration - 2) < 0.1, "duration \(recording.duration)")
        #expect(recording.peakDBFS > -9 && recording.peakDBFS < -3, "peak \(recording.peakDBFS)")
        #expect(recording.url == wav)
        let check = try AVAudioFile(forReading: wav)
        #expect(check.fileFormat.sampleRate == 16_000)
        #expect(check.fileFormat.channelCount == 1)
        let samples = try AudioFile.readSamples(from: wav)
        #expect(abs(Double(samples.count) / 16_000 - recording.duration) < 0.01)
    }

    @Test func longerAudioStreamsInChunks() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let source = directory.url.appending(path: "Long.m4a")
        try Self.writeM4A(source, seconds: 12, amplitude: 0.3, sampleRate: 48_000)
        let recording = try AudioFile.convertToProcessingWAV(from: source, to: directory.url.appending(path: "long.wav"))
        #expect(abs(recording.duration - 12) < 0.15)
    }

    @Test func silentM4AIsDetectedAsSilence() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let source = directory.url.appending(path: "Silence.m4a")
        try Self.writeM4A(source, seconds: 1.5, amplitude: 0)
        let recording = try AudioFile.convertToProcessingWAV(from: source, to: directory.url.appending(path: "s.wav"))
        #expect(SpeechGate.isSilent(peakDBFS: recording.peakDBFS))
    }

    @Test func unreadableAudioThrows() throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let source = directory.url.appending(path: "junk.m4a")
        try Data("not audio".utf8).write(to: source)
        #expect(throws: TranscriptionError.unreadableAudio) {
            try AudioFile.convertToProcessingWAV(from: source, to: directory.url.appending(path: "j.wav"))
        }
    }
}

// MARK: - Serial job queue and background jobs

@MainActor
@Suite struct SerialJobQueueTests {
    @Test func jobsRunOneAtATimeInSubmissionOrder() async throws {
        let queue = SerialJobQueue()
        var log: [String] = []
        var running = 0
        var maxRunning = 0
        func job(_ name: String, sleep: Int) -> Task<Void, Never> {
            Task {
                await queue.run {
                    running += 1
                    maxRunning = max(maxRunning, running)
                    log.append("start \(name)")
                    try? await Task.sleep(for: .milliseconds(sleep))
                    log.append("end \(name)")
                    running -= 1
                }
            }
        }
        let a = job("A", sleep: 60)
        await Task.yield()
        let b = job("B", sleep: 5)
        await Task.yield()
        let c = job("C", sleep: 1)
        _ = await (a.value, b.value, c.value)
        #expect(log == ["start A", "end A", "start B", "end B", "start C", "end C"])
        #expect(maxRunning == 1)
        #expect(!queue.isBusy)
    }

    @Test func aFailingJobDoesNotBlockTheNext() async throws {
        let queue = SerialJobQueue()
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await queue.run { throw Boom() } }
        #expect(await queue.run { 42 } == 42)
    }
}

@MainActor
@Suite struct ShortcutJobPipelineTests {
    let directory: TempDirectory
    let history: HistoryStore

    init() throws {
        directory = try TempDirectory()
        history = try HistoryStore(directory: directory.url)
    }

    func pipeline(engine: StubEngine = StubEngine(text: "hello world")) -> DictationPipeline {
        DictationPipeline(
            recorder: StubRecorder(),
            engines: StubEngines(engine: engine),
            formatters: StubFormatters(formatter: StubFormatter()),
            history: history,
            settings: { Settings() }
        )
    }

    func pendingRecord() async throws -> (HistoryRecord, Recording) {
        let wav = history.newRecordingURL()
        try AudioFile.writeWAV(Signal.tone(seconds: 2), to: wav)
        let record = HistoryRecord(
            duration: 2, modeName: "Notes", engine: "", rawTranscript: "", formattedText: "",
            audioFileName: wav.lastPathComponent, status: .pending
        )
        try await history.add(record)
        return (record, Recording(url: wav, duration: 2, peakDBFS: -6))
    }

    @Test func jobCompletesThePendingRecordWithoutTouchingThePhase() async throws {
        defer { directory.cleanUp() }
        let pipeline = pipeline()
        var phases: [DictationPhase] = []
        pipeline.phaseHandler = { phases.append($0) }
        var stages: [DictationActivity.Stage] = []
        let (pending, recording) = try await pendingRecord()
        #expect(try await history.pending().map(\.id) == [pending.id])

        let result = try await pipeline.processJob(recording, mode: .email, options: .init(
            engineOverride: .appleSpeech, record: pending, onStage: { stages.append($0) }
        ))

        #expect(result.text == "FORMATTED: hello world")
        #expect(result.record.id == pending.id)
        #expect(result.record.status == .done)
        #expect(stages == [.transcribing, .formatting])
        #expect(phases.isEmpty, "background jobs leave the app's phase alone")
        #expect(pipeline.phase == .idle)
        #expect(try await history.pending().isEmpty)
        #expect(try await history.all().count == 1, "updated in place, not added")
        #expect(history.audioURL(for: result.record) != nil)
    }

    @Test func failedJobKeepsTheAudio() async throws {
        defer { directory.cleanUp() }
        let pipeline = pipeline(engine: StubEngine(text: "", error: .failed("offline")))
        let (pending, recording) = try await pendingRecord()
        await #expect(throws: DictationError.self) {
            try await pipeline.processJob(recording, mode: .dictation, options: .init(record: pending))
        }
        #expect(FileManager.default.fileExists(atPath: recording.url.path))
        #expect(try await history.pending().map(\.id) == [pending.id], "still resumable")
    }

    @Test func silentJobIsNoSpeech() async throws {
        defer { directory.cleanUp() }
        let pipeline = pipeline()
        let (pending, recording) = try await pendingRecord()
        var silent = recording
        silent.peakDBFS = -80
        await #expect(throws: DictationError.noSpeech) {
            try await pipeline.processJob(silent, mode: .dictation, options: .init(record: pending))
        }
    }

    @Test func appRecordingAndJobsShareOneQueue() async throws {
        defer { directory.cleanUp() }
        let pipeline = pipeline()
        let (first, firstRecording) = try await pendingRecord()
        let (second, secondRecording) = try await pendingRecord()
        async let one = pipeline.processJob(firstRecording, mode: .dictation, options: .init(record: first))
        async let two = pipeline.processJob(secondRecording, mode: .dictation, options: .init(record: second))
        let results = try await [one, two]
        #expect(results.map(\.record.id) == [first.id, second.id])
        #expect(!pipeline.jobs.isBusy)
    }

    @Test func retentionKeepsAudioOfPendingAndFailedRecords() async throws {
        defer { directory.cleanUp() }
        let (pending, _) = try await pendingRecord()
        var failed = try await pendingRecord().0
        failed.status = .failed
        failed.failureMessage = "offline"
        try await history.update(failed)

        try await history.applyRetention(RetentionPolicy(period: .days7, keepsAudio: false),
                                         now: Date.now.addingTimeInterval(30 * 24 * 3600))
        let kept = try await history.all()
        #expect(Set(kept.map(\.id)) == [pending.id, failed.id])
        #expect(kept.allSatisfy { history.audioURL(for: $0) != nil })
        #expect(try await history.record(id: failed.id)?.failureMessage == "offline")
    }
}

// MARK: - Recorder duration (interruption salvage input)

@MainActor
@Suite struct RecordedDurationTests {
    @Test func salvageUsesTheCapturedDuration() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let recorder = StubRecorder()
        recorder.samples = Signal.tone(seconds: 1.2)
        try await recorder.start(writingTo: directory.url.appending(path: "a.wav"))
        #expect(InterruptionSalvage.shouldProcess(recordedDuration: recorder.recordedDuration))
        recorder.samples = Signal.tone(seconds: 0.4)
        #expect(!InterruptionSalvage.shouldProcess(recordedDuration: recorder.recordedDuration))
        recorder.cancel()
        #expect(recorder.recordedDuration == 0)
    }

    @Test func interruptedRecordingOfASecondIsProcessedByThePipeline() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let history = try HistoryStore(directory: directory.url)
        let recorder = StubRecorder()
        recorder.samples = Signal.tone(seconds: 1.5)
        let pipeline = DictationPipeline(
            recorder: recorder,
            engines: StubEngines(engine: StubEngine(text: "salvaged")),
            formatters: StubFormatters(formatter: StubFormatter()),
            history: history,
            settings: { Settings() }
        )
        try await pipeline.startRecording(mode: .dictation)
        var reducer = DictationActivityReducer()
        let session = UUID()
        _ = reducer.handle(.startAppRecording(sessionID: session, source: .app, modeID: nil, now: .now))
        let effects = reducer.handle(.audioInterrupted(recordedDuration: pipeline.recordedDuration, now: .now))
        #expect(effects == [.processAppRecording(jobID: session)])
        let result = try await pipeline.stopAndProcess()
        #expect(result.text == "salvaged")
        #expect(try await history.all().count == 1)
    }
}
