import Foundation

/// What the Live Activity shows, derived from `DictationActivity`. Plain
/// data so KVoiceCore stays free of ActivityKit; the app wraps it in its
/// `ActivityAttributes`.
public struct DictationLiveStatus: Codable, Sendable, Hashable {
    public enum Stage: Codable, Sendable, Hashable {
        case recording(startedAt: Date)
        case transcribing
        case formatting
        case done(preview: String)
        case failed(message: String)
        /// The engine keeps running until `until`; `lastPreview` is the text
        /// just copied, if any.
        case standby(until: Date, lastPreview: String?)
    }

    public var stage: Stage
    public var modeName: String
    public var modeIcon: String

    public init(stage: Stage, modeName: String, modeIcon: String) {
        self.stage = stage
        self.modeName = modeName
        self.modeIcon = modeIcon
    }

    /// The longest result preview, in characters.
    public static let previewLength = 80

    /// The status for a phase, or nil when the Live Activity should end
    /// (idle).
    public static func from(
        phase: DictationActivity.Phase,
        modeName: String,
        modeIcon: String,
        resultText: String? = nil
    ) -> DictationLiveStatus? {
        let stage: Stage
        switch phase {
        case .idle:
            return nil
        case .standby(let expiresAt):
            let last = resultText.map(preview(of:)).flatMap { $0.isEmpty ? nil : $0 }
            stage = .standby(until: expiresAt, lastPreview: last)
        case .recording(_, _, let startedAt):
            stage = .recording(startedAt: startedAt)
        case .processing(.transcribing, _):
            stage = .transcribing
        case .processing(.formatting, _):
            stage = .formatting
        case .delivered:
            stage = .done(preview: preview(of: resultText ?? ""))
        case .failed(_, let message):
            stage = .failed(message: message)
        }
        return DictationLiveStatus(stage: stage, modeName: modeName, modeIcon: modeIcon)
    }

    /// The first 80 characters, with an ellipsis when cut.
    public static func preview(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > previewLength else { return trimmed }
        return String(trimmed.prefix(previewLength)) + "…"
    }
}
