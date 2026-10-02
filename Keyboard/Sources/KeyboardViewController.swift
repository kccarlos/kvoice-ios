import KVoiceCore
import SwiftUI
import UIKit

/// The KVoice keyboard. iOS keyboards cannot use the microphone, so the
/// keyboard hands each dictation to the app through the App Group mailbox
/// (`DictationHandoff`) and types the result; see `KeyboardDictation`.
final class KeyboardViewController: UIInputViewController, KeyboardHost {
    private lazy var model = KeyboardModel(host: self)
    private lazy var feedback = UIImpactFeedbackGenerator(style: .medium)

    static let preferredHeight: CGFloat = 260

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // The system owns the input view's height; a high-priority (not
        // required) constraint on it requests ours.
        let height = view.heightAnchor.constraint(equalToConstant: Self.preferredHeight)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.activate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Darwin observers and the poll timer go away with the keyboard;
        // `activate` rebuilds state from the mailbox when it comes back.
        model.deactivate()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        model.refreshTraits()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        model.textDidChange()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        model.textDidChange()
    }

    // MARK: KeyboardHost

    var documentContextBeforeInput: String? { textDocumentProxy.documentContextBeforeInput }
    var returnKeyType: UIReturnKeyType? { textDocumentProxy.returnKeyType }

    func insertText(_ text: String) { textDocumentProxy.insertText(text) }
    func deleteBackward() { textDocumentProxy.deleteBackward() }

    func attachInputModeSwitch(to button: UIButton) {
        button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    }

    func openURL(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        AppURLOpener.open(url, from: self, completion: completion)
    }

    func playHaptic(_ haptic: KeyboardDictation.Haptic) {
        // Keyboard haptics only work with Full Access.
        guard hasFullAccess else { return }
        feedback.impactOccurred(intensity: haptic == .start ? 0.8 : 0.6)
    }
}
