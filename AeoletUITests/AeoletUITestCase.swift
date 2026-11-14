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
    func launch(reset: Bool = true, fault: String? = nil, animations: Bool = false,
                arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeoletMockGmail"] + arguments
        if reset { app.launchArguments.append("-AeoletResetState") }
        if !animations { app.launchArguments.append("-AeoletDisableAnimations") }
        if let fault { app.launchEnvironment["AEOLET_MOCK_FAULT"] = fault }
        app.launchEnvironment.merge(environment) { _, new in new }
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

    static func number(ofLogLine line: String) -> Int { number(of: line) }

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
        let top = navigation.exists ? min(navigation.frame.maxY - 4, screen.minY + 140) : screen.minY + 60
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
        // iPad's search drawer stays active with a Cancel button, which hides the toolbar.
        let cancel = app.navigationBars.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
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

    /// Pulls the list down to refresh. Gestures land differently on iPhone and iPad, so it tries a held
    /// drag and then a plain swipe, stopping as soon as the app asks the server for the list again.
    func pullToRefresh() {
        let list = app.collectionViews.firstMatch
        let before = logPosition
        let refreshed = { self.log.contains { Self.number(of: $0) > before && ($0.contains("LIST") || $0.contains("OFFLINE")) } }
        let firstRow = list.cells.firstMatch
        let start = (firstRow.exists ? firstRow : list).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let attempts: [() -> Void] = [
            { start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500))) },
            { start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)),
                          withVelocity: .slow, thenHoldForDuration: 0.6) },
            { list.swipeDown(velocity: .slow) },
            { list.swipeDown() },
        ]
        for attempt in attempts {
            attempt()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if refreshed() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
    }

    // MARK: Screens

    func openFolders() {
        app.buttons["Folders and accounts"].tap()
        XCTAssertTrue(app.navigationBars["Mailboxes"].waitForExistence(timeout: 10))
    }

    func showLabel(_ name: String) {
        openFolders()
        // Folder rows read "Travel" or "Travel, 2" when there is unread mail.
        let folders = app.collectionViews.containing(.button, identifier: "Add Gmail account").firstMatch
        let target = folders.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
        // On iPad the folder sheet is a smaller card, so lower folders may need a scroll.
        for _ in 0..<4 where !(target.exists && target.isHittable) { folders.swipeUp(velocity: .slow) }
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
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp(velocity: .slow) }
        for _ in 0..<3 where (toggle.value as? String == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0", "\(label) did not turn \(on ? "on" : "off")", file: file, line: line)
    }

    /// Puts the keyboard away with Compose's own button, so controls further down the form are reachable.
    /// Two buttons are labelled "Hide keyboard": Compose's toolbar button and a key on the system keyboard, which
    /// can sit off screen. With a hardware keyboard, iPad shows Compose's toolbar shrunk to a small floating button,
    /// which accessibility doesn't report as hittable, so the on-screen button is found by its frame and tapped by position.
    func hideKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            if app.keyboards.count == 0 { return }
            let screen = app.windows.firstMatch.frame
            let onScreen = app.buttons.matching(identifier: "Hide keyboard").allElementsBoundByIndex
                .first { $0.exists && screen.contains($0.frame) }
            onScreen?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && app.keyboards.count > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        waitUntil(2, "the keyboard to go away", file: file, line: line) { app.keyboards.count == 0 }
    }

    /// Picks "Photo Library" or "Files" from Compose's Attach choices. In mock runs these pick fixtures
    /// unless the app was launched with -AeoletRealPickers.
    func attach(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        hideKeyboard(file: file, line: line)
        let menu = app.buttons["Attach"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "No Attach menu", file: file, line: line)
        for _ in 0..<3 where !menu.isHittable { app.swipeUp(velocity: .slow) }
        menu.tap()
        let item = app.buttons[source]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(source) in the Attach choices", file: file, line: line)
        item.tap()
    }

    /// Taps by position: on older iOS, menus such as Compose's Close can't be reached through accessibility.
    func tapByPosition(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        // On iPad a tap sometimes lands while the form is still moving, leaving the field unfocused. Tap until it has focus.
        for _ in 0..<4 {
            element.tap()
            if hasFocus(element) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if hasFocus(element) { break }
        }
        element.typeText(text)
    }

    func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
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
            // On iPad the tap can land while the sheet is still settling; typing then fails outright.
            guard hasFocus(field) else { continue }
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

    // MARK: PGP

    func generateKey(for account: String, name: String) {
        let generate = app.buttons["Generate a new key"].firstMatch
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "No Generate button for \(account)")
        generate.tap()
        XCTAssertTrue(app.navigationBars["New PGP key"].waitForExistence(timeout: 10))
        XCTAssertTrue(anyText(containing: account).exists, "Key sheet is for the wrong account")
        type(name, into: app.textFields["Your name"])
        typeSecure(Self.passphrase, into: app.secureTextFields["Passphrase, 12 characters or more"])
        typeSecure(Self.passphrase, into: app.secureTextFields["Repeat passphrase"])
        XCTAssertTrue(app.buttons["Create"].isEnabled, "Create stayed disabled after entering the passphrase")
        app.buttons["Create"].tap()
        waitUntil(90, "key generation for \(account) to finish") { !app.navigationBars["New PGP key"].exists }
        XCTAssertTrue(keychain.contains("pgp.private.\(account)"), "No private key stored for \(account): \(keychain)")
    }

    func enterPassphrase(_ value: String, confirm: String) {
        let field = app.secureTextFields["Passphrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No passphrase prompt")
        typeSecure(value, into: field)
        app.alerts.buttons[confirm].tap()
    }
}
