import AppIntents
import Foundation

/// Opens KVoice and starts dictating; if KVoice is already recording, it
/// stops and processes instead (so one press starts and the next one
/// finishes). Follows the shared `DictationActivity`: it does not start
/// while an Action Button shortcut owns the microphone. Compiled into the app and the widget extension; it
/// always runs in the app.
struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource { "Dictate with KVoice" }
    static var description: IntentDescription {
        IntentDescription("Opens KVoice and starts recording. Run it again to finish the dictation.")
    }
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Mode", description: "The mode to dictate in. Uses the active mode when empty.")
    var mode: ModeEntity?

    init() {}

    init(mode: ModeEntity?) {
        self.mode = mode
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Dictate in \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !KVOICE_WIDGET_EXTENSION
        let model = AppModel.shared
        model.selectedTab = .home
        if model.pipeline.isRecording {
            await model.stopDictation()
        } else {
            // Refused with a notice while the Action Button records.
            await model.startDictation(modeID: mode?.id, source: .intent)
        }
        #endif
        return .result()
    }
}
