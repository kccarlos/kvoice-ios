import Foundation

/// One transcription job: a finished recording on disk.
public struct TranscriptionRequest: Sendable, Hashable {
    public var audioURL: URL
    /// Spoken language as BCP-47, or nil for automatic detection.
    public var language: String?
    /// Translate to English while transcribing, where the engine can.
    public var translateToEnglish: Bool

    public init(audioURL: URL, language: String? = nil, translateToEnglish: Bool = false) {
        self.audioURL = audioURL
        self.language = language
        self.translateToEnglish = translateToEnglish
    }

    /// The ISO 639 language code ("en" for "en-US"), which Whisper and the
    /// OpenAI-compatible endpoints expect.
    public var languageCode: String? {
        guard let language, !language.isEmpty else { return nil }
        return Locale(identifier: language).language.languageCode?.identifier ?? language
    }
}

public struct TranscriptionResult: Sendable, Hashable {
    public var text: String
    /// Whether the engine already translated to English.
    public var isTranslatedToEnglish: Bool
    /// The language the engine detected, if it reports one.
    public var detectedLanguage: String?

    public init(text: String, isTranslatedToEnglish: Bool = false, detectedLanguage: String? = nil) {
        self.text = text
        self.isTranslatedToEnglish = isTranslatedToEnglish
        self.detectedLanguage = detectedLanguage
    }
}

/// Speech-to-text from an audio file. Implemented by Apple Speech, WhisperKit
/// and the cloud providers.
public protocol TranscriptionEngine: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

public enum TranscriptionError: Error, Equatable, Sendable, LocalizedError {
    /// The recording had no speech in it.
    case noSpeech
    case unreadableAudio
    case unsupportedLanguage(String)
    /// The engine is not usable on this device.
    case engineUnavailable(String)
    /// The Whisper model is not downloaded yet.
    case modelNotInstalled(String)
    case assetsNotInstalled
    /// The recording is over the engine's upload limit.
    case audioTooLong(maxMinutes: Int)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noSpeech: "No speech was detected."
        case .unreadableAudio: "The recording could not be read."
        case .unsupportedLanguage(let language): "Speech recognition does not support \(language) on this device."
        case .engineUnavailable(let reason): reason
        case .modelNotInstalled(let name): "Download the \(name) model in Settings first."
        case .assetsNotInstalled: "The speech recognition model for this language is not installed yet."
        case .audioTooLong(let minutes): "This recording is too long for this engine (about \(minutes) minutes at most). Record a shorter clip or choose another engine."
        case .failed(let reason): "Transcription failed: \(reason)"
        }
    }
}

/// Builds an engine for a selection.
public protocol TranscriptionEngineProviding: Sendable {
    func engine(for selection: TranscriptionEngineSelection) throws -> any TranscriptionEngine
}

/// The production engine factory. Engines that keep a model loaded
/// (WhisperKit) are cached for the process lifetime.
public final class TranscriptionEngineFactory: TranscriptionEngineProviding {
    public let secrets: any SecretStore
    public let transport: any HTTPTransport
    public let whisperModels: WhisperModelManager
    private let whisperEngine: WhisperKitEngine
    private let appleSpeech = AppleSpeechEngine()

    public init(
        secrets: any SecretStore,
        whisperModels: WhisperModelManager = WhisperModelManager(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.secrets = secrets
        self.transport = transport
        self.whisperModels = whisperModels
        self.whisperEngine = WhisperKitEngine(models: whisperModels)
    }

    /// Whether a Whisper selection's model is loaded in this process.
    public func isWhisperModelLoaded(_ selection: TranscriptionEngineSelection) async -> Bool {
        guard selection.kind == .whisper else { return false }
        let model = selection.whisperModelID.flatMap(WhisperModel.model(id:)) ?? .base
        return await whisperEngine.isLoaded(model)
    }

    public func engine(for selection: TranscriptionEngineSelection) throws -> any TranscriptionEngine {
        switch selection.kind {
        case .appleSpeech:
            return appleSpeech
        case .whisper:
            let model = selection.whisperModelID.flatMap(WhisperModel.model(id:)) ?? .base
            return whisperEngine.using(model)
        case .cloud:
            let configuration = selection.cloud ?? CloudTranscriptionConfiguration(provider: .openAI)
            guard let api = configuration.provider.transcriptionAPI else {
                throw TranscriptionError.engineUnavailable(
                    "\(configuration.provider.displayName) does not offer transcription. Choose another provider in Settings."
                )
            }
            guard let key = try secrets.apiKey(for: configuration.provider), !key.isEmpty else {
                throw ProviderError.missingAPIKey(configuration.provider)
            }
            switch api {
            case .openAIAudioTranscriptions:
                return CloudTranscriptionEngine(configuration: configuration, apiKey: key, transport: transport)
            case .geminiGenerateContent:
                return GeminiTranscriptionEngine(configuration: configuration, apiKey: key, transport: transport)
            }
        }
    }
}
