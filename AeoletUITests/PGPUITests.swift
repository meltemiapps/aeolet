import XCTest

final class PGPUITests: AeoletUITestCase {
    /// Export warns first, hands over the passphrase-locked key through the share sheet, and cleans up after.
    private func exportPrivateKey() {
        let export = app.buttons["Export private key"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 10), "No Export private key button")
        export.tap()
        let warning = app.alerts["Export your private key?"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10), "No warning before exporting")
        XCTAssertTrue(warning.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "locked with your passphrase")).firstMatch.exists)
        // Cancelling exports nothing.
        let start = logPosition
        warning.buttons["Cancel"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(log.contains { $0.contains("EXPORT key") }, "Cancel still exported the key")

        export.tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        warning.buttons["Export"].tap()
        let line = waitForLog("EXPORT key account=\(Self.elena)", after: start)
        XCTAssertTrue(line.contains("locked=true") && line.contains("armour=private"), "Exported key was not passphrase-locked: \(line)")
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "Share sheet did not open")
        XCTAssertTrue(anyText(containing: "private key").exists, "Share sheet does not show the key file")
        closeShareSheet(sheet)
        XCTAssertTrue(app.navigationBars["PGP keys"].exists)
    }

    /// The share sheet's X lives in its own remote view; try it by name, then by its place in the top right corner.
    private func closeShareSheet(_ sheet: XCUIElement) {
        let closes = app.buttons.matching(NSPredicate(format: "label ==[c] 'Close' OR identifier ==[c] 'Close'"))
        for index in (0..<closes.count).reversed() {
            let close = closes.element(boundBy: index)
            if close.isHittable { close.tap(); break }
        }
        if !waitFor(3, { !sheet.exists }) {
            let window = app.windows.firstMatch.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.maxX - 48, dy: sheet.frame.minY - 40)).tap()
        }
        if !waitFor(3, { !sheet.exists }) { sheet.swipeDown(velocity: .fast) }
        waitUntil(10, "the share sheet to close") { !sheet.exists }
    }

    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return true
    }

    func testEncryptSignSendDecryptVerifyAndWrongKey() {
        launch(animations: true)
        signInAndWaitForInbox()
        addSecondAccount()

        // Turn PGP on and give each account its own key.
        openSettings()
        setSwitch("Enable PGP", on: true)
        app.buttons["Keys"].tap()
        XCTAssertTrue(app.navigationBars["PGP keys"].waitForExistence(timeout: 10))
        generateKey(for: Self.elena, name: "Elena Marinou")
        generateKey(for: Self.nikos, name: "Nikos Andreou")
        XCTAssertFalse(app.buttons["Generate a new key"].exists, "Both accounts should have a key")
        XCTAssertTrue(keychain.contains("pgp.private.\(Self.elena)") && keychain.contains("pgp.private.\(Self.nikos)"), "\(keychain)")
        exportPrivateKey()
        app.navigationBars["PGP keys"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()

        // Elena sends Nikos an encrypted, signed message. Both keys are on this device, so each
        // account already has the other's public key; that is the exchange.
        switchAccount(to: Self.elena)
        app.buttons["New message"].tap()
        type(Self.nikos, into: app.textFields["To"])
        type("Lighthouse", into: app.textFields["Subject"])
        type("Meet at the lighthouse at nine.", into: app.textViews.firstMatch)
        hideKeyboard()
        let encrypt = app.switches["Encrypt"]
        XCTAssertTrue(encrypt.waitForExistence(timeout: 10), "Encrypt option missing")
        setSwitch("Encrypt", on: true)
        setSwitch("Sign", on: true)
        XCTAssertFalse(anyText(containing: "No key for").exists, "Recipient key should be known")
        var start = logPosition
        app.buttons["Send"].tap()
        enterPassphrase(Self.passphrase, confirm: "Sign and send")
        let sent = waitForLog("SEND from=\(Self.elena)", "subject=Lighthouse", after: start, timeout: 40)
        XCTAssertTrue(sent.hasSuffix("pgp=encrypted"), "Message was not PGP/MIME encrypted: \(sent)")
        waitForLog("DELIVER to=\(Self.nikos)", after: start)

        // Nikos decrypts it and sees a verified signature.
        switchAccount(to: Self.nikos)
        // PGP/MIME mail is recognised from its Content-Type, so the list never shows armour or "Version: 1".
        let lighthouse = scrollTo("Lighthouse")
        XCTAssertTrue(lighthouse.label.contains("Encrypted message"), "Encrypted row: \(lighthouse.label)")
        open("Lighthouse")
        XCTAssertTrue(anyText(containing: "End-to-end encrypted").waitForExistence(timeout: 15))
        XCTAssertFalse(anyText(containing: "Meet at the lighthouse").exists, "Plaintext visible before decrypting")
        app.buttons["Decrypt"].tap()
        enterPassphrase(Self.passphrase, confirm: "Decrypt")
        XCTAssertTrue(anyText(containing: "Decrypted on this device").waitForExistence(timeout: 30), "Decryption failed")
        XCTAssertTrue(anyText(containing: "Signature verified").waitForExistence(timeout: 10), "Signature not verified")
        XCTAssertTrue(anyText(containing: "Meet at the lighthouse at nine.").waitForExistence(timeout: 10), "Decrypted text not shown")
        goBack()

        // A message encrypted to someone else's key fails with a clear reason.
        switchAccount(to: Self.elena)
        // Elena's passphrase is still in memory from signing, so the app tries it as soon as the thread opens.
        open("Confidential: contract draft")
        let reason = anyText(containing: "encrypted to a different key")
        if !reason.waitForExistence(timeout: 10) {
            app.buttons["Decrypt"].firstMatch.tap()
            if app.secureTextFields["Passphrase"].waitForExistence(timeout: 3) {
                enterPassphrase(Self.passphrase, confirm: "Decrypt")
            }
        }
        XCTAssertTrue(anyText(containing: "encrypted to a different key").waitForExistence(timeout: 30),
                      "Wrong-key decryption did not explain the failure")
        XCTAssertTrue(app.buttons["Try again"].exists)
        goBack()

        // A signature from a key we don't hold is reported, never shown as valid.
        open("Signed release notes")
        XCTAssertTrue(anyText(containing: "Signed by a key you do not have").waitForExistence(timeout: 30))
        XCTAssertFalse(anyText(containing: "Signature verified").exists)
    }
}
