import Foundation
// The only file in KVoiceKit that imports WhisperKit. No WhisperKit type
// leaves this file.
import WhisperKit

// MARK: - Model management

/// Downloads, lists and deletes Whisper models. Models live in Application
/// Support (excluded from backup): only the app transcribes, so the App
/// Group container would gain nothing and back up gigabytes.
public actor WhisperModelManager {
    public nonisolated let directory: URL
    private var manifest: WhisperModelManifest
    private var activeDownloads: [String: Task<URL, any Error>] = [:]

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "WhisperModels", directoryHint: .isDirectory)
    }

    public init(directory: URL? = nil) {
        let directory = directory ?? Self.defaultDirectory
        self.directory = directory
        self.manifest = WhisperModelManifest.load(from: directory)
    }

    /// Identifiers of models whose folders are present on disk.
    public func installedModelIDs() -> Set<String> {
        Set(manifest.installed.keys.filter { folder(forModelID: $0) != nil })
    }

    public func isInstalled(_ model: WhisperModel) -> Bool {
        folder(for: model) != nil
    }

    public func isDownloading(_ model: WhisperModel) -> Bool {
        activeDownloads[model.id] != nil
    }

    /// The model's folder, if downloaded.
    public func folder(for model: WhisperModel) -> URL? {
        folder(forModelID: model.id)
    }

    private func folder(forModelID id: String) -> URL? {
        guard let relative = manifest.installed[id] else { return nil }
        let url = directory.appending(path: relative, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads a model (or joins a download already in progress).
    /// `progress` receives 0...1 on an arbitrary thread.
    @discardableResult
    public func download(
        _ model: WhisperModel,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let folder = folder(for: model) {
            progress?(1)
            return folder
        }
        if let running = activeDownloads[model.id] {
            return try await running.value
        }
        let directory = self.directory
        let task = Task<URL, any Error> {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try? excluded.setResourceValues(values)
            return try await WhisperKit.download(
                variant: model.variant,
                downloadBase: directory,
                progressCallback: { value in progress?(value.fractionCompleted) }
            )
        }
        activeDownloads[model.id] = task
        defer { activeDownloads[model.id] = nil }
        let folder = try await task.value
        manifest.installed[model.id] = Self.relativePath(of: folder, in: directory)
        try manifest.save(to: directory)
        progress?(1)
        return folder
    }

    public func cancelDownload(_ model: WhisperModel) {
        activeDownloads[model.id]?.cancel()
    }

    public func delete(_ model: WhisperModel) throws {
        if let folder = folder(for: model) {
            try FileManager.default.removeItem(at: folder)
        }
        manifest.installed[model.id] = nil
        try manifest.save(to: directory)
    }

    static func relativePath(of folder: URL, in directory: URL) -> String {
        let base = directory.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(base) else { return path }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Engine

/// On-device Whisper transcription. One model stays loaded for the process
/// lifetime and is replaced when a different model is requested.
public actor WhisperKitEngine {
    private let models: WhisperModelManager
    private var loaded: (id: String, box: WhisperKitBox)?

    public init(models: WhisperModelManager) {
        self.models = models
    }

    /// A `TranscriptionEngine` bound to one model.
    public nonisolated func using(_ model: WhisperModel) -> WhisperModelEngine {
        WhisperModelEngine(engine: self, model: model)
    }

    /// Loads (and warms) a model ahead of the first dictation.
    public func prepare(_ model: WhisperModel) async throws {
        _ = try await whisperKit(for: model)
    }

    public func unload() async {
        if let loaded { await loaded.box.kit.unloadModels() }
        loaded = nil
    }

    private func whisperKit(for model: WhisperModel) async throws -> WhisperKitBox {
        if let loaded, loaded.id == model.id { return loaded.box }
        guard let folder = await models.folder(for: model) else {
            throw TranscriptionError.modelNotInstalled(model.name)
        }
        await unload()
        let config = WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        do {
            let box = WhisperKitBox(kit: try await WhisperKit(config))
            loaded = (model.id, box)
            return box
        } catch {
            throw TranscriptionError.engineUnavailable("The \(model.name) model could not be loaded. Try downloading it again.")
        }
    }

    func transcribe(_ request: TranscriptionRequest, model: WhisperModel) async throws -> TranscriptionResult {
        let samples = try AudioFile.readSamples(from: request.audioURL)
        let input = try WhisperInput.prepare(samples)
        let box = try await whisperKit(for: model)
        let language = request.languageCode
        let options = DecodingOptions(
            verbose: false,
            task: request.translateToEnglish ? .translate : .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false
        )
        let text: String
        let detected: String?
        do {
            let results = try await box.kit.transcribe(
                audioArray: input.samples,
                decodeOptions: options,
                callback: { _ in Task.isCancelled ? false : nil }
            )
            try Task.checkCancellation()
            text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            detected = results.first?.language
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }
        guard !text.isEmpty, !SpeechGate.isLikelyHallucination(text, peakDBFS: input.peakDBFS) else {
            throw TranscriptionError.noSpeech
        }
        return TranscriptionResult(
            text: text,
            isTranslatedToEnglish: request.translateToEnglish,
            detectedLanguage: detected
        )
    }
}

/// `WhisperKitEngine` bound to one model.
public struct WhisperModelEngine: TranscriptionEngine {
    let engine: WhisperKitEngine
    public let model: WhisperModel

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try await engine.transcribe(request, model: model)
    }
}

/// WhisperKit is not `Sendable`; it is only ever used from inside the
/// `WhisperKitEngine` actor, one call at a time.
private final class WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
}
