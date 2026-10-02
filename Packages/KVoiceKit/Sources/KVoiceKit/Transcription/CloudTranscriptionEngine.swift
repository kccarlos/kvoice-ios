import Foundation

/// OpenAI-compatible `POST {base}/audio/transcriptions` (OpenAI, Groq, or a
/// custom endpoint) with the user's own key.
public struct CloudTranscriptionEngine: TranscriptionEngine {
    public let configuration: CloudTranscriptionConfiguration
    let apiKey: String
    let transport: any HTTPTransport
    /// Injectable so tests can assert the exact body.
    let boundary: String

    public init(
        configuration: CloudTranscriptionConfiguration,
        apiKey: String,
        transport: any HTTPTransport,
        boundary: String = "KVoiceBoundary-\(UUID().uuidString)"
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
        self.boundary = boundary
    }

    /// Only Whisper models serve `/audio/translations`; for the others the
    /// AI step does the translating.
    var translatesNatively: Bool {
        configuration.model.lowercased().contains("whisper")
    }

    public func makeRequest(for request: TranscriptionRequest, audio: Data) throws -> URLRequest {
        let translate = request.translateToEnglish && translatesNatively
        let url = try HTTP.endpoint(
            base: configuration.resolvedBaseURL,
            suffix: translate ? "/audio/translations" : "/audio/transcriptions"
        )
        var form = MultipartForm(boundary: boundary)
        form.addField(name: "model", value: configuration.model)
        form.addField(name: "response_format", value: "json")
        if !translate, let language = request.languageCode {
            form.addField(name: "language", value: language)
        }
        let fileName = request.audioURL.lastPathComponent.isEmpty ? "audio.wav" : request.audioURL.lastPathComponent
        form.addFile(
            name: "file",
            fileName: fileName,
            contentType: Self.contentType(forExtension: request.audioURL.pathExtension),
            data: audio
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = form.finalized()
        return urlRequest
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "wav": "audio/wav"
        case "m4a", "mp4": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "ogg": "audio/ogg"
        case "webm": "audio/webm"
        default: "application/octet-stream"
        }
    }

    public static func parse(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let audio: Data
        do {
            audio = try Data(contentsOf: request.audioURL)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        let text = try Self.parse(try await HTTP.send(makeRequest(for: request, audio: audio), with: transport))
        guard !text.isEmpty else { throw TranscriptionError.noSpeech }
        return TranscriptionResult(
            text: text,
            isTranslatedToEnglish: request.translateToEnglish && translatesNatively
        )
    }
}

/// A `multipart/form-data` body.
struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
