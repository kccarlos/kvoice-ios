import XCTest

/// Types with the real KVoice keyboard extension into a KVoice-owned text
/// field (`-kvoiceTypingField`). Needs a device where the KVoice keyboard is
/// added in Settings; skips otherwise. Run on the device with
/// `-only-testing:KVoiceUITests/KeyboardExtensionUITests`.
@MainActor
final class KeyboardExtensionUITests: XCTestCase {
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard appeared")

        // Switch keyboards until KVoice's toolbar mic shows.
        let kvoiceMic = app.buttons["Dictate"]
        for _ in 0..<6 where !kvoiceMic.waitForExistence(timeout: 2) {
            app.buttons["Next keyboard"].firstMatch.tap()
        }
        attach(app.debugDescription, "hierarchy")
        guard kvoiceMic.exists else { throw XCTSkip("The KVoice keyboard is not enabled on this device.") }

        // An empty field starts shifted: the first key reads "H".
        for character in ["H", "e", "l", "l", "o", "Space", "w", "o", "r", "l", "d"] {
            let key = app.keys[character].exists ? app.keys[character] : app.buttons[character]
            XCTAssertTrue(key.waitForExistence(timeout: 2), "no key \(character)")
            key.tap()
        }
        XCTAssertEqual(field.value as? String, "Hello world")
        attach(XCUIScreen.main.screenshot(), "typed")
        #endif
    }

    private func attach(_ text: String, _ name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ screenshot: XCUIScreenshot, _ name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
