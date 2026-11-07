import Foundation

/// Whether a mode's AI step can run with what is set up on this device.
public enum AIReadiness {
    /// True when `mode` uses AI and its provider cannot run: Apple
    /// Intelligence is unavailable, or a cloud provider has no API key.
    public static func needsSetup(
        _ mode: Mode, settings: Settings, appleIntelligenceAvailable: Bool, hasKey: (ProviderKind) -> Bool
    ) -> Bool {
        guard mode.usesAI else { return false }
        let kind = settings.provider(for: mode).kind
        return kind == .appleIntelligence ? !appleIntelligenceAvailable : !hasKey(kind)
    }
}
