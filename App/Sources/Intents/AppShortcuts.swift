import AppIntents
import Foundation

/// Stops the dictation in progress and returns its text (for Shortcuts).
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource { "Stop KVoice Dictation" }
    static var description: IntentDescription {
        IntentDescription("Stops the KVoice dictation in progress and returns the finished text.")
    }
    static var supportedModes: IntentModes { .background }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = await AppModel.shared.stopDictation()
        return .result(value: result?.text ?? "")
    }
}

struct KVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start \(.applicationName)",
                "Start dictating with \(.applicationName)",
                "Dictate \(\.$mode) with \(.applicationName)"
            ],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Stop dictating with \(.applicationName)"
            ],
            shortTitle: "Stop Dictation",
            systemImageName: "stop.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .purple }
}
