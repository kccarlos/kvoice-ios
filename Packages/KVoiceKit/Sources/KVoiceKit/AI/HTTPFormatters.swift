import Foundation

// MARK: - OpenAI-compatible chat completions

/// OpenAI, Groq, OpenRouter, or any OpenAI-compatible
/// `POST {base}/chat/completions` endpoint.
public struct OpenAICompatibleFormatter: TextFormatter {
    public let configuration: ProviderConfiguration
    let apiKey: String
    let transport: any HTTPTransport

    public init(configuration: ProviderConfiguration, apiKey: String, transport: any HTTPTransport) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    public func makeRequest(for request: FormatRequest) throws -> URLRequest {
        let url = try HTTP.endpoint(base: configuration.resolvedBaseURL, suffix: "/chat/completions")
        let prompt = PromptComposer.compose(request)
        var urlRequest = try HTTP.jsonRequest(url: url, body: Body(
            model: configuration.model,
            messages: [
                .init(role: "system", content: prompt.system),
                .init(role: "user", content: prompt.user)
            ],
            stream: false
        ))
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if configuration.kind == .openRouter {
            urlRequest.setValue("KVoice", forHTTPHeaderField: "X-Title")
        }
        return urlRequest
    }

    public static func parse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        let text = PromptComposer.cleanedOutput(response.choices.first?.message.content ?? "")
        guard !text.isEmpty else { throw ProviderError.emptyResponse }
        return text
    }

    public func format(_ request: FormatRequest) async throws -> String {
        try Self.parse(try await HTTP.send(makeRequest(for: request), with: transport))
    }
}

// MARK: - Anthropic Messages

/// Anthropic `POST {base}/messages`.
public struct AnthropicFormatter: TextFormatter {
    public static let apiVersion = "2023-06-01"
    public static let maxTokens = 4096

    public let configuration: ProviderConfiguration
    let apiKey: String
    let transport: any HTTPTransport

    public init(configuration: ProviderConfiguration, apiKey: String, transport: any HTTPTransport) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    public func makeRequest(for request: FormatRequest) throws -> URLRequest {
        let url = try HTTP.endpoint(base: configuration.resolvedBaseURL, suffix: "/messages")
        let prompt = PromptComposer.compose(request)
        var urlRequest = try HTTP.jsonRequest(url: url, body: Body(
            model: configuration.model,
            max_tokens: Self.maxTokens,
            system: prompt.system,
            messages: [.init(role: "user", content: prompt.user)]
        ))
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return urlRequest
    }

    public static func parse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        let joined = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        let text = PromptComposer.cleanedOutput(joined)
        guard !text.isEmpty else { throw ProviderError.emptyResponse }
        return text
    }

    public func format(_ request: FormatRequest) async throws -> String {
        try Self.parse(try await HTTP.send(makeRequest(for: request), with: transport))
    }
}

// MARK: - Google AI Studio and Vertex AI

/// Gemini `generateContent` on Google AI Studio or Vertex AI (see
/// `GeminiAPI` for the endpoints). The key goes in the `x-goog-api-key`
/// header, never in the URL.
public struct GeminiFormatter: TextFormatter {
    /// Low, so formatting stays close to what was said.
    public static let temperature = 0.2

    public let configuration: ProviderConfiguration
    let apiKey: String
    let transport: any HTTPTransport

    public init(configuration: ProviderConfiguration, apiKey: String, transport: any HTTPTransport) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    public func makeRequest(for request: FormatRequest) throws -> URLRequest {
        let prompt = PromptComposer.compose(request)
        return try GeminiAPI.request(
            kind: configuration.kind,
            base: configuration.resolvedBaseURL,
            model: configuration.model,
            apiKey: apiKey,
            body: GeminiAPI.Body(
                system_instruction: GeminiAPI.Content(role: nil, parts: [.init(text: prompt.system)]),
                contents: [GeminiAPI.Content(role: "user", parts: [.init(text: prompt.user)])],
                generation_config: GeminiAPI.GenerationConfig(temperature: Self.temperature)
            )
        )
    }

    public static func parse(_ data: Data) throws -> String {
        let text = PromptComposer.cleanedOutput(try GeminiAPI.text(from: data))
        guard !text.isEmpty else { throw ProviderError.emptyResponse }
        return text
    }

    public func format(_ request: FormatRequest) async throws -> String {
        try Self.parse(try await GeminiAPI.send(makeRequest(for: request), with: transport))
    }
}
