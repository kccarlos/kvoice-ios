import Foundation
import KVoiceKit
import UIKit
import UserNotifications

/// A Transcribe Audio job could not deliver text.
enum AudioJobError: Error, LocalizedError, Equatable {
    case noSpeech
    case failed(String)
    /// Continuing in the foreground was declined; the audio is kept in
    /// History and finished the next time KVoice opens.
    case savedForLater

    var errorDescription: String? {
        switch self {
        case .noSpeech: "No speech detected."
        case .failed(let message): message
        case .savedForLater: "Saved in KVoice History. Open KVoice to finish it."
        }
    }
}

/// Where Transcribe Audio jobs run (the app process).
extension AppModel {
    /// Transcribes an audio file from the Shortcuts app (Record Audio).
    ///
    /// The audio is saved to History as a pending record first, converted
    /// to 16 kHz mono, then transcribed and formatted on the pipeline's
    /// serial job queue. Returns the text for the shortcut.
    ///
    /// - Parameters:
    ///   - data: The audio file's bytes (m4a/AAC or any readable format).
    ///   - fileExtension: The source extension, kept for the pending file.
    ///   - modeID: The intent's Mode parameter.
    ///   - language: Overrides the mode's language (BCP-47).
    ///   - isForeground: The intent already runs in the foreground.
    ///   - continueInForeground: Asks the system to bring KVoice to the
    ///     front (throws when declined).
    func transcribeShortcutAudio(
        data: Data,
        fileExtension: String,
        modeID: UUID?,
        language: String?,
        isForeground: Bool,
        continueInForeground: @MainActor () async throws -> Void
    ) async throws -> String {
        guard let history else { throw AudioJobError.failed("KVoice History is unavailable, so the audio could not be saved.") }
        // Provisional (no prompt), so the "dictation saved" notice can be
        // delivered even if the setup screen was never opened.
        JobNotifier.requestAuthorization()
        var jobID = UUID()
        var jobModeID = modeID
        for case let .runJob(id, mode, _) in handoff.send(.transcribeRequested(newJobID: jobID, modeID: modeID, now: .now)) {
            jobID = id
            jobModeID = mode
        }
        let mode = jobModeID.flatMap(modes.mode(id:)) ?? modes.activeMode

        // 1. Never lose audio: save it and a pending record before anything else.
        let ext = fileExtension.isEmpty ? "m4a" : fileExtension.lowercased()
        let original = history.recordingsDirectory.appending(path: "\(jobID.uuidString)-source.\(ext)")
        do {
            try data.write(to: original, options: AppGroup.fileWriteOptions)
        } catch {
            finishJob(jobID, failure: "The audio could not be saved.")
            throw AudioJobError.failed("The audio could not be saved: \(error.localizedDescription)")
        }
        let pending = HistoryRecord(
            id: jobID, duration: 0, modeID: mode.id, modeName: mode.name,
            engine: "", rawTranscript: "", formattedText: "",
            audioFileName: original.lastPathComponent, status: .pending
        )
        try? await history.upsert(pending)
        historyChanged()

        return try await runAudioJob(
            record: pending, mode: mode, language: language,
            isForeground: isForeground, continueInForeground: continueInForeground
        )
    }

    /// Finishes pending History records left by a job the system stopped.
    /// Runs when the app becomes active.
    func resumePendingJobs() async {
        guard let history, let records = try? await history.pending() else { return }
        for record in records where !runningJobIDs.contains(record.id) {
            handoff.send(.jobQueued(jobID: record.id, modeID: record.modeID, now: .now))
            let mode = record.modeID.flatMap(modes.mode(id:)) ?? modes.activeMode
            do {
                _ = try await runAudioJob(
                    record: record, mode: mode, language: nil,
                    isForeground: true, continueInForeground: {}
                )
                notice = nil
            } catch {
                // Kept in History as failed (or removed when silent).
            }
        }
    }

    // MARK: Job steps

