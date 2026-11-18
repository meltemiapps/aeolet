import XCTest

final class AccountsUITests: AeoletUITestCase {
    func testAddSwitchAndSignOutOneAccount() {
        launch()
        signInAndWaitForInbox()

        addSecondAccount()
        XCTAssertTrue(row("Welcome to Aeolet").waitForExistence(timeout: 15), "Second account's inbox did not load")
        XCTAssertFalse(row("Photos from the weekend").exists, "First account's mail leaked into the second")

        switchAccount(to: Self.elena)
        XCTAssertTrue(row("Photos from the weekend").waitForExistence(timeout: 15))
        XCTAssertFalse(row("Welcome to Aeolet").exists)

        switchAccount(to: Self.nikos)
        XCTAssertTrue(row("Welcome to Aeolet").waitForExistence(timeout: 15))

        // Both accounts have tokens and cached mail before signing out.
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.elena)"), "\(keychain)")
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.nikos)"), "\(keychain)")
        waitUntil(10, "both accounts to have cached mail") { (cacheFiles[Self.elena] ?? 0) > 0 && (cacheFiles[Self.nikos] ?? 0) > 0 }

        openSettings()
        let start = logPosition
        app.buttons[Self.nikos].tap()
        app.buttons["Sign out"].tap()
        waitForLog("REVOKE token=mock-refresh-\(Self.nikos)", after: start)
        // Signing out the account on screen switches to the remaining one, which closes Settings by itself.
        // Give that a moment, and only close Settings if it is still there.
        let settings = app.navigationBars["Settings"]
        let deadline = Date().addingTimeInterval(5)
        while settings.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        let done = settings.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }

        waitUntil(10, "Nikos's credentials and cache to be removed") {
            !keychain.contains("oauth.refresh.\(Self.nikos)") && cacheFiles[Self.nikos] == 0
        }
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.elena)"), "Elena's token was removed too: \(keychain)")
        XCTAssertGreaterThan(cacheFiles[Self.elena] ?? 0, 0, "Elena's cached mail was removed too")
        XCTAssertFalse(log.contains { $0.contains("REVOKE token=mock-refresh-\(Self.elena)") }, "Elena's grant must not be revoked")

        // The app falls back to the remaining account.
        XCTAssertTrue(row("Photos from the weekend").waitForExistence(timeout: 15))
        openFolders()
        XCTAssertTrue(accountRow(Self.elena).exists)
        XCTAssertFalse(accountRow(Self.nikos).exists, "Signed-out account still listed")
    }

    /// The IMAP form: with nothing published for the domain (the mock answers every autoconfig request with 404,
    /// and DNS is not queried in mock runs), the fields are filled from the domain on the implicit-TLS ports,
    /// and the account can't be added without a password.
    func testOtherAccountFallsBackToTheDomainAndOffersOnlyEncryptedConnections() {
        launch()
        let other = app.buttons["signIn.other"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()

        type("alex@example.com", into: app.textFields["manual.email"])
        app.buttons["manual.discover"].tap()
        XCTAssertTrue(app.staticTexts["manual.discoveryNote"].waitForExistence(timeout: 30), "Discovery did not finish")
        XCTAssertTrue(app.staticTexts["manual.discoveryNote"].label.contains("No published settings"))

        XCTAssertEqual(app.textFields["imap.host"].value as? String, "example.com")
        XCTAssertEqual(app.textFields["imap.port"].value as? String, "993")
        XCTAssertEqual(app.textFields["smtp.host"].value as? String, "example.com")
        XCTAssertEqual(app.textFields["smtp.port"].value as? String, "465")
        // Rows below the fold are created only when scrolled to.
        let form = app.collectionViews.firstMatch
        let username = app.textFields["manual.username"]
        for _ in 0..<5 where !username.exists { form.swipeUp(velocity: .slow) }
        XCTAssertEqual(username.value as? String, "alex@example.com")

        let add = app.buttons["manual.add"]
        for _ in 0..<5 where !(add.exists && add.isHittable) { form.swipeUp(velocity: .slow) }
        XCTAssertFalse(add.isEnabled, "An account can't be added without a password")

        // The security menu offers SSL/TLS and STARTTLS, nothing unencrypted.
        let security = app.buttons["imap.security"]
        for _ in 0..<5 where !(security.exists && security.isHittable) { form.swipeDown(velocity: .slow) }
        security.tap()
        XCTAssertTrue(app.buttons["STARTTLS"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["None"].exists)
        XCTAssertFalse(app.buttons["Plain"].exists)
    }
}
