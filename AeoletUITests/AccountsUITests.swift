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

    /// A Gmail address typed into the IMAP form gets Gmail's servers without asking the network, and the
    /// app-password note with its link.
    func testGmailAddressInOtherAccountUsesGmailsServers() {
        launch()
        let other = app.buttons["signIn.other"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()

        type("alex@gmail.com", into: app.textFields["manual.email"])
        app.buttons["manual.discover"].tap()
        XCTAssertTrue(app.staticTexts["manual.discoveryNote"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["manual.discoveryNote"].label.contains("Gmail"))
        XCTAssertEqual(app.textFields["imap.host"].value as? String, "imap.gmail.com")
        XCTAssertEqual(app.textFields["smtp.host"].value as? String, "smtp.gmail.com")
    }

    /// The Gmail preset asks only for the address, name and app password, shows the fixed servers and links to
    /// where app passwords are made.
    func testGmailPresetShowsServersAndAppPasswordLink() {
        launch()
        signInAndWaitForInbox()
        openFolders()
        app.buttons["Add account"].tap()
        let gmail = app.buttons["addAccount.gmail"]
        XCTAssertTrue(gmail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addAccount.yahoo"].exists)
        gmail.tap()

        type("alex@gmail.com", into: app.textFields["preset.email"])
        let link = app.descendants(matching: .any)["preset.appPasswordLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "No link to create a Google app password")
        // Dragging the form dismisses the keyboard (.scrollDismissesKeyboard) and reaches the rows below it.
        let form = app.collectionViews.firstMatch
        let add = app.buttons["preset.add"]
        for _ in 0..<5 where !(add.exists && add.isHittable) { form.swipeUp(velocity: .slow) }
        XCTAssertFalse(add.isEnabled, "An account can't be added without an app password")
        XCTAssertTrue(anyText(containing: "imap.gmail.com:993").exists)
        XCTAssertTrue(anyText(containing: "smtp.gmail.com:465").exists)
    }

    /// Google sign-in for an address that is already an IMAP account is refused, and its grant is revoked, not kept.
    func testGoogleSignInForAnExistingIMAPAddressIsRefused() {
        launch(environment: ["AEOLET_MOCK_IMAP_ACCOUNT": Self.elena])
        openFolders()
        app.buttons["Add account"].tap()
        let google = app.buttons["addAccount.google"]
        XCTAssertTrue(google.waitForExistence(timeout: 10))
        google.tap()
        waitForLog("TOKEN grant=authorization_code account=\(Self.elena)")

        let error = app.staticTexts["addAccount.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "No message for the duplicate address")
        XCTAssertEqual(error.label, "This address is already in Aeolet.")
        XCTAssertFalse(keychain.contains("oauth.refresh.\(Self.elena)"), "The new token was stored: \(keychain)")
        waitForLog("REVOKE token=mock-refresh-\(Self.elena)")
        XCTAssertTrue(google.exists, "Add Account closed although nothing was added")
    }

    /// 1.2 without Google sign-in: the first-run screen has one Add Account button, the choices are Gmail, Yahoo
    /// Mail and Other mail account in that order, and the Gmail form explains how to get an app password.
    func testNewAccountsAreAddedWithoutGoogleSignIn() {
        launch(googleSignIn: false)
        let add = app.buttons["signIn.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "No Add Account button on the first-run screen")
        XCTAssertFalse(app.buttons["Sign in with Google"].exists, "Google sign-in is still offered")
        add.tap()

        let gmail = app.buttons["addAccount.gmail"]
        let yahoo = app.buttons["addAccount.yahoo"]
        let other = app.buttons["addAccount.manual"]
        XCTAssertTrue(gmail.waitForExistence(timeout: 10), "No Gmail choice")
        XCTAssertTrue(yahoo.exists && other.exists)
        XCTAssertFalse(app.buttons["addAccount.google"].exists, "Google is still a choice")
        XCTAssertLessThan(gmail.frame.minY, yahoo.frame.minY, "Gmail should come first")
        XCTAssertLessThan(yahoo.frame.minY, other.frame.minY, "Yahoo Mail should come before Other mail account")
        XCTAssertTrue(gmail.label.hasPrefix("Gmail"))

        gmail.tap()
        XCTAssertTrue(app.descendants(matching: .any)["preset.twoStepLink"].waitForExistence(timeout: 5), "No 2-Step Verification step")
        XCTAssertTrue(app.descendants(matching: .any)["preset.appPasswordLink"].exists, "No link to create an app password")
        XCTAssertTrue(anyText(containing: "myaccount.google.com/apppasswords").exists)
    }

    /// An account signed in with Google in 1.0 keeps working once the option is hidden, and Add Account then
    /// offers no Google choice.
    func testGoogleAccountFromVersionOneKeepsWorking() {
        launch()
        signInAndWaitForInbox()
        app.terminate()

        launch(reset: false, googleSignIn: false)
        XCTAssertTrue(row("Dinner on Friday?").waitForExistence(timeout: 20), "The Google account's inbox did not load")
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.elena)"), "The Google token was lost: \(keychain)")
        openFolders()
        app.buttons["Add account"].tap()
        XCTAssertTrue(app.buttons["addAccount.gmail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["addAccount.google"].exists, "Google is still a choice")
    }
}
