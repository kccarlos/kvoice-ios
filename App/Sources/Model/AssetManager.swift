import Foundation
import KVoiceKit
import Observation

/// Downloads of speech models (Whisper models and Apple's speech assets),
/// kept in the app model so progress survives navigation.
@MainActor
@Observable
final class AssetManager {
    private(set) var installedWhisperModels: Set<String> = []
    /// Model id → 0...1 while downloading.
    private(set) var whisperProgress: [String: Double] = [:]
    private(set) var speechAssetStatus: SpeechAssetStatus?
    /// 0...1 while Apple's speech model downloads.
    private(set) var speechAssetProgress: Double?
    var errorMessage: String?

    @ObservationIgnored private let whisper: WhisperModelManager
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]

    init(whisper: WhisperModelManager) {
        self.whisper = whisper
    }

    func refresh(language: String? = nil) async {
        installedWhisperModels = await whisper.installedModelIDs()
        speechAssetStatus = await AppleSpeechEngine.assetStatus(language: language)
    }

    func isDownloading(_ model: WhisperModel) -> Bool { whisperProgress[model.id] != nil }

    func download(_ model: WhisperModel) {
        guard downloads[model.id] == nil else { return }
        whisperProgress[model.id] = 0
        downloads[model.id] = Task {
            defer {
                whisperProgress[model.id] = nil
                downloads[model.id] = nil
            }
            do {
                try await whisper.download(model) { value in
                    Task { @MainActor in
                        guard self.whisperProgress[model.id] != nil else { return }
                        self.whisperProgress[model.id] = value
                    }
                }
                installedWhisperModels.insert(model.id)
            } catch is CancellationError {
            } catch {
                errorMessage = "The \(model.name) model could not be downloaded. \(error.localizedDescription)"
            }
        }
    }

    func cancelDownload(_ model: WhisperModel) {
        downloads[model.id]?.cancel()
        Task { await whisper.cancelDownload(model) }
    }

    func delete(_ model: WhisperModel) async {
        do {
            try await whisper.delete(model)
            installedWhisperModels.remove(model.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installSpeechAssets(language: String? = nil) async {
        guard speechAssetProgress == nil else { return }
        speechAssetProgress = 0
        defer { speechAssetProgress = nil }
        do {
            try await AppleSpeechEngine.installAssets(language: language) { value in
                Task { @MainActor in
                    guard self.speechAssetProgress != nil else { return }
                    self.speechAssetProgress = value
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        speechAssetStatus = await AppleSpeechEngine.assetStatus(language: language)
    }
}
