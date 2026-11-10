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
        // Signing out the account on screen switches to the remaining one, which closes Settings.
        if app.navigationBars["Settings"].exists { app.buttons["Done"].tap() }

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
}
