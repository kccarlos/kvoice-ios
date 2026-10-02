import Foundation

/// The Gemini `generateContent` protocol shared by Google AI Studio and
/// Vertex AI, for formatting and transcription. The key always goes in the
/// `x-goog-api-key` header, never in the URL.
enum GeminiAPI {
    /// `{base}/models/{model}:generateContent` (AI Studio) or
    /// `{base}/publishers/google/models/{model}:generateContent` (Vertex AI,
    /// where the base is the express-mode root or a project and location
    /// path). The model is percent-encoded as one path segment.
    static func endpoint(kind: ProviderKind, base: URL?, model: String) throws -> URL {
        guard let base,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw ProviderError.invalidBaseURL
        }
        switch scheme {
        case "https": break
        case "http" where HTTP.isLoopback(host): break
        case "http": throw ProviderError.insecureBaseURL
        default: throw ProviderError.invalidBaseURL
        }
        let modelID = modelIdentifier(model)
        guard !modelID.isEmpty else { throw ProviderError.missingModel }
        guard let encodedModel = modelID.addingPercentEncoding(withAllowedCharacters: modelAllowed) else {
            throw ProviderError.missingModel
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let collection = kind == .vertexAI ? "/publishers/google/models/" : "/models/"
        components.percentEncodedPath = path + collection + encodedModel + ":generateContent"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ProviderError.invalidBaseURL }
        return url
    }

    /// Unreserved characters only, so `/`, `:`, `?` and `#` in a model name
    /// cannot change the request path.
    static let modelAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The bare model ID: accepts `models/x` and, for Vertex AI,
    /// `publishers/google/models/x` as typed from Google's docs.
    static func modelIdentifier(_ model: String) -> String {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["publishers/google/models/", "models/"] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        return id
    }

    // MARK: Wire types

    struct InlineData: Codable, Equatable {
        let mime_type: String
        /// Base64.
        let data: String
    }

    struct Part: Codable {
        var text: String?
        var inline_data: InlineData?
        /// Set on thought summaries, which are not output.
        var thought: Bool?

        init(text: String) { self.text = text }
        init(inlineData: InlineData) { self.inline_data = inlineData }
    }

    struct Content: Codable {
        let role: String?
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
    }

    struct Body: Encodable {
        let system_instruction: Content?
        let contents: [Content]
        let generation_config: GenerationConfig
    }

    struct Response: Decodable {
        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }
        struct PromptFeedback: Decodable {
            let blockReason: String?
        }
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
    }

    /// Finish reasons that mean the output was withheld by a filter.
    static let blockedFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"
    ]

    static func request(
        kind: ProviderKind,
        base: URL?,
        model: String,
        apiKey: String,
        body: Body
    ) throws -> URLRequest {
        let url = try endpoint(kind: kind, base: base, model: model)
        var request = try HTTP.jsonRequest(url: url, body: body)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    /// The text of the first candidate (thoughts skipped), untrimmed.
    /// Throws `.refused` when the prompt or the output was blocked, and
    /// `.malformedResponse` for an unreadable body.
    static func text(from data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        if response.promptFeedback?.blockReason != nil { throw ProviderError.refused }
        guard let candidate = response.candidates?.first else {
            // No candidates means the prompt itself was blocked.
            throw ProviderError.refused
        }
        let text = (candidate.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let reason = candidate.finishReason, blockedFinishReasons.contains(reason) {
            throw ProviderError.refused
        }
        return text
    }

    /// Sends a request, mapping Google's failure shapes: an invalid key is a
    /// 400 `API_KEY_INVALID` rather than a 401.
    static func send(_ request: URLRequest, with transport: any HTTPTransport) async throws -> Data {
        do {
            return try await HTTP.send(request, with: transport)
        } catch ProviderError.http(let status, let message) where status == 400 && isInvalidKey(message) {
            throw ProviderError.unauthorized
        }
    }

    static func isInvalidKey(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return message.contains("api key not valid") || message.contains("api_key_invalid")
            || message.contains("api key expired")
    }
}
