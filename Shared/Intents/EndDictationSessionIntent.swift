import AppIntents
import Foundation
#if !KVOICE_WIDGET_EXTENSION
import KVoiceKit
#endif

/// The End button of the standby Live Activity: releases the microphone
/// KVoice kept for the keyboard and the Action Button. Runs in the app.
struct EndDictationSessionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "End KVoice Session" }
    static var description: IntentDescription {
        IntentDescription("Stops KVoice from listening between dictations and releases the microphone.")
    }
    static var isDiscoverable: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !KVOICE_WIDGET_EXTENSION
        guard let handoff = AppModel.shared.handoff else { return .result() }
        // Only a standby ends; a recording or job is never touched.
        if case .standby = handoff.effectivePhase {
            DiagnosticsLog.shared.append(category: "standby", "ended by live activity")
            handoff.endStandby()
        }
        #endif
        return .result()
    }
}
