import Foundation

/// Cloud providers get the user's audio or text only after the user allows
/// each one in the app (App Review Guideline 5.1.2(i), third-party AI).
/// Apple Speech, Whisper and Apple Intelligence run on device and need no
/// consent. Consent is stored in `Settings`, so a background run in the app
/// process sees the same answer as the app.
extension Settings {
    /// Whether data may be sent to `kind` at `baseURL`. A custom endpoint is
    /// allowed per host, so changing its URL asks again; without a host
    /// nothing can be sent, so it asks once the URL is entered.
    public func allowsCloud(_ kind: ProviderKind, baseURL: URL? = nil) -> Bool {
        if kind == .customOpenAICompatible {
            guard let host = Self.host(of: baseURL) else { return true }
            return allowedCustomHosts?.contains(host) == true
        }
        return kind == .appleIntelligence || allowedCloudProviders?.contains(kind) == true
    }

    /// The cloud provider a transcription engine sends audio to, if any.
    public static func cloudProvider(of engine: TranscriptionEngineSelection) -> ProviderKind? {
        engine.kind == .cloud ? (engine.cloud?.provider ?? .openAI) : nil
    }

    static func host(of url: URL?) -> String? { url?.host()?.lowercased() }

    /// Every provider chosen (the defaults and each mode) with the base URL
    /// it would be sent to.
    private func cloudChoices(modes: [Mode]) -> [(kind: ProviderKind, baseURL: URL?)] {
        var choices: [(kind: ProviderKind, baseURL: URL?)] = []
        func add(_ engine: TranscriptionEngineSelection?) {
            if let engine, let kind = Self.cloudProvider(of: engine) { choices.append((kind, engine.cloud?.resolvedBaseURL)) }
        }
        add(defaultEngine)
        choices.append((defaultProvider.kind, defaultProvider.resolvedBaseURL))
        for mode in modes {
            add(mode.engineOverride)
            if let provider = mode.providerOverride { choices.append((provider.kind, provider.resolvedBaseURL)) }
        }
        return choices
    }

    /// The first cloud provider chosen anywhere (the defaults or a mode)
    /// that the user has not allowed yet.
    public func providerNeedingConsent(modes: [Mode]) -> ProviderKind? {
        cloudChoices(modes: modes).first { !allowsCloud($0.kind, baseURL: $0.baseURL) }?.kind
    }

    /// The hosts of the custom endpoints chosen anywhere, in order.
    public func customHosts(modes: [Mode]) -> [String] {
        var hosts: [String] = []
        for choice in cloudChoices(modes: modes) where choice.kind == .customOpenAICompatible {
            if let host = Self.host(of: choice.baseURL), !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    /// Allows `kind`; for a custom endpoint, the hosts chosen in `modes` and
    /// the defaults.
    public mutating func allowCloud(_ kind: ProviderKind, modes: [Mode] = []) {
        allowedCloudProviders = (allowedCloudProviders ?? []).union([kind])
        if kind == .customOpenAICompatible {
            allowedCustomHosts = (allowedCustomHosts ?? []).union(customHosts(modes: modes))
        }
    }

    /// Declined or withdrawn: forget the consent and move the defaults that
    /// use `kind` back on device (modes: `Mode.removingCloud(_:)`).
    public mutating func revokeCloud(_ kind: ProviderKind) {
        allowedCloudProviders?.remove(kind)
        if kind == .customOpenAICompatible { allowedCustomHosts = nil }
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
