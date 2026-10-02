import Foundation

/// The App Group shared by the app and the keyboard extension. Its identifier
/// comes from the `KVoiceAppGroup` Info.plist key, set from the build setting.
public enum AppGroup {
    public static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "KVoiceAppGroup") as? String
            ?? "group.io.github.kccarlos.kvoice.ios"
    }

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
