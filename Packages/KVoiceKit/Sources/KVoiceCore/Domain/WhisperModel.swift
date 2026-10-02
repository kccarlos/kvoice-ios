import Foundation

/// A downloadable Whisper model (Core ML builds from the WhisperKit model
/// repository).
public struct WhisperModel: Sendable, Hashable, Identifiable, Codable {
    /// Stable identifier used in settings ("tiny", "base", ...).
    public let id: String
    public let name: String
    /// The WhisperKit variant folder name in the model repository.
    public let variant: String
    /// Approximate download size, for the UI.
    public let approximateSizeMB: Int
    public let summary: String

    public static let tiny = WhisperModel(
        id: "tiny", name: "Tiny", variant: "openai_whisper-tiny",
        approximateSizeMB: 75, summary: "Fastest, lowest accuracy."
    )
    public static let base = WhisperModel(
        id: "base", name: "Base", variant: "openai_whisper-base",
        approximateSizeMB: 145, summary: "Fast, good for short dictation."
    )
    public static let small = WhisperModel(
        id: "small", name: "Small", variant: "openai_whisper-small",
        approximateSizeMB: 480, summary: "Balanced speed and accuracy."
    )
    public static let largeV3Turbo = WhisperModel(
        id: "large-v3-turbo", name: "Large v3 Turbo",
        variant: "openai_whisper-large-v3-v20240930_turbo_632MB",
        approximateSizeMB: 632, summary: "Most accurate. Needs a recent iPhone (A16 or newer)."
    )

    public static let all: [WhisperModel] = [.tiny, .base, .small, .largeV3Turbo]

    public static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
