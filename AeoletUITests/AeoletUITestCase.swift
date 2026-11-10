import XCTest

/// Shared harness. Every test runs against the in-app mock Gmail server (-AeoletMockGmail), never a real account.
class AeoletUITestCase: XCTestCase {
    var app: XCUIApplication!

    static let elena = "elena@example.com"
    static let nikos = "nikos@example.com"
    static let passphrase = "correct horse battery"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, testRun?.hasSucceeded == false {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Failure \(name)"
            shot.lifetime = .keepAlways
            add(shot)
            let probe = XCTAttachment(string: probeValue)
            probe.name = "Mock probe at failure"
            probe.lifetime = .keepAlways
            add(probe)
        }
    }

    // MARK: Launching

    @discardableResult
    func launch(reset: Bool = true, fault: String? = nil, animations: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeoletMockGmail"]
        if reset { app.launchArguments.append("-AeoletResetState") }
        if !animations { app.launchArguments.append("-AeoletDisableAnimations") }
        if let fault { app.launchEnvironment["AEOLET_MOCK_FAULT"] = fault }
        app.launch()
        self.app = app
        return app
    }

    func signIn(expecting account: String = elena) {
        let button = app.buttons["Sign in with Google"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Sign-in screen did not appear")
        button.tap()
        waitForLog("TOKEN grant=authorization_code account=\(account)")
    }

    func signInAndWaitForInbox() {
        signIn()
        XCTAssertTrue(row("Dinner on Friday?").waitForExistence(timeout: 20), "Inbox did not load")
    }

    // MARK: Mock probe

    var probeValue: String {
        let element = app.descendants(matching: .any)["mock-probe"]
        guard element.exists else { return "{}" }
        return element.value as? String ?? "{}"
    }

    var probe: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(probeValue.utf8))) as? [String: Any] ?? [:]
    }

    /// The latest requests the mock received, each prefixed "#<number> ".
    var log: [String] { probe["log"] as? [String] ?? [] }
    /// Number of the latest request, for "anything after this point" checks.
    var logPosition: Int { probe["seq"] as? Int ?? 0 }

    private static func number(of line: String) -> Int {
        Int(line.dropFirst().prefix { $0.isNumber }) ?? 0
    }
    var keychain: [String] { probe["keychain"] as? [String] ?? [] }
    var cacheFiles: [String: Int] { probe["cacheFiles"] as? [String: Int] ?? [:] }

    /// Waits until a request matching every fragment has reached the mock server, and returns its log line.
    @discardableResult
    func waitForLog(_ fragments: String..., after start: Int = 0, timeout: TimeInterval = 20,
                    file: StaticString = #filePath, line: UInt = #line) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = log.last(where: { entry in Self.number(of: entry) > start && fragments.allSatisfy { entry.contains($0) } }) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        XCTFail("No mock request containing \(fragments). Log:\n\(log.suffix(25).joined(separator: "\n"))", file: file, line: line)
        return ""
    }

    func waitUntil(_ timeout: TimeInterval = 15, _ description: String, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    // MARK: Finding things

    /// The list row for a thread, found by its subject. Rows read "Sender, time, Subject, snippet".
    func row(_ subject: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label ENDSWITH %@", ", \(subject), ", ", \(subject)")).firstMatch
    }

    /// Scrolls the mailbox until the thread's row is on screen.
    @discardableResult
    func scrollTo(_ subject: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = row(subject)
        let list = app.collectionViews.firstMatch
        var attempts = 0
        // Rows half hidden under the navigation bar or a floating search bar don't count as reachable.
        // iPhone puts search at the bottom, iPad in the top bar, so measure both bars rather than guess.
        let screen = app.windows.firstMatch.frame
        let navigation = app.navigationBars.firstMatch
        let search = app.searchFields.firstMatch
        let top = navigation.exists ? navigation.frame.maxY - 4 : screen.minY + 60
        let bottom = search.exists && search.frame.minY > screen.midY ? search.frame.minY - 8 : screen.maxY - 30
        func clear() -> Bool {
            guard target.exists, target.isHittable else { return false }
            return target.frame.minY >= top && target.frame.maxY <= bottom
        }
        // Look further down first, then back up, so it works wherever the list is scrolled to.
        while !clear() && attempts < 16 {
            if target.exists && target.frame.maxY > bottom && target.frame.minY < screen.maxY {
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)))
            } else if attempts < 6 {
                list.swipeUp(velocity: .slow)
            } else {
                list.swipeDown(velocity: .slow)
            }
            attempts += 1
        }
        XCTAssertTrue(clear(), "Could not find \"\(subject)\" in the list", file: file, line: line)
        return target
    }

    func anyText(containing fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment)).firstMatch
    }

    func open(_ subject: String) {
        _ = row(subject).waitForExistence(timeout: 15)
        scrollTo(subject).tap()
    }

    func clearSearch() {
        let search = app.searchFields["Search mail"]
        if search.buttons["Clear text"].exists { search.buttons["Clear text"].tap() }
        if app.buttons["close"].exists { app.buttons["close"].tap() }
    }

    func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Short drag that reveals swipe actions without triggering the full-swipe action.
    func revealActions(on cell: XCUIElement, leading: Bool) {
        let start = cell.coordinate(withNormalizedOffset: CGVector(dx: leading ? 0.2 : 0.8, dy: 0.5))
        let end = start.withOffset(CGVector(dx: leading ? 170 : -170, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// A slow pull from the first row, held at the bottom, the way a person pulls to refresh.
    func pullToRefresh() {
        let list = app.collectionViews.firstMatch
        let firstRow = list.cells.firstMatch
        let start = (firstRow.exists ? firstRow : list).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 450)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    // MARK: Screens

    func openFolders() {
        app.buttons["Folders and accounts"].tap()
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 10))
    }

    func showLabel(_ name: String) {
        openFolders()
        // Folder rows read "Travel" or "Travel, 2" when there is unread mail.
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ","))
        let target = candidates.allElementsBoundByIndex.first { $0.isHittable } ?? candidates.firstMatch
        target.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "Did not switch to \(name)")
    }

    func openSettings() {
        openFolders()
        app.navigationBars["Mailboxes"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    func switchAccount(to account: String) {
        openFolders()
        let start = logPosition
        accountRow(account).tap()
        waitForLog("LIST label=INBOX", "account=\(account)", after: start)
    }

    /// An account row in the folder sheet. Searched only inside that sheet, because mail rows mention addresses too.
    func accountRow(_ account: String) -> XCUIElement {
        let folders = app.collectionViews.containing(.button, identifier: "Add Gmail account").firstMatch
        return folders.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", account, account + ",")).firstMatch
    }

    func addSecondAccount() {
        openFolders()
        app.buttons["Add Gmail account"].tap()
        waitForLog("TOKEN grant=authorization_code account=\(Self.nikos)")
        waitForLog("LIST label=INBOX", "account=\(Self.nikos)")
    }

    /// Turns a SwiftUI toggle on or off by tapping its switch, which is more reliable than tapping the row.
    func setSwitch(_ label: String, on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches[label]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "No switch \(label)", file: file, line: line)
        for _ in 0..<3 where (toggle.value as? String == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "\(label) did not turn \(on ? "on" : "off")", file: file, line: line)
    }

    func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        element.tap()
        element.typeText(text)
    }

    /// Secure fields clear themselves when refocused, and drop keystrokes while the keyboard switches
    /// to its secure layout. So: tap, let the keyboard settle, type everything in one go, and check.
    func typeSecure(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), file: file, line: line)
        var shown = ""
        for _ in 0..<4 {
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            field.typeText(text)
            // Long values are reported truncated, as "••••…" or "••••...".
            shown = field.value as? String ?? ""
            let dots = shown.filter { $0 == "•" }.count
            if dots == text.count || (dots >= 15 && dots < text.count && (shown.hasSuffix("...") || shown.hasSuffix("…"))) { return }
        }
        XCTFail("Could not type into the secure field; it shows \"\(shown)\"", file: file, line: line)
    }

    func save(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
