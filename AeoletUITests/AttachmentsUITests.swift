import XCTest

/// Attaching photos and files in Compose, Gmail's 25 MB limit, and previewing, saving and sharing received attachments.
/// Mock runs pick fixture photos and files through the same code the system pickers feed; the last test opens the real pickers.
final class AttachmentsUITests: AeoletUITestCase {
    private func startMessage(to recipient: String = "sofia@example.org", subject: String) {
        app.buttons["New message"].tap()
        type(recipient, into: app.textFields["To"])
        type(subject, into: app.textFields["Subject"])
    }

    private func send() {
        let button = app.buttons["Send"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    /// The ATTACHMENT lines the mock server logged for the latest message sent after `start`.
    private func sentAttachments(after start: Int) -> [String] {
        waitForLog("SEND account=\(Self.elena)", after: start, timeout: 60)
        waitForLog("ATTACHMENT", after: start)
        // The server logs one line per attachment; give the probe a moment to show them all.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        return log.filter { Self.number(ofLogLine: $0) > start && $0.contains("ATTACHMENT") }
    }

    /// Checks the running total under the attachments, scrolling to it: attachments or the keyboard can push it off screen.
    private func assertTotal(_ used: String, file: StaticString = #filePath, line: UInt = #line) {
        hideKeyboard(file: file, line: line)
        let pattern = "^Attachments total " + used.replacingOccurrences(of: " ", with: "[ \\u00a0]") + " of 25[ \\u00a0]MB$"
        let total = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", pattern)).firstMatch
        XCTAssertTrue(reveal(total), "No attachments total matching \(pattern)", file: file, line: line)
    }

    /// A Compose row showing this name and size. Sizes may be written with a non-breaking space.
    private func attachmentRow(_ name: String, size: String) -> XCUIElement {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: name) + ", " + size.replacingOccurrences(of: " ", with: "[ \\u00a0]") + "$"
        return app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", pattern)).firstMatch
    }

    /// Brings a Compose element into view. On iPad the sheet is small and the keyboard covers its lower half,
    /// so rows further down are not even created until the keyboard is away and the form is scrolled.
    @discardableResult
    private func reveal(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }
        hideKeyboard()
        let deadline = Date().addingTimeInterval(timeout)
        while !element.exists && Date() < deadline {
            app.swipeUp(velocity: .slow)
            _ = element.waitForExistence(timeout: 1)
        }
        return element.exists
    }

