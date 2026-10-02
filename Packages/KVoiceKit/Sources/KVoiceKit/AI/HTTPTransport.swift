import Foundation

/// The network seam: production uses `URLSessionTransport`, tests a stub.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 180
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse
        }
        return (data, http)
    }
}

/// Errors from an AI provider or a cloud transcription endpoint.
public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case missingAPIKey(ProviderKind)
    case invalidBaseURL
    case insecureBaseURL
    case missingModel
    case unauthorized
    case rateLimited
    case http(status: Int, message: String?)
    case malformedResponse
    case emptyResponse
    case offline
    case unavailable(String)
    case refused

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "Add your \(provider.displayName) API key in Settings."
        case .invalidBaseURL:
            "The endpoint URL is not valid."
        case .insecureBaseURL:
            "The endpoint must use HTTPS."
        case .missingModel:
            "Choose a model for this provider in Settings."
        case .unauthorized:
            "The provider rejected the API key."
        case .rateLimited:
            "The provider is rate limiting requests. Try again shortly."
        case .http(let status, let message):
            "The provider returned an error (\(status))" + (message.map { ": \($0)" } ?? ".")
        case .malformedResponse:
            "The provider sent a response KVoice could not read."
        case .emptyResponse:
            "The provider returned no text."
        case .offline:
            "No internet connection."
        case .unavailable(let reason):
            reason
        case .refused:
            "The model declined to format this text."
        }
    }
}

/// URL and response helpers shared by the HTTP providers.
enum HTTP {
    /// Resolves an API root (`https://host/v1`) or a full endpoint to the
    /// endpoint with `suffix`, never appending it twice. A bare host means
    /// the API root `/v1`. HTTPS is required except for loopback hosts.
    static func endpoint(base: URL?, suffix: String) throws -> URL {
        guard let base,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw ProviderError.invalidBaseURL
        }
        switch scheme {
        case "https": break
        case "http" where isLoopback(host): break
        case "http": throw ProviderError.insecureBaseURL
        default: throw ProviderError.invalidBaseURL
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/v1" }
        if !path.lowercased().hasSuffix(suffix.lowercased()) { path += suffix }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ProviderError.invalidBaseURL }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Sends a request and maps transport and HTTP failures.
    static func send(_ request: URLRequest, with transport: any HTTPTransport) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            throw ProviderError.offline
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw ProviderError.unauthorized
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.http(status: response.statusCode, message: errorMessage(in: data))
        }
    }

    /// The `error.message` most providers put in failure bodies.
    static func errorMessage(in data: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        guard let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message else {
            return nil
        }
        return String(message.prefix(300))
    }

    static func jsonRequest(url: URL, body: some Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }
}
