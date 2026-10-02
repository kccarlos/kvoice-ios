#if DEBUG
import KVoiceKit
import SwiftUI
import UIKit

/// Debug-only host for the keyboard UI, for simulator screenshots (a
/// keyboard extension can't be enabled from a script):
/// `-kvoiceKeyboardPreview ready|noFullAccess|recording|shortcutRecording`. Uses a scratch
/// mailbox and mode store, never the shared ones.
struct KeyboardPreviewScreen: View {
    enum State: String {
        case ready, noFullAccess, recording, shortcutRecording
    }

    static var requestedState: State? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-kvoiceKeyboardPreview") else { return nil }
        guard arguments.indices.contains(index + 1) else { return .ready }
        return State(rawValue: arguments[index + 1]) ?? .ready
    }

    @SwiftUI.State private var host: PreviewKeyboardHost
    @SwiftUI.State private var model: KeyboardModel

    init(state: State) {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "KeyboardPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let mailbox = DictationHandoff(directory: scratch.appending(path: "Handoff"), postsNotifications: false)
        let defaults = UserDefaults(suiteName: "kvoice.keyboardPreview") ?? .standard
        defaults.set(Mode.BuiltInID.cleanUp.uuidString, forKey: "activeModeID")
        if state == .recording {
            try? mailbox.writeResult(HandoffResult(sessionID: UUID(), status: .recording))
        }
        if state == .shortcutRecording {
            var reducer = DictationActivityReducer()
            _ = reducer.handle(.beginShortcut(newID: UUID(), modeID: Mode.BuiltInID.cleanUp, now: .now))
            try? mailbox.writeActivity(reducer.activity)
        }
        let host = PreviewKeyboardHost(hasFullAccess: state != .noFullAccess)
        _host = .init(initialValue: host)
        _model = .init(initialValue: KeyboardModel(
            host: host,
            mailbox: mailbox,
            modeStore: { ModeStore(directory: scratch, defaults: defaults, postsNotifications: false) }
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard preview").font(.headline)
                Text(host.text.isEmpty ? "Text field" : host.text)
                    .foregroundStyle(host.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
            .padding()
            Spacer()
            KeyboardView(model: model)
                .frame(height: 260)
                .background(KeyboardColors.backdrop)
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }
}

@MainActor
@Observable
final class PreviewKeyboardHost: KeyboardHost {
    var text = ""
    let hasFullAccess: Bool
    let needsInputModeSwitchKey = true
    let returnKeyType: UIReturnKeyType? = .default

    init(hasFullAccess: Bool) {
        self.hasFullAccess = hasFullAccess
    }

    var documentContextBeforeInput: String? { text }
    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func attachInputModeSwitch(to button: UIButton) {}
    func openURL(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(true) }
    func playHaptic(_ haptic: KeyboardDictation.Haptic) {}
}
#endif
