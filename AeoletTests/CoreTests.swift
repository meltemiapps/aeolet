import XCTest
@testable import Aeolet

final class CoreTests: XCTestCase {
    func testBase64URLRoundTrip() {
        let data = Data([0xFB, 0xFF, 0xBF, 0x00, 0x01])
        XCTAssertFalse(data.base64URLEncoded.contains("+"))
        XCTAssertEqual(Data(base64URL: data.base64URLEncoded), data)
    }

    func testPKCEMatchesRFC7636AppendixB() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testHeaderInjectionIsRemoved() {
        let headers = OutgoingHeaders(from: "a@example.org", to: ["b@example.org"], subject: "Hi\r\nBcc: evil@example.org")
        let text = String(decoding: MIMEBuilder.message(headers: headers, entity: Data("\r\nbody".utf8), senderDomain: "example.org"), as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nBcc:"))
    }

    func testUnicodeRoundTripThroughBuilderAndParser() {
        let attachment = OutgoingAttachment(filename: "résumé.pdf", mimeType: "application/pdf", data: Data([1, 2, 3, 255]))
        let entity = MIMEBuilder.contentEntity(text: "Γειά σου\nline 2", attachments: [attachment])
        let parsed = MIMEParser.parse([UInt8](entity))
        let body = MIMEParser.display(parsed)
        XCTAssertEqual(body.text, "Γειά σου\r\nline 2")
        XCTAssertEqual(body.attachments.first?.filename, "résumé.pdf")
        XCTAssertEqual(body.attachments.first?.source, .local(Data([1, 2, 3, 255])))
    }

    func testEncodedSubjectDecodes() {
        let encoded = MIMEBuilder.encodeHeaderWord("Καλημέρα από την Κρήτη και καλό χειμώνα")
        XCTAssertEqual(MIMEParser.decodeEncodedWords(encoded.replacingOccurrences(of: "\r\n", with: "")), "Καλημέρα από την Κρήτη και καλό χειμώνα")
    }

    func testSignedEntityPreservesExactSignedBytes() {
        let content = MIMEBuilder.contentEntity(text: "signed", attachments: [])
        let signed = MIMEBuilder.signedEntity(content: content, signature: "-----BEGIN PGP SIGNATURE-----\nabc\n-----END PGP SIGNATURE-----", micalg: "pgp-sha512")
        let parsed = MIMEParser.parse([UInt8](signed))
        XCTAssertEqual(parsed.contentType, "multipart/signed")
        XCTAssertEqual(Data(parsed.parts[0].raw), content)
    }

    func testEncryptedEntityStructure() {
        let parsed = MIMEParser.parse([UInt8](MIMEBuilder.encryptedEntity(armored: "-----BEGIN PGP MESSAGE-----\nabc\n-----END PGP MESSAGE-----")))
        XCTAssertEqual(parsed.contentType, "multipart/encrypted")
        XCTAssertEqual(parsed.parts.map(\.contentType), ["application/pgp-encrypted", "application/octet-stream"])
        XCTAssertTrue(String(decoding: parsed.parts[1].body, as: UTF8.self).contains("BEGIN PGP MESSAGE"))
    }

    func testAddressHelpers() {
        XCTAssertEqual("Jane, Doe <JANE@example.org>".emailAddressOnly, "jane@example.org")
        XCTAssertEqual("\"Doe, Jane\" <j@x.org>, b@y.org".splitAddresses.count, 2)
    }

    func testGoogleErrorBodyIsShownInsteadOfDecodingError() {
        let body = Data(#"{"error":{"code":403,"message":"Gmail API has not been used in project 1 before or it is disabled."}}"#.utf8)
        XCTAssertThrowsError(try GmailClient.decode(GmailProfile.self, from: body)) { error in
            XCTAssertEqual(error.localizedDescription, "Gmail API has not been used in project 1 before or it is disabled.")
        }
        let oauth = Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8)
        XCTAssertThrowsError(try GmailClient.decode(TokenResponse.self, from: oauth)) { error in
            XCTAssertEqual(error.localizedDescription, "Bad Request")
        }
    }

    func testMissingFieldIsNamed() {
        XCTAssertThrowsError(try GmailClient.decode(GmailProfile.self, from: Data(#"{"historyId":"1"}"#.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Gmail returned an incomplete response (missing emailAddress).")
        }
    }

    func testRemoteContentIsBlockedUnlessAllowed() {
        let blocked = MessageWebView.document(from: "<img src=\"https://tracker.example/x.gif\">", allowRemote: false)
        XCTAssertTrue(blocked.contains("img-src data:;"), "Only inline images may load by default")
        XCTAssertFalse(blocked.contains("img-src data: https:"))
        XCTAssertTrue(blocked.contains("default-src 'none'"))
        let allowed = MessageWebView.document(from: "", allowRemote: true)
        XCTAssertTrue(allowed.contains("img-src data: https:"))
    }

    func testCacheFilesAreGroupedPerAccount() {
        let elena = MailCache.prefix(account: "Elena@Example.com")
        XCTAssertEqual(elena, MailCache.prefix(account: "elena@example.com"), "Prefix must ignore case")
        XCTAssertNotEqual(elena, MailCache.prefix(account: "nikos@example.com"))
        MailCache.save([], account: "elena@example.com", label: "INBOX")
        MailCache.save([], account: "nikos@example.com", label: "INBOX")
        MailCache.deleteAll(account: "nikos@example.com")
        XCTAssertTrue(PrivateFile.names().contains { $0.hasPrefix(elena) })
        XCTAssertFalse(PrivateFile.names().contains { $0.hasPrefix(MailCache.prefix(account: "nikos@example.com")) })
        MailCache.deleteAll(account: "elena@example.com")
    }

    func testDecodingErrorsNameNestedFields() {
        let body = Data(#"{"threads":[{"snippet":"no id"}]}"#.utf8)
        XCTAssertThrowsError(try GmailClient.decode(GmailThreadList.self, from: body)) { error in
            XCTAssertEqual(error.localizedDescription, "Gmail returned an incomplete response (missing threads[0].id).")
        }
    }

    func testNetworkErrorsReadPlainly() {
        XCTAssertEqual(URLError(.notConnectedToInternet).userMessage, "You're offline. Check your connection and try again.")
        XCTAssertEqual(URLError(.timedOut).userMessage, "Gmail took too long to respond. Try again.")
        XCTAssertFalse(URLError(.cannotFindHost).userMessage.contains("NSURLErrorDomain"))
        XCTAssertEqual(GmailError.http(403, "Quota exceeded").userMessage, "Quota exceeded")
    }

    func testPGPMailGetsAPlainPreview() {
        XCTAssertEqual(ThreadSummary.preview(snippet: "-----BEGIN PGP MESSAGE----- hQIMA3x", contentType: "text/plain; charset=utf-8"), .encrypted)
        XCTAssertEqual(ThreadSummary.preview(snippet: "", contentType: "multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=x"), .encrypted)
        XCTAssertEqual(ThreadSummary.preview(snippet: "-----BEGIN PGP SIGNED MESSAGE----- Hash: SHA512 Release 2.1", contentType: nil), .signed)
        XCTAssertEqual(ThreadSummary.preview(snippet: "Release 2.1 is out", contentType: "Multipart/Signed; micalg=pgp-sha512"), .signed)
        XCTAssertEqual(ThreadSummary.preview(snippet: "See you at -----BEGIN PGP MESSAGE-----", contentType: "text/plain"), .text("See you at -----BEGIN PGP MESSAGE-----"))
    }

    func testThreadSummaryFromGmailUsesContentTypeAndOldCachesStillDecode() throws {
        let json = #"{"id":"t1","messages":[{"id":"m1","labelIds":["INBOX"],"snippet":"","internalDate":"0","payload":{"headers":[{"name":"From","value":"A <a@example.org>"},{"name":"Subject","value":"Secret"},{"name":"Content-Type","value":"multipart/encrypted; protocol=\"application/pgp-encrypted\""}]}}]}"#
        let thread = try GmailClient.decode(GmailThread.self, from: Data(json.utf8))
        let summary = try XCTUnwrap(ThreadSummary(thread: thread))
        XCTAssertEqual(summary.preview, .encrypted)

        // A summary cached before contentType existed still loads, and still recognises inline armour.
        let old = #"{"id":"t2","sender":"B","subject":"S","snippet":"-----BEGIN PGP MESSAGE----- x","date":0,"isUnread":false,"isStarred":false,"messageCount":1,"labelIds":[]}"#
        let cached = try JSONDecoder().decode(ThreadSummary.self, from: Data(old.utf8))
        XCTAssertNil(cached.contentType)
        XCTAssertEqual(cached.preview, .encrypted)
    }
}
