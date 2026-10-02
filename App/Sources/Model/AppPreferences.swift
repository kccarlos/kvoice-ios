import Foundation
import KVoiceKit

/// App-only preferences (not needed by the keyboard), stored in App Group
/// defaults next to the shared settings.
enum AppPreferences {
    static let autoCopyKey = "pref.autoCopy"
    static let keepAliveMinutesKey = "pref.keepAliveMinutes"
    static let onboardingDoneKey = "pref.onboardingDone"

    static var store: UserDefaults { AppGroup.defaults }

    /// Copy every finished dictation to the clipboard.
    static var autoCopy: Bool {
        store.object(forKey: autoCopyKey) as? Bool ?? true
    }

    /// How long the app keeps listening for keyboard commands in the
    /// background after a keyboard dictation; 0 turns it off.
    static var keepAliveMinutes: Int {
        store.object(forKey: keepAliveMinutesKey) as? Int ?? 5
    }

    static let keepAliveChoices = [0, 1, 5, 10, 15]

    /// UI-test and screenshot hooks: `-kvoiceSkipOnboarding`, `-kvoiceTab <name>`,
    /// `-kvoiceOpenURL <url>`.
    static var launchArguments: [String] { ProcessInfo.processInfo.arguments }

    static var skipsOnboarding: Bool { launchArguments.contains("-kvoiceSkipOnboarding") }

    /// `-kvoiceOpenURL <url>`: handle a URL at launch as if opened (the
    /// simulator asks for confirmation when a URL is opened from the host).
    static var launchURL: URL? {
        guard let index = launchArguments.firstIndex(of: "-kvoiceOpenURL"),
              launchArguments.indices.contains(index + 1) else { return nil }
        return URL(string: launchArguments[index + 1])
    }

    /// `-kvoiceScreen actionButton`: open a Settings screen (screenshots).
    static var initialScreen: String? {
        guard let index = launchArguments.firstIndex(of: "-kvoiceScreen"),
              launchArguments.indices.contains(index + 1) else { return nil }
        return launchArguments[index + 1]
    }

    static var initialTab: AppTab? {
        guard let index = launchArguments.firstIndex(of: "-kvoiceTab"),
              launchArguments.indices.contains(index + 1) else { return nil }
        return AppTab(rawValue: launchArguments[index + 1].lowercased())
    }
}

enum AppTab: String, Hashable, CaseIterable {
    case home, modes, history, settings
}
