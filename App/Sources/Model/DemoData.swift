#if DEBUG
import Foundation
import KVoiceKit

/// `-kvoiceDemo`: run on scratch stores with sample modes and history, no
/// API keys and fresh preferences, for UI tests and screenshots. The real
/// modes, history, settings and Keychain are never read or written.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-kvoiceDemo") }

    static let suiteName = "kvoice.demo"
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }
    static let directory = URL.temporaryDirectory.appending(path: "KVoiceDemo", directoryHint: .isDirectory)
    /// A Keychain service prefix nothing else uses, so no key is found.
    static let secretsPrefix = "io.github.kccarlos.kvoice.ios.demo.apikey"
    static let chineseNotesID = UUID(uuidString: "D3A0C0DE-0000-4000-8000-000000000002")!

    /// Fresh scratch stores with the sample modes (history is seeded by
    /// `seed(_:)` at launch, as it is async).
    @MainActor
    static func stores() -> AppModel.Stores {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        let modes = ModeStore(directory: directory, defaults: defaults, postsNotifications: false)
        seed(modes)
        return (
            modes,
            SettingsStore(defaults: defaults, postsNotifications: false),
            KeychainStore(servicePrefix: secretsPrefix),
            try? HistoryStore(directory: directory)
        )
    }

    @MainActor
    private static func seed(_ modes: ModeStore) {
        let custom = [
            Mode(name: "Standup Update", icon: "person.3",
                 instructions: "Turn this into a short standup update: Yesterday, Today, Blockers, one line each."),
            Mode(id: chineseNotesID, name: "中文笔记", icon: "character.book.closed.zh",
                 instructions: "把口述内容整理成简洁的中文要点，保留人名、数字和日期。", language: "zh-Hans"),
            Mode(name: "Code Comment", icon: "chevron.left.forwardslash.chevron.right",
                 instructions: "Rewrite as a concise code comment in the imperative mood. No Markdown."),
        ]
        for mode in custom { try? modes.save(mode) }
        try? modes.setActiveMode(id: Mode.BuiltInID.cleanUp, chosenByUser: false)
    }

    static func seed(_ history: HistoryStore) async {
        let now = Date.now
        let hour: TimeInterval = 3600
        let records = [
            HistoryRecord(
                date: now - 0.2 * hour, duration: 14, modeID: Mode.BuiltInID.cleanUp, modeName: "Clean up",
                engine: "Apple Speech", provider: "Apple Intelligence",
                rawTranscript: "um so I think we should uh move the launch to Thursday because the build isn't ready",
                formattedText: "I think we should move the launch to Thursday because the build isn't ready."),
            HistoryRecord(
                date: now - 1.5 * hour, duration: 22, modeID: Mode.BuiltInID.email, modeName: "Email",
                engine: "Whisper Base", provider: "Apple Intelligence",
                rawTranscript: "hi Sam thanks for the notes I'll send the revised draft by Friday Alex",
                formattedText: "Hi Sam,\n\nThanks for the notes. I'll send the revised draft by Friday.\n\nAlex"),
            HistoryRecord(
                date: now - 3 * hour, duration: 9, modeID: Mode.BuiltInID.dictation, modeName: "Dictation",
                engine: "Apple Speech",
                rawTranscript: "Pick up oat milk, coffee beans and batteries on the way home.",
                formattedText: "Pick up oat milk, coffee beans and batteries on the way home."),
            HistoryRecord(
                date: now - 26 * hour, duration: 31, modeID: chineseNotesID, modeName: "中文笔记", engine: "Whisper Base",
                provider: "Apple Intelligence",
                rawTranscript: "明天上午十点和设计团队开会讨论新版首页然后下午把测试版发给王老师",
                formattedText: "- 明天上午 10 点与设计团队开会，讨论新版首页\n- 下午把测试版发给王老师"),
            HistoryRecord(
                date: now - 28 * hour, duration: 18, modeID: Mode.BuiltInID.notes, modeName: "Notes",
                engine: "Apple Speech", provider: "Apple Intelligence",
                rawTranscript: "budget review is done marketing needs two more weeks and Priya owns the vendor contract",
                formattedText: "- Budget review is done\n- Marketing needs two more weeks\n- Priya owns the vendor contract"),
            HistoryRecord(
                date: now - 74 * hour, duration: 12, modeID: Mode.BuiltInID.message, modeName: "Message",
                engine: "Apple Speech", provider: "Apple Intelligence",
                rawTranscript: "running about ten minutes late save me a seat",
                formattedText: "Running about 10 minutes late, save me a seat!"),
        ]
        for record in records { try? await history.add(record) }
    }
}
#endif
