import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

private let geminiReply = """
{"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"},{"text":" there."}]},"finishReason":"STOP"}]}
"""

@Suite struct GoogleProviderKindTests {
    @Test func kindsAndDefaults() {
        #expect(ProviderKind.gemini.rawValue == "gemini", "raw value is persisted")
        #expect(ProviderKind.gemini.displayName == "Google AI Studio (Gemini)")
        #expect(ProviderKind.vertexAI.displayName == "Google Vertex AI")
        for kind in [ProviderKind.gemini, .vertexAI] {
            #expect(kind.api == .geminiGenerateContent)
            #expect(kind.transcriptionAPI == .geminiGenerateContent)
            #expect(kind.supportsTranscription)
            #expect(kind.requiresAPIKey)
            #expect(kind.defaultModel == "gemini-2.5-flash")
            #expect(kind.defaultTranscriptionModel == "gemini-2.5-flash")
            #expect(CloudTranscriptionConfiguration(provider: kind).model == "gemini-2.5-flash")
        }
        #expect(ProviderKind.vertexAI.defaultBaseURL?.absoluteString == "https://aiplatform.googleapis.com/v1")
        #expect(ProviderKind.openAI.transcriptionAPI == .openAIAudioTranscriptions)
        #expect(ProviderKind.groq.transcriptionAPI == .openAIAudioTranscriptions)
        #expect(ProviderKind.customOpenAICompatible.transcriptionAPI == .openAIAudioTranscriptions)
        #expect(!ProviderKind.anthropic.supportsTranscription)
        #expect(!ProviderKind.openRouter.supportsTranscription)
        #expect(!ProviderKind.appleIntelligence.supportsTranscription)
        #expect(KeychainStore().service(for: .vertexAI).hasSuffix(".vertexAI"))
    }

    @Test func endpointsPerProvider() throws {
        #expect(try GeminiAPI.endpoint(kind: .gemini, base: ProviderKind.gemini.defaultBaseURL, model: "gemini-2.5-flash").absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(try GeminiAPI.endpoint(kind: .vertexAI, base: ProviderKind.vertexAI.defaultBaseURL, model: "gemini-2.5-flash").absoluteString
            == "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:generateContent")

        let project = URL(string: "https://us-central1-aiplatform.googleapis.com/v1/projects/demo-project/locations/us-central1/")
        #expect(try GeminiAPI.endpoint(kind: .vertexAI, base: project, model: "publishers/google/models/gemini-2.5-pro").absoluteString
            == "https://us-central1-aiplatform.googleapis.com/v1/projects/demo-project/locations/us-central1/publishers/google/models/gemini-2.5-pro:generateContent")
        #expect(try GeminiAPI.endpoint(kind: .gemini, base: ProviderKind.gemini.defaultBaseURL, model: " models/gemini-x ").path
            == "/v1beta/models/gemini-x:generateContent")
    }

    @Test func modelIsPercentEncodedAsOneSegment() throws {
        let url = try GeminiAPI.endpoint(kind: .vertexAI, base: ProviderKind.vertexAI.defaultBaseURL, model: "my model/x?y#z")
        #expect(url.absoluteString
            == "https://aiplatform.googleapis.com/v1/publishers/google/models/my%20model%2Fx%3Fy%23z:generateContent")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
    }

    @Test func rejectsBadBaseURLsAndModels() {
        #expect(throws: ProviderError.insecureBaseURL) {
            try GeminiAPI.endpoint(kind: .vertexAI, base: URL(string: "http://aiplatform.googleapis.com/v1"), model: "m")
        }
        #expect(throws: ProviderError.invalidBaseURL) {
            try GeminiAPI.endpoint(kind: .gemini, base: nil, model: "m")
        }
        #expect(throws: ProviderError.missingModel) {
            try GeminiAPI.endpoint(kind: .gemini, base: ProviderKind.gemini.defaultBaseURL, model: "  ")
        }
    }
}

@Suite struct GoogleFormatterTests {
    let request = FormatRequest(transcript: "um send the report", mode: .cleanUp)

