import AVFoundation
import Foundation
import KVoiceKit
import Observation
import UIKit
import WidgetKit

/// The app's state and services: stores, the dictation pipeline, the
/// keyboard handoff, and the actions the UI and App Intents call.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let modes: ModeStore
    let settings: SettingsStore
    let secrets: KeychainStore
    /// Nil if the history database could not be opened (dictation still works).
    let history: HistoryStore?
    let recorder: AudioRecorder
    let whisperModels: WhisperModelManager
    let assets: AssetManager
    let pipeline: DictationPipeline
    let engineFactory: TranscriptionEngineFactory
    @ObservationIgnored private(set) var handoff: HandoffCoordinator!

    var selectedTab: AppTab = AppPreferences.initialTab ?? .home
    /// The result shown on Home: the last dictation or re-run.
    var currentResult: DictationResult?
    /// Bumped whenever history changes so lists reload.
    private(set) var historyRevision = 0
    /// A transient message for the Home screen.
    var notice: String?

    /// Transcribe Audio jobs running in this process (not to be resumed).
    @ObservationIgnored var runningJobIDs: Set<UUID> = []
    @ObservationIgnored private var isResumingJobs = false

    @ObservationIgnored private var darwinObservers: [DarwinNotificationObserver] = []
    @ObservationIgnored private var systemObservers: [any NSObjectProtocol] = []

    private init() {
        let modes = ModeStore()
        let settings = SettingsStore()
        let secrets = KeychainStore.shared()
        let history = try? HistoryStore()
        let recorder = AudioRecorder()
        let whisperModels = WhisperModelManager()
        self.modes = modes
        self.settings = settings
        self.secrets = secrets
        self.history = history
        self.recorder = recorder
        self.whisperModels = whisperModels
        self.assets = AssetManager(whisper: whisperModels)
        let engineFactory = TranscriptionEngineFactory(secrets: secrets, whisperModels: whisperModels)
        self.engineFactory = engineFactory
        self.pipeline = DictationPipeline(
            recorder: recorder,
            engines: engineFactory,
            formatters: TextFormatterFactory(secrets: secrets),
            history: history,
            settings: { settings.settings }
        )
        self.handoff = HandoffCoordinator(model: self)
        pipeline.phaseHandler = { [weak self] phase in self?.phaseChanged(phase) }
        recorder.engineStoppedHandler = { [weak self] in
            self?.handleAudioLoss()
        }
        observeOtherProcess()
        observeAudioSession()
        handoff.appLaunched()
    }

    // MARK: Dictation (Home, intents, widgets)

    var isRecording: Bool { pipeline.phase == .recording }

    /// Starts recording in the app (record button, `DictateIntent`,
    /// `kvoice://dictate`). Shows a notice instead when the microphone is
    /// owned elsewhere (an Action Button recording) or a job is running.
    func startDictation(modeID: UUID? = nil, source: DictationActivity.Source = .app) async {
        guard !pipeline.isBusy else { return }
        if let modeID, modes.mode(id: modeID) != nil {
            try? modes.setActiveMode(id: modeID)
        }
        notice = await handoff.requestAppRecording(source: source, mode: modes.activeMode)
    }

    @discardableResult
    func stopDictation() async -> DictationResult? {
        guard pipeline.isRecording else { return nil }
        return await handoff.stopAppRecording()
    }

    /// Runs `work` with background execution time requested, so a job
    /// started in the foreground (or by an interruption) can finish.
    func withBackgroundTime<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let application = UIApplication.shared
        let identifier = application.beginBackgroundTask(withName: name)
        defer {
            if identifier != .invalid { application.endBackgroundTask(identifier) }
        }
        return try await work()
    }

    func cancelDictation() {
        pipeline.cancel()
    }

    /// Re-runs a result with another mode: reprocesses the saved audio when
    /// there is any (re-transcribes), otherwise reformats the transcript.
    /// Saves and returns a new history record.
    @discardableResult
    func rerun(_ record: HistoryRecord, with mode: Mode, preferAudio: Bool = true) async throws -> DictationResult {
        if preferAudio, let history, let audio = history.audioURL(for: record) {
            let copy = history.newRecordingURL()
            try FileManager.default.copyItem(at: audio, to: copy)
            let samples = (try? AudioFile.readSamples(from: copy)) ?? []
            let recording = Recording(
                url: copy, duration: record.duration,
                peakDBFS: SpeechGate.peakLevelDBFS(of: samples)
            )
            let result = try await pipeline.process(recording, mode: mode)
            currentResult = result
            return result
        }
        let formatted = try await pipeline.reformat(record.rawTranscript, mode: mode)
        let provider = settings.settings.provider(for: mode)
        let newRecord = HistoryRecord(
            duration: record.duration,
            modeID: mode.id,
            modeName: mode.name,
            engine: record.engine,
            provider: mode.usesAI ? Self.providerLabel(provider) : nil,
            rawTranscript: record.rawTranscript,
            formattedText: formatted
        )
        try? await history?.add(newRecord)
        historyRevision += 1
        let result = DictationResult(record: newRecord, formattingError: nil)
        currentResult = result
        if AppPreferences.autoCopy { UIPasteboard.general.string = formatted }
        return result
    }

    static func providerLabel(_ provider: ProviderConfiguration) -> String {
        provider.kind == .appleIntelligence ? provider.kind.displayName : "\(provider.kind.displayName) \(provider.model)"
    }

    func historyChanged() { historyRevision += 1 }

    /// The app became active: finish Action Button jobs the system stopped.
    func appBecameActive() {
        guard !isResumingJobs else { return }
        isResumingJobs = true
        Task {
            await resumePendingJobs()
            isResumingJobs = false
        }
    }

    func applyRetention() async {
        _ = try? await history?.applyRetention(settings.settings.retention)
        historyRevision += 1
    }

    private func phaseChanged(_ phase: DictationPhase) {
        if phase == .done, let result = pipeline.lastResult {
            currentResult = result
            historyRevision += 1
            if AppPreferences.autoCopy { UIPasteboard.general.string = result.text }
        }
        if phase == .recording { notice = nil }
        handoff.phaseChanged(phase, result: pipeline.lastResult)
    }

    // MARK: Cross-process and audio session events

    private func observeOtherProcess() {
        func observe(_ name: DarwinNotificationName, _ action: @escaping @MainActor @Sendable (AppModel) -> Void) {
            darwinObservers.append(DarwinNotifications.observe(name) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
            })
        }
        observe(.modesChanged) { model in
            model.modes.reload()
            KVoiceShortcuts.updateAppShortcutParameters()
            WidgetCenter.shared.reloadAllTimelines()
        }
        observe(.activeModeChanged) { model in
            model.modes.reload()
            WidgetCenter.shared.reloadAllTimelines()
        }
        observe(.settingsChanged) { $0.settings.reload() }
        observe(.handoffCommand) { $0.handoff.handleCommand() }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            MainActor.assumeIsolated {
                self?.handleAudioLoss()
            }
        })
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAudioLoss()
            }
        })
        systemObservers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handoff.appWillTerminate() }
        })
    }

    /// The microphone was taken away (a call, Siri, another app such as
    /// Shortcuts' Record Audio, a route change or a media reset): process
    /// what was recorded if it is at least 1 s long, otherwise cancel; end
    /// standby quietly.
    private func handleAudioLoss() {
        if pipeline.isRecording, !InterruptionSalvage.shouldProcess(recordedDuration: pipeline.recordedDuration) {
            notice = "Recording was interrupted."
        }
        handoff.audioInterrupted()
    }
}