    private func attachmentRow(_ name: String) -> XCUIElement {
        // The whole row, read as "name, size".
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name + ", ")).firstMatch
    }

    func testPhotoLibraryConvertsHEICToJPEGAndRemovesLocation() {
        launch()
        signInAndWaitForInbox()
        startMessage(subject: "Photos from Hydra")
        attach("Photo Library")
        // Several photos at once, each shown with its size.
        XCTAssertTrue(reveal(attachmentRow("Harbour.jpg", size: "\\d+ KB")), "HEIC photo was not added as JPEG with its size")
        XCTAssertTrue(reveal(attachmentRow("Terrace.jpg")), "Second photo was not added")
        assertTotal("\\S+ KB")

        let start = logPosition
        send()
        let sent = sentAttachments(after: start)
        XCTAssertEqual(sent.count, 2, sent.joined(separator: "\n"))
        XCTAssertTrue(sent.contains { $0.contains("name=Harbour.jpg type=image/jpeg") && $0.hasSuffix("location=no") }, sent.joined(separator: "\n"))
        XCTAssertTrue(sent.contains { $0.contains("name=Terrace.jpg type=image/jpeg") && $0.hasSuffix("location=no") }, sent.joined(separator: "\n"))
    }

    func testKeepPhotoOriginalsSendsHEICWithLocation() {
        launch(environment: ["AEOLET_MOCK_PHOTOS": "harbour"])
        signInAndWaitForInbox()
        openSettings()
        XCTAssertTrue(anyText(containing: "location they were taken removed").exists, "Default should remove location")
        setSwitch("Keep photo originals", on: true)
        XCTAssertTrue(anyText(containing: "including HEIC format").exists)
        app.navigationBars["Settings"].buttons["Done"].tap()

        startMessage(subject: "Original photo")
        attach("Photo Library")
        XCTAssertTrue(attachmentRow("Harbour.heic").waitForExistence(timeout: 10), "Original HEIC was not kept")
        let start = logPosition
        send()
        let sent = sentAttachments(after: start)
        XCTAssertEqual(sent.count, 1, sent.joined(separator: "\n"))
        XCTAssertTrue(sent[0].contains("name=Harbour.heic type=image/heic") && sent[0].hasSuffix("location=yes"), sent[0])
    }

    func testFilesAttachesAnyTypeWithSizes() {
        launch(environment: ["AEOLET_MOCK_FILES": "Itinerary.pdf,Notes.txt,Model.xyzzy:1500000"])
        signInAndWaitForInbox()
        startMessage(subject: "Files for the trip")
        attach("Files")
        XCTAssertTrue(reveal(attachmentRow("Itinerary.pdf")))
        XCTAssertTrue(reveal(attachmentRow("Notes.txt")))
        XCTAssertTrue(reveal(attachmentRow("Model.xyzzy", size: "1.5 MB")), "No size shown for Model.xyzzy")
        assertTotal("\\S+ MB")

        let start = logPosition
        send()
        let sent = sentAttachments(after: start)
        XCTAssertEqual(sent.count, 3, sent.joined(separator: "\n"))
        XCTAssertTrue(sent.contains { $0.contains("name=Itinerary.pdf type=application/pdf") }, sent.joined(separator: "\n"))
        XCTAssertTrue(sent.contains { $0.contains("name=Notes.txt type=text/plain") }, sent.joined(separator: "\n"))
        // An unknown type goes out as generic binary data, at its full size.
        XCTAssertTrue(sent.contains { $0.contains("name=Model.xyzzy type=application/octet-stream bytes=1500000") }, sent.joined(separator: "\n"))
    }

    func testAttachmentsOver25MBAreRefusedWithAClearMessage() {
        launch(environment: ["AEOLET_MOCK_FILES": "Survey.mov:20000000,Drone footage.mov:9000000"])
        signInAndWaitForInbox()
        startMessage(subject: "Site survey")
        attach("Files")
        let alert = app.alerts["Attachments"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "No message about the size limit")
        let message = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "25 MB")).firstMatch
        XCTAssertTrue(message.exists, "Alert does not mention the limit")
        XCTAssertTrue(message.label.contains("Drone footage.mov"), message.label)
        XCTAssertTrue(message.label.contains("5 MB left"), message.label)
        save(app.screenshot(), as: "Attachment limit")
        alert.buttons["OK"].tap()

        // The file that fits stays attached; the one that didn't is not.
        XCTAssertTrue(reveal(attachmentRow("Survey.mov", size: "20 MB")))
        XCTAssertFalse(attachmentRow("Drone footage.mov").exists)
        assertTotal("20 MB")
    }

    func testReceivedAttachmentPreviewSaveToFilesAndShare() {
        launch()
        signInAndWaitForInbox()
        open("Your ferry tickets: Piraeus to Naxos")
        let options = app.buttons["Options for Boarding passes.pdf"]
        XCTAssertTrue(options.waitForExistence(timeout: 15), "No options for the attachment")

        // Quick Look preview.
        options.tap()
        app.buttons["Preview"].tap()
        let done = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "Quick Look did not open")
        XCTAssertTrue(anyText(containing: "Boarding passes").exists)
        tapUntilGone(done)
        XCTAssertTrue(options.waitForExistence(timeout: 10))

        // Save to Files: the system's export picker, saving into On My iPhone/iPad.
        var start = logPosition
        openOption("Save to Files", on: options)
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR label == 'Move'")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 20), "Save to Files did not open")
        waitUntil(10, "the Save button to be enabled") { save.isEnabled }
        // Saving again over an earlier test's copy asks whether to replace it.
        let replace = app.buttons["Replace"]
        for _ in 0..<4 where !log.contains(where: { Self.number(ofLogLine: $0) > start && $0.contains("EXPORT") }) {
            if replace.exists { replace.tap() } else if save.exists && save.isHittable { save.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(3))
        }
        waitForLog("EXPORT file=Boarding passes.pdf saved=true", after: start, timeout: 30)

        // The share sheet.
        start = logPosition
        openOption("Share", on: options)
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "Share sheet did not open")
        XCTAssertTrue(anyText(containing: "Boarding passes").exists, "Share sheet is not sharing the attachment")
        // Close it without sharing: tap outside where it's a popover, otherwise swipe it down.
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists {
            outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        } else {
            sheet.swipeDown(velocity: .fast)
        }
        waitForLog("SHARE file=Boarding passes.pdf completed=false", after: start)
    }

    private func openOption(_ name: String, on menu: XCUIElement) {
        let item = app.buttons[name]
        for _ in 0..<3 where !item.exists {
            menu.tap()
            _ = item.waitForExistence(timeout: 3)
        }
        item.tap()
    }

    /// Taps until the button goes away; a tap can land while a system sheet is still settling.
    private func tapUntilGone(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<4 where button.exists {
            if button.isHittable { button.tap() }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && button.exists { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        XCTAssertFalse(button.exists, "\(button) did not go away", file: file, line: line)
    }

    /// The real pickers: both open straight away, with no request for photo library access,
    /// and photos picked from the Simulator's sample library arrive as JPEG.
    func testRealPickersOpenWithoutAPermissionPrompt() {
        launch(arguments: ["-AeoletRealPickers"])
        signInAndWaitForInbox()
        startMessage(subject: "Real pickers")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        attach("Photo Library")
        let collections = app.buttons["Collections"]
        XCTAssertTrue(collections.waitForExistence(timeout: 20), "Photo picker did not open")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "A permission prompt appeared")
        XCTAssertFalse(app.alerts.firstMatch.exists, "A permission prompt appeared")
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        if photos.count >= 2 {
            photos.element(boundBy: 0).tap()
            photos.element(boundBy: 1).tap()
            let done = app.buttons["Done"]
            waitUntil(10, "the picker's Done button to enable") { done.isEnabled }
            tapUntilGone(done)
            // Sample photos are large, so check what reached the server rather than rows that may be off screen.
            XCTAssertTrue(reveal(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '.jpg, '")).firstMatch, timeout: 20),
                          "Picked photos were not attached")
            let start = logPosition
            send()
            let sent = sentAttachments(after: start)
            XCTAssertEqual(sent.count, 2, sent.joined(separator: "\n"))
            XCTAssertTrue(sent.allSatisfy { $0.contains("type=image/jpeg") && $0.hasSuffix("location=no") }, sent.joined(separator: "\n"))
            startMessage(subject: "Real files picker")
        } else {
            // A Simulator without sample photos: just close the picker.
            tapUntilGone(app.buttons["Cancel"])
        }
        XCTAssertTrue(app.buttons["Attach"].waitForExistence(timeout: 10))

        attach("Files")
        // iPhone shows Recents and Browse tabs; iPad shows a sidebar of locations.
        let browse = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN {'Browse', 'Recents', 'Shared', 'Locations', 'On My iPad', 'On My iPhone'}")).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 20), "Document picker did not open")
        tapUntilGone(app.buttons["Cancel"].firstMatch)
        XCTAssertTrue(app.buttons["Attach"].waitForExistence(timeout: 10))
    }
}
