import Foundation
// The only file in KVoiceKit that imports FoundationModels.
import FoundationModels

/// Why Apple Intelligence cannot run right now.
public enum AppleIntelligenceAvailability: Sendable, Hashable {
    case available
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case unknown

    public var isAvailable: Bool { self == .available }

    public var message: String {
        switch self {
        case .available: "Apple Intelligence is ready."
        case .deviceNotEligible: "This device does not support Apple Intelligence."
        case .notEnabled: "Turn on Apple Intelligence in Settings to use it for formatting."
        case .modelNotReady: "Apple Intelligence is still downloading. Try again later."
        case .unknown: "Apple Intelligence is not available right now."
        }
    }
}

/// On-device formatting with the system language model. No key, no network.
public struct AppleIntelligenceFormatter: TextFormatter {
    public init() {}

    public static var availability: AppleIntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        }
    }

    public func format(_ request: FormatRequest) async throws -> String {
        let availability = Self.availability
        guard availability.isAvailable else {
            throw ProviderError.unavailable(availability.message)
        }
        let prompt = PromptComposer.compose(request)
        // One session per request: formatting is stateless, and a shared
        // transcript would only use up the context window.
        let session = LanguageModelSession(instructions: prompt.system)
        do {
            let response = try await session.respond(
                to: prompt.user,
                options: GenerationOptions(samplingMode: .greedy)
            )
            let text = PromptComposer.cleanedOutput(response.content)
            guard !text.isEmpty else { throw ProviderError.emptyResponse }
            return text
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal:
                throw ProviderError.refused
            case .exceededContextWindowSize:
                throw ProviderError.unavailable("The text is too long for Apple Intelligence. Try a cloud provider.")
            case .unsupportedLanguageOrLocale:
                throw ProviderError.unavailable("Apple Intelligence does not support this language yet.")
            case .assetsUnavailable:
                throw ProviderError.unavailable(AppleIntelligenceAvailability.modelNotReady.message)
            case .rateLimited, .concurrentRequests:
                throw ProviderError.rateLimited
            default:
                throw ProviderError.unavailable("Apple Intelligence could not format this text.")
            }
        }
    }
}
