import Foundation

/// A dictation mode: what happens to a transcript after speech recognition.
///
/// A `.plainDictation` mode inserts the transcript as spoken (no AI, works
/// offline). An `.aiFormat` mode sends the transcript to an AI provider with
/// the mode's `instructions`.
public struct Mode: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// The transcript as recognised, no AI step.
        case plainDictation
        /// The transcript reformatted by an AI provider.
        case aiFormat
    }

    public var id: UUID
    public var name: String
    /// An SF Symbol name.
    public var icon: String
    /// Instructions for the AI step; ignored for `.plainDictation`.
    public var instructions: String
    public var kind: Kind
    /// Spoken language: `nil` means automatic detection, otherwise a BCP-47
    /// tag such as "en-US" or "de".
    public var language: String?
    /// Ask for English output: the Whisper engine translates while it
    /// transcribes, and the AI step is told to write English.
    public var translateToEnglish: Bool
    /// Use this provider instead of the default one for the AI step.
    public var providerOverride: ProviderConfiguration?
    /// Use this engine instead of the default one for transcription.
    public var engineOverride: TranscriptionEngineSelection?
    /// True for the modes KVoice ships with. Built-ins can be edited but are
    /// restored by "reset", and their identifiers are stable.
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "text.bubble",
        instructions: String = "",
        kind: Kind = .aiFormat,
        language: String? = nil,
        translateToEnglish: Bool = false,
        providerOverride: ProviderConfiguration? = nil,
        engineOverride: TranscriptionEngineSelection? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.instructions = instructions
        self.kind = kind
        self.language = language
        self.translateToEnglish = translateToEnglish
        self.providerOverride = providerOverride
        self.engineOverride = engineOverride
        self.isBuiltIn = isBuiltIn
    }

    /// Whether the pipeline runs an AI step for this mode.
    public var usesAI: Bool { kind == .aiFormat }
}

// MARK: - Built-in modes

extension Mode {
    /// Stable identifiers so the keyboard and the app agree on built-ins
    /// across launches and resets.
    public enum BuiltInID {
        public static let dictation = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000001")!
        public static let cleanUp = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000002")!
        public static let message = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000003")!
        public static let email = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000004")!
        public static let notes = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000005")!
        public static let summary = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000006")!
        public static let translateToEnglish = UUID(uuidString: "6B7C0001-0000-4000-8000-000000000007")!
    }

    public static let dictation = Mode(
        id: BuiltInID.dictation,
        name: "Dictation",
        icon: "mic",
        instructions: "",
        kind: .plainDictation,
        isBuiltIn: true
    )

    public static let cleanUp = Mode(
        id: BuiltInID.cleanUp,
        name: "Clean up",
        icon: "sparkles",
        instructions: """
        Clean up the dictated text. Remove filler words, stutters, false starts and \
        accidental repetitions; where the speaker restated something, keep only the \
        final version. Fix punctuation, capitalization, grammar and sentence \
        boundaries, and correct clearly misheard words when context makes the \
        intended word obvious. Keep the speaker's wording, tone, and meaning. Leave \
        names, numbers, URLs, code and technical terms untouched. Do not add, \
        answer, summarize, or continue anything.
        """,
        isBuiltIn: true
    )

    public static let message = Mode(
        id: BuiltInID.message,
        name: "Message",
        icon: "message",
        instructions: """
        Turn the dictated text into a short, natural chat message. Clean up filler \
        words and false starts, fix punctuation, and keep a casual, friendly tone \
        that matches the speaker. Keep it brief; no greeting or sign-off unless the \
        speaker said one. No Markdown.
        """,
        isBuiltIn: true
    )

    public static let email = Mode(
        id: BuiltInID.email,
        name: "Email",
        icon: "envelope",
        instructions: """
        Turn the dictated text into a well-written email body. Add a greeting and a \
        sign-off line only if the speaker named the recipient or themselves; never \
        invent names. Use short paragraphs, a clear and polite tone, and correct \
        grammar and punctuation. Keep every fact the speaker gave and add none. \
        Do not write a subject line. No Markdown.
        """,
        isBuiltIn: true
    )

    public static let notes = Mode(
        id: BuiltInID.notes,
        name: "Notes",
        icon: "list.bullet",
        instructions: """
        Turn the dictated text into concise notes: a bulleted list using "- " with \
        one idea per bullet, grouped in the order spoken. Keep names, numbers, dates \
        and action items exactly. Drop filler and repetition. Do not add a title or \
        anything that was not said.
        """,
        isBuiltIn: true
    )

    public static let summary = Mode(
        id: BuiltInID.summary,
        name: "Summary",
        icon: "text.append",
        instructions: """
        Summarize the dictated text in a few clear sentences that keep the key \
        points, decisions, names, numbers and action items. Write plain prose, \
        shorter than the original. Do not add opinions or information that was \
        not said.
        """,
        isBuiltIn: true
    )

    public static let translateToEnglish = Mode(
        id: BuiltInID.translateToEnglish,
        name: "Translate to English",
        icon: "globe",
        instructions: """
        Translate the dictated text into fluent, natural English. Remove filler \
        words and false starts before translating, preserve the tone and meaning, \
        and keep names, URLs, code and numbers unchanged. If the text is already \
        English, return it cleaned up but untranslated.
        """,
        translateToEnglish: true,
        isBuiltIn: true
    )

    /// The modes KVoice ships with, in display order.
    public static let builtIns: [Mode] = [
        .dictation, .cleanUp, .message, .email, .notes, .summary, .translateToEnglish
    ]
}
