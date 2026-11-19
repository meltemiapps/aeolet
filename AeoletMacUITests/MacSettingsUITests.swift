import XCTest

final class MacSettingsUITests: MacUITestCase {
    

    private func openSettings(tab: String) {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "⌘, did not open Settings")
        settings.toolbars.buttons[tab].click()
    }

    func testSettingsShowsRefreshIntervalLockAndLogin() {
        launch()
        signInAndWaitForInbox()
        openSettings(tab: "General")
        let interval = element("refresh-interval", in: settings)
        XCTAssertTrue(interval.waitForExistence(timeout: 5), "Refresh interval missing")
        XCTAssertTrue("\(interval.value ?? "")".contains("5 minutes") || interval.label.contains("5 minutes") || anyText(containing: "Every 5 minutes").exists,
                      "Default interval should be 5 minutes")
        XCTAssertTrue(element("open-at-login", in: settings).exists, "Open at login missing")
        XCTAssertTrue(element("require-unlock", in: settings).exists, "Touch ID lock missing")
    }

    func testTwoAccountsAndSigningOutDeletesCredentialsAndCache() {
        launch()
        signInAndWaitForInbox()
        openSettings(tab: "Accounts")
        settings.buttons["Add Account…"].click()
        let google = app.buttons["addAccount.google"]
        XCTAssertTrue(google.waitForExistence(timeout: 10), "No Google choice in Add Account")
        google.click()
        waitForLog("TOKEN grant=authorization_code account=\(Self.nikos)")
        XCTAssertTrue(sidebar("INBOX", account: Self.nikos).waitForExistence(timeout: 15), "Second account missing from the sidebar")
        // Opening Nikos's inbox writes his cache.
        sidebar("INBOX", account: Self.nikos).click()
        waitForLog("LIST label=INBOX", "account=\(Self.nikos)")
        waitUntil(10, "both accounts to have cached mail") { (cacheFiles[Self.elena] ?? 0) > 0 && (cacheFiles[Self.nikos] ?? 0) > 0 }
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.nikos)"))

        openSettings(tab: "Accounts")
        settings.buttons.matching(identifier: "Sign Out…").element(boundBy: 1).click()
        let start = logPosition
        clickDialogButton("Sign Out")
        waitForLog("REVOKE", after: start)
        waitUntil(10, "Nikos's token to be deleted") { !keychain.contains("oauth.refresh.\(Self.nikos)") }
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.elena)"), "Elena must stay signed in")
        waitUntil(10, "Nikos's cache to be deleted") { cacheFiles[Self.nikos] == 0 }
        XCTAssertGreaterThan(cacheFiles[Self.elena] ?? 0, 0, "Elena's cache must stay")
        XCTAssertFalse(sidebar("INBOX", account: Self.nikos).exists)

        settings.buttons.matching(identifier: "Sign Out…").firstMatch.click()
        clickDialogButton("Sign Out")
        // Only the (now empty) account list stays in the Keychain, as on iOS.
        waitUntil(15, "every credential to be deleted") {
            !keychain.contains { $0.hasPrefix("oauth.refresh.") || $0.hasPrefix("pgp.private.") } && cacheFiles.values.allSatisfy { $0 == 0 }
        }
        XCTAssertTrue(app.buttons["Sign in with Google"].waitForExistence(timeout: 10))
    }

    /// 1.2 without Google sign-in: the first window has one Add Account button, the choices are Gmail, Yahoo Mail
    /// and Other mail account in that order, and the Gmail form explains how to get an app password.
    func testNewAccountsAreAddedWithoutGoogleSignIn() {
        launch(googleSignIn: false)
        let add = app.buttons["signIn.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "No Add Account button in the first window")
        XCTAssertFalse(app.buttons["Sign in with Google"].exists, "Google sign-in is still offered")
        add.click()

        let gmail = app.buttons["addAccount.gmail"]
        let yahoo = app.buttons["addAccount.yahoo"]
        let other = app.buttons["addAccount.manual"]
        XCTAssertTrue(gmail.waitForExistence(timeout: 10), "No Gmail choice")
        XCTAssertTrue(yahoo.exists && other.exists)
        XCTAssertFalse(app.buttons["addAccount.google"].exists, "Google is still a choice")
        XCTAssertLessThan(gmail.frame.minY, yahoo.frame.minY, "Gmail should come first")
        XCTAssertLessThan(yahoo.frame.minY, other.frame.minY, "Yahoo Mail should come before Other mail account")

        gmail.click()
        XCTAssertTrue(element("preset.twoStepLink").waitForExistence(timeout: 5), "No 2-Step Verification step")
        XCTAssertTrue(element("preset.appPasswordLink").exists, "No link to create an app password")
    }

    /// A build without a Google client ID opens normally and adds accounts with an app password or IMAP. With
    /// Google sign-in turned on, the Google option stays hidden and Settings says why.
    func testBuildWithoutGoogleClientIDOpensWithoutGoogleSignIn() {
        launch(extra: ["-AeoletNoGoogleClientID"])
        let add = app.buttons["signIn.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "No Add Account button in the first window")
        XCTAssertFalse(app.buttons["Sign in with Google"].exists, "Google sign-in offered without a client ID")
        add.click()
        XCTAssertTrue(app.buttons["addAccount.gmail"].waitForExistence(timeout: 10), "No Gmail choice")
        XCTAssertTrue(app.buttons["addAccount.yahoo"].exists && app.buttons["addAccount.manual"].exists)
        XCTAssertFalse(app.buttons["addAccount.google"].exists, "Google is a choice without a client ID")
        app.typeKey(.escape, modifierFlags: [])

        openSettings(tab: "Accounts")
        let note = element("settings.googleUnavailable")
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Settings doesn't say why Google sign-in is hidden")
    }

    /// With a client ID (the App Store build) and Google sign-in off, Settings shows no note.
    func testSettingsHasNoGoogleNoteWhenSignInIsOff() {
        launch(googleSignIn: false)
        openSettings(tab: "Accounts")
        XCTAssertTrue(settings.buttons["Add Account…"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("settings.googleUnavailable").exists, "Note shown although nothing is hidden")
    }
}

final class MacErrorUITests: MacUITestCase {
    func test403ShowsGooglesReason() {
        launch(fault: "403")
        signIn()
        waitForLog("FAULT 403")
        XCTAssertTrue(anyText(containing: "Gmail API has not been used in project").waitForExistence(timeout: 40))
        XCTAssertFalse(anyText(containing: "couldn't be read").exists, "Generic decoding error shown")
    }

    func testOfflineKeepsCachedMailAndReadsPlainly() {
        launch()
        signInAndWaitForInbox()
        app.terminate()

        launch(reset: false, fault: "offline")
        XCTAssertTrue(anyText(containing: "You're offline").waitForExistence(timeout: 20), "No offline message")
        XCTAssertTrue(row("Dinner on Friday?").exists, "Cached mail should stay readable offline")
        XCTAssertFalse(anyText(containing: "NSURLErrorDomain").exists, "Raw error code shown")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
