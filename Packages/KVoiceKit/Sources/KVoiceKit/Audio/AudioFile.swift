import AVFoundation
import Foundation

/// Reading and writing the 16 kHz mono audio KVoice works with.
public enum AudioFile {
    public static let sampleRate: Double = 16_000

    /// The processing format: 16 kHz mono Float32, non-interleaved.
    public static var processingFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// WAV file settings: 16 kHz mono 16-bit PCM (accepted by every
    /// transcription endpoint and small enough to keep in history).
    public static var wavSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    /// All samples of an audio file as 16 kHz mono Float32, converting
    /// sample rate and channel count when needed.
    public static func readSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw TranscriptionError.unreadableAudio
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        if sourceFormat.sampleRate == sampleRate, sourceFormat.channelCount == 1 {
            return samples(of: buffer)
        }
        return try samples(of: convert(buffer, to: processingFormat))
    }

    /// Writes samples as a 16 kHz mono 16-bit WAV file.
    public static func writeWAV(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: wavSettings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(max(samples.count, 1))
        ), let channel = buffer.floatChannelData else {
            throw TranscriptionError.unreadableAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel[0].update(from: base, count: samples.count) }
        }
        try file.write(from: buffer)
    }

    /// Duration of an audio file in seconds.
    public static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// Converts a whole buffer to `format` (one-shot, flushes the converter).
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriptionError.unreadableAudio
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriptionError.unreadableAudio
        }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { throw TranscriptionError.unreadableAudio }
        return output
    }
}
