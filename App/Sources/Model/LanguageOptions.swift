import Foundation

/// Spoken languages offered in the mode editor (BCP-47). Whisper supports
/// many more; these cover the common choices.
enum LanguageOptions {
    static let tags = [
        "en-US", "en-GB", "es", "fr", "de", "it", "pt-BR", "pt-PT", "nl", "sv", "da", "nb", "fi",
        "pl", "cs", "uk", "ru", "tr", "el", "he", "ar", "hi", "zh-Hans", "zh-Hant", "yue",
        "ja", "ko", "vi", "th", "id", "ms"
    ]

    static func name(for tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }
}
