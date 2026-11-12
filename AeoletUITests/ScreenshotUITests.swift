import XCTest

/// Captures the inbox, a thread, compose, Settings and a decrypted PGP message from the mock run.
/// Run with animations on for natural rendering.
final class ScreenshotUITests: AeoletUITestCase {
    func testCaptureScreenshots() {
        launch(animations: true)
        signInAndWaitForInbox()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        save(app.screenshot(), as: "1-Inbox")

        open("Dinner on Friday?")
        XCTAssertTrue(anyText(containing: "Booked a table").waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        save(app.screenshot(), as: "2-Thread")
        goBack()

        app.buttons["New message"].tap()
        type("Sofia Papadaki <sofia@example.org>", into: app.textFields["To"])
        type("Weekend in Hydra", into: app.textFields["Subject"])
        type("Hi Sofia,\n\nThe early ferry leaves Piraeus at 8:00. Shall we meet at the gate?\n\nElena", into: app.textViews.firstMatch)
        app.buttons["Attach file"].tap()
        app.textViews.firstMatch.tap()
        app.buttons["Hide keyboard"].firstMatch.tap()
        waitUntil(5, "the keyboard to go away") { !keyboardIsUp }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app.screenshot(), as: "3-Compose")
        tapByPosition(app.buttons["Close"])
        tapByPosition(app.buttons["Discard"])

        openSettings()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app.screenshot(), as: "4-Settings")
        app.navigationBars["Settings"].buttons["Done"].tap()

        // Nikos sends Elena an encrypted, signed message; Elena decrypts it on her device.
        addSecondAccount()
        openSettings()
        setSwitch("Enable PGP", on: true)
        app.buttons["Keys"].tap()
        XCTAssertTrue(app.navigationBars["PGP keys"].waitForExistence(timeout: 10))
        generateKey(for: Self.elena, name: "Elena Marinou")
        generateKey(for: Self.nikos, name: "Nikos Andreou")
        app.navigationBars["PGP keys"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()

        // Adding Nikos left his inbox on screen.
        XCTAssertTrue(row("Welcome to Aeolet").waitForExistence(timeout: 15), "Expected Nikos's inbox")
        app.buttons["New message"].tap()
        type(Self.elena, into: app.textFields["To"])
        type("Keys to the Naxos studio", into: app.textFields["Subject"])
        type("Hi Elena,\n\nThe lease is signed. The door code is 4815 and the spare key is with Maria at the bakery on the corner.\n\nNikos",
             into: app.textViews.firstMatch)
        hideKeyboard()
        setSwitch("Encrypt", on: true)
        setSwitch("Sign", on: true)
        let start = logPosition
        app.buttons["Send"].tap()
        enterPassphrase(Self.passphrase, confirm: "Sign and send")
        waitForLog("DELIVER to=\(Self.elena)", after: start, timeout: 40)

        switchAccount(to: Self.elena)
        open("Keys to the Naxos studio")
        let decrypt = app.buttons["Decrypt"]
        if decrypt.waitForExistence(timeout: 10) {
            decrypt.tap()
            enterPassphrase(Self.passphrase, confirm: "Decrypt")
        }
        XCTAssertTrue(anyText(containing: "The lease is signed").waitForExistence(timeout: 30), "Decrypted text not shown")
        XCTAssertTrue(anyText(containing: "Decrypted on this device").exists)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        save(app.screenshot(), as: "5-Encrypted")
    }
}
