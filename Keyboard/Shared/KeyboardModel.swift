import Foundation
import KVoiceCore
import Observation
import UIKit

/// What the keyboard UI needs from its `UIInputViewController` (or from a
/// stand-in in the app's debug preview).
@MainActor
protocol KeyboardHost: AnyObject {
    var hasFullAccess: Bool { get }
    var needsInputModeSwitchKey: Bool { get }
    var documentContextBeforeInput: String? { get }
    var returnKeyType: UIReturnKeyType? { get }
    func insertText(_ text: String)
    func deleteBackward()
    /// Wires the globe key (tap: next keyboard, long press: keyboard list).
    func attachInputModeSwitch(to button: UIButton)
    func openURL(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func playHaptic(_ haptic: KeyboardDictation.Haptic)
}

/// Runs `KeyboardDictation` against the App Group mailbox and the text
/// field. Kept light: the extension's memory limit is tight.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var dictation = KeyboardDictation()
    private(set) var modes: [Mode] = []
    private(set) var activeModeID: UUID?
    private(set) var hasFullAccess = false
    private(set) var showsGlobeKey = false
    private(set) var canUndo = false
    private(set) var returnKeyType: UIReturnKeyType = .default

    @ObservationIgnored private weak var host: (any KeyboardHost)?
    @ObservationIgnored private let mailbox: DictationHandoff
    @ObservationIgnored private let makeModeStore: () -> ModeStore
    @ObservationIgnored private var modeStore: ModeStore?
    @ObservationIgnored private var observers: [DarwinNotificationObserver] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(
        host: any KeyboardHost,
        mailbox: DictationHandoff = DictationHandoff(),
        modeStore: @escaping () -> ModeStore = { ModeStore() }
    ) {
        self.host = host
        self.mailbox = mailbox
        self.makeModeStore = modeStore
    }

    var phase: KeyboardDictation.Phase { dictation.phase }

    // MARK: Lifecycle

    /// The keyboard appeared: read shared state and start listening.
    func activate() {
        refreshTraits()
        guard hasFullAccess else { return }
        if modeStore == nil { modeStore = makeModeStore() }
        reloadModes()
        if observers.isEmpty {
            observers = [
                observe(.handoffResult) { $0.readMailbox() },
                observe(.modesChanged) { $0.reloadModes() },
                observe(.activeModeChanged) { $0.reloadModes() }
            ]
        }
        readMailbox()
    }

    /// The keyboard went away (the user opened KVoice or switched
    /// keyboards): stop observing; `activate` re-reads everything.
    func deactivate() {
        observers.forEach { $0.cancel() }
        observers = []
        ticker?.cancel()
        ticker = nil
    }

    func refreshTraits() {
        guard let host else { return }
        hasFullAccess = host.hasFullAccess
        showsGlobeKey = host.needsInputModeSwitchKey
        returnKeyType = host.returnKeyType ?? .default
        updateUndo()
    }

    /// The text or selection changed outside the keyboard.
    func textDidChange() {
        refreshTraits()
    }

    private func observe(
        _ name: DarwinNotificationName,
        _ action: @escaping @MainActor (KeyboardModel) -> Void
    ) -> DarwinNotificationObserver {
        DarwinNotifications.observe(name) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        }
    }

    // MARK: Modes (FR-22)

    var activeMode: Mode? { modes.first { $0.id == activeModeID } }

    func selectMode(_ id: UUID) {
        guard hasFullAccess, let modeStore else { return }
        try? modeStore.setActiveMode(id: id)
        reloadModes()
    }

    private func reloadModes() {
        guard let modeStore else { return }
        modeStore.reload()
        modes = modeStore.modes
        activeModeID = modeStore.activeModeID
    }

    // MARK: Dictation

    func micTapped() {
        guard hasFullAccess else { return }
        reloadModes()
        let acceptsCommands = mailbox.readAppState()?.acceptsCommands() == true
        send(.micTapped(
            newSessionID: UUID(),
            modeID: activeModeID ?? Mode.BuiltInID.dictation,
            appAcceptsCommands: acceptsCommands,
            now: .now
        ))
    }

    func cancelTapped() {
        send(.cancelTapped(now: .now))
    }

    func undoTapped() {
        send(.undoTapped(contextBeforeInput: host?.documentContextBeforeInput))
    }

    private func readMailbox() {
        guard hasFullAccess else { return }
        let result = mailbox.readResult()
        let pending = result.map { mailbox.readRequest()?.sessionID == $0.sessionID } ?? false
        send(.mailboxChanged(result: result, requestPending: pending, now: .now))
    }

    private func send(_ event: KeyboardDictation.Event) {
        let effects = dictation.handle(event)
        effects.forEach(perform)
        updateTicker()
        updateUndo()
    }

    private func perform(_ effect: KeyboardDictation.Effect) {
        switch effect {
        case .sendRequest(let request):
            do {
                try mailbox.writeRequest(request)
                open(session: request.sessionID)
            } catch {
                send(.openFailed(request.sessionID))
            }
        case .openApp(let session):
            open(session: session)
        case .sendCommand(let command):
            try? mailbox.writeCommand(command)
        case let .insert(text, session):
            let typed = KeyboardDictation.insertionText(for: text, contextBeforeInput: host?.documentContextBeforeInput)
            host?.insertText(typed)
            dictation.didInsert(typed)
            try? mailbox.markResultConsumed(sessionID: session)
        case .markConsumed(let session):
            try? mailbox.markResultConsumed(sessionID: session)
        case .deleteBackward(let count):
            for _ in 0..<count { host?.deleteBackward() }
        case .haptic(let haptic):
            host?.playHaptic(haptic)
        }
    }

    private func open(session: UUID) {
        host?.openURL(DictationHandoff.dictationURL(sessionID: session)) { [weak self] opened in
            if !opened { self?.send(.openFailed(session)) }
        }
    }

    /// While a session is in flight, re-read the mailbox and check
    /// timeouts every half second (Darwin posts can be missed or coalesce).
    private func updateTicker() {
        guard dictation.phase.isActive else {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil, !observers.isEmpty else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.readMailbox()
                self.send(.tick(now: .now))
            }
        }
    }

    private func updateUndo() {
        canUndo = dictation.lastInsertion.flatMap {
            KeyboardDictation.undoDeletionCount(inserted: $0, contextBeforeInput: host?.documentContextBeforeInput)
        } != nil
    }

    // MARK: Keys

    func attachInputModeSwitch(to button: UIButton) {
        host?.attachInputModeSwitch(to: button)
    }

    func insertSpace() { type(" ") }
    func insertReturn() { type("\n") }

    func deleteBackward() {
        host?.deleteBackward()
        edited()
    }

    private func type(_ text: String) {
        host?.insertText(text)
        edited()
    }

    private func edited() {
        if dictation.lastInsertion != nil { send(.userEdited) }
    }
}
