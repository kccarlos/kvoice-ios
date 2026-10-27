import Foundation

/// How Toggle Dictation behaves after it starts recording. A debug knob: it
/// is not part of `Settings`.
public enum ToggleStartStrategy: String, CaseIterable, Sendable, Hashable {
    /// The intent returns an empty string at once.
    case returnImmediately
    /// The intent stays running until the recording ends, in case iOS only
    /// lends the microphone while `perform` is running.
    case holdUntilStopped

    public static let defaultsKey = "debug.toggleStartStrategy"

    /// The stored strategy, `.returnImmediately` when unset or unknown.
    public static func current(defaults: UserDefaults = AppGroup.defaults) -> ToggleStartStrategy {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .returnImmediately
    }

    public static func set(_ strategy: ToggleStartStrategy, defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(strategy.rawValue, forKey: defaultsKey)
    }
}