    func formatter(_ kind: ProviderKind, _ transport: StubTransport, baseURL: URL? = nil) -> GeminiFormatter {
        GeminiFormatter(configuration: ProviderConfiguration(kind: kind, baseURL: baseURL), apiKey: "goog-key", transport: transport)
    }

    @Test(arguments: [ProviderKind.gemini, .vertexAI])
    func buildsSharedRequest(kind: ProviderKind) async throws {
        let transport = StubTransport(json: geminiReply)
        #expect(try await formatter(kind, transport).format(request) == "Hello there.")

        let sent = try #require(transport.requests.first)
        let expectedURL = kind == .vertexAI
            ? "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:generateContent"
            : "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        #expect(sent.url?.absoluteString == expectedURL)
        #expect(sent.url?.query == nil, "the key never goes in the URL")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "goog-key")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(sent.jsonBody)
        let prompt = PromptComposer.compose(request)
        let system = try #require(body["system_instruction"] as? [String: Any])
        #expect((system["parts"] as? [[String: String]]) == [["text": prompt.system]])
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents.first?["role"] as? String == "user")
        #expect((contents.first?["parts"] as? [[String: String]]) == [["text": prompt.user]])
        let config = try #require(body["generation_config"] as? [String: Any])
        #expect(config["temperature"] as? Double == GeminiFormatter.temperature)
        #expect(GeminiFormatter.temperature <= 0.3)
    }

    @Test func vertexProjectBaseURL() throws {
        let base = URL(string: "https://europe-west4-aiplatform.googleapis.com/v1/projects/p1/locations/europe-west4")
        let sent = try formatter(.vertexAI, StubTransport(json: "{}"), baseURL: base).makeRequest(for: request)
        #expect(sent.url?.absoluteString
            == "https://europe-west4-aiplatform.googleapis.com/v1/projects/p1/locations/europe-west4/publishers/google/models/gemini-2.5-flash:generateContent")
    }

    @Test func parsingSkipsThoughtsAndCleansEnvelope() throws {
        let data = Data("""
        {"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"<TRANSCRIPT>\\nDone.\\n</TRANSCRIPT>"}]}}]}
        """.utf8)
        #expect(try GeminiFormatter.parse(data) == "Done.")
    }

    @Test func emptyAndMalformedResponses() {
        #expect(throws: ProviderError.emptyResponse) {
            try GeminiFormatter.parse(Data(#"{"candidates":[{"content":{"parts":[{"text":"  "}]},"finishReason":"MAX_TOKENS"}]}"#.utf8))
        }
        #expect(throws: ProviderError.malformedResponse) {
            try GeminiFormatter.parse(Data("not json".utf8))
        }
        #expect(throws: ProviderError.refused) {
            try GeminiFormatter.parse(Data(#"{"candidates":[]}"#.utf8))
        }
        #expect(throws: ProviderError.refused) {
            try GeminiFormatter.parse(Data(#"{"candidates":[{"finishReason":"PROHIBITED_CONTENT"}]}"#.utf8))
        }
    }

    @Test(arguments: [
        (400, #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#, ProviderError.unauthorized),
        (401, #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#, .unauthorized),
        (403, #"{"error":{"code":403,"message":"Permission denied.","status":"PERMISSION_DENIED"}}"#, .unauthorized),
        (429, #"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}"#, .rateLimited),
        (404, #"{"error":{"code":404,"message":"models/nope is not found.","status":"NOT_FOUND"}}"#,
         .http(status: 404, message: "models/nope is not found.")),
        (400, #"{"error":{"code":400,"message":"Invalid JSON payload.","status":"INVALID_ARGUMENT"}}"#,
         .http(status: 400, message: "Invalid JSON payload."))
    ])
    func mapsErrors(status: Int, json: String, expected: ProviderError) async {
        for kind in [ProviderKind.gemini, .vertexAI] {
            await #expect(throws: expected) {
                try await formatter(kind, StubTransport(status: status, json: json)).format(request)
            }
        }
    }

    @Test func factoryRoutesBothGoogleProviders() throws {
        let secrets = InMemorySecretStore([.gemini: "g", .vertexAI: "v"])
        let factory = TextFormatterFactory(secrets: secrets, transport: StubTransport(json: "{}"))
        let vertex = try #require(try factory.makeFormatter(for: ProviderConfiguration(kind: .vertexAI)) as? GeminiFormatter)
        #expect(vertex.apiKey == "v")
        let studio = try #require(try factory.makeFormatter(for: ProviderConfiguration(kind: .gemini)) as? GeminiFormatter)
        #expect(studio.apiKey == "g")
        #expect(throws: ProviderError.missingAPIKey(.vertexAI)) {
            try TextFormatterFactory(secrets: InMemorySecretStore([.gemini: "g"]), transport: StubTransport(json: "{}"))
                .makeFormatter(for: ProviderConfiguration(kind: .vertexAI))
        }
    }
}

@Suite struct GeminiTranscriptionTests {
    func engine(_ kind: ProviderKind, _ transport: StubTransport, model: String? = nil, baseURL: URL? = nil) -> GeminiTranscriptionEngine {
        GeminiTranscriptionEngine(
            configuration: CloudTranscriptionConfiguration(provider: kind, baseURL: baseURL, model: model),
            apiKey: "goog-key",
            transport: transport
        )
    }

    func parts(of request: URLRequest) throws -> [[String: Any]] {
        let body = try #require(request.jsonBody)
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents.first?["role"] as? String == "user")
        return try #require(contents.first?["parts"] as? [[String: Any]])
    }

    @Test(arguments: [ProviderKind.gemini, .vertexAI])
    func buildsInlineAudioRequest(kind: ProviderKind) throws {
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xFF])
        let request = TranscriptionRequest(audioURL: URL(filePath: "/tmp/clip.wav"), language: "de-DE")
        let sent = try engine(kind, StubTransport(json: "{}")).makeRequest(for: request, audio: audio)

        let expectedURL = kind == .vertexAI
            ? "https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-flash:generateContent"
            : "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        #expect(sent.url?.absoluteString == expectedURL)
        #expect(sent.url?.query == nil)
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "goog-key")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let parts = try parts(of: sent)
        #expect(parts.count == 2)
        let inline = try #require(parts.first?["inline_data"] as? [String: String])
        #expect(inline["mime_type"] == "audio/wav")
        #expect(inline["data"] == audio.base64EncodedString())
        #expect(Data(base64Encoded: inline["data"] ?? "") == audio)
        let instruction = try #require(parts.last?["text"] as? String)
        #expect(instruction == GeminiTranscriptionEngine.instruction(for: request))
        #expect(instruction.contains("verbatim"))
        #expect(instruction.contains("Output only the transcript"))
        #expect(instruction.contains("The speaker's language is German"))
        #expect(instruction.contains("(de-DE)."))
        #expect(!instruction.contains("Translate"))

        let body = try #require(sent.jsonBody)
        #expect(body["system_instruction"] == nil)
        let config = try #require(body["generation_config"] as? [String: Any])
        #expect(config["temperature"] as? Double == 0)
    }

    @Test func instructionVariants() {
        let auto = GeminiTranscriptionEngine.instruction(for: TranscriptionRequest(audioURL: URL(filePath: "/a.wav")))
        #expect(auto.contains("verbatim"))
        #expect(!auto.contains("speaker's language"))
        #expect(auto.contains("no speech, output nothing"))

        let translate = GeminiTranscriptionEngine.instruction(
            for: TranscriptionRequest(audioURL: URL(filePath: "/a.wav"), language: "fr", translateToEnglish: true)
        )
        #expect(translate.contains("Translate the speech in this audio into English"))
        #expect(translate.contains("French (fr)"))
        #expect(!translate.contains("verbatim"))
    }

    @Test func customModelAndProjectURL() throws {
        let base = URL(string: "https://us-central1-aiplatform.googleapis.com/v1/projects/p/locations/us-central1")
        let sent = try engine(.vertexAI, StubTransport(json: "{}"), model: "gemini-2.5-flash-lite", baseURL: base)
            .makeRequest(for: TranscriptionRequest(audioURL: URL(filePath: "/a.wav")), audio: Data([1]))
        #expect(sent.url?.absoluteString
            == "https://us-central1-aiplatform.googleapis.com/v1/projects/p/locations/us-central1/publishers/google/models/gemini-2.5-flash-lite:generateContent")
    }

    @Test func rejectsOversizedAudio() throws {
        let max = GeminiTranscriptionEngine.maxAudioBytes
        // Base64 plus the JSON envelope must stay under Google's ~20 MB.
        #expect((max + 2) / 3 * 4 + 4096 < 20 * 1024 * 1024)
        #expect(GeminiTranscriptionEngine.maxAudioMinutes == 7)
        try GeminiTranscriptionEngine.checkSize(of: Data(count: max))
        #expect(throws: TranscriptionError.audioTooLong(maxMinutes: 7)) {
            try GeminiTranscriptionEngine.checkSize(of: Data(count: max + 1))
        }
        let transport = StubTransport(json: geminiReply)
        #expect(throws: TranscriptionError.audioTooLong(maxMinutes: 7)) {
            try engine(.gemini, transport).makeRequest(
                for: TranscriptionRequest(audioURL: URL(filePath: "/a.wav")), audio: Data(count: max + 1)
            )
        }
        #expect(transport.requests.isEmpty)
        #expect(TranscriptionError.audioTooLong(maxMinutes: 7).errorDescription?.contains("7 minutes") == true)
    }

    @Test func transcribesFile() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let url = directory.url.appending(path: "clip.wav")
        try AudioFile.writeWAV(Signal.tone(seconds: 0.5), to: url)
        let transport = StubTransport(json: """
        {"candidates":[{"content":{"parts":[{"text":"  Hello there. \\n"}]},"finishReason":"STOP"}]}
        """)
        let result = try await engine(.vertexAI, transport).transcribe(TranscriptionRequest(audioURL: url))
        #expect(result.text == "Hello there.")
        #expect(!result.isTranslatedToEnglish)

        let sent = try #require(transport.requests.first)
        let inline = try #require(try parts(of: sent).first?["inline_data"] as? [String: String])
        #expect(Data(base64Encoded: inline["data"] ?? "") == (try Data(contentsOf: url)))

        let translated = try await engine(.gemini, StubTransport(json: geminiReply))
            .transcribe(TranscriptionRequest(audioURL: url, language: "es", translateToEnglish: true))
        #expect(translated.text == "Hello there.")
        #expect(translated.isTranslatedToEnglish)
    }

    @Test func emptyTranscriptIsNoSpeech() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let url = directory.url.appending(path: "clip.wav")
        try AudioFile.writeWAV(Signal.tone(seconds: 0.2), to: url)
        await #expect(throws: TranscriptionError.noSpeech) {
            try await engine(.gemini, StubTransport(json: #"{"candidates":[{"content":{"parts":[{"text":" \n"}]},"finishReason":"STOP"}]}"#))
                .transcribe(TranscriptionRequest(audioURL: url))
        }
        await #expect(throws: TranscriptionError.noSpeech) {
            try await engine(.gemini, StubTransport(json: #"{"candidates":[{"finishReason":"STOP"}]}"#))
                .transcribe(TranscriptionRequest(audioURL: url))
        }
    }

    @Test func mapsFailures() async throws {
        let directory = try TempDirectory()
        defer { directory.cleanUp() }
        let url = directory.url.appending(path: "clip.wav")
        try AudioFile.writeWAV(Signal.tone(seconds: 0.2), to: url)
        let request = TranscriptionRequest(audioURL: url)

        await #expect(throws: ProviderError.unauthorized) {
            try await engine(.gemini, StubTransport(status: 400, json: #"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#))
                .transcribe(request)
        }
        await #expect(throws: ProviderError.rateLimited) {
            try await engine(.vertexAI, StubTransport(status: 429, json: #"{"error":{"message":"Quota exceeded."}}"#))
                .transcribe(request)
        }
        await #expect(throws: TranscriptionError.failed("Google blocked the response for this recording.")) {
            try await engine(.vertexAI, StubTransport(json: #"{"promptFeedback":{"blockReason":"SAFETY"}}"#))
                .transcribe(request)
        }
        await #expect(throws: TranscriptionError.unreadableAudio) {
            try await engine(.gemini, StubTransport(json: geminiReply))
                .transcribe(TranscriptionRequest(audioURL: directory.url.appending(path: "missing.wav")))
        }
    }

    @Test func factoryRoutesByProvider() throws {
        let factory = TranscriptionEngineFactory(
            secrets: InMemorySecretStore([.gemini: "g", .vertexAI: "v", .groq: "q"]),
            whisperModels: WhisperModelManager(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)),
            transport: StubTransport(json: "{}")
        )
        let studio = try #require(try factory.engine(for: .cloud(CloudTranscriptionConfiguration(provider: .gemini))) as? GeminiTranscriptionEngine)
        #expect(studio.apiKey == "g")
        let vertex = try #require(try factory.engine(for: .cloud(CloudTranscriptionConfiguration(provider: .vertexAI))) as? GeminiTranscriptionEngine)
        #expect(vertex.apiKey == "v")
        #expect(vertex.configuration.model == "gemini-2.5-flash")
        #expect(try factory.engine(for: .cloud(CloudTranscriptionConfiguration(provider: .groq))) is CloudTranscriptionEngine)
        #expect(throws: ProviderError.missingAPIKey(.openAI)) {
            try factory.engine(for: .cloud(CloudTranscriptionConfiguration(provider: .openAI)))
        }
        #expect(throws: TranscriptionError.self) {
            try factory.engine(for: .cloud(CloudTranscriptionConfiguration(provider: .anthropic)))
        }
    }
}

