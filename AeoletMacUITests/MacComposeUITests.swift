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
        let save = app.buttons["Save Draft"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Closing a message with content should ask about a draft")
        let start = logPosition
        save.click()
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
        let chip = app.descendants(matching: .any)["attachment-Boarding passes.pdf"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))

        // Save Attachment… writes the file where the person chooses (the mock answers the Save panel).
        var start = logPosition
        chip.menuButtons.firstMatch.click()
        app.menuItems["Save Attachment…"].click()
        waitForLog("SAVE attachment=Boarding passes.pdf", after: start)

        // Drag the attachment into a new message.
        app.typeKey("n", modifierFlags: .command)
        waitForCompose()
        start = logPosition
        chip.press(forDuration: 0.6, thenDragTo: compose.textViews["compose-body"])
        waitForLog("ATTACH file=Boarding passes.pdf", after: start)
        XCTAssertTrue(compose.descendants(matching: .any)["outgoing-Boarding passes.pdf"].waitForExistence(timeout: 5))
    }
}
