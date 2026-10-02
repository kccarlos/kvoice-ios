import Foundation
import Observation

/// How long history is kept.
public enum RetentionPeriod: String, Codable, Sendable, Hashable, CaseIterable {
    case forever
    case days30
    case days7

    /// The maximum age of a record, or `nil` to keep forever.
    public var maximumAge: TimeInterval? {
        switch self {
        case .forever: nil
        case .days30: 30 * 24 * 3600
        case .days7: 7 * 24 * 3600
        }
    }
}

public struct RetentionPolicy: Codable, Sendable, Hashable {
    public var period: RetentionPeriod
    /// When false, recordings are deleted as soon as they are transcribed
    /// and history keeps only text.
    public var keepsAudio: Bool

    public init(period: RetentionPeriod = .forever, keepsAudio: Bool = true) {
        self.period = period
        self.keepsAudio = keepsAudio
    }
}

/// App-wide defaults, shared with the keyboard through App Group defaults.
public struct Settings: Codable, Sendable, Hashable {
    public var defaultEngine: TranscriptionEngineSelection
    public var defaultProvider: ProviderConfiguration
    /// Per-provider edits (base URL, model) so switching providers back and
    /// forth keeps what the user typed.
    public var providerConfigurations: [ProviderKind: ProviderConfiguration]
    public var retention: RetentionPolicy

    public init(
        defaultEngine: TranscriptionEngineSelection = .appleSpeech,
        defaultProvider: ProviderConfiguration = .appleIntelligence,
        providerConfigurations: [ProviderKind: ProviderConfiguration] = [:],
        retention: RetentionPolicy = RetentionPolicy()
    ) {
        self.defaultEngine = defaultEngine
        self.defaultProvider = defaultProvider
        self.providerConfigurations = providerConfigurations
        self.retention = retention
    }

    /// The stored configuration for a provider, or its defaults.
    public func configuration(for kind: ProviderKind) -> ProviderConfiguration {
        providerConfigurations[kind] ?? ProviderConfiguration(kind: kind)
    }

    /// The engine a mode transcribes with.
    public func engine(for mode: Mode) -> TranscriptionEngineSelection {
        mode.engineOverride ?? defaultEngine
    }

    /// The provider a mode formats with.
    public func provider(for mode: Mode) -> ProviderConfiguration {
        mode.providerOverride ?? defaultProvider
    }
}

/// Persists `Settings` as JSON in App Group defaults.
@MainActor
@Observable
public final class SettingsStore {
    public var settings: Settings {
        didSet { persist() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifies: Bool
    static let key = "settings.v1"

    public init(defaults: UserDefaults = AppGroup.defaults, postsNotifications: Bool = true) {
        self.defaults = defaults
        self.notifies = postsNotifications
        self.settings = Self.load(from: defaults)
    }

    /// Re-reads settings written by the other process.
    public func reload() {
        let loaded = Self.load(from: defaults)
        if loaded != settings { settings = loaded }
    }

    private static func load(from defaults: UserDefaults) -> Settings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
        if notifies { DarwinNotifications.post(.settingsChanged) }
    }
}
