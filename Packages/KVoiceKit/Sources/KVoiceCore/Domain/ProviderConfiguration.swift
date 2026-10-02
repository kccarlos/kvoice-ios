import Foundation

/// An AI provider KVoice can format text with.
public enum ProviderKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Apple Foundation Models, on device. No key, no network.
    case appleIntelligence
    case openAI
    case anthropic
    case gemini
    case groq
    case openRouter
    /// Any OpenAI-compatible chat completions endpoint.
    case customOpenAICompatible

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .groq: "Groq"
        case .openRouter: "OpenRouter"
        case .customOpenAICompatible: "Custom (OpenAI-compatible)"
        }
    }

    /// The wire protocol the provider speaks.
    public enum API: Sendable, Hashable {
        case foundationModels
        case openAIChatCompletions
        case anthropicMessages
        case geminiGenerateContent
    }

    public var api: API {
        switch self {
        case .appleIntelligence: .foundationModels
        case .anthropic: .anthropicMessages
        case .gemini: .geminiGenerateContent
        case .openAI, .groq, .openRouter, .customOpenAICompatible: .openAIChatCompletions
        }
    }

    /// Whether the provider needs an API key from the Keychain.
    public var requiresAPIKey: Bool { self != .appleIntelligence }

    /// Whether the provider also serves OpenAI-compatible
    /// `/audio/transcriptions` (usable as a cloud transcription engine).
    public var supportsTranscription: Bool {
        switch self {
        case .openAI, .groq, .customOpenAICompatible: true
        default: false
        }
    }

    public var defaultBaseURL: URL? {
        switch self {
        case .appleIntelligence, .customOpenAICompatible: nil
        case .openAI: URL(string: "https://api.openai.com/v1")
        case .anthropic: URL(string: "https://api.anthropic.com/v1")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta")
        case .groq: URL(string: "https://api.groq.com/openai/v1")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")
        }
    }

    public var defaultModel: String {
        switch self {
        case .appleIntelligence: "system"
        case .openAI: "gpt-4.1-mini"
        case .anthropic: "claude-sonnet-5-5"
        case .gemini: "gemini-2.5-flash"
        case .groq: "llama-3.3-70b-versatile"
        case .openRouter: "openai/gpt-4.1-mini"
        case .customOpenAICompatible: ""
        }
    }

    /// Default speech-to-text model for providers that support it.
    public var defaultTranscriptionModel: String? {
        switch self {
        case .openAI: "gpt-4o-transcribe"
        case .groq: "whisper-large-v3-turbo"
        case .customOpenAICompatible: "whisper-1"
        default: nil
        }
    }
}

/// Which provider and model an AI step uses. The API key is not part of the
/// value: it is looked up in the Keychain by `kind` at request time.
public struct ProviderConfiguration: Codable, Sendable, Hashable {
    public var kind: ProviderKind
    /// Overrides `kind.defaultBaseURL`; required for a custom endpoint.
    public var baseURL: URL?
    public var model: String

    public init(kind: ProviderKind, baseURL: URL? = nil, model: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model ?? kind.defaultModel
    }

    /// The base URL requests go to, or `nil` when none is configured.
    public var resolvedBaseURL: URL? { baseURL ?? kind.defaultBaseURL }

    public static let appleIntelligence = ProviderConfiguration(kind: .appleIntelligence)
}

/// A transcription engine choice.
public struct TranscriptionEngineSelection: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// Apple's on-device SpeechAnalyzer. No download beyond system assets.
        case appleSpeech
        /// On-device Whisper via WhisperKit, downloadable models.
        case whisper
        /// OpenAI-compatible `/audio/transcriptions` with the user's key.
        case cloud
    }

    public var kind: Kind
    /// For `.whisper`: a `WhisperModel.id`.
    public var whisperModelID: String?
    /// For `.cloud`: the endpoint provider (base URL override and model).
    public var cloud: CloudTranscriptionConfiguration?

    public init(kind: Kind, whisperModelID: String? = nil, cloud: CloudTranscriptionConfiguration? = nil) {
        self.kind = kind
        self.whisperModelID = whisperModelID
        self.cloud = cloud
    }

    public static let appleSpeech = TranscriptionEngineSelection(kind: .appleSpeech)

    public static func whisper(_ modelID: String = WhisperModel.base.id) -> TranscriptionEngineSelection {
        TranscriptionEngineSelection(kind: .whisper, whisperModelID: modelID)
    }

    public static func cloud(_ configuration: CloudTranscriptionConfiguration) -> TranscriptionEngineSelection {
        TranscriptionEngineSelection(kind: .cloud, cloud: configuration)
    }

    /// A short label for history records.
    public var displayName: String {
        switch kind {
        case .appleSpeech: "Apple Speech"
        case .whisper: "Whisper " + (whisperModelID.flatMap { WhisperModel.model(id: $0)?.name } ?? whisperModelID ?? "")
        case .cloud: "Cloud " + (cloud?.model ?? "")
        }
    }
}

/// An OpenAI-compatible speech-to-text endpoint. The key comes from the
/// Keychain entry of `provider`.
public struct CloudTranscriptionConfiguration: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var baseURL: URL?
    public var model: String

    public init(provider: ProviderKind, baseURL: URL? = nil, model: String? = nil) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model ?? provider.defaultTranscriptionModel ?? "whisper-1"
    }

    public var resolvedBaseURL: URL? { baseURL ?? provider.defaultBaseURL }
}
