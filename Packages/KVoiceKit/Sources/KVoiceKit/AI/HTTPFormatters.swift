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

// MARK: - Google Gemini

/// Gemini `POST {base}/models/{model}:generateContent`. The key goes in the
/// `x-goog-api-key` header, never in the URL.
public struct GeminiFormatter: TextFormatter {
    public let configuration: ProviderConfiguration
    let apiKey: String
    let transport: any HTTPTransport

    public init(configuration: ProviderConfiguration, apiKey: String, transport: any HTTPTransport) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    struct Part: Codable { let text: String? }
    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    struct Body: Encodable {
        let system_instruction: Content
        let contents: [Content]
    }

    struct Response: Decodable {
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
    }

    public func makeRequest(for request: FormatRequest) throws -> URLRequest {
        guard let base = configuration.resolvedBaseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else {
            throw ProviderError.invalidBaseURL
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let model = configuration.model.hasPrefix("models/")
            ? String(configuration.model.dropFirst("models/".count))
            : configuration.model
        components.path = path + "/models/" + model + ":generateContent"
        components.query = nil
        guard let url = components.url else { throw ProviderError.invalidBaseURL }

        let prompt = PromptComposer.compose(request)
        var urlRequest = try HTTP.jsonRequest(url: url, body: Body(
            system_instruction: Content(role: nil, parts: [Part(text: prompt.system)]),
            contents: [Content(role: "user", parts: [Part(text: prompt.user)])]
        ))
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return urlRequest
    }

    public static func parse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        guard let candidate = response.candidates?.first else {
            // No candidates means the prompt itself was blocked.
            throw ProviderError.refused
        }
        let joined = (candidate.content?.parts ?? []).compactMap(\.text).joined()
        let text = PromptComposer.cleanedOutput(joined)
        guard !text.isEmpty else {
            if candidate.finishReason == "SAFETY" { throw ProviderError.refused }
            throw ProviderError.emptyResponse
        }
        return text
    }

    public func format(_ request: FormatRequest) async throws -> String {
        try Self.parse(try await HTTP.send(makeRequest(for: request), with: transport))
    }
}
