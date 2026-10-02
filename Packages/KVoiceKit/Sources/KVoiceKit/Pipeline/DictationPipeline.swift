import Foundation
import Observation

/// Builds a formatter for a provider configuration (a stub in tests).
public protocol TextFormatterProviding: Sendable {
    func makeFormatter(for configuration: ProviderConfiguration) throws -> any TextFormatter
}

extension TextFormatterFactory: TextFormatterProviding {}

/// A user-presentable dictation failure.
public enum DictationError: Error, Hashable, Sendable, LocalizedError {
    case microphonePermissionDenied
    case alreadyRecording
    case notRecording
    case recordingFailed(String)
    case noSpeech
    case transcriptionFailed(String)
    case formattingFailed(String)
    case missingAPIKey(ProviderKind)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: RecordingError.permissionDenied.errorDescription
        case .alreadyRecording: RecordingError.alreadyRecording.errorDescription
        case .notRecording: RecordingError.notRecording.errorDescription
        case .recordingFailed(let reason): reason
        case .noSpeech: TranscriptionError.noSpeech.errorDescription
        case .transcriptionFailed(let reason): reason
        case .formattingFailed(let reason): reason
        case .missingAPIKey(let provider): ProviderError.missingAPIKey(provider).errorDescription
        case .cancelled: "Dictation was cancelled."
        }
    }

    init(_ error: any Error, formatting: Bool = false) {
        switch error {
        case let error as DictationError: self = error
        case is CancellationError: self = .cancelled
        case RecordingError.permissionDenied: self = .microphonePermissionDenied
        case RecordingError.alreadyRecording: self = .alreadyRecording
        case RecordingError.notRecording: self = .notRecording
        case let error as RecordingError: self = .recordingFailed(error.localizedDescription)
        case TranscriptionError.noSpeech: self = .noSpeech
        case ProviderError.missingAPIKey(let provider): self = .missingAPIKey(provider)
        default:
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self = formatting ? .formattingFailed(message) : .transcriptionFailed(message)
        }
    }
}

public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case formatting
    case done
    case failed(DictationError)
}

public struct DictationResult: Sendable, Hashable {
    /// The history record (also returned when history is off).
    public var record: HistoryRecord
    /// The text to insert: the formatted text, or the raw transcript when
    /// the mode is plain dictation or formatting failed.
    public var text: String { record.formattedText }
    /// Set when the AI step failed and `text` is the raw transcript.
    public var formattingError: DictationError?

    public init(record: HistoryRecord, formattingError: DictationError? = nil) {
        self.record = record
        self.formattingError = formattingError
    }
}

/// Record → stop → transcribe → format → save to history.
@MainActor
@Observable
public final class DictationPipeline {
    public private(set) var phase: DictationPhase = .idle {
        didSet { phaseHandler?(phase) }
    }
    /// 0...1 microphone level while recording, for a waveform.
    public private(set) var level: Float = 0
    public private(set) var lastResult: DictationResult?
    /// The mode of the recording in progress.
    public private(set) var recordingMode: Mode?

    /// Called on every phase change (for example to update a keyboard handoff).
    @ObservationIgnored public var phaseHandler: ((DictationPhase) -> Void)?

    @ObservationIgnored private let recorder: any AudioRecording
    @ObservationIgnored private let engines: any TranscriptionEngineProviding
    @ObservationIgnored private let formatters: any TextFormatterProviding
    @ObservationIgnored private let history: HistoryStore?
    @ObservationIgnored private let settings: @MainActor () -> Settings
    @ObservationIgnored private let recordingsDirectory: URL
    @ObservationIgnored private var processingTask: Task<DictationResult, any Error>?

    /// - Parameters:
    ///   - history: Where results are saved; nil to keep no history.
    ///   - settings: Read at each step so changes apply to the next dictation.
    public init(
        recorder: any AudioRecording,
        engines: any TranscriptionEngineProviding,
        formatters: any TextFormatterProviding,
        history: HistoryStore?,
        settings: @escaping @MainActor () -> Settings
    ) {
        self.recorder = recorder
        self.engines = engines
        self.formatters = formatters
        self.history = history
        self.settings = settings
        self.recordingsDirectory = history?.recordingsDirectory
            ?? FileManager.default.temporaryDirectory.appending(path: "KVoiceRecordings", directoryHint: .isDirectory)
        recorder.levelHandler = { [weak self] level in self?.level = level }
    }

    public var isRecording: Bool { recorder.isRecording }

