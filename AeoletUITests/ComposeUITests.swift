import XCTest

/// Each test checks the exact message the app uploaded to the mock Gmail server.
final class ComposeUITests: AeoletUITestCase {
    private func send() {
        let button = app.buttons["Send"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func field(_ placeholder: String) -> XCUIElement { app.textFields[placeholder] }

    func testNewMessageWithAttachment() {
        launch()
        signInAndWaitForInbox()
        app.buttons["New message"].tap()
        type("sofia@example.org", into: field("To"))
        type("Weekend plans", into: field("Subject"))
        type("Shall we take the early ferry on Saturday?", into: app.textViews.firstMatch)
        app.buttons["Attach file"].tap()
        XCTAssertTrue(anyText(containing: "Itinerary.pdf").waitForExistence(timeout: 5))
        let start = logPosition
        send()

        let sent = waitForLog("SEND from=\(Self.elena)", after: start)
        XCTAssertTrue(sent.contains("to=sofia@example.org |"), sent)
        XCTAssertTrue(sent.contains("cc= |"), sent)
        XCTAssertTrue(sent.contains("subject=Weekend plans |"), sent)
        XCTAssertTrue(sent.contains("inReplyTo= |"), sent)
        XCTAssertTrue(sent.contains("threadId= |"), sent)
        XCTAssertTrue(sent.contains("attachments=Itinerary.pdf |"), sent)
        XCTAssertTrue(sent.hasSuffix("pgp=none"), sent)
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 10), "Compose sheet did not close after sending")
    }

    func testReplyReplyAllAndForward() {
        launch()
        signInAndWaitForInbox()

        // Reply goes to the sender only, in the same thread.
        open("Dinner on Friday?")
        XCTAssertTrue(app.buttons["All"].waitForExistence(timeout: 15))
        app.toolbars.buttons["Reply"].tap()
        XCTAssertEqual(field("Subject").value as? String, "Re: Dinner on Friday?")
        type("Sounds perfect, see you there. ", into: app.textViews.firstMatch)
        var start = logPosition
        send()
        let reply = waitForLog("SEND from=\(Self.elena)", "subject=Re: Dinner on Friday?", after: start)
        XCTAssertTrue(reply.contains("to=\"Nikos Andreou\" <nikos@example.com> |"), reply)
        XCTAssertTrue(reply.contains("cc= |"), reply)
        XCTAssertFalse(reply.contains("inReplyTo= |"), "Reply must carry In-Reply-To: \(reply)")
        XCTAssertFalse(reply.contains("threadId= |"), "Reply must stay in the thread: \(reply)")
        waitForLog("DELIVER to=\(Self.nikos)", after: start)

        // Reply all copies everyone except me.
        app.buttons.matching(identifier: "All").allElementsBoundByIndex.last!.tap()
        let cc = field("Cc")
        XCTAssertTrue(cc.waitForExistence(timeout: 10))
        let ccValue = cc.value as? String ?? ""
        XCTAssertTrue(ccValue.contains("sofia@example.org") && ccValue.contains("maria@example.org"), ccValue)
        XCTAssertFalse(ccValue.contains(Self.elena), "Reply all must not copy me: \(ccValue)")
        start = logPosition
        send()
        let replyAll = waitForLog("SEND from=\(Self.elena)", "subject=Re: Dinner on Friday?", after: start)
        XCTAssertTrue(replyAll.contains("nikos@example.com"), replyAll)
        XCTAssertTrue(replyAll.contains("sofia@example.org") && replyAll.contains("maria@example.org"), replyAll)
        XCTAssertFalse(replyAll.contains("inReplyTo= |"), replyAll)
        goBack()

        // Forward carries the attachment and starts a new thread.
        open("Your ferry tickets: Piraeus to Naxos")
        let forward = app.buttons["Forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 15))
        forward.tap()
        XCTAssertEqual(field("Subject").value as? String, "Fwd: Your ferry tickets: Piraeus to Naxos")
        XCTAssertTrue(anyText(containing: "Boarding passes.pdf").waitForExistence(timeout: 15), "Forward did not include the attachment")
        type("yannis@example.org", into: field("To"))
        start = logPosition
        send()
        let forwarded = waitForLog("SEND from=\(Self.elena)", "subject=Fwd: Your ferry tickets", after: start)
        XCTAssertTrue(forwarded.contains("to=yannis@example.org |"), forwarded)
        XCTAssertTrue(forwarded.contains("attachments=Boarding passes.pdf |"), forwarded)
        XCTAssertTrue(forwarded.contains("inReplyTo= |"), forwarded)
        XCTAssertTrue(forwarded.contains("threadId= |"), forwarded)
    }
}
