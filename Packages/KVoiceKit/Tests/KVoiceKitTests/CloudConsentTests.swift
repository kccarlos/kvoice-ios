import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@MainActor
@Suite struct CloudConsentTests {
    let openAIEngine = TranscriptionEngineSelection.cloud(CloudTranscriptionConfiguration(provider: .openAI))
    let groq = ProviderConfiguration(kind: .groq)

    @Test func onDeviceNeedsNoConsent() {
        let settings = Settings()
        #expect(settings.providerNeedingConsent(modes: Mode.builtIns) == nil)
        #expect(settings.allowsCloud(.appleIntelligence))
        #expect(!settings.allowsCloud(.openAI))
        #expect(Settings(defaultEngine: .whisper()).providerNeedingConsent(modes: []) == nil)
    }

    @Test func everyCloudChoiceNeedsConsent() {
        #expect(Settings(defaultEngine: openAIEngine).providerNeedingConsent(modes: []) == .openAI)
        #expect(Settings(defaultProvider: groq).providerNeedingConsent(modes: []) == .groq)
        var mode = Mode.email
        mode.providerOverride = groq
        #expect(Settings().providerNeedingConsent(modes: [mode]) == .groq)
        mode = Mode.dictation
        mode.engineOverride = .cloud(CloudTranscriptionConfiguration(provider: .gemini))
        #expect(Settings().providerNeedingConsent(modes: [mode]) == .gemini)

        var both = Settings(defaultEngine: openAIEngine, defaultProvider: groq)
        both.allowCloud(.openAI)
        #expect(both.providerNeedingConsent(modes: []) == .groq)
        both.allowCloud(.groq)
        #expect(both.providerNeedingConsent(modes: []) == nil)
    }

    @Test func customEndpointConsentIsPerHost() async throws {
        let hostA = ProviderConfiguration(kind: .customOpenAICompatible, baseURL: URL(string: "https://A.example.com/v1"))
        let hostB = ProviderConfiguration(kind: .customOpenAICompatible, baseURL: URL(string: "https://b.example.org/v1"))
        var mode = Mode.email
        mode.providerOverride = hostB
        var settings = Settings(defaultProvider: hostA)
        #expect(settings.customHosts(modes: [mode]) == ["a.example.com", "b.example.org"])
        settings.allowCloud(.customOpenAICompatible)
        #expect(settings.allowedCustomHosts == ["a.example.com"])
        #expect(settings.providerNeedingConsent(modes: []) == nil)
        #expect(settings.providerNeedingConsent(modes: [mode]) == .customOpenAICompatible)

        // Switching the default to another host asks again, and the pipeline refuses it.
        settings.defaultProvider = hostB
        #expect(settings.providerNeedingConsent(modes: []) == .customOpenAICompatible)
        let current = settings
        let pipeline = DictationPipeline(
            recorder: StubRecorder(),
            engines: StubEngines(engine: StubEngine(text: "hi")),
            formatters: StubFormatters(formatter: StubFormatter()),
            history: nil,
            settings: { current }
        )
        await #expect(throws: DictationError.cloudConsentRequired(.customOpenAICompatible)) {
            try await pipeline.reformat("raw", mode: .notes)
        }

        settings.allowCloud(.customOpenAICompatible, modes: [mode])
        #expect(settings.providerNeedingConsent(modes: [mode]) == nil)
        settings.revokeCloud(.customOpenAICompatible)
        #expect(settings.allowedCustomHosts == nil)
    }

    @Test func customConsentFromBeforeHostsAsksAgain() {
        let custom = ProviderConfiguration(kind: .customOpenAICompatible, baseURL: URL(string: "https://llm.example.com"))
        let old = Settings(defaultProvider: custom, allowedCloudProviders: [.customOpenAICompatible])
        #expect(old.providerNeedingConsent(modes: []) == .customOpenAICompatible)
        // No URL yet: nothing can be sent, so allowing the provider is enough.
        var empty = Settings(defaultProvider: ProviderConfiguration(kind: .customOpenAICompatible))
        empty.allowCloud(.customOpenAICompatible)
        #expect(empty.providerNeedingConsent(modes: []) == nil)
    }

    @Test func revokingMovesChoicesOnDevice() {
        var settings = Settings(defaultEngine: openAIEngine, defaultProvider: ProviderConfiguration(kind: .openAI))
        settings.allowCloud(.openAI)
        settings.revokeCloud(.openAI)
        #expect(!settings.allowsCloud(.openAI))
        #expect(settings.defaultEngine == .appleSpeech)
        #expect(settings.defaultProvider == .appleIntelligence)

        var mode = Mode.email
        mode.providerOverride = groq
        mode.engineOverride = openAIEngine
        #expect(mode.removingCloud(.anthropic) == nil)
        let moved = mode.removingCloud(.groq)
        #expect(moved?.providerOverride == .appleIntelligence)
        #expect(moved?.engineOverride == openAIEngine)
    }

    @Test func settingsSavedBeforeConsentStillDecode() throws {
        var old = Settings(defaultEngine: openAIEngine)
        old.allowedCloudProviders = nil
        var json = try #require(String(data: JSONEncoder().encode(old), encoding: .utf8))
        json = json.replacingOccurrences(of: ",\"allowedCloudProviders\":null", with: "")
        #expect(!json.contains("allowedCloudProviders"))
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(decoded.defaultEngine == openAIEngine)
        #expect(decoded.providerNeedingConsent(modes: []) == .openAI)
    }

    @Test func pipelineSendsNothingWithoutConsent() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let history = try HistoryStore(directory: directory.url)
        var settings = Settings(defaultEngine: openAIEngine)
        let pipeline = DictationPipeline(
            recorder: StubRecorder(),
            engines: StubEngines(engine: StubEngine(text: "hello world")),
            formatters: StubFormatters(formatter: StubFormatter()),
            history: history,
            settings: { settings }
        )
        try await pipeline.startRecording(mode: .dictation)
        await #expect(throws: DictationError.cloudConsentRequired(.openAI)) { try await pipeline.stopAndProcess() }
        #expect(try await history.all().isEmpty)

        // Formatting without consent keeps the transcript on device.
        settings = Settings(defaultProvider: groq)
        try await pipeline.startRecording(mode: .cleanUp)
        let result = try await pipeline.stopAndProcess()
        #expect(result.text == "hello world")
        #expect(result.formattingError == .cloudConsentRequired(.groq))
        await #expect(throws: DictationError.cloudConsentRequired(.groq)) {
            try await pipeline.reformat("raw", mode: .notes)
        }

        settings.allowCloud(.groq)
        #expect(try await pipeline.reformat("raw", mode: .notes) == "FORMATTED: raw")
    }
}
