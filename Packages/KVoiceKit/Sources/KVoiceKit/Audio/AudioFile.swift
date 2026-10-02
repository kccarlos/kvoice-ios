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

    /// Converts any audio file AVFoundation can read (the m4a/AAC that the
    /// Shortcuts Record Audio action produces, CAF, WAV…) to the 16 kHz mono
    /// 16-bit WAV the engines take. Streams through `AVAudioConverter` in
    /// chunks, so long recordings never sit in memory whole.
    public static func convertToProcessingWAV(from source: URL, to destination: URL) throws -> Recording {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
            throw TranscriptionError.unreadableAudio
        }
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination, settings: wavSettings,
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
        } catch {
            throw TranscriptionError.failed("The recording could not be saved: \(error.localizedDescription)")
        }

        let chunk: AVAudioFrameCount = 16_384
        let outputCapacity = AVAudioFrameCount((Double(chunk) * sampleRate / inputFormat.sampleRate).rounded(.up)) + 1_024
        let reader = ChunkReader(file: input, format: inputFormat, chunk: chunk)
        var peak: Float = 0
        var frames: AVAudioFramePosition = 0
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: outputCapacity) else {
                throw TranscriptionError.unreadableAudio
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                reader.next(inputStatus)
            }
            guard status != .error, error == nil, !reader.failed else { throw TranscriptionError.unreadableAudio }
            if buffer.frameLength > 0 {
                for sample in samples(of: buffer) where sample.isFinite {
                    peak = max(peak, abs(sample))
                }
                do {
                    try output.write(from: buffer)
                } catch {
                    throw TranscriptionError.failed("The recording could not be saved: \(error.localizedDescription)")
                }
                frames += AVAudioFramePosition(buffer.frameLength)
            }
            if status == .endOfStream || (status == .inputRanDry && reader.finished) { break }
        }
        let peakDB = peak > 0 ? max(SpeechGate.silenceFloorDBFS, 20 * log10(peak)) : SpeechGate.silenceFloorDBFS
        return Recording(url: destination, duration: Double(frames) / sampleRate, peakDBFS: peakDB)
    }

    /// Feeds file chunks to an `AVAudioConverter` input block.
    private final class ChunkReader: @unchecked Sendable {
        let file: AVAudioFile
        let format: AVAudioFormat
        let chunk: AVAudioFrameCount
        private(set) var finished = false
        private(set) var failed = false

        init(file: AVAudioFile, format: AVAudioFormat, chunk: AVAudioFrameCount) {
            self.file = file
            self.format = format
            self.chunk = chunk
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !finished, file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                failed = true
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            guard buffer.frameLength > 0 else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
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
