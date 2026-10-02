import Foundation
import Testing
@testable import KVoiceCore
@testable import KVoiceKit

@Suite struct OpenAICompatibleFormatterTests {
    let request = FormatRequest(transcript: "um send the report", mode: .cleanUp)

    @Test func buildsChatCompletionsRequest() async throws {
        let transport = StubTransport(json: #"{"choices":[{"message":{"role":"assistant","content":" Send the report. "}}]}"#)
        let formatter = OpenAICompatibleFormatter(
            configuration: ProviderConfiguration(kind: .openAI, model: "gpt-test"),
            apiKey: "sk-test", transport: transport
        )
        let text = try await formatter.format(request)
        #expect(text == "Send the report.")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(sent.jsonBody)
        #expect(body["model"] as? String == "gpt-test")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[0]["content"] == PromptComposer.compose(request).system)
        #expect(messages[1]["content"] == "<TRANSCRIPT>\num send the report\n</TRANSCRIPT>")
    }

    @Test(arguments: [
        ("https://api.groq.com/openai/v1", "https://api.groq.com/openai/v1/chat/completions"),
        ("https://example.com/v1/chat/completions", "https://example.com/v1/chat/completions"),
        ("https://example.com/", "https://example.com/v1/chat/completions"),
        ("http://localhost:11434", "http://localhost:11434/v1/chat/completions")
    ])
    func normalisesBaseURLs(base: String, expected: String) throws {
        let url = try HTTP.endpoint(base: URL(string: base), suffix: "/chat/completions")
        #expect(url.absoluteString == expected)
    }

    @Test func rejectsInsecureRemoteURL() {
        #expect(throws: ProviderError.insecureBaseURL) {
            try HTTP.endpoint(base: URL(string: "http://example.com/v1"), suffix: "/chat/completions")
        }
        #expect(throws: ProviderError.invalidBaseURL) {
            try HTTP.endpoint(base: nil, suffix: "/chat/completions")
        }
    }

    @Test func mapsHTTPErrors() async {
        let unauthorized = OpenAICompatibleFormatter(
            configuration: ProviderConfiguration(kind: .openRouter),
            apiKey: "bad", transport: StubTransport(status: 401, json: #"{"error":{"message":"bad key"}}"#)
        )
        await #expect(throws: ProviderError.unauthorized) { try await unauthorized.format(request) }

        let server = OpenAICompatibleFormatter(
            configuration: ProviderConfiguration(kind: .groq),
            apiKey: "k", transport: StubTransport(status: 500, json: #"{"error":{"message":"overloaded"}}"#)
        )
        await #expect(throws: ProviderError.http(status: 500, message: "overloaded")) { try await server.format(request) }
    }

    @Test func parsesEmptyAndMalformedResponses() {
        #expect(throws: ProviderError.emptyResponse) {
            try OpenAICompatibleFormatter.parse(Data(#"{"choices":[{"message":{"content":"  "}}]}"#.utf8))
        }
        #expect(throws: ProviderError.malformedResponse) {
            try OpenAICompatibleFormatter.parse(Data("<html>".utf8))
        }
    }

    @Test func openRouterGetsTitleHeader() throws {
        let formatter = OpenAICompatibleFormatter(
            configuration: ProviderConfiguration(kind: .openRouter), apiKey: "k",
            transport: StubTransport(json: "{}")
        )
        let sent = try formatter.makeRequest(for: request)
        #expect(sent.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "X-Title") == "KVoice")
    }
}

@Suite struct AnthropicFormatterTests {
    @Test func buildsMessagesRequest() async throws {
        let transport = StubTransport(json: """
        {"id":"msg_1","type":"message","role":"assistant","content":[
          {"type":"text","text":"Hello "},{"type":"text","text":"world."}
        ],"stop_reason":"end_turn"}
        """)
        let formatter = AnthropicFormatter(
            configuration: ProviderConfiguration(kind: .anthropic), apiKey: "ak-test", transport: transport
        )
        let request = FormatRequest(transcript: "hello world", mode: .message)
        #expect(try await formatter.format(request) == "Hello world.")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "ak-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(sent.jsonBody)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == AnthropicFormatter.maxTokens)
        #expect(body["system"] as? String == PromptComposer.compose(request).system)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": PromptComposer.compose(request).user]])
    }

    @Test func defaultModelIsSonnet() {
        #expect(ProviderKind.anthropic.defaultModel == "claude-sonnet-5-5")
    }

    @Test func ignoresNonTextBlocks() throws {
        let data = Data(#"{"content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"Done."}]}"#.utf8)
        #expect(try AnthropicFormatter.parse(data) == "Done.")
    }

    @Test func mapsRateLimit() async {
        let formatter = AnthropicFormatter(
            configuration: ProviderConfiguration(kind: .anthropic), apiKey: "k",
            transport: StubTransport(status: 429, json: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#)
        )
        await #expect(throws: ProviderError.rateLimited) {
            try await formatter.format(FormatRequest(transcript: "x", instructions: "y"))
        }
    }
}

@Suite struct GeminiFormatterTests {
    @Test func buildsGenerateContentRequestWithKeyInHeader() async throws {
        let transport = StubTransport(json: """
        {"candidates":[{"content":{"role":"model","parts":[{"text":"- Milk"},{"text":"\\n- Eggs"}]},"finishReason":"STOP"}]}
        """)
        let formatter = GeminiFormatter(
            configuration: ProviderConfiguration(kind: .gemini, model: "gemini-test"),
            apiKey: "g-key", transport: transport
        )
        let request = FormatRequest(transcript: "milk and eggs", mode: .notes)
        #expect(try await formatter.format(request) == "- Milk\n- Eggs")

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent")
        #expect(sent.url?.query == nil, "the key never goes in the URL")
        #expect(sent.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        let body = try #require(sent.jsonBody)
        let system = try #require(body["system_instruction"] as? [String: Any])
        let systemParts = try #require(system["parts"] as? [[String: String]])
        #expect(systemParts == [["text": PromptComposer.compose(request).system]])
        let contents = try #require(body["contents"] as? [[String: Any]])
        #expect(contents.first?["role"] as? String == "user")
        #expect((contents.first?["parts"] as? [[String: String]]) == [["text": PromptComposer.compose(request).user]])
    }

    @Test func blockedPromptIsRefused() {
        #expect(throws: ProviderError.refused) {
            try GeminiFormatter.parse(Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8))
        }
        #expect(throws: ProviderError.refused) {
            try GeminiFormatter.parse(Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8))
        }
    }
}

