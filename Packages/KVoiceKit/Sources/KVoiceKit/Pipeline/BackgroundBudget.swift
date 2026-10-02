import Foundation

/// Decides how a Transcribe Audio job can finish inside the time iOS gives
/// an App Intent in the background (about 30 s).
///
/// The estimates are deliberately rough and conservative: a job that might
/// overrun is better moved to Apple Speech, or to the foreground, than
/// killed half-way.
public enum BackgroundBudget {
    /// The part of the ~30 s budget a job may plan to use.
    public static let seconds: TimeInterval = 25
    /// Whisper is not used in the background for audio longer than this.
    public static let longAudio: TimeInterval = 60
    /// Allowance for the AI formatting step.
    public static let formattingCost: TimeInterval = 6

    public enum Plan: Sendable, Hashable {
        /// Run with the mode's engine.
        case runSelected
        /// Use Apple Speech for this job.
        case useAppleSpeech
        /// Ask to continue in the foreground (the app opens and finishes).
        case continueInForeground
    }

    public struct Inputs: Sendable, Hashable {
        public var engine: TranscriptionEngineSelection.Kind
        public var audioDuration: TimeInterval
        /// The mode's Whisper model is loaded in this process.
        public var whisperModelLoaded: Bool
        /// Apple Speech assets are installed for the job's language.
        public var appleSpeechInstalled: Bool
        public var usesAI: Bool
        /// The app is in the foreground: no budget applies.
        public var isForeground: Bool

        public init(
            engine: TranscriptionEngineSelection.Kind,
            audioDuration: TimeInterval,
            whisperModelLoaded: Bool,
            appleSpeechInstalled: Bool,
            usesAI: Bool,
            isForeground: Bool
        ) {
            self.engine = engine
            self.audioDuration = audioDuration
            self.whisperModelLoaded = whisperModelLoaded
            self.appleSpeechInstalled = appleSpeechInstalled
            self.usesAI = usesAI
            self.isForeground = isForeground
        }
    }

    /// Estimated transcription seconds, or infinity when the engine cannot
    /// run in the background (Whisper not loaded, or long audio; Apple
    /// Speech without its assets would download them first).
    public static func transcriptionEstimate(_ inputs: Inputs, engine: TranscriptionEngineSelection.Kind) -> TimeInterval {
        let duration = max(0, inputs.audioDuration)
        switch engine {
        case .appleSpeech:
            return inputs.appleSpeechInstalled ? 1 + 0.1 * duration : .infinity
        case .whisper:
            guard inputs.whisperModelLoaded, duration <= longAudio else { return .infinity }
            return 1 + 0.3 * duration
        case .cloud:
            return 3 + 0.1 * duration
        }
    }

    public static func plan(_ inputs: Inputs) -> Plan {
        if inputs.isForeground { return .runSelected }
        let formatting = inputs.usesAI ? formattingCost : 0
        if transcriptionEstimate(inputs, engine: inputs.engine) + formatting <= seconds {
            return .runSelected
        }
        if inputs.engine != .appleSpeech,
           transcriptionEstimate(inputs, engine: .appleSpeech) + formatting <= seconds {
            return .useAppleSpeech
        }
        return .continueInForeground
    }
}
