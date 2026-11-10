import XCTest

final class MailboxUITests: AeoletUITestCase {
    func testSignInLoadsInboxAndPullToRefreshFetchesNewMail() throws {
        launch()
        XCTAssertTrue(app.staticTexts["Open-source Gmail, private by design."].waitForExistence(timeout: 10), "Expected a fresh install")
        signInAndWaitForInbox()

        waitForLog("GET /profile account=\(Self.elena)")
        XCTAssertTrue(app.navigationBars["Inbox"].exists)
        for subject in ["Your ferry tickets: Piraeus to Naxos", "Photos from the weekend", "Confidential: contract draft"] {
            XCTAssertTrue(row(subject).exists, "Missing \(subject)")
        }
        XCTAssertFalse(row("Repair request").exists, "Sent-only mail must not be in the inbox")
        XCTAssertFalse(row("Last month's newsletter").exists, "Binned mail must not be in the inbox")
        XCTAssertFalse(row("Ferry delayed by 20 minutes").exists)

        // XCUITest's synthetic drags don't trigger the refresh control on iPad, although a real swipe does
        // (checked by hand in the iPad Simulator). The gesture is covered on iPhone.
        if UIDevice.current.userInterfaceIdiom == .pad {
            throw XCTSkip("Pull to refresh can't be driven by XCUITest on iPad; covered on iPhone.")
        }
        let before = logPosition
        pullToRefresh()
        waitForLog("LIST label=INBOX", "account=\(Self.elena)", after: before)
        XCTAssertTrue(row("Ferry delayed by 20 minutes").waitForExistence(timeout: 15), "Pull to refresh did not show new mail")
    }

    func testOpenThreadSearchAndSwitchLabel() {
        launch()
        signInAndWaitForInbox()

        open("Your ferry tickets: Piraeus to Naxos")
        waitForLog("GET /threads/", "account=\(Self.elena)")
        XCTAssertTrue(anyText(containing: "Boarding passes.pdf").waitForExistence(timeout: 15), "Attachment not listed")
        XCTAssertTrue(anyText(containing: "gate E7").waitForExistence(timeout: 15), "Message body not shown")
        goBack()

        let search = app.searchFields["Search mail"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("naxos\n")
        waitForLog("LIST label=- q=naxos")
        XCTAssertTrue(row("Your ferry tickets: Piraeus to Naxos").waitForExistence(timeout: 10))
        waitUntil(10, "search results to replace the inbox") { !row("Photos from the weekend").exists }
        clearSearch()
        XCTAssertTrue(row("Photos from the weekend").waitForExistence(timeout: 15), "Clearing search did not restore the inbox")

        showLabel("Travel")
        waitForLog("LIST label=Label_1")
        XCTAssertTrue(row("Hotel booking in Chania").waitForExistence(timeout: 10), "Archived Travel mail missing")
        XCTAssertFalse(row("Photos from the weekend").exists)

        showLabel("Sent")
        XCTAssertTrue(row("Repair request").waitForExistence(timeout: 10))

        showLabel("Starred")
        XCTAssertTrue(row("Passport renewal appointment").waitForExistence(timeout: 10))
    }

    func testArchiveStarLabelReadUnreadAndBin() {
        launch()
        signInAndWaitForInbox()

        // Archive
        var start = logPosition
        revealActions(on: scrollTo("Apartment viewing"), leading: false)
        app.buttons["Archive"].tap()
        waitForLog("MODIFY thread=", "remove=INBOX", "account=\(Self.elena)", after: start)
        waitUntil(10, "archived thread to leave the inbox") { !row("Apartment viewing").exists }

        // Star
        start = logPosition
        revealActions(on: scrollTo("Route for Sunday"), leading: true)
        app.buttons["Star"].tap()
        waitForLog("MODIFY thread=", "add=STARRED", after: start)

        // Read, then unread
        start = logPosition
        revealActions(on: scrollTo("Harvest volunteers needed"), leading: true)
        app.buttons["Read"].tap()
        waitForLog("MODIFY thread=", "remove=UNREAD", after: start)
        start = logPosition
        revealActions(on: scrollTo("Harvest volunteers needed"), leading: true)
        app.buttons["Unread"].tap()
        waitForLog("MODIFY thread=", "add=UNREAD", after: start)

        // Apply and remove a label from inside a thread
        open("Workshop materials")
        let labels = app.buttons["Labels"]
        XCTAssertTrue(labels.waitForExistence(timeout: 10))
        start = logPosition
        labels.tap()
        app.buttons["Travel"].tap()
        waitForLog("MODIFY thread=", "add=Label_1", after: start)
        start = logPosition
        labels.tap()
        app.buttons["Travel"].tap()
        waitForLog("MODIFY thread=", "remove=Label_1", after: start)
        goBack()

        // Move to Bin, then find it in Bin
        start = logPosition
        revealActions(on: scrollTo("Your saved recipes"), leading: false)
        app.buttons["Bin"].tap()
        waitForLog("TRASH thread=", "add=TRASH", after: start)
        waitUntil(10, "binned thread to leave the inbox") { !row("Your saved recipes").exists }
        showLabel("Bin")
        XCTAssertTrue(row("Your saved recipes").waitForExistence(timeout: 10), "Binned thread is not in Bin")
        XCTAssertTrue(row("Last month's newsletter").exists, "Bin should list earlier binned mail too")

        // Archived and starred threads show up where Gmail would put them
        showLabel("Starred")
        XCTAssertTrue(row("Route for Sunday").waitForExistence(timeout: 10))
    }
}
