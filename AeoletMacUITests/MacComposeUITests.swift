import XCTest

/// Compose runs in its own window. Each test checks the exact message the app uploaded to the mock Gmail server.
final class MacComposeUITests: MacUITestCase {
    private func field(_ id: String) -> XCUIElement { compose.textFields[id] }

    private func waitForCompose(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "No compose window", file: file, line: line)
    }

    func testNewMessageInItsOwnWindowWithAttachment() {
        launch()
        signInAndWaitForInbox()
        let windows = app.windows.count
        app.typeKey("n", modifierFlags: .command)
        waitForCompose()
        XCTAssertEqual(app.windows.count, windows + 1, "Compose should open a new window")
        type("sofia@example.org", into: field("compose-to"))
        type("Weekend plans", into: field("compose-subject"))
        type("Shall we take the early ferry on Saturday?", into: compose.textViews["compose-body"])
        app.typeKey("a", modifierFlags: [.command, .shift])
        XCTAssertTrue(compose.descendants(matching: .any)["outgoing-Itinerary.pdf"].waitForExistence(timeout: 5))
        let start = logPosition
        app.typeKey("d", modifierFlags: [.command, .shift])

        let sent = waitForLog("SEND account=\(Self.elena)", after: start)
        XCTAssertTrue(sent.contains("from=Elena Marinou <elena@example.com> |"), sent)
        XCTAssertTrue(sent.contains("to=sofia@example.org |"), sent)
        XCTAssertTrue(sent.contains("subject=Weekend plans |"), sent)
        XCTAssertTrue(sent.contains("attachments=Itinerary.pdf |"), sent)
        XCTAssertTrue(sent.hasSuffix("pgp=none"), sent)
        waitUntil(10, "the compose window to close after sending") { !compose.exists }
    }

    func testReplyReplyAllAndForwardShortcuts() {
        launch()
        signInAndWaitForInbox()
        select("Dinner on Friday?")
        XCTAssertTrue(anyText(containing: "Booked a table").waitForExistence(timeout: 15))

        // ⌘R replies to the sender, in the same thread.
        app.typeKey("r", modifierFlags: .command)
        waitForCompose()
        XCTAssertEqual(field("compose-subject").value as? String, "Re: Dinner on Friday?")
        var start = logPosition
        app.typeKey("d", modifierFlags: [.command, .shift])
        let reply = waitForLog("SEND account=\(Self.elena)", "subject=Re: Dinner on Friday?", after: start)
        XCTAssertTrue(reply.contains("to=Nikos Andreou <nikos@example.com> |"), reply)
        XCTAssertFalse(reply.contains("inReplyTo= |"), "Reply must carry In-Reply-To: \(reply)")
        XCTAssertFalse(reply.contains("threadId= |"), "Reply must stay in the thread: \(reply)")
        waitUntil(10, "the reply window to close") { !compose.exists }

        // ⇧⌘R copies everyone except me.
        mainWindow.click()
        app.typeKey("r", modifierFlags: [.command, .shift])
        waitForCompose()
        XCTAssertFalse((field("compose-cc").value as? String ?? "").contains(Self.elena), "Reply all must not copy me")
        start = logPosition
        app.typeKey("d", modifierFlags: [.command, .shift])
        waitForLog("SEND account=\(Self.elena)", "subject=Re: Dinner on Friday?", after: start)
        waitUntil(10, "the reply-all window to close") { !compose.exists }

        // ⇧⌘F forwards, with a Fwd: subject.
        select("Your ferry tickets: Piraeus to Naxos")
        XCTAssertTrue(anyText(containing: "Boarding passes.pdf").waitForExistence(timeout: 15))
        app.typeKey("f", modifierFlags: [.command, .shift])
        waitForCompose()
        XCTAssertEqual(field("compose-subject").value as? String, "Fwd: Your ferry tickets: Piraeus to Naxos")
        XCTAssertTrue(compose.descendants(matching: .any)["outgoing-Boarding passes.pdf"].waitForExistence(timeout: 10),
                      "Forward should carry the attachment")
        type("sofia@example.org", into: field("compose-to"))
        start = logPosition
        app.typeKey("d", modifierFlags: [.command, .shift])
        let forward = waitForLog("SEND account=\(Self.elena)", "subject=Fwd: Your ferry tickets", after: start)
        XCTAssertTrue(forward.contains("attachments=Boarding passes.pdf"), forward)
    }

    func testClosingAsksToSaveADraft() {
        launch()
        signInAndWaitForInbox()
        app.typeKey("n", modifierFlags: .command)
        waitForCompose()
        type("A thought for later", into: field("compose-subject"))
        app.typeKey("w", modifierFlags: .command)
        let start = logPosition
        clickDialogButton("Save Draft")
        waitForLog("DRAFT account=\(Self.elena)", "subject=A thought for later", after: start)
        waitUntil(10, "the compose window to close") { !compose.exists }

        // An empty message closes without asking.
        app.typeKey("n", modifierFlags: .command)
        waitForCompose()
        app.typeKey("w", modifierFlags: .command)
        waitUntil(10, "the empty compose window to close") { !compose.exists }
    }

    func testAttachmentSaveAndDragIntoAMessage() {
        launch(extra: ["-AeoletAutoSave"])
        signInAndWaitForInbox()
        select("Your ferry tickets: Piraeus to Naxos")
        let actions = element("attachment-actions-Boarding passes.pdf")
        XCTAssertTrue(actions.waitForExistence(timeout: 15))
        let chip = app.staticTexts.matching(NSPredicate(format: "value == %@", "Boarding passes.pdf")).firstMatch

        // Save Attachment… writes the file where the person chooses (the mock answers the Save panel).
        var start = logPosition
        actions.click()
        app.menuItems["Save Attachment…"].click()
        waitForLog("SAVE attachment=Boarding passes.pdf", after: start)

        // Drag the attachment into a new message, with the message window moved clear of the attachment.
        app.typeKey("n", modifierFlags: .command)
        waitForCompose()
        let titleBar = compose.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let screenRight = XCUIScreen.main.screenshot().image.size.width
        titleBar.press(forDuration: 0.3, thenDragTo: titleBar.withOffset(CGVector(dx: screenRight - 40 - compose.frame.maxX, dy: 0)))
        start = logPosition
        let dropPoint = compose.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6))
        chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.8, thenDragTo: dropPoint)
        let attached = waitForLog("ATTACH file=", after: start)
        XCTAssertTrue(attached.contains(".pdf bytes="), "Dropped attachment should arrive as the PDF: \(attached)")
        XCTAssertFalse(attached.hasSuffix("bytes=0"), attached)
    }
}
