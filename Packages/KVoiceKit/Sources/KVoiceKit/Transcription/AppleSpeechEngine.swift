import AVFoundation
import Foundation
// The only file in KVoiceKit that imports Speech. No Speech type leaves it.
import Speech

/// Installation state of Apple's on-device speech model for a language.
public enum SpeechAssetStatus: Sendable, Hashable {
    case unsupported
    case supported
    case downloading
    case installed
}

/// On-device transcription with Apple's SpeechAnalyzer / SpeechTranscriber.
///
/// SpeechTranscriber has no automatic language detection: with no language
/// hint the device's current locale is used.
public struct AppleSpeechEngine: TranscriptionEngine {
    public init() {}

    /// Whether this device can run SpeechTranscriber at all.
    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// BCP-47 identifiers SpeechTranscriber supports.
    public static func supportedLanguages() async -> [String] {
        await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    /// The supported locale matching a hint (or the current locale).
    static func resolvedLocale(for language: String?) async -> Locale? {
        let requested = language.map { Locale(identifier: $0) } ?? Locale.current
        return await SpeechTranscriber.supportedLocale(equivalentTo: requested)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    public static func assetStatus(language: String?) async -> SpeechAssetStatus {
        guard let locale = await resolvedLocale(for: language) else { return .unsupported }
        switch await AssetInventory.status(forModules: [makeTranscriber(locale: locale)]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    /// Downloads the speech model for a language if needed. `progress`
    /// receives 0...1.
    public static func installAssets(
        language: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard isAvailable else {
            throw TranscriptionError.engineUnavailable("On-device speech recognition is not available on this device.")
        }
        guard let locale = await resolvedLocale(for: language) else {
            throw TranscriptionError.unsupportedLanguage(language ?? Locale.current.identifier)
        }
        let transcriber = makeTranscriber(locale: locale)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                progress?(1)
                return
            }
            let monitor = Task {
                while !Task.isCancelled {
                    progress?(min(max(request.progress.fractionCompleted, 0), 1))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { monitor.cancel() }
            try await request.downloadAndInstall()
            progress?(1)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.engineUnavailable("The speech model could not be downloaded: \(error.localizedDescription)")
        }
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard Self.isAvailable else {
            throw TranscriptionError.engineUnavailable("On-device speech recognition is not available on this device.")
        }
        guard let locale = await Self.resolvedLocale(for: request.language) else {
            throw TranscriptionError.unsupportedLanguage(request.language ?? Locale.current.identifier)
        }
        // Installs on first use; a no-op when the model is already present.
        try await Self.installAssets(language: locale.identifier(.bcp47))

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: request.audioURL)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Collect before starting so no result is missed; the sequence ends
        // when the analyzer finishes after the file.
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.noSpeech }
            return TranscriptionResult(text: text, detectedLanguage: locale.identifier(.bcp47))
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch {
            collector.cancel()
            throw TranscriptionError.failed(error.localizedDescription)
        }
    }
}
