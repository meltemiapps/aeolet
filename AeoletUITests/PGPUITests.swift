import XCTest

final class PGPUITests: AeoletUITestCase {
    private func generateKey(for account: String, name: String) {
        let generate = app.buttons["Generate a new key"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "No Generate button for \(account)")
        generate.tap()
        XCTAssertTrue(app.navigationBars["New PGP key"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyText(containing: account).exists, "Key sheet is for the wrong account")
        type(name, into: app.textFields["Your name"])
        typeSecure(Self.passphrase, into: app.secureTextFields["Passphrase, 12 characters or more"])
        typeSecure(Self.passphrase, into: app.secureTextFields["Repeat passphrase"])
        XCTAssertTrue(app.buttons["Create"].isEnabled, "Create stayed disabled after entering the passphrase")
        app.buttons["Create"].tap()
        waitUntil(90, "key generation for \(account) to finish") { !app.navigationBars["New PGP key"].exists }
        XCTAssertTrue(keychain.contains("pgp.private.\(account)"), "No private key stored for \(account): \(keychain)")
    }

    private func enterPassphrase(_ value: String, confirm: String) {
        let field = app.secureTextFields["Passphrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No passphrase prompt")
        typeSecure(value, into: field)
        app.alerts.buttons[confirm].tap()
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
