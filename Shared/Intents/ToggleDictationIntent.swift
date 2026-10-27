import AppIntents
import Foundation

/// One press starts dictating in the background; the next press stops,
/// transcribes and returns the text (also copied to the clipboard). The
/// first press returns an empty string, so a shortcut can branch on it.
/// Compiled into the app and the widget extension (Control, Live Activity
/// Stop button); it always runs in the app.
struct ToggleDictationIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource { "Toggle Dictation" }
    static var description: IntentDescription {
        IntentDescription("Starts dictating in the background. Run it again to stop; KVoice copies the text and returns it.")
    }
    /// Background, continuing in the foreground on demand (when iOS does
    /// not let KVoice start the microphone in the background).
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Mode", description: "The mode to dictate in. Uses the active mode when empty.")
    var mode: ModeEntity?

    init() {}

    init(mode: ModeEntity?) {
        self.mode = mode
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle dictation in \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        #if !KVOICE_WIDGET_EXTENSION
        let text = try await AppModel.shared.toggleDictation(
            modeID: mode?.id,
            isForeground: systemContext.currentMode == .foreground,
            continueInForeground: { reason in
                try await continueInForeground(IntentDialog(stringLiteral: reason), alwaysConfirm: false)
            }
        )
        return .result(value: text)
        #else
        return .result(value: "")
        #endif
    }
}
