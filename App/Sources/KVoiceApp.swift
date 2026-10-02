import AppIntents
import KVoiceKit
import SwiftUI

@main
struct KVoiceApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        KVoiceShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let state = KeyboardPreviewScreen.requestedState {
                KeyboardPreviewScreen(state: state)
            } else {
                root
            }
            #else
            root
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.modes.reload()
                model.settings.reload()
            case .background:
                // Leave the compact recorder once the keyboard session is over.
                if model.handoff.sessionID == nil { model.handoff.isPresentingRecorder = false }
            default:
                break
            }
        }
    }

    private var root: some View {
        RootView()
            .environment(model)
            .onOpenURL { url in
                model.handoff.handle(url)
            }
            .task {
                if let url = AppPreferences.launchURL { model.handoff.handle(url) }
                await model.applyRetention()
            }
    }
}
