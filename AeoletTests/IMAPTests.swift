import Security
import XCTest
@testable import Aeolet

/// IMAP/SMTP accounts: discovery, settings, message mapping and credential storage. No network.
final class IMAPTests: XCTestCase {
    // MARK: Autoconfig

    private let autoconfig = """
    <?xml version="1.0" encoding="UTF-8"?>
    <clientConfig version="1.1">
      <emailProvider id="example.com">
        <domain>example.com</domain>
        <incomingServer type="pop3">
          <hostname>pop.example.com</hostname><port>995</port><socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username>
        </incomingServer>
        <incomingServer type="imap">
          <hostname>plain.example.com</hostname><port>143</port><socketType>plain</socketType>
          <username>%EMAILADDRESS%</username>
        </incomingServer>
        <incomingServer type="imap">
          <hostname>imap.%EMAILDOMAIN%</hostname><port>993</port><socketType>SSL</socketType>
          <username>%EMAILLOCALPART%</username>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>smtp.example.com</hostname><port>587</port><socketType>STARTTLS</socketType>
          <username>%EMAILADDRESS%</username>
        </outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    func testAutoconfigSkipsPlainTextAndFillsPlaceholders() throws {
        let account = try XCTUnwrap(AutoconfigParser.parse(Data(autoconfig.utf8), email: "alex@example.com"))
        XCTAssertEqual(account.imap, ServerEndpoint(host: "imap.example.com", port: 993, security: .tls))
        XCTAssertEqual(account.smtp, ServerEndpoint(host: "smtp.example.com", port: 587, security: .startTLS))
        XCTAssertEqual(account.username, "alex")
        XCTAssertEqual(account.email, "alex@example.com")
    }

    func testAutoconfigWithOnlyPlainTextServersIsRejected() {
        let plain = """
        <clientConfig><emailProvider id="example.com">
          <incomingServer type="imap"><hostname>mail.example.com</hostname><port>143</port><socketType>plain</socketType></incomingServer>
          <outgoingServer type="smtp"><hostname>mail.example.com</hostname><port>25</port><socketType>plain</socketType></outgoingServer>
        </emailProvider></clientConfig>
        """
        XCTAssertNil(AutoconfigParser.parse(Data(plain.utf8), email: "alex@example.com"))
    }

    func testAutoconfigIgnoresMalformedXMLAndExternalEntities() {
        XCTAssertNil(AutoconfigParser.parse(Data("<clientConfig><emailProvider>".utf8), email: "alex@example.com"))
        let entity = """
        <?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]>
        <clientConfig><emailProvider><incomingServer type="imap"><hostname>&e;</hostname><port>993</port><socketType>SSL</socketType></incomingServer></emailProvider></clientConfig>
        """
        XCTAssertNil(AutoconfigParser.parse(Data(entity.utf8), email: "alex@example.com"))
    }

    func testAutoconfigURLsAreHTTPSAndCarryOnlyTheDomain() {
        let urls = Autodiscovery.autoconfigURLs(domain: "example.com").map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://autoconfig.example.com/mail/config-v1.1.xml",
            "https://example.com/.well-known/autoconfig/mail/config-v1.1.xml",
        ])
    }

    // MARK: DNS SRV

    func testSRVRecordParsing() throws {
        // Priority 10, weight 5, port 993, target imap.example.com.
        var bytes: [UInt8] = [0, 10, 0, 5, 0x03, 0xE1]
        for label in ["imap", "example", "com"] {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: Array(label.utf8))
        }
        bytes.append(0)
        let record = try XCTUnwrap(SRVLookup.parse(bytes))
        XCTAssertEqual(record, SRVLookup.Record(priority: 10, weight: 5, port: 993, target: "imap.example.com"))
        XCTAssertNil(SRVLookup.parse([0, 1, 2]))
    }

    func testSRVBestPrefersLowPriorityThenHighWeightAndSkipsUnavailable() {
        let records = [
            SRVLookup.Record(priority: 20, weight: 0, port: 993, target: "backup.example.com"),
            SRVLookup.Record(priority: 0, weight: 0, port: 0, target: "."),
            SRVLookup.Record(priority: 10, weight: 1, port: 993, target: "b.example.com"),
            SRVLookup.Record(priority: 10, weight: 9, port: 993, target: "a.example.com"),
        ]
        XCTAssertEqual(SRVLookup.best(records)?.target, "a.example.com")
        XCTAssertNil(SRVLookup.best([SRVLookup.Record(priority: 0, weight: 0, port: 0, target: ".")]))
    }

    // MARK: Settings

    func testDefaultsUseTheDomainOverImplicitTLS() {
        let account = MailAccount.defaults(for: "alex@example.com")
        XCTAssertEqual(account.imap, ServerEndpoint(host: "example.com", port: 993, security: .tls))
        XCTAssertEqual(account.smtp, ServerEndpoint(host: "example.com", port: 465, security: .tls))
        XCTAssertEqual(account.username, "alex@example.com")
        XCTAssertTrue(account.isValid)
    }

    func testOnlyEncryptedConnectionsCanBeChosen() {
        XCTAssertEqual(ConnectionSecurity.allCases, [.tls, .startTLS])
        XCTAssertEqual(IMAPLogin.transport(.tls), .implicitTLS)
        XCTAssertEqual(IMAPLogin.transport(.startTLS), .startTLS)
        // Stored settings that name anything else don't decode.
        let stored = #"{"host":"mail.example.com","port":143,"security":"plain"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ServerEndpoint.self, from: Data(stored.utf8)))
    }

    func testServerNamesMustBeBareHosts() {
        func valid(_ host: String, _ port: Int = 993) -> Bool { ServerEndpoint(host: host, port: port, security: .tls).isValid }
        XCTAssertTrue(valid("mail.example.com"))
        XCTAssertFalse(valid(""))
        XCTAssertFalse(valid("https://mail.example.com"))
        XCTAssertFalse(valid("mail.example.com:993"))
        XCTAssertFalse(valid(" mail.example.com"))
        XCTAssertFalse(valid("mail.example.com", 0))
        XCTAssertFalse(valid("mail.example.com", 70000))
        XCTAssertFalse(MailAccount.isPlausibleEmail("alex"))
        XCTAssertFalse(MailAccount.isPlausibleEmail("alex@localhost"))
        XCTAssertTrue(MailAccount.isPlausibleEmail("alex@example.com"))
    }

    // MARK: Message identifiers and conversations

    func testRefsRoundTripAndRejectOtherIDs() throws {
        let ref = IMAPRef(folder: "INBOX/Travel", validity: 1_700_000_000, uids: [4, 9])
        XCTAssertEqual(IMAPRef(ref.encoded), ref)
        XCTAssertNil(IMAPRef("18c2a1b3f0e4d5c6"), "A Gmail thread ID is not an IMAP reference")
        XCTAssertNil(IMAPRef("imap.not-base64!"))
        XCTAssertEqual(IMAPRef(ref.single(9).encoded)?.uids, [9])
    }

    func testRepliesGroupIntoOneConversation() {
        func message(_ uid: UInt32, id: String, replyTo: String? = nil, refs: [String] = [], minutes: Double) -> IMAPListedMessage {
            IMAPListedMessage(uid: uid, from: "Alex <alex@example.com>", subject: "Plans", date: Date(timeIntervalSince1970: minutes * 60),
                              isSeen: true, isFlagged: false, contentType: nil, messageID: "<\(id)@example.com>",
                              inReplyTo: replyTo.map { "<\($0)@example.com>" }, references: refs.map { "<\($0)@example.com>" })
        }
        let groups = IMAPMapping.conversations([
            message(1, id: "a", minutes: 1),
            message(2, id: "other", minutes: 2),
            message(3, id: "b", replyTo: "a", refs: ["a"], minutes: 3),
            message(4, id: "c", replyTo: "b", refs: ["a", "b"], minutes: 4),
        ])
        XCTAssertEqual(groups.map { $0.map(\.uid) }, [[1, 3, 4], [2]], "Newest conversation first, oldest message first within it")

        let summary = IMAPMapping.summary(groups[0], folder: "INBOX", validity: 7, folderLabel: "INBOX")
        XCTAssertEqual(summary?.messageCount, 3)
        XCTAssertEqual(IMAPRef(summary?.id ?? "")?.uids, [1, 3, 4])
    }

    // MARK: Bodies and attachments

    private let multipart = Data("""
    From: Alex <alex@example.com>\r
    To: Sam <sam@example.com>\r
    Subject: Tickets\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary="b1"\r
    \r
    --b1\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    Here are the tickets.\r
    --b1\r
    Content-Type: application/pdf; name="tickets.pdf"\r
    Content-Disposition: attachment; filename="tickets.pdf"\r
    Content-Transfer-Encoding: base64\r
    \r
    JVBERi0xLjQ=\r
    --b1--\r
    """.utf8)

    func testRawMessageBecomesTextAndFetchableAttachment() throws {
        let message = IMAPMapping.message(raw: multipart, id: "m", threadID: "t", labelIds: ["INBOX"], internalDate: Date())
        let body = GmailBodyExtractor.body(of: message)
        XCTAssertEqual(body.text?.trimmingCharacters(in: .whitespacesAndNewlines), "Here are the tickets.")
        let attachment = try XCTUnwrap(body.attachments.first)
        XCTAssertEqual(attachment.filename, "tickets.pdf")
        guard case let .gmail(_, path) = attachment.source else { return XCTFail("Attachment should be fetched on demand") }
        XCTAssertEqual(IMAPMapping.attachment(raw: multipart, path: path), Data("%PDF-1.4".utf8))
        XCTAssertNil(IMAPMapping.attachment(raw: multipart, path: "9"))
    }

    // MARK: Sending

    func testBccIsRemovedFromTheMessageButStillReceivesIt() {
        let raw = Data("From: alex@example.com\r\nTo: Sam <sam@example.com>, kim@example.com\r\nCc: lee@example.com\r\nBcc: hidden@example.com,\r\n  also-hidden@example.com\r\nSubject: Hi\r\n\r\nBody with Bcc: text\r\n".utf8)
        XCTAssertEqual(IMAPMapping.recipients(of: raw),
                       ["sam@example.com", "kim@example.com", "lee@example.com", "hidden@example.com", "also-hidden@example.com"])
        let sent = String(decoding: IMAPMapping.removingBcc(from: raw), as: UTF8.self)
        XCTAssertFalse(sent.contains("hidden@example.com"))
        XCTAssertTrue(sent.contains("Subject: Hi\r\n\r\nBody with Bcc: text"), "The body must be untouched")
    }

    // MARK: Credentials

    func testPasswordIsStoredDeviceOnlyAndRemovedWithTheAccount() throws {
        let email = "unit-test-\(UUID().uuidString.prefix(8))@example.com".lowercased()
        let account = MailAccount.defaults(for: email)
        let others = AccountStore.mailAccounts()
        do {
            try AccountStore.add(account, password: "not-a-real-password")
        } catch KeychainError.status(errSecMissingEntitlement) {
            throw XCTSkip("This build is not signed with a team, so it can't reach the data protection keychain.")
        }
        defer { AccountStore.remove(email) }

        XCTAssertEqual(AccountStore.mailAccount(email), account)
        XCTAssertEqual(try AccountStore.password(for: email), "not-a-real-password")
        XCTAssertThrowsError(try AccountStore.add(account, password: "x"), "The same address can't be added twice")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: AccountStore.passwordKey(email),
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)

        AccountStore.remove(email)
        XCTAssertNil(AccountStore.mailAccount(email))
        XCTAssertNil(try KeychainStore.load(AccountStore.passwordKey(email)))
        XCTAssertEqual(AccountStore.mailAccounts(), others, "Other accounts must be untouched")
    }

    func testPlainTextPasswordNeverReachesTheAccountList() throws {
        let account = MailAccount.defaults(for: "alex@example.com")
        let encoded = String(decoding: try JSONEncoder().encode([account]), as: UTF8.self)
        XCTAssertFalse(encoded.lowercased().contains("password"))
    }

    // MARK: Gmail and Yahoo presets

    func testPresetsUseTheProvidersImplicitTLSServers() throws {
        let gmail = try XCTUnwrap(MailAccount.preset(.gmail, email: "alex@gmail.com"))
        XCTAssertEqual(gmail.imap, ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls))
        XCTAssertEqual(gmail.smtp, ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls))
        XCTAssertEqual(gmail.username, "alex@gmail.com")
        XCTAssertTrue(gmail.isValid)

        let yahoo = try XCTUnwrap(MailAccount.preset(.yahoo, email: "alex@yahoo.com"))
        XCTAssertEqual(yahoo.imap, ServerEndpoint(host: "imap.mail.yahoo.com", port: 993, security: .tls))
        XCTAssertEqual(yahoo.smtp, ServerEndpoint(host: "smtp.mail.yahoo.com", port: 465, security: .tls))
        XCTAssertNil(MailAccount.preset(.manual, email: "alex@example.com"))
    }

    func testKnownDomainsAreRecognisedWithoutTheNetwork() async {
        XCTAssertEqual(MailAccount.knownProvider(forDomain: "Gmail.com"), .gmail)
        XCTAssertEqual(MailAccount.knownProvider(forDomain: "googlemail.com"), .gmail)
        XCTAssertEqual(MailAccount.knownProvider(forDomain: "yahoo.co.uk"), .yahoo)
        XCTAssertEqual(MailAccount.knownProvider(forDomain: "ymail.com"), .yahoo)
        XCTAssertNil(MailAccount.knownProvider(forDomain: "example.com"))
        XCTAssertNil(MailAccount.knownProvider(forDomain: "notyahoo.example.com"))

        let result = await Autodiscovery.discover(email: "alex@gmail.com")
        XCTAssertEqual(result.source, .known(.gmail))
        XCTAssertEqual(result.account.imap.host, "imap.gmail.com")
    }

    func testAppPasswordSpacesAreDroppedOnlyForPresets() {
        XCTAssertEqual(MailAccount.Provider.gmail.normalisedPassword("abcd efgh\tijkl mnop"), "abcdefghijklmnop")
        XCTAssertEqual(MailAccount.Provider.manual.normalisedPassword(" pass word "), " pass word ")
    }

    func testOnlyGmailFilesSentMailItself() {
        XCTAssertTrue(MailAccount.Provider.gmail.filesSentMail)
        XCTAssertFalse(MailAccount.Provider.yahoo.filesSentMail)
        XCTAssertFalse(MailAccount.Provider.manual.filesSentMail)
    }

    func testAppPasswordLinksAreHTTPSOnTheProvidersOwnSites() {
        XCTAssertEqual(MailAccount.Provider.gmail.appPasswordURL?.absoluteString, "https://myaccount.google.com/apppasswords")
        XCTAssertEqual(MailAccount.Provider.yahoo.appPasswordURL?.host, "help.yahoo.com")
        XCTAssertNil(MailAccount.Provider.manual.appPasswordURL)
    }

    func testMessageIDIsReadFromTheHeader() {
        let raw = Data("From: a@example.com\r\nMessage-ID: <abc@example.com>\r\nSubject: Hi\r\n\r\nBody".utf8)
        XCTAssertEqual(IMAPMapping.messageID(of: raw), "<abc@example.com>")
        XCTAssertNil(IMAPMapping.messageID(of: Data("Subject: Hi\r\n\r\nBody".utf8)))
    }
}
