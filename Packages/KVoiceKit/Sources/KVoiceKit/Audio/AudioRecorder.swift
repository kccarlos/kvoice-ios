@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// A finished recording on disk.
public struct Recording: Sendable, Hashable {
    public var url: URL
    public var duration: TimeInterval
    /// Loudest sample in dBFS; drives the silence gate.
    public var peakDBFS: Float

    public init(url: URL, duration: TimeInterval, peakDBFS: Float) {
        self.url = url
        self.duration = duration
        self.peakDBFS = peakDBFS
    }
}

public enum RecordingError: Error, Equatable, Sendable, LocalizedError {
    case permissionDenied
    case alreadyRecording
    case notRecording
    case noInputDevice
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "KVoice needs microphone access. Turn it on in Settings."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "Nothing is being recorded."
        case .noInputDevice: "No microphone is available."
        case .failed(let reason): "Recording failed: \(reason)"
        }
    }
}

/// What the pipeline needs from a recorder (a stub in tests).
@MainActor
public protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    /// Called on the main actor with a 0...1 level about 10 times a second.
    var levelHandler: ((Float) -> Void)? { get set }
    func start(writingTo url: URL) async throws
    func stop() async throws -> Recording
    func cancel()
}

/// Records the microphone with AVAudioEngine into a 16 kHz mono 16-bit WAV
/// file, converting from the hardware format on the fly, and meters the
/// level for a waveform.
@MainActor
public final class AudioRecorder: AudioRecording {
    public private(set) var isRecording = false
    public var levelHandler: ((Float) -> Void)?
    /// Deactivate the audio session after stopping. Set to false to keep the
    /// app alive in the background between dictations.
    public var deactivatesSessionOnStop = true

    private var engine: AVAudioEngine?
    private var writer: TapWriter?
    private var url: URL?

    public init() {}

    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public static var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Configures and activates the shared audio session for recording.
    public static func activateSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        try session.setActive(true)
        #endif
    }

    public static func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    public func start(writingTo url: URL) async throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        guard await Self.requestPermission() else { throw RecordingError.permissionDenied }
        do {
            try Self.activateSession()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordingError.noInputDevice }
            let writer = try TapWriter(url: url, inputFormat: format) { [weak self] level in
                Task { @MainActor in self?.levelHandler?(level) }
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tapBlock(writer))
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.writer = writer
            self.url = url
            isRecording = true
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.failed(error.localizedDescription)
        }
    }

    /// Built outside the main actor so the audio thread never runs
    /// main-actor-isolated code.
    nonisolated private static func tapBlock(_ writer: TapWriter) -> AVAudioNodeTapBlock {
        { buffer, _ in writer.process(buffer) }
    }

    public func stop() async throws -> Recording {
        guard isRecording, let engine, let writer, let url else { throw RecordingError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let summary = writer.finish()
        tearDown()
        return Recording(url: url, duration: summary.duration, peakDBFS: summary.peakDBFS)
    }

    public func cancel() {
        guard isRecording else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        _ = writer?.finish()
        if let url { try? FileManager.default.removeItem(at: url) }
        tearDown()
    }

    private func tearDown() {
        engine = nil
        writer = nil
        url = nil
        isRecording = false
        if deactivatesSessionOnStop { Self.deactivateSession() }
    }
}

/// Converts and writes tap buffers on the audio thread.
final class TapWriter: @unchecked Sendable {
    struct Summary {
        var duration: TimeInterval
        var peakDBFS: Float
    }

    private struct State {
        var file: AVAudioFile?
        var framesWritten: AVAudioFramePosition = 0
        var peak: Float = 0
        var lastLevelReport: CFAbsoluteTime = 0
    }

    private let converter: AVAudioConverter
    private let outputFormat = AudioFile.processingFormat
    private let state: Mutex<State>
    private let onLevel: @Sendable (Float) -> Void

    init(url: URL, inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: AudioFile.processingFormat) else {
            throw RecordingError.failed("unsupported input format")
        }
        self.converter = converter
        self.onLevel = onLevel
        let file = try AVAudioFile(
            forWriting: url, settings: AudioFile.wavSettings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        self.state = Mutex(State(file: file))
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData else { return }

        let count = Int(output.frameLength)
        var peak: Float = 0
        var sumSquares: Float = 0
        for index in 0..<count {
            let sample = channel[0][index]
            guard sample.isFinite else { continue }
            peak = max(peak, abs(sample))
            sumSquares += sample * sample
        }
        let rms = (sumSquares / Float(count)).squareRoot()

        let shouldReport = state.withLock { state -> Bool in
            guard let file = state.file else { return false }
            try? file.write(from: output)
            state.framesWritten += AVAudioFramePosition(count)
            state.peak = max(state.peak, peak)
            let now = CFAbsoluteTimeGetCurrent()
            guard now - state.lastLevelReport >= 0.1 else { return false }
            state.lastLevelReport = now
            return true
        }
        if shouldReport { onLevel(Self.normalizedLevel(rms: rms)) }
    }

    /// Maps RMS to 0...1 on a -60…0 dBFS scale.
    static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }

    /// Closes the file and returns what was written.
    func finish() -> Summary {
        state.withLock { state in
            state.file = nil // AVAudioFile finalizes the header on release.
            let duration = Double(state.framesWritten) / AudioFile.sampleRate
            let peakDB = state.peak > 0 ? max(SpeechGate.silenceFloorDBFS, 20 * log10(state.peak)) : SpeechGate.silenceFloorDBFS
            return Summary(duration: duration, peakDBFS: peakDB)
        }
    }
}
