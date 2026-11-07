import Foundation
import Testing
@testable import KVoiceCore

@Suite struct KeyboardKeysTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Layout

    @Test func lettersLayout() {
        let rows = KeyboardKeys.rows(.letters, showsGlobe: false)
        #expect(rows.count == 4)
        #expect(rows[0] == "qwertyuiop".map { .character(String($0)) })
        #expect(rows[1].count == 9)
        #expect(rows[2].first == .shift && rows[2].last == .delete && rows[2].count == 9)
        #expect(rows[3] == [.layer(.numbers), .space, .returnKey])
    }

    @Test func globeOnlyWhenNeeded() {
        #expect(KeyboardKeys.rows(.letters, showsGlobe: true)[3] == [.layer(.numbers), .globe, .space, .returnKey])
        #expect(KeyboardKeys.rows(.numbers, showsGlobe: true)[3] == [.layer(.letters), .globe, .space, .returnKey])
    }

    @Test func numberAndSymbolLayers() {
        let numbers = KeyboardKeys.rows(.numbers, showsGlobe: false)
        #expect(numbers[0] == "1234567890".map { .character(String($0)) })
        #expect(numbers[1].count == 10 && numbers[1].last == .character("\""))
        #expect(numbers[2] == [.layer(.symbols)] + ".,?!'".map { .character(String($0)) } + [.delete])
        let symbols = KeyboardKeys.rows(.symbols, showsGlobe: false)
        #expect(symbols[0].first == .character("[") && symbols[1].contains(.character("\\")))
        #expect(symbols[2].first == .layer(.numbers))
        #expect(symbols[3].first == .layer(.letters))
    }

    @Test func layerSwitching() {
        var keys = KeyboardKeys()
        _ = keys.tap(.layer(.numbers), context: nil, now: t0)
        #expect(keys.layer == .numbers)
        _ = keys.tap(.layer(.symbols), context: nil, now: at(1))
        #expect(keys.layer == .symbols)
        _ = keys.tap(.layer(.letters), context: nil, now: at(2))
        #expect(keys.layer == .letters)
    }

    @Test func spaceOnNumbersReturnsToLetters() {
        var keys = KeyboardKeys()
        _ = keys.tap(.layer(.numbers), context: nil, now: t0)
        #expect(keys.tap(.character("5"), context: "", now: at(1)) == [.insert("5")])
        #expect(keys.tap(.space, context: "5", now: at(2)) == [.insert(" ")])
        #expect(keys.layer == .letters)
    }

    // MARK: Shift

    @Test func oneShotShiftClearsAfterOneLetter() {
        var keys = KeyboardKeys()
        _ = keys.tap(.shift, context: "a ", now: t0)
        #expect(keys.shift == .once)
        #expect(keys.tap(.character("h"), context: "a ", now: at(1)) == [.insert("H")])
        #expect(keys.shift == .off)
        #expect(keys.tap(.character("i"), context: "a H", now: at(2)) == [.insert("i")])
    }

    @Test func slowSecondTapTurnsShiftOff() {
        var keys = KeyboardKeys()
        _ = keys.tap(.shift, context: nil, now: t0)
        _ = keys.tap(.shift, context: nil, now: at(1))
        #expect(keys.shift == .off)
    }

    @Test func doubleTapLocksAndTapUnlocks() {
        var keys = KeyboardKeys()
        _ = keys.tap(.shift, context: nil, now: t0)
        _ = keys.tap(.shift, context: nil, now: at(0.2))
        #expect(keys.shift == .locked)
        #expect(keys.tap(.character("a"), context: "", now: at(1)) == [.insert("A")])
        #expect(keys.tap(.character("b"), context: "A", now: at(2)) == [.insert("B")])
        keys.textChanged(context: "AB", autocapitalizes: true)
        #expect(keys.shift == .locked)
        _ = keys.tap(.shift, context: nil, now: at(3))
        #expect(keys.shift == .off)
    }

    @Test func doubleTapFromAutoShiftLocks() {
        var keys = KeyboardKeys()
        keys.textChanged(context: "", autocapitalizes: true)
        #expect(keys.shift == .once)
        _ = keys.tap(.shift, context: "", now: t0)
        #expect(keys.shift == .off)
        _ = keys.tap(.shift, context: "", now: at(0.2))
        #expect(keys.shift == .locked)
    }

    @Test func shiftDoesNotChangeSymbols() {
        var keys = KeyboardKeys()
        _ = keys.tap(.shift, context: nil, now: t0)
        _ = keys.tap(.layer(.numbers), context: nil, now: at(1))
        #expect(keys.text(for: "a") == "a")
    }

    // MARK: Auto-capitalization

    @Test(arguments: [
        (nil, true), ("", true), ("Hi. ", true), ("Wow! ", true), ("Why? ", true), ("Line\n", true),
        ("Hi.  ", true), ("   ", true), ("Hi.", false), ("Hi ", false), ("Hi", false), ("e.g", false),
    ] as [(String?, Bool)])
    func startsSentence(context: String?, expected: Bool) {
        #expect(KeyboardKeys.startsSentence(context) == expected)
    }

    @Test func autoShiftFollowsContextAndRespectsNone() {
        var keys = KeyboardKeys()
        keys.textChanged(context: "Done. ", autocapitalizes: true)
        #expect(keys.shift == .once)
        keys.textChanged(context: "Done. W", autocapitalizes: true)
        #expect(keys.shift == .off)
        keys.textChanged(context: "", autocapitalizes: false)
        #expect(keys.shift == .off)
    }

    // MARK: Space, delete, return

    @Test func doubleSpaceAfterWordTypesPeriod() {
        var keys = KeyboardKeys()
        #expect(keys.tap(.space, context: "Hello", now: t0) == [.insert(" ")])
        #expect(keys.tap(.space, context: "Hello ", now: at(0.2)) == [.deleteBackward, .insert(". ")])
        // A third quick space is a plain space.
        #expect(keys.tap(.space, context: "Hello. ", now: at(0.3)) == [.insert(" ")])
    }

    @Test func slowOrNonWordSpacesStayPlain() {
        var keys = KeyboardKeys()
        _ = keys.tap(.space, context: "Hello", now: t0)
        #expect(keys.tap(.space, context: "Hello ", now: at(1)) == [.insert(" ")])
        _ = keys.tap(.space, context: "Hi,", now: at(2))
        #expect(keys.tap(.space, context: "Hi, ", now: at(2.1)) == [.insert(" ")])
        // Another key in between breaks the double tap.
        _ = keys.tap(.space, context: "a", now: at(3))
        _ = keys.tap(.delete, context: "a ", now: at(3.1))
        #expect(keys.tap(.space, context: "a", now: at(3.2)) == [.insert(" ")])
    }

    @Test func deleteAndReturn() {
        var keys = KeyboardKeys()
        #expect(keys.tap(.delete, context: "a", now: t0) == [.deleteBackward])
        #expect(keys.tap(.returnKey, context: "a", now: t0) == [.insert("\n")])
        #expect(keys.tap(.globe, context: "a", now: t0).isEmpty)
    }

    @Test(arguments: [
        (0, "return"), (1, "go"), (2, "search"), (3, "join"), (4, "next"), (5, "route"),
        (6, "search"), (7, "send"), (8, "search"), (9, "done"), (10, "emergency"), (11, "continue"), (99, "return"),
    ])
    func returnKeyLabels(rawValue: Int, label: String) {
        #expect(KeyboardKeys.returnKeyLabel(rawValue: rawValue) == label)
    }
}
