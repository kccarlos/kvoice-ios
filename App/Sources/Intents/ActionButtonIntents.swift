import AppIntents
import Foundation
import KVoiceKit
import UniformTypeIdentifiers

/// What Begin Dictation tells the shortcut: "If Outcome is Record".
enum DictationGateOutcome: String, AppEnum {
    case record
    case stoppedExisting
    case alreadyRecording

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Dictation Outcome" }
    static var caseDisplayRepresentations: [DictationGateOutcome: DisplayRepresentation] {
        [
            .record: "Record",
            .stoppedExisting: "Stopped Existing",
            .alreadyRecording: "Already Recording"
        ]
    }

    init(_ outcome: DictationActivityReducer.GateOutcome) {
        // The raw values match (a package test pins them).
        self = DictationGateOutcome(rawValue: outcome.rawValue) ?? .record
    }
}

/// Step 1 of the Action Button shortcut. Runs in the background, decides
/// whether the shortcut should record (see `Docs/DictationStates.md`), and
/// toggles: if KVoice itself is recording, it stops and finishes that
/// dictation instead.
struct BeginDictationIntent: AppIntent {
    static var title: LocalizedStringResource { "Begin Dictation" }
    static var description: IntentDescription {
        IntentDescription("Prepares a KVoice dictation from any app. Use it before Record Audio and Transcribe Audio; record only if the outcome is Record.")
    }
    /// Background only: the shortcut keeps the current app in front (the
    /// iOS 26 replacement for `openAppWhenRun = false`).
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Mode", description: "The mode for this dictation. Uses the active mode when empty.")
    var mode: ModeEntity?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Begin dictation in \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<DictationGateOutcome> & ProvidesDialog {
        let model = AppModel.shared
        model.modes.reload()
        if let id = mode?.id, model.modes.mode(id: id) != nil {
            try? model.modes.setActiveMode(id: id)
        }
        let outcome = model.handoff.beginShortcut(modeID: mode?.id)
        return .result(value: DictationGateOutcome(outcome), dialog: IntentDialog(stringLiteral: outcome.dialog))
    }
}

/// Step 3 of the Action Button shortcut: transcribes the Record Audio file
/// in the background and returns the text (copied by the shortcut, typed
/// by a visible KVoice keyboard, saved in History). Continues in the
/// foreground when the job cannot finish in the background budget.
struct TranscribeAudioIntent: AppIntent {
    static var title: LocalizedStringResource { "Transcribe Audio" }
    static var description: IntentDescription {
        IntentDescription("Transcribes and formats an audio recording with KVoice and returns the text. Saves it in History.")
    }
    /// Background, continuing in the foreground on demand: the iOS 26 form
    /// of `ForegroundContinuableIntent`.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Audio", description: "A recording, for example from Record Audio.", supportedContentTypes: [.audio])
    var audio: IntentFile

    @Parameter(title: "Mode", description: "Uses the active mode when empty.")
    var mode: ModeEntity?

    @Parameter(title: "Language", description: "A language code such as en-US. Uses the mode's language when empty.")
    var language: String?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$audio) in \(\.$mode)") {
            \.$language
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        model.modes.reload()
        model.settings.reload()
        let fileExtension = URL(filePath: audio.filename).pathExtension.nonEmpty
            ?? audio.type?.preferredFilenameExtension
            ?? "m4a"
        let text = try await model.transcribeShortcutAudio(
            data: audio.data,
            fileExtension: fileExtension,
            modeID: mode?.id,
            language: language?.trimmingCharacters(in: .whitespaces).nonEmpty,
            isForeground: systemContext.currentMode == .foreground,
            continueInForeground: {
                try await continueInForeground("Finish this dictation in KVoice?", alwaysConfirm: false)
            }
        )
        return .result(value: text, dialog: IntentDialog(stringLiteral: Self.preview(text)))
    }

    /// A short dialog: the start of the text.
    static func preview(_ text: String) -> String {
        text.count > 120 ? String(text.prefix(117)) + "…" : text
    }
}

extension AudioJobError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Dictation failed.")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