@Suite struct GoogleSettingsCompatibilityTests {
    /// Settings as written before Vertex AI existed.
    static let legacyJSON = """
    {
      "defaultEngine": {"kind": "cloud", "cloud": {"provider": "groq", "model": "whisper-large-v3-turbo"}},
      "defaultProvider": {"kind": "gemini", "model": "gemini-2.0-flash"},
      "providerConfigurations": [
        "gemini", {"kind": "gemini", "model": "gemini-2.0-flash"},
        "openAI", {"kind": "openAI", "baseURL": "https://api.openai.com/v1", "model": "gpt-4.1-mini"}
      ],
      "retention": {"period": "days30", "keepsAudio": true}
    }
    """

    @Test func decodesLegacySettings() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(Self.legacyJSON.utf8))
        #expect(settings.defaultProvider == ProviderConfiguration(kind: .gemini, model: "gemini-2.0-flash"))
        #expect(settings.defaultProvider.kind.displayName == "Google AI Studio (Gemini)")
        #expect(settings.defaultEngine == .cloud(CloudTranscriptionConfiguration(provider: .groq)))
        #expect(settings.configuration(for: .gemini).model == "gemini-2.0-flash")
        #expect(settings.configuration(for: .openAI).baseURL?.absoluteString == "https://api.openai.com/v1")
        #expect(settings.configuration(for: .vertexAI) == ProviderConfiguration(kind: .vertexAI))
        #expect(settings.retention.period == .days30)
    }

    @MainActor @Test func googleSettingsRoundTrip() throws {
        let defaults = TestDefaults()
        defer { defaults.cleanUp() }
        let base = URL(string: "https://us-central1-aiplatform.googleapis.com/v1/projects/p/locations/us-central1")
        let store = SettingsStore(defaults: defaults.defaults, postsNotifications: false)
        store.settings.defaultProvider = ProviderConfiguration(kind: .vertexAI, baseURL: base, model: "gemini-2.5-pro")
        store.settings.defaultEngine = .cloud(CloudTranscriptionConfiguration(provider: .vertexAI, baseURL: base))
        store.settings.providerConfigurations[.vertexAI] = store.settings.defaultProvider
        store.settings.providerConfigurations[.gemini] = ProviderConfiguration(kind: .gemini, model: "gemini-2.5-flash-lite")

        let reloaded = SettingsStore(defaults: defaults.defaults, postsNotifications: false)
        #expect(reloaded.settings == store.settings)
        #expect(reloaded.settings.defaultEngine.cloud?.provider == .vertexAI)
        #expect(reloaded.settings.defaultEngine.cloud?.model == "gemini-2.5-flash")
        #expect(reloaded.settings.configuration(for: .vertexAI).baseURL == base)
    }
}
