import XCTest

/// Shared harness for the Mac app. Every test runs against the in-app mock Gmail server (-AeoletMockGmail),
/// never a real account. Mock runs keep their own Keychain items, files and preferences, so running these
/// on a Mac never touches the real app's sign-in.
class MacUITestCase: XCTestCase {
    var app: XCUIApplication!

    static let elena = "elena@example.com"
    static let nikos = "nikos@example.com"
    static let passphrase = "correct horse battery"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, testRun?.hasSucceeded == false {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Failure \(name)"
            shot.lifetime = .keepAlways
            add(shot)
            let probe = XCTAttachment(string: probeValue)
            probe.name = "Mock probe at failure"
            probe.lifetime = .keepAlways
            add(probe)
        }
        app?.terminate()
    }

    // MARK: Launching

    @discardableResult
    func launch(reset: Bool = true, fault: String? = nil, extra: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AeoletMockGmail", "-ApplePersistenceIgnoreState", "YES"] + extra
        if reset { app.launchArguments.append("-AeoletResetState") }
        if let fault { app.launchEnvironment["AEOLET_MOCK_FAULT"] = fault }
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
        app.activate()
        self.app = app
        return app
    }

    var mainWindow: XCUIElement { app.windows.containing(.any, identifier: "mock-probe").firstMatch }

    func signIn(expecting account: String = elena) {
        let button = app.buttons["Sign in with Google"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Sign-in screen did not appear")
        button.click()
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

    var log: [String] { probe["log"] as? [String] ?? [] }
    var logPosition: Int { probe["seq"] as? Int ?? 0 }
    var keychain: [String] { probe["keychain"] as? [String] ?? [] }
    var cacheFiles: [String: Int] { probe["cacheFiles"] as? [String: Int] ?? [:] }

    private static func number(of line: String) -> Int {
        Int(line.dropFirst().prefix { $0.isNumber }) ?? 0
    }

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

    func noLog(_ fragments: String..., after start: Int, file: StaticString = #filePath, line: UInt = #line) {
        let hit = log.first { entry in Self.number(of: entry) > start && fragments.allSatisfy { entry.contains($0) } }
        XCTAssertNil(hit, "Unexpected mock request: \(hit ?? "")", file: file, line: line)
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

    /// The list row for a conversation, by its subject.
    func row(_ subject: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "thread-\(subject)").firstMatch
    }

    func select(_ subject: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = row(subject)
        XCTAssertTrue(target.waitForExistence(timeout: 15), "No row \(subject)", file: file, line: line)
        for _ in 0..<12 where !target.isHittable { app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -120) }
        target.click()
    }

    func sidebar(_ label: String, account: String = elena) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "label-\(account)-\(label)").firstMatch
    }

    /// Text anywhere in the app, including inside a message's web view. Only static texts are searched:
    /// a predicate over every element times out on a full mailbox.
    func anyText(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", fragment, fragment)).firstMatch
    }

    /// A button in a dialog or sheet. Every dialog button has a Touch Bar twin, which can't be clicked.
    func dialogButton(_ title: String) -> XCUIElement {
        let sheet = app.sheets.buttons[title].firstMatch
        return sheet.exists ? sheet : app.dialogs.buttons[title].firstMatch
    }

    func clickDialogButton(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !dialogButton(title).exists { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertTrue(dialogButton(title).exists, "No dialog button \(title)", file: file, line: line)
        dialogButton(title).click()
    }

    func menu(_ path: String...) {
        var item = app.menuBars.menuBarItems[path[0]]
        item.click()
        for title in path.dropFirst() {
            item = item.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "No menu item \(path)")
            item.click()
        }
    }

    func menuItem(_ menu: String, _ title: String) -> XCUIElement {
        app.menuBars.menuBarItems[menu].menuItems[title]
    }

    /// The Settings window, whose title is the selected tab.
    var settings: XCUIElement {
        app.windows.matching(NSPredicate(format: "title IN %@", ["General", "Accounts", "Encryption", "About"])).firstMatch
    }

    /// Any element by accessibility identifier, whatever control type this macOS version reports it as.
    func element(_ identifier: String, in scope: XCUIElement? = nil) -> XCUIElement {
        (scope ?? app).descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The front compose window.
    var compose: XCUIElement { app.windows.containing(.any, identifier: "compose-body").firstMatch }

    func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        element.click()
        element.typeText(text)
    }

    func save(_ image: NSImage, as name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
