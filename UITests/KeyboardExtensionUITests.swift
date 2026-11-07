import XCTest

/// Types with the real KVoice keyboard extension into a KVoice-owned text
/// field (`-kvoiceTypingField`). Needs a device where the KVoice keyboard is
/// added in Settings; skips otherwise. Run on the device with
/// `-only-testing:KVoiceUITests/KeyboardExtensionUITests`.
///
/// A keyboard extension's views are not in the host's accessibility tree,
/// so the keys are tapped by position: KVoice's layout (KeyboardView: a
/// 44 pt toolbar and four 53.5 pt key rows, 260 pt in all) sits right above
/// the system bar with the "Next keyboard" button.
@MainActor
final class KeyboardExtensionUITests: XCTestCase {
    private let kvoiceCell = "KVoice, Multiple languages"

    func testTypesHelloWorldWithTheRealKeys() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The KVoice keyboard is not enabled on the simulator.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["-kvoiceTypingField"]
        app.launch()
        let field = app.textFields["typingField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let globe = app.buttons["Next keyboard"].firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5), "no system keyboard bar")

        // Pick KVoice from the keyboard list, then check it is the selected one.
        globe.press(forDuration: 1.2)
        let cell = app.cells[kvoiceCell]
        guard cell.waitForExistence(timeout: 3) else {
            throw XCTSkip("The KVoice keyboard is not enabled on this device.")
        }
        cell.tap()
        sleep(1)
        globe.press(forDuration: 1.2)
        XCTAssertTrue(app.cells[kvoiceCell].waitForExistence(timeout: 3))
        XCTAssertTrue(app.cells[kvoiceCell].isSelected, "KVoice is not the current keyboard")
        app.cells[kvoiceCell].tap()
        sleep(1)

        // An empty field starts shifted, so the first key types "H".
        for character in "hello world" {
            key(character, app: app, bottom: globe.frame.minY - 7).tap()
            usleep(300_000)
        }
        sleep(2)
        attach(XCUIScreen.main.screenshot(), "typed")
        XCTAssertEqual(field.value as? String, "Hello world")
        #endif
    }

    /// The centre of a key on KVoice's letters layer.
    private func key(_ character: Character, app: XCUIApplication, bottom: CGFloat) -> XCUICoordinate {
        let width = app.windows.firstMatch.frame.width
        let unit = (width - 6) / 10
        let rowHeight: CGFloat = (260 - 44 - 2) / 4
        func centre(row: Int, x: CGFloat) -> XCUICoordinate {
            let y = bottom - 2 - (CGFloat(3 - row) + 0.5) * rowHeight
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        if character == " " {
            // Between the 123 (and globe, if shown) keys and return.
            let left = 3 + unit * 1.3
            let right = width - 3 - unit * 2.4
            return centre(row: 3, x: (left + right) / 2)
        }
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let row = rows.firstIndex { $0.contains(character) }!
        let index = CGFloat(rows[row].distance(from: rows[row].startIndex, to: rows[row].firstIndex(of: character)!))
        let start: CGFloat = [3, 3 + unit / 2, 3 + unit * 1.5][row]
        return centre(row: row, x: start + (index + 0.5) * unit)
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
