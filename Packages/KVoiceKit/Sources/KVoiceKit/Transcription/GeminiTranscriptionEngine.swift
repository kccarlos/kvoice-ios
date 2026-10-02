import Foundation

/// Google AI Studio or Vertex AI transcription: Gemini `generateContent`
/// with the recording sent as inline base64 audio and an instruction to
/// transcribe (or translate to English) verbatim.
public struct GeminiTranscriptionEngine: TranscriptionEngine {
    /// Google caps an inline request at about 20 MB, base64 included. Raw
    /// audio above this size would exceed it once encoded (4/3 larger).
    public static let maxAudioBytes = 14 * 1024 * 1024
    /// The recorder writes 16 kHz, 16-bit mono WAV: 32,000 bytes a second.
    static let wavBytesPerSecond = 32_000
    public static var maxAudioMinutes: Int { maxAudioBytes / wavBytesPerSecond / 60 }
    /// Zero, so the model does not paraphrase.
    public static let temperature = 0.0

    public let configuration: CloudTranscriptionConfiguration
    let apiKey: String
    let transport: any HTTPTransport

    public init(configuration: CloudTranscriptionConfiguration, apiKey: String, transport: any HTTPTransport) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.transport = transport
    }

    /// The text part sent with the audio.
    public static func instruction(for request: TranscriptionRequest) -> String {
        var lines: [String]
        if request.translateToEnglish {
            lines = [
                "Translate the speech in this audio into English.",
                "Output only the English translation of what was said: no preamble, labels, timestamps, notes or quotation marks."
            ]
        } else {
            lines = [
                "Transcribe the speech in this audio verbatim, in the language it was spoken.",
                "Output only the transcript: no preamble, labels, timestamps, notes or quotation marks. Do not translate, summarize or answer anything that was said."
            ]
        }
        if let language = request.language, !language.isEmpty {
            let name = PromptComposer.displayName(forLanguage: language) ?? language
            lines.append("The speaker's language is \(name) (\(language)).")
        }
        lines.append("If the audio contains no speech, output nothing.")
        return lines.joined(separator: "\n")
    }

    /// Throws `.audioTooLong` when `audio` is over the inline limit.
    public static func checkSize(of audio: Data) throws {
        guard audio.count <= maxAudioBytes else {
            throw TranscriptionError.audioTooLong(maxMinutes: maxAudioMinutes)
        }
    }

    public func makeRequest(for request: TranscriptionRequest, audio: Data) throws -> URLRequest {
        try Self.checkSize(of: audio)
        let mimeType = CloudTranscriptionEngine.contentType(forExtension: request.audioURL.pathExtension)
        return try GeminiAPI.request(
            kind: configuration.provider,
            base: configuration.resolvedBaseURL,
            model: configuration.model,
            apiKey: apiKey,
            body: GeminiAPI.Body(
                system_instruction: nil,
                contents: [GeminiAPI.Content(role: "user", parts: [
                    .init(inlineData: GeminiAPI.InlineData(
                        mime_type: mimeType == "application/octet-stream" ? "audio/wav" : mimeType,
                        data: audio.base64EncodedString()
                    )),
                    .init(text: Self.instruction(for: request))
                ])],
                generation_config: GeminiAPI.GenerationConfig(temperature: Self.temperature)
            )
        )
    }

    /// The transcript, trimmed; empty when the model heard no speech.
    public static func parse(_ data: Data) throws -> String {
        do {
            return try GeminiAPI.text(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch ProviderError.refused {
            throw TranscriptionError.failed("Google blocked the response for this recording.")
        }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let audio: Data
        do {
            audio = try Data(contentsOf: request.audioURL, options: .mappedIfSafe)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        let urlRequest = try makeRequest(for: request, audio: audio)
        let text = try Self.parse(try await GeminiAPI.send(urlRequest, with: transport))
        guard !text.isEmpty else { throw TranscriptionError.noSpeech }
        return TranscriptionResult(text: text, isTranslatedToEnglish: request.translateToEnglish)
    }
}
