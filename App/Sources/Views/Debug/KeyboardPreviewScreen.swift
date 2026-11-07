#if DEBUG
import KVoiceKit
import SwiftUI
import UIKit

/// Debug-only host for the keyboard UI, for simulator screenshots (a
/// keyboard extension can't be enabled from a script):
/// `-kvoiceKeyboardPreview <State>`. Uses a scratch mailbox and mode store,
/// never the shared ones.
struct KeyboardPreviewScreen: View {
    enum State: String {
        case letters, shift, capsLock, numbers, symbols, noFullAccess, fullAccessCard
        case recording, processing, shortcutRecording
    }

    static var requestedState: State? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-kvoiceKeyboardPreview") else { return nil }
        guard arguments.indices.contains(index + 1) else { return .letters }
        return State(rawValue: arguments[index + 1]) ?? .letters
    }

    @SwiftUI.State private var host: PreviewKeyboardHost
    @SwiftUI.State private var model: KeyboardModel
    private let state: State

    init(state: State) {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "KeyboardPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        let mailbox = DictationHandoff(directory: scratch.appending(path: "Handoff"), postsNotifications: false)
        let defaults = UserDefaults(suiteName: "kvoice.keyboardPreview") ?? .standard
        defaults.set(Mode.BuiltInID.cleanUp.uuidString, forKey: "activeModeID")
        if state == .recording || state == .processing {
            try? mailbox.writeResult(HandoffResult(sessionID: UUID(), status: state == .recording ? .recording : .transcribing))
        }
        if state == .shortcutRecording {
            var reducer = DictationActivityReducer()
            _ = reducer.handle(.beginShortcut(newID: UUID(), modeID: Mode.BuiltInID.cleanUp, now: .now))
            try? mailbox.writeActivity(reducer.activity)
        }
        let host = PreviewKeyboardHost(hasFullAccess: state != .noFullAccess && state != .fullAccessCard)
        // Mid-sentence, so the letters show in lower case.
        if [.letters, .numbers, .symbols].contains(state) { host.text = "Fix this" }
        self.state = state
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
                .frame(height: KeyboardView.height)
                .background(KeyboardColors.backdrop)
        }
        .onAppear {
            model.activate()
            switch state {
            case .capsLock: model.tap(.shift); model.tap(.shift)
            case .numbers: model.tap(.layer(.numbers))
            case .symbols: model.tap(.layer(.numbers)); model.tap(.layer(.symbols))
            case .fullAccessCard: model.micTapped()
            default: break
            }
        }
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
    let autocapitalizes = true

    init(hasFullAccess: Bool) {
        self.hasFullAccess = hasFullAccess
    }

    var documentContextBeforeInput: String? { text }
    func insertText(_ text: String) { self.text += text }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func playKeyFeedback() {}
    func attachInputModeSwitch(to button: UIButton) {}
    func openURL(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(true) }
    func playHaptic(_ haptic: KeyboardDictation.Haptic) {}
}

/// `-kvoiceTypingField`: a plain text field for the real keyboard test
/// (UITests/KeyboardExtensionUITests), outside AppModel.
struct TypingFieldScreen: View {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-kvoiceTypingField") }

    @SwiftUI.State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Type here", text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($focused)
            .accessibilityIdentifier("typingField")
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { focused = true }
    }
}
#endif