    private func runAudioJob(
        record pending: HistoryRecord,
        mode baseMode: Mode,
        language: String?,
        isForeground: Bool,
        continueInForeground: @MainActor () async throws -> Void
    ) async throws -> String {
        let jobID = pending.id
        guard let history else { throw AudioJobError.failed("KVoice History is unavailable.") }
        runningJobIDs.insert(jobID)
        defer { runningJobIDs.remove(jobID) }
        var mode = baseMode
        if let language, !language.isEmpty { mode.language = language }
        var record = pending

        // 2. Convert to 16 kHz mono WAV (the source stays until it worked).
        guard let source = history.audioURL(for: record) else {
            await markFailed(&record, message: "The audio file is missing.")
            finishJob(jobID, failure: "The audio file is missing.")
            throw AudioJobError.failed("The audio file is missing.")
        }
        let recording: Recording
        if source.pathExtension.lowercased() == "wav" {
            let samples = (try? AudioFile.readSamples(from: source)) ?? []
            recording = Recording(
                url: source, duration: Double(samples.count) / AudioFile.sampleRate,
                peakDBFS: SpeechGate.peakLevelDBFS(of: samples)
            )
        } else {
            let wav = history.recordingsDirectory.appending(path: "\(jobID.uuidString).wav")
            do {
                recording = try AudioFile.convertToProcessingWAV(from: source, to: wav)
            } catch {
                try? FileManager.default.removeItem(at: wav)
                let message = "The recording could not be read."
                await markFailed(&record, message: message)
                finishJob(jobID, failure: message)
                throw AudioJobError.failed(message)
            }
            try? FileManager.default.removeItem(at: source)
            record.audioFileName = wav.lastPathComponent
        }
        record.duration = recording.duration
        try? await history.upsert(record)

        // 3. Silence: nothing to keep, nothing to copy.
        if recording.duration < 0.1 || SpeechGate.isSilent(peakDBFS: recording.peakDBFS) {
            try? await history.delete(id: jobID)
            historyChanged()
            finishJob(jobID, failure: AudioJobError.noSpeech.localizedDescription)
            throw AudioJobError.noSpeech
        }

        // 4. Background budget.
        let selection = settings.settings.engine(for: mode)
        var foreground = isForeground || UIApplication.shared.applicationState == .active
        var engineOverride: TranscriptionEngineSelection?
        if !foreground {
            let whisperLoaded = await engineFactory.isWhisperModelLoaded(selection)
            let speechInstalled = AppleSpeechEngine.isAvailable
                ? await AppleSpeechEngine.assetStatus(language: mode.language) == .installed
                : false
            let inputs = BackgroundBudget.Inputs(
                engine: selection.kind,
                audioDuration: recording.duration,
                whisperModelLoaded: whisperLoaded,
                appleSpeechInstalled: speechInstalled,
                usesAI: mode.usesAI,
                isForeground: false
            )
            switch BackgroundBudget.plan(inputs) {
            case .runSelected:
                break
            case .useAppleSpeech:
                engineOverride = .appleSpeech
            case .continueInForeground:
                do {
                    try await continueInForeground()
                    foreground = true
                } catch {
                    // Declined: the pending record is resumed on next launch.
                    finishJob(jobID, failure: AudioJobError.savedForLater.localizedDescription)
                    throw AudioJobError.savedForLater
                }
            }
        }

        // 5. Process on the serial queue; a notification covers a kill.
        if !foreground { JobNotifier.scheduleKilledNotice(jobID: jobID) }
        defer { JobNotifier.cancelKilledNotice(jobID: jobID) }
        let handoff: HandoffCoordinator = self.handoff
        let options = DictationPipeline.JobOptions(
            engineOverride: engineOverride,
            record: record,
            onStage: { stage in handoff.send(.jobStage(jobID: jobID, stage: stage, now: .now)) }
        )
        do {
            let result = try await withBackgroundTime("Transcribe audio") {
                try await pipeline.processJob(recording, mode: mode, options: options)
            }
            historyChanged()
            if UIApplication.shared.applicationState == .active {
                currentResult = result
                if AppPreferences.autoCopy { UIPasteboard.general.string = result.text }
            }
            // 6. Offer it to a visible keyboard, then settle the activity.
            handoff.deliver(text: result.text, jobID: jobID, source: .shortcut)
            finishJob(jobID, failure: nil)
            return result.text
        } catch DictationError.noSpeech {
            try? await history.delete(id: jobID)
            historyChanged()
            finishJob(jobID, failure: AudioJobError.noSpeech.localizedDescription)
            throw AudioJobError.noSpeech
        } catch DictationError.cancelled {
            // The system stopped us: the record stays pending for next launch.
            finishJob(jobID, failure: DictationError.cancelled.localizedDescription)
            throw AudioJobError.savedForLater
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await markFailed(&record, message: message)
            finishJob(jobID, failure: message)
            throw AudioJobError.failed(message)
        }
    }

    private func markFailed(_ record: inout HistoryRecord, message: String) async {
        record.status = .failed
        record.failureMessage = message
        try? await history?.upsert(record)
        historyChanged()
    }

    private func finishJob(_ jobID: UUID, failure: String?) {
        handoff.send(.jobFinished(jobID: jobID, failure: failure, standbyUntil: handoff.standbyUntil, now: .now))
    }
}

/// Local notifications for Action Button jobs.
enum JobNotifier {
    /// A background job that outlives this is assumed killed.
    static let killedNoticeDelay: TimeInterval = 40

    /// Quiet (provisional) delivery needs no prompt.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
    }

    static func scheduleKilledNotice(jobID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "Dictation saved"
        content.body = "KVoice didn't have time to finish it. Open KVoice and it will be transcribed; it's in History."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: killedNoticeDelay, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier(jobID), content: content, trigger: trigger)
        )
    }

    static func cancelKilledNotice(jobID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(jobID)])
    }

    private static func identifier(_ jobID: UUID) -> String { "job.\(jobID.uuidString)" }
}

#if DEBUG
extension AppModel {
    /// `-kvoiceTranscribeFile <path>`: runs the Action Button flow as the
    /// shortcut would (Begin Dictation, then Transcribe Audio on the file)
    /// and shows the outcome on Home. Simulator verification only.
    static var debugTranscribeFile: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-kvoiceTranscribeFile"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(filePath: arguments[index + 1])
    }

    func debugRunShortcut(file: URL) async {
        let gate = handoff.beginShortcut(modeID: nil)
        print("[KVoice debug] Begin Dictation → \(gate.rawValue)")
        guard gate == .record, let data = try? Data(contentsOf: file) else {
            notice = "Begin Dictation: \(gate.rawValue); file readable: \(FileManager.default.fileExists(atPath: file.path))"
            return
        }
        do {
            let text = try await transcribeShortcutAudio(
                data: data, fileExtension: file.pathExtension, modeID: Mode.BuiltInID.dictation,
                language: nil, isForeground: true, continueInForeground: {}
            )
            print("[KVoice debug] Transcribe Audio → \(text)")
            notice = "Transcribe Audio returned: \(text)"
        } catch {
            print("[KVoice debug] Transcribe Audio failed → \(error.localizedDescription)")
            notice = "Transcribe Audio failed: \(error.localizedDescription)"
        }
        print("[KVoice debug] activity → \(handoff.activity.phase)")
    }
}
#endif
