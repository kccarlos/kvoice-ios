import Foundation

/// Keeps silence away from Whisper and rejects its stock silence phrases.
///
/// Whisper emits "Thank you.", "Thanks for watching." and similar phrases
/// when handed empty or near-empty audio. Speech peaks sit around
/// -20…-6 dBFS; a quiet room's noise floor peaks well below -45 dBFS. The
/// phrase list is only consulted when the recording was quiet, so a user who
/// really says "thank you" into the microphone is never dropped.
public enum SpeechGate {
    /// At or below this peak the recording is treated as silence.
    public static let silencePeakDBFS: Float = -45
    /// At or below this peak a known hallucination phrase is discarded.
    public static let quietPeakDBFS: Float = -28
    /// Reported for audio with no energy at all.
    public static let silenceFloorDBFS: Float = -160
    /// Silence kept after the last audible frame when trimming the tail.
    public static let trailingSilenceKeepSeconds: Double = 0.4
    /// Recordings shorter than this are never trimmed.
    public static let trailingSilenceMinimumSeconds: Double = 1.0
    static let frameSeconds: Double = 0.05

    static let hallucinationPhrases: [String] = [
        "thank you", "thanks", "thank you for watching", "thanks for watching",
        "thank you very much", "thank you so much", "you", "bye", "goodbye",
        "subtitles by", "subtitled by", "amara.org", "please subscribe",
        "like and subscribe", "see you next time", "see you in the next video",
        "the end", "music", "silence", "applause", "字幕", "謝謝", "谢谢",
        "谢谢观看", "謝謝觀看", "請訂閱", "请订阅", "ご視聴ありがとうございました"
    ]

    /// Peak level of samples in dBFS (0 dBFS = full scale). Non-finite
    /// samples are ignored.
    public static func peakLevelDBFS(of samples: some Sequence<Float>) -> Float {
        var peak: Float = 0
        for sample in samples where sample.isFinite {
            peak = max(peak, abs(sample))
        }
        guard peak > 0 else { return silenceFloorDBFS }
        return max(silenceFloorDBFS, 20 * log10(peak))
    }

    /// True when the peak never rises above the silence threshold.
    public static func isSilent(peakDBFS: Float) -> Bool {
        peakDBFS <= silencePeakDBFS
    }

    public static func isSilent(_ samples: some Sequence<Float>) -> Bool {
        isSilent(peakDBFS: peakLevelDBFS(of: samples))
    }

    /// True when `text` is one of Whisper's stock silence phrases and the
    /// audio was quiet enough that it is likely invented.
    public static func isLikelyHallucination(_ text: String, peakDBFS: Float) -> Bool {
        guard peakDBFS <= quietPeakDBFS else { return false }
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return hallucinationPhrases.contains { phrase in
            normalized == phrase || normalized.hasPrefix(phrase + ".") || normalized.hasPrefix(phrase + "!")
        }
    }

    /// Number of leading samples to keep so trailing near-silence is removed
    /// apart from `trailingSilenceKeepSeconds`. Returns `samples.count` when
    /// there is nothing to trim or the recording is too short.
    public static func trailingSilenceTrimmedCount(
        of samples: [Float],
        sampleRate: Double = 16_000
    ) -> Int {
        let count = samples.count
        let minimum = Int(trailingSilenceMinimumSeconds * sampleRate)
        guard count > minimum else { return count }
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        let threshold = pow(10, silencePeakDBFS / 20)

        var audibleEnd = 0
        var frameEnd = count
        scan: while frameEnd > 0 {
            let frameStart = max(0, frameEnd - frameLength)
            for index in frameStart..<frameEnd where samples[index].isFinite && abs(samples[index]) > threshold {
                audibleEnd = frameEnd
                break scan
            }
            frameEnd = frameStart
        }
        let keep = audibleEnd + Int(trailingSilenceKeepSeconds * sampleRate)
        return min(count, max(minimum, keep))
    }
}

/// WhisperKit 1.1.0 stops seeking `windowClipTime` (1 s) before the end of
/// a clip, so a clip of one second or less never reaches the encoder and
/// comes back empty. Short clips are zero-padded to 1.5 s instead of
/// changing `windowClipTime`, whose tail protection real clips need.
public enum ShortClipPadding {
    public static let sampleRate: Double = 16_000
    /// 24,000 samples (1.5 s at 16 kHz).
    public static let minimumSampleCount = Int(1.5 * sampleRate)

    public static func applied(to samples: [Float]) -> [Float] {
        guard samples.count < minimumSampleCount else { return samples }
        return samples + [Float](repeating: 0, count: minimumSampleCount - samples.count)
    }
}

/// What Whisper should be fed for a recording.
public enum WhisperInput {
    /// The model input for 16 kHz mono samples: trailing silence trimmed
    /// (keeping 0.4 s) and short clips padded to 1.5 s. Throws `.noSpeech`
    /// when the recording peaks at or below -45 dBFS.
    public static func prepare(_ samples: [Float]) throws -> (samples: [Float], peakDBFS: Float) {
        let peak = SpeechGate.peakLevelDBFS(of: samples)
        guard !SpeechGate.isSilent(peakDBFS: peak) else { throw TranscriptionError.noSpeech }
        let keep = SpeechGate.trailingSilenceTrimmedCount(of: samples)
        let trimmed = keep < samples.count ? Array(samples.prefix(keep)) : samples
        return (ShortClipPadding.applied(to: trimmed), peak)
    }
}
