import XCTest

/// Captures the inbox, a thread, compose and Settings from the mock run. Run with animations on for natural rendering.
final class ScreenshotUITests: AeoletUITestCase {
    func testCaptureScreenshots() {
        launch(animations: true)
        signInAndWaitForInbox()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        save(app.screenshot(), as: "1-Inbox")

        open("Dinner on Friday?")
        XCTAssertTrue(anyText(containing: "Booked a table").waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        save(app.screenshot(), as: "2-Thread")
        goBack()

        app.buttons["New message"].tap()
        type("Sofia Papadaki <sofia@example.org>", into: app.textFields["To"])
        type("Weekend in Hydra", into: app.textFields["Subject"])
        type("Hi Sofia,\n\nThe early ferry leaves Piraeus at 8:00. Shall we meet at the gate?\n\nElena", into: app.textViews.firstMatch)
        app.buttons["Attach file"].tap()
        app.textViews.firstMatch.tap()
        app.buttons["Hide keyboard"].firstMatch.tap()
        waitUntil(5, "the keyboard to go away") { app.keyboards.count == 0 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app.screenshot(), as: "3-Compose")
        tapByPosition(app.buttons["Close"])
        tapByPosition(app.buttons["Discard"])

        openSettings()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        save(app.screenshot(), as: "4-Settings")
    }
}