    /// Whether a dictation is recording or being processed.
    public var isBusy: Bool {
        switch phase {
        case .recording, .transcribing, .formatting: true
        default: false
        }
    }

    public func startRecording(mode: Mode) async throws {
        guard !isBusy else { throw DictationError.alreadyRecording }
        let url = recordingsDirectory.appending(path: "\(UUID().uuidString).wav")
        do {
            try await recorder.start(writingTo: url)
            recordingMode = mode
            level = 0
            phase = .recording
        } catch {
            let failure = DictationError(error)
            phase = .failed(failure)
            throw failure
        }
    }

    /// Stops recording and runs transcription, formatting and history.
    @discardableResult
    public func stopAndProcess() async throws -> DictationResult {
        guard recorder.isRecording, let mode = recordingMode else { throw DictationError.notRecording }
        let recording: Recording
        do {
            recording = try await recorder.stop()
        } catch {
            let failure = DictationError(error)
            phase = .failed(failure)
            throw failure
        }
        level = 0
        return try await process(recording, mode: mode)
    }

    /// Discards the recording or stops processing.
    public func cancel() {
        if recorder.isRecording { recorder.cancel() }
        processingTask?.cancel()
        recordingMode = nil
        level = 0
        phase = .idle
    }

    /// Transcribes and formats a recording (also used to re-run a history
    /// item's audio with another mode).
    @discardableResult
    public func process(_ recording: Recording, mode: Mode) async throws -> DictationResult {
        let task = Task { try await self.run(recording, mode: mode) }
        processingTask = task
        defer { processingTask = nil; recordingMode = nil }
        do {
            let result = try await task.value
            lastResult = result
            phase = .done
            return result
        } catch {
            let failure = DictationError(error)
            phase = failure == .cancelled ? .idle : .failed(failure)
            throw failure
        }
    }

    /// Formats existing text with a mode (re-run without audio).
    public func reformat(_ transcript: String, mode: Mode) async throws -> String {
        guard mode.usesAI else { return transcript }
        do {
            let formatter = try formatters.makeFormatter(for: settings().provider(for: mode))
            return try await formatter.format(FormatRequest(transcript: transcript, mode: mode))
        } catch {
            throw DictationError(error, formatting: true)
        }
    }

    private func run(_ recording: Recording, mode: Mode) async throws -> DictationResult {
        let settings = settings()
        guard !SpeechGate.isSilent(peakDBFS: recording.peakDBFS) else {
            discardAudio(recording.url)
            throw DictationError.noSpeech
        }

        phase = .transcribing
        let engineSelection = settings.engine(for: mode)
        let transcription: TranscriptionResult
        do {
            let engine = try engines.engine(for: engineSelection)
            transcription = try await engine.transcribe(TranscriptionRequest(
                audioURL: recording.url,
                language: mode.language,
                translateToEnglish: mode.translateToEnglish
            ))
        } catch {
            if case .noSpeech = DictationError(error) { discardAudio(recording.url) }
            throw DictationError(error)
        }
        try Task.checkCancellation()
        let raw = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !SpeechGate.isLikelyHallucination(raw, peakDBFS: recording.peakDBFS) else {
            discardAudio(recording.url)
            throw DictationError.noSpeech
        }

        var formatted = raw
        var formattingError: DictationError?
        var providerName: String?
        if mode.usesAI {
            phase = .formatting
            let provider = settings.provider(for: mode)
            providerName = provider.kind == .appleIntelligence
                ? provider.kind.displayName
                : "\(provider.kind.displayName) \(provider.model)"
            do {
                let formatter = try formatters.makeFormatter(for: provider)
                formatted = try await formatter.format(FormatRequest(transcript: raw, mode: mode))
            } catch is CancellationError {
                throw DictationError.cancelled
            } catch {
                // Keep the dictation: fall back to the raw transcript.
                formattingError = DictationError(error, formatting: true)
            }
        }
        try Task.checkCancellation()

        var audioFileName: String? = recording.url.lastPathComponent
        if !settings.retention.keepsAudio || history == nil {
            discardAudio(recording.url)
            audioFileName = nil
        }
        let record = HistoryRecord(
            duration: recording.duration,
            modeID: mode.id,
            modeName: mode.name,
            engine: engineSelection.displayName,
            provider: providerName,
            rawTranscript: raw,
            formattedText: formatted,
            audioFileName: audioFileName
        )
        if let history {
            try? await history.add(record)
        }
        return DictationResult(record: record, formattingError: formattingError)
    }

    private func discardAudio(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
