import XCTest

/// Each failure must show Google's own reason or name the missing field, never Foundation's generic decoding text.
final class ErrorUITests: AeoletUITestCase {
    private static let generic = "couldn't be read"

    private func assertInboxError(fault: String, expected: String, file: StaticString = #filePath, line: UInt = #line) {
        launch(fault: fault)
        signIn()
        waitForLog("FAULT \(fault)")
        let message = anyText(containing: expected)
        XCTAssertTrue(message.waitForExistence(timeout: 40), "Expected \"\(expected)\" for \(fault)", file: file, line: line)
        XCTAssertFalse(anyText(containing: Self.generic).exists, "Generic decoding error shown for \(fault)", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    func test401ShowsGooglesReason() {
        assertInboxError(fault: "401", expected: "Request had invalid authentication credentials")
        // The app refreshed its token once before giving up, as it should.
        XCTAssertTrue(log.contains { $0.contains("TOKEN grant=refresh_token") }, "\(log)")
    }

    func test403ShowsGooglesReason() {
        assertInboxError(fault: "403", expected: "Gmail API has not been used in project")
    }

    func test429ShowsGooglesReasonAfterRetrying() {
        assertInboxError(fault: "429", expected: "Too many concurrent requests for user.")
        XCTAssertGreaterThanOrEqual(log.filter { $0.contains("FAULT 429") }.count, 5, "Rate limits should be retried with backoff")
    }

    func test500ShowsGooglesReason() {
        assertInboxError(fault: "500", expected: "Backend Error")
    }

    func testMissingFieldIsNamed() {
        assertInboxError(fault: "missingField", expected: "Gmail returned an incomplete response (missing threads[0].id).")
    }

    func testOfflineShowsClearMessageAndDoesNotCrash() {
        launch()
        signInAndWaitForInbox()
        app.terminate()

        launch(reset: false, fault: "offline")
        let offline = anyText(containing: "offline")
        XCTAssertTrue(offline.waitForExistence(timeout: 20), "No offline message")
        XCTAssertFalse(anyText(containing: Self.generic).exists)
        XCTAssertTrue(row("Dinner on Friday?").exists, "Cached mail should stay readable offline")

        pullToRefresh()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(offline.exists)

        open("Dinner on Friday?")
        XCTAssertTrue(anyText(containing: "offline").waitForExistence(timeout: 20), "Opening a thread offline gave no message")
        app.buttons["New message"].exists ? () : goBack()
        XCTAssertEqual(app.state, .runningForeground, "App crashed while offline")
    }
}
