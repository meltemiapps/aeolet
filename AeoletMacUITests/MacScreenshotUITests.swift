import XCTest

/// Captures the Mac App Store screenshots from the mock run: inbox, a conversation with an attachment,
/// compose, Settings and a decrypted PGP message. The viewer window is 1440 × 900 points, which is
/// 2880 × 1800 pixels on a Retina display. Each shot is the screen cropped to that window, so a compose or
/// Settings window in front of it is included.
final class MacScreenshotUITests: MacUITestCase {
    private func capture(_ name: String) {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let frame = mainWindow.frame
        let screen = XCUIScreen.main.screenshot().image
        guard let full = screen.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("No screen image")
            return
        }
        let scale = CGFloat(full.width) / screen.size.width
        let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        guard let cropped = full.cropping(to: crop.integral) else {
            XCTFail("Could not crop to the window")
            return
        }
        save(NSImage(cgImage: cropped, size: frame.size), as: name)
    }

    

    func testCaptureScreenshots() {
        launch(extra: ["-AeoletWindowSize", "1440x900"])
        signInAndWaitForInbox()
        select("Dinner on Friday?")
        XCTAssertTrue(anyText(containing: "Booked a table").waitForExistence(timeout: 15))
        capture("1-Inbox")

        select("Your ferry tickets: Piraeus to Naxos")
        XCTAssertTrue(anyText(containing: "Boarding passes.pdf").waitForExistence(timeout: 15))
        capture("2-Thread")

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        type("Sofia Papadaki <sofia@example.org>", into: compose.textFields["compose-to"])
        type("Weekend in Hydra", into: compose.textFields["compose-subject"])
        type("Hi Sofia,\n\nThe early ferry leaves Piraeus at 8:00. Shall we meet at the gate?\n\nElena", into: compose.textViews["compose-body"])
        app.typeKey("a", modifierFlags: [.command, .shift])
        capture("3-Compose")
        app.typeKey("w", modifierFlags: .command)
        app.buttons["Delete Draft"].firstMatch.click()

        // Nikos sends Elena an encrypted, signed message; Elena decrypts it on her Mac.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.toolbars.buttons["Accounts"].click()
        settings.buttons["Add Gmail Account"].click()
        waitForLog("TOKEN grant=authorization_code account=\(Self.nikos)")
        settings.toolbars.buttons["Encryption"].click()
        let enable = settings.checkBoxes["Enable PGP"].exists ? settings.checkBoxes["Enable PGP"] : settings.switches["Enable PGP"]
        enable.click()
        for (account, name) in [(Self.elena, "Elena Marinou"), (Self.nikos, "Nikos Andreou")] {
            let generate = settings.buttons["Generate a New Key…"].firstMatch
            XCTAssertTrue(generate.waitForExistence(timeout: 10), "No Generate button for \(account)")
            generate.click()
            let sheet = settings.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            type(name, into: sheet.textFields["Your name"])
            type(Self.passphrase, into: sheet.secureTextFields["Passphrase"])
            type(Self.passphrase, into: sheet.secureTextFields["Repeat passphrase"])
            sheet.buttons["Create"].click()
            waitUntil(90, "key generation for \(account)") { !sheet.exists }
        }
        capture("4-Settings")
        settings.typeKey("w", modifierFlags: .command)

        mainWindow.click()
        sidebar("INBOX", account: Self.nikos).click()
        waitForLog("LIST label=INBOX", "account=\(Self.nikos)")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        type(Self.elena, into: compose.textFields["compose-to"])
        type("Keys to the Naxos studio", into: compose.textFields["compose-subject"])
        type("Hi Elena,\n\nThe lease is signed. The door code is 4815 and the spare key is with Maria at the bakery on the corner.\n\nNikos",
             into: compose.textViews["compose-body"])
        compose.checkBoxes["Encrypt"].click()
        compose.checkBoxes["Sign"].click()
        let start = logPosition
        app.typeKey("d", modifierFlags: [.command, .shift])
        let field = app.secureTextFields["Passphrase"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No passphrase prompt")
        type(Self.passphrase, into: field)
        app.buttons["Sign and Send"].firstMatch.click()
        waitForLog("DELIVER to=\(Self.elena)", after: start, timeout: 40)

        mainWindow.click()
        sidebar("INBOX").click()
        waitForLog("LIST label=INBOX", "account=\(Self.elena)", after: start)
        select("Keys to the Naxos studio")
        let decrypt = app.buttons["Decrypt"].firstMatch
        if decrypt.waitForExistence(timeout: 10) {
            decrypt.click()
            let prompt = app.secureTextFields["Passphrase"].firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10))
            type(Self.passphrase, into: prompt)
            app.buttons["Decrypt"].firstMatch.click()
        }
        XCTAssertTrue(anyText(containing: "The lease is signed").waitForExistence(timeout: 30), "Decrypted text not shown")
        XCTAssertTrue(anyText(containing: "Decrypted on this Mac").exists)
        capture("5-Encrypted")
    }
}
