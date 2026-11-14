import XCTest

final class MacMailboxUITests: MacUITestCase {
    func testSignInShowsThreeColumnsAndLabels() {
        launch()
        XCTAssertTrue(app.staticTexts["Open-source Gmail, private by design."].waitForExistence(timeout: 15), "Expected a fresh install")
        signInAndWaitForInbox()
        waitForLog("GET /profile account=\(Self.elena)")
        for subject in ["Your ferry tickets: Piraeus to Naxos", "Photos from the weekend", "Confidential: contract draft"] {
            XCTAssertTrue(row(subject).exists, "Missing \(subject)")
        }
        XCTAssertFalse(row("Repair request").exists, "Sent-only mail must not be in the inbox")
        XCTAssertTrue(sidebar("INBOX").exists)
        XCTAssertTrue(sidebar("Label_1").waitForExistence(timeout: 10), "Travel label missing from the sidebar")
        XCTAssertTrue(anyText(containing: "No Conversation Selected").exists, "Detail column should be empty until a selection")
        XCTAssertTrue(keychain.contains("oauth.refresh.\(Self.elena)"), "Refresh token not stored: \(keychain)")
    }

    func testOpenThreadSearchAndSwitchLabel() {
        launch()
        signInAndWaitForInbox()

        select("Your ferry tickets: Piraeus to Naxos")
        waitForLog("GET /threads/", "account=\(Self.elena)")
        XCTAssertTrue(anyText(containing: "Boarding passes.pdf").waitForExistence(timeout: 15), "Attachment not listed")
        XCTAssertTrue(anyText(containing: "gate E7").waitForExistence(timeout: 15), "Message body not shown")
        waitForLog("MODIFY thread=", "remove=UNREAD")

        // ⌘F puts the cursor in the toolbar search field.
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("naxos\r")
        waitForLog("LIST label=- q=naxos")
        waitUntil(10, "search results to replace the inbox") { !row("Photos from the weekend").exists }
        XCTAssertTrue(row("Your ferry tickets: Piraeus to Naxos").exists)
        // Typing E in the search field types, it does not archive.
        let start = logPosition
        search.typeText("e")
        XCTAssertTrue((search.value as? String ?? "").hasSuffix("e"), "E should type into the search field: \(search.value ?? "")")
        noLog("MODIFY", after: start)

        sidebar("Label_1").click()
        waitForLog("LIST label=Label_1")
        XCTAssertTrue(row("Hotel booking in Chania").waitForExistence(timeout: 10), "Archived Travel mail missing")

        sidebar("SENT").click()
        XCTAssertTrue(row("Repair request").waitForExistence(timeout: 10))
    }

    func testKeyboardShortcutsArchiveBinStarAndRead() {
        launch()
        signInAndWaitForInbox()

        // E archives and selects the next conversation down.
        select("Apartment viewing")
        var start = logPosition
        app.typeKey("e", modifierFlags: [])
        waitForLog("MODIFY thread=", "remove=INBOX", "account=\(Self.elena)", after: start)
        waitUntil(10, "archived thread to leave the inbox") { !row("Apartment viewing").exists }

        // ⌘⌫ moves to Bin.
        select("Your saved recipes")
        start = logPosition
        app.typeKey(.delete, modifierFlags: .command)
        waitForLog("TRASH thread=", "add=TRASH", after: start)
        waitUntil(10, "binned thread to leave the inbox") { !row("Your saved recipes").exists }

        // ⇧⌘L stars, ⇧⌘U toggles read.
        select("Route for Sunday")
        start = logPosition
        app.typeKey("l", modifierFlags: [.command, .shift])
        waitForLog("MODIFY thread=", "add=STARRED", after: start)
        start = logPosition
        app.typeKey("u", modifierFlags: [.command, .shift])
        waitForLog("MODIFY thread=", "add=UNREAD", after: start)

        // Archive and Bin from the menu bar too.
        select("Harvest volunteers needed")
        start = logPosition
        menu("Message", "Archive")
        waitForLog("MODIFY thread=", "remove=INBOX", after: start)

        sidebar("TRASH").click()
        XCTAssertTrue(row("Your saved recipes").waitForExistence(timeout: 10), "Binned thread is not in Bin")
    }

    func testOpenConversationInItsOwnWindow() {
        launch()
        signInAndWaitForInbox()
        select("Dinner on Friday?")
        let before = app.windows.count
        app.typeKey("o", modifierFlags: .command)
        waitUntil(10, "a second window") { app.windows.count > before }
        XCTAssertTrue(app.windows["Dinner on Friday?"].waitForExistence(timeout: 10), "No window titled with the subject")
    }

    func testPGPMailShowsAPlainPreviewInsteadOfArmour() {
        launch()
        signInAndWaitForInbox()
        XCTAssertTrue(anyText(containing: "Encrypted message").exists, "Encrypted row should say so")
        XCTAssertFalse(anyText(containing: "-----BEGIN PGP").exists, "Raw PGP armour shown in the list")
    }
}