@Suite struct TextFormatterFactoryTests {
    @Test func requiresKeyForCloudProviders() throws {
        let factory = TextFormatterFactory(secrets: InMemorySecretStore(), transport: StubTransport(json: "{}"))
        #expect(throws: ProviderError.missingAPIKey(.anthropic)) {
            try factory.makeFormatter(for: ProviderConfiguration(kind: .anthropic))
        }
        #expect(try factory.makeFormatter(for: .appleIntelligence) is AppleIntelligenceFormatter)
    }

    @Test func picksClientByProvider() throws {
        let secrets = InMemorySecretStore([.anthropic: "a", .gemini: "g", .groq: "q", .customOpenAICompatible: "c"])
        let factory = TextFormatterFactory(secrets: secrets, transport: StubTransport(json: "{}"))
        #expect(try factory.makeFormatter(for: ProviderConfiguration(kind: .anthropic)) is AnthropicFormatter)
        #expect(try factory.makeFormatter(for: ProviderConfiguration(kind: .gemini)) is GeminiFormatter)
        #expect(try factory.makeFormatter(for: ProviderConfiguration(kind: .groq)) is OpenAICompatibleFormatter)
        #expect(throws: ProviderError.missingModel) {
            try factory.makeFormatter(for: ProviderConfiguration(kind: .customOpenAICompatible))
        }
    }

    @Test func inMemorySecretsRoundTrip() throws {
        let secrets = InMemorySecretStore()
        try secrets.setAPIKey("k1", for: .openAI)
        #expect(try secrets.apiKey(for: .openAI) == "k1")
        try secrets.setAPIKey(nil, for: .openAI)
        #expect(try secrets.apiKey(for: .openAI) == nil)
        #expect(KeychainStore().service(for: .groq).hasSuffix(".groq"))
    }
}
