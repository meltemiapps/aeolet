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
        XCTAssertTrue(settings.popUpButtons.firstMatch.waitForExistence(timeout: 5), "Refresh interval missing")
        XCTAssertEqual(settings.popUpButtons.firstMatch.value as? String, "Every 5 minutes")
        XCTAssertTrue(settings.checkBoxes["Open at login"].exists || settings.switches["Open at login"].exists)
        XCTAssertTrue(settings.checkBoxes["Require Touch ID or password"].exists || settings.switches["Require Touch ID or password"].exists)
    }

    func testTwoAccountsAndSigningOutDeletesCredentialsAndCache() {
        launch()
        signInAndWaitForInbox()
        openSettings(tab: "Accounts")
        settings.buttons["Add Gmail Account"].click()
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
        waitUntil(15, "every credential to be deleted") { keychain.isEmpty && cacheFiles.values.allSatisfy { $0 == 0 } }
        XCTAssertTrue(app.buttons["Sign in with Google"].waitForExistence(timeout: 10))
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
