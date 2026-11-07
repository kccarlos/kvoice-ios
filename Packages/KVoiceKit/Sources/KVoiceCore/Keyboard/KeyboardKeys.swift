import Foundation

/// The typing half of the KVoice keyboard (English QWERTY): layers, shift,
/// auto-capitalization and the edits each key makes. Pure, so it is tested
/// without UIKit; the keyboard applies the returned edits to the text field.
public struct KeyboardKeys: Sendable, Equatable {
    public enum Layer: Sendable, Equatable { case letters, numbers, symbols }
    public enum Shift: Sendable, Equatable { case off, once, locked }

    public enum Key: Sendable, Hashable {
        case character(String)
        case shift, delete, globe, space, returnKey
        /// 123 / ABC / #+=: switch to this layer.
        case layer(Layer)
    }

    public enum Edit: Sendable, Equatable {
        case insert(String)
        case deleteBackward
    }

    /// Two taps closer than this are a double tap (caps lock, ". ").
    public static let doubleTapInterval: TimeInterval = 0.35

    public private(set) var layer: Layer = .letters
    public private(set) var shift: Shift = .off
    private var lastShiftTap: Date?
    private var lastSpaceTap: Date?

    public init() {}

    // MARK: Layout

    /// The key rows of a layer, top to bottom.
    public static func rows(_ layer: Layer, showsGlobe: Bool) -> [[Key]] {
        func chars(_ string: String) -> [Key] { string.map { .character(String($0)) } }
        let bottom: [Key] = [.layer(layer == .letters ? .numbers : .letters)]
            + (showsGlobe ? [.globe] : []) + [.space, .returnKey]
        let punctuation = chars(".,?!'")
        switch layer {
        case .letters:
            return [chars("qwertyuiop"), chars("asdfghjkl"), [.shift] + chars("zxcvbnm") + [.delete], bottom]
        case .numbers:
            return [chars("1234567890"), chars("-/:;()$&@\""), [.layer(.symbols)] + punctuation + [.delete], bottom]
        case .symbols:
            return [chars("[]{}#%^*+="), chars("_\\|~<>€£¥•"), [.layer(.numbers)] + punctuation + [.delete], bottom]
        }
    }

    /// What a character key shows and types: upper case while shifted.
    public func text(for character: String) -> String {
        layer == .letters && shift != .off ? character.uppercased() : character
    }

    /// The return key's caption for a `UIReturnKeyType` raw value.
    public static func returnKeyLabel(rawValue: Int) -> String {
        switch rawValue {
        case 1: "go"
        case 2, 6, 8: "search"   // google, search, yahoo
        case 3: "join"
        case 4: "next"
        case 5: "route"
        case 7: "send"
        case 9: "done"
        case 10: "emergency"
        case 11: "continue"
        default: "return"
        }
    }

    // MARK: Keys

    /// A key tap. `context` is the text before the cursor.
    public mutating func tap(_ key: Key, context: String?, now: Date) -> [Edit] {
        if key != .space { lastSpaceTap = nil }
        switch key {
        case .character(let character):
            let typed = text(for: character)
            if shift == .once { shift = .off }
            return [.insert(typed)]
        case .shift:
            let isDoubleTap = lastShiftTap.map { now.timeIntervalSince($0) < Self.doubleTapInterval } ?? false
            switch shift {
            // A double tap locks, also from an automatic shift (on, off, on).
            case .off: shift = isDoubleTap ? .locked : .once
            case .once: shift = isDoubleTap ? .locked : .off
            case .locked: shift = .off
            }
            lastShiftTap = shift == .locked ? nil : now
            return []
        case .delete:
            return [.deleteBackward]
        case .space:
            let isDoubleTap = lastSpaceTap.map { now.timeIntervalSince($0) < Self.doubleTapInterval } ?? false
            lastSpaceTap = now
            if layer == .numbers { layer = .letters }
            if isDoubleTap, Self.endsWithWordAndSpace(context) {
                lastSpaceTap = nil
                return [.deleteBackward, .insert(". ")]
            }
            return [.insert(" ")]
        case .returnKey:
            return [.insert("\n")]
        case .layer(let target):
            layer = target
            return []
        case .globe:
            return []
        }
    }

    /// The text field's autocapitalization (`UITextAutocapitalizationType`).
    public enum Autocapitalization: Sendable {
        case none, words, sentences, allCharacters
    }

    /// The text changed (typed, dictated, or moved by the user): shift
    /// once where the field capitalizes, unless caps lock is on.
    public mutating func textChanged(context: String?, autocapitalization: Autocapitalization) {
        guard shift != .locked else { return }
        let capitalizes = switch autocapitalization {
        case .none: false
        case .words: context?.last.map { $0.isWhitespace } ?? true
        case .sentences: Self.startsSentence(context)
        case .allCharacters: true
        }
        shift = capitalizes ? .once : .off
    }

    /// Start of the document, or after ". ", "! ", "? " or a newline.
    public static func startsSentence(_ context: String?) -> Bool {
        guard let context, !context.isEmpty else { return true }
        if context.hasSuffix("\n") { return true }
        let beforeSpaces = context.reversed().drop { $0 == " " }
        guard beforeSpaces.count < context.count else { return false }
        guard let last = beforeSpaces.first else { return true }
        return ".!?\n".contains(last)
    }

    /// "word " (letter or digit, then one space): a second space makes ". ".
    static func endsWithWordAndSpace(_ context: String?) -> Bool {
        guard let context, context.hasSuffix(" ") else { return false }
        let before = context.dropLast().last
        return before?.isLetter == true || before?.isNumber == true
    }
}
