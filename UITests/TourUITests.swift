import XCTest

/// Screenshot tour of every user-facing screen, in light, dark and the
/// largest accessibility text size. Runs on `-kvoiceDemo` scratch data, so
/// the real modes, history and keys are untouched. Not part of CI: run it
/// with `Scripts/dev/tour.sh`. Attachments are named `NN-screen-variant`.
@MainActor
final class TourUITests: XCTestCase {
    private var app = XCUIApplication()
    private var originalAppearance = XCUIDevice.Appearance.unspecified

    override func setUp() async throws {
        continueAfterFailure = true
        originalAppearance = XCUIDevice.shared.appearance
    }

    override func tearDown() async throws {
        app.terminate()
        if originalAppearance != .unspecified { XCUIDevice.shared.appearance = originalAppearance }
    }

    func test1Light() { tour(appearance: .light, largeText: false) }
    func test2Dark() { tour(appearance: .dark, largeText: false) }
    func test3LargeText() { tour(appearance: .light, largeText: true) }

    // MARK: Tour

    private func tour(appearance: XCUIDevice.Appearance, largeText: Bool) {
        XCUIDevice.shared.appearance = appearance
        let textSize = largeText
            ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []

        // First launch on fresh demo data: onboarding, then the app.
        launch(["-kvoiceDemo"] + textSize)
        onboarding()
        home()
        modes()
        history()
        settings()

        launch(["-kvoiceDemo", "-kvoiceSkipOnboarding", "-kvoiceScreen", "handoff"] + textSize)
        shot("40-handoff-stopped")

        for (index, state) in ["ready", "noFullAccess", "recording", "shortcutRecording"].enumerated() {
            launch(["-kvoiceKeyboardPreview", state] + textSize)
            shot(String(format: "%02d-keyboard-%@", 50 + index, state))
        }
    }

    private func onboarding() {
        let pages = [
            ("welcome", "Welcome to KVoice"), ("microphone", "Microphone"), ("engine", "Speech recognition"),
            ("ai", "AI formatting (optional)"), ("keyboard", "Add the KVoice keyboard"),
            ("actionbutton", "Action Button (optional)"),
        ]
        for (index, (page, title)) in pages.enumerated() {
            if page == "actionbutton" { dismissSystemAlert() }  // notification permission
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "onboarding \(page) did not appear")
            shot(String(format: "%02d-onboarding-%@", 1 + index, page))
            let next = app.buttons[index == pages.count - 1 ? "Start Dictating" : "Continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 5), "onboarding \(page): no next button")
            next.tap()
        }
        dismissSystemAlert()
    }

    private func home() {
        let record = app.buttons["Start dictation"]
        XCTAssertTrue(record.waitForExistence(timeout: 5), "Home did not appear")
        shot("10-home-idle")

        let email = app.buttons["Email"]
        if email.waitForExistence(timeout: 2) {
            email.tap()
            shot("11-home-modechip-email")
            app.buttons["Clean up"].tap()
        }

        #if targetEnvironment(simulator)
        // Recording needs a microphone; the simulator uses the Mac's input.
        // Skipped on the device so the tour never records the room.
        record.tap()
        dismissSystemAlert()
        if app.buttons["Stop dictation"].waitForExistence(timeout: 5) {
            shot("12-home-recording")
            app.buttons["Cancel"].tap()
        }
        #endif
    }

    private func modes() {
        tab("Modes")
        shot("20-modes-list")
        tapText("Standup Update")
        shot("21-modeeditor-custom")
        app.buttons["Icon"].firstMatch.tapIfExists()
        if app.navigationBars["Icon"].waitForExistence(timeout: 3) {
            shot("22-modeeditor-iconpicker")
            app.buttons["Done"].tap()
        }
        app.swipeUp()
        shot("23-modeeditor-custom-scrolled")
        back()
        app.navigationBars.buttons["New Mode"].tap()
        shot("24-modeeditor-new")
        app.buttons["Cancel"].tap()
    }

    private func history() {
        tab("History")
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 5), "History is empty")
        shot("30-history-list")
        tapText("I think we should move the launch to Thursday because the build isn't ready.")
        shot("31-historydetail-formatted")
        app.buttons["Transcript"].tapIfExists()
        shot("32-historydetail-transcript")
        back()
        tapText("明天上午 10 点与设计团队开会", contains: true)
        shot("33-historydetail-chinese")
        back()
    }

    private func settings() {
        tab("Settings")
        shot("60-settings-top")
        for (number, row) in [(61, "Transcription"), (62, "AI formatting")] {
            tapText(row)
            shot("\(number)-settings-\(row.lowercased().replacingOccurrences(of: " ", with: ""))")
            app.swipeUp()
            shot("\(number)-settings-\(row.lowercased().replacingOccurrences(of: " ", with: ""))-scrolled")
            back()
        }
        tapText("Set up the KVoice keyboard")
        shot("63-settings-keyboard")
        back()
        tapText("Action Button")
        shot("64-settings-actionbutton")
        app.swipeUp()
        shot("64-settings-actionbutton-scrolled")
        back()
        tapText("Diagnostics")
        shot("65-settings-diagnostics")
        back()
        app.swipeUp()
        shot("66-settings-bottom")
    }

    // MARK: Helpers

    private func launch(_ arguments: [String]) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 10)
        sleep(1)
    }

    private func shot(_ name: String) {
        sleep(1)  // let transitions settle
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        // Scrolling down minimizes the tab bar; scrolling back up restores it.
        for _ in 0..<3 where !button.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(button.exists, "no \(name) tab")
        button.tap()
    }

    /// Taps a row by its text, scrolling down to it if needed.
    private func tapText(_ text: String, contains: Bool = false) {
        let element = contains
            ? app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            : app.staticTexts[text].firstMatch
        _ = element.waitForExistence(timeout: 5)
        var swipes = 0
        while !element.isHittable, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "\(text) not reachable")
        element.tapIfExists()
    }

    private func back() {
        let button = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no back button")
        button.tap()
    }

    /// Accepts a system permission alert if one is showing.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        let allow = alert.buttons["Allow"].firstMatch
        (allow.exists ? allow : alert.buttons.element(boundBy: 1)).tap()
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if waitForExistence(timeout: 3), isHittable { tap() }
    }
}
