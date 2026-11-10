import XCTest

final class PrivacyUITests: AeoletUITestCase {
    func testRemoteImagesBlockedUntilRequested() {
        launch()
        signInAndWaitForInbox()
        open("This week: hidden beaches of Milos")
        let load = app.buttons["Load remote images"]
        XCTAssertTrue(load.waitForExistence(timeout: 15), "Remote images were not blocked by default")
        XCTAssertTrue(anyText(containing: "Five coves").waitForExistence(timeout: 10), "Message text should show while images are blocked")
        load.tap()
        waitUntil(10, "the remote images button to go away once images are allowed") { !load.exists }

        // Mail without remote content never offers the button.
        goBack()
        open("Sunday lunch")
        XCTAssertTrue(anyText(containing: "Gemista").waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Load remote images"].exists)
    }

    func testFaceIDLockMatchAndNonMatch() {
        Biometrics.enrol()
        launch()
        signInAndWaitForInbox()

        openSettings()
        setSwitch("Require Face ID or passcode", on: true)
        // Leave Settings open: the lock must cover sheets as well as the mailbox.

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.activate()

        let locked = app.staticTexts["Aeolet is locked"]
        XCTAssertTrue(locked.waitForExistence(timeout: 10), "App did not lock after leaving the foreground")
        allowFaceIDIfAsked()

        // A face that doesn't match must leave the app locked.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        Biometrics.nonMatchingFace()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(locked.exists, "A non-matching face unlocked the app")
        XCTAssertFalse(app.navigationBars["Settings"].exists, "An open sheet showed through the lock screen")
        XCTAssertFalse(row("Dinner on Friday?").exists, "Mail was reachable (for example by VoiceOver) while locked")
        dismissFaceIDRetryIfShown()

        // A matching face unlocks it.
        if app.buttons["Unlock"].isHittable { app.buttons["Unlock"].tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        Biometrics.matchingFace()
        waitUntil(15, "a matching face to unlock the app") { !locked.exists }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Unlocking should return to where I was")
        app.buttons["Done"].tap()
        XCTAssertTrue(row("Dinner on Friday?").waitForExistence(timeout: 10))
    }

    /// iOS asks once whether the app may use Face ID.
    private func allowFaceIDIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["OK", "Allow"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 3) { button.tap(); return }
        }
    }

    private func dismissFaceIDRetryIfShown() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons.matching(identifier: "Cancel").firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() }
    }
}
