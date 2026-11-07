import Foundation

/// Cloud providers get the user's audio or text only after the user allows
/// each one in the app (App Review Guideline 5.1.2(i), third-party AI).
/// Apple Speech, Whisper and Apple Intelligence run on device and need no
/// consent. Consent is stored in `Settings`, so a background run in the app
/// process sees the same answer as the app.
extension Settings {
    /// Whether data may be sent to `kind`.
    public func allowsCloud(_ kind: ProviderKind) -> Bool {
        kind == .appleIntelligence || allowedCloudProviders?.contains(kind) == true
    }

    /// The cloud provider a transcription engine sends audio to, if any.
    public static func cloudProvider(of engine: TranscriptionEngineSelection) -> ProviderKind? {
        engine.kind == .cloud ? (engine.cloud?.provider ?? .openAI) : nil
    }

    /// The first cloud provider chosen anywhere (the defaults or a mode)
    /// that the user has not allowed yet.
    public func providerNeedingConsent(modes: [Mode]) -> ProviderKind? {
        var chosen = [Self.cloudProvider(of: defaultEngine), defaultProvider.kind]
        for mode in modes {
            chosen.append(mode.engineOverride.flatMap(Self.cloudProvider(of:)))
            chosen.append(mode.providerOverride?.kind)
        }
        return chosen.compactMap(\.self).first { !allowsCloud($0) }
    }

    public mutating func allowCloud(_ kind: ProviderKind) {
        allowedCloudProviders = (allowedCloudProviders ?? []).union([kind])
    }

    /// Declined or withdrawn: forget the consent and move the defaults that
    /// use `kind` back on device (modes: `Mode.removingCloud(_:)`).
    public mutating func revokeCloud(_ kind: ProviderKind) {
        allowedCloudProviders?.remove(kind)
        if Self.cloudProvider(of: defaultEngine) == kind { defaultEngine = .appleSpeech }
        if defaultProvider.kind == kind { defaultProvider = .appleIntelligence }
    }
}

extension Mode {
    /// This mode with its overrides that use `kind` moved on device, or nil
    /// when it does not use `kind`.
    public func removingCloud(_ kind: ProviderKind) -> Mode? {
        var mode = self
        if engineOverride.flatMap(Settings.cloudProvider(of:)) == kind { mode.engineOverride = .appleSpeech }
        if providerOverride?.kind == kind { mode.providerOverride = .appleIntelligence }
        return mode == self ? nil : mode
    }
}
