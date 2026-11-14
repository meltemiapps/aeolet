import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Aeolet

final class AttachmentTests: XCTestCase {
    private func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
    }

    func testFixturesCarryLocation() {
        XCTAssertEqual(type(of: MockGmailFixtures.heicWithLocation), UTType.heic.identifier)
        XCTAssertTrue(PhotoAttachments.hasLocation(MockGmailFixtures.heicWithLocation))
        XCTAssertTrue(PhotoAttachments.hasLocation(MockGmailFixtures.jpegWithLocation(caption: "Test")))
    }

    func testHEICBecomesJPEGWithoutLocationByDefault() throws {
        let item = try PhotoAttachments.prepare(data: MockGmailFixtures.heicWithLocation, type: .heic, baseName: "IMG_0042.HEIC", keepOriginals: false)
        XCTAssertEqual(item.filename, "IMG_0042.jpg")
        XCTAssertEqual(item.mimeType, "image/jpeg")
        XCTAssertEqual(type(of: item.data), UTType.jpeg.identifier)
        XCTAssertFalse(PhotoAttachments.hasLocation(item.data))
        // Still a real image of the same size.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(item.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 240)
    }

    func testJPEGKeepsFormatButLosesLocation() throws {
        let item = try PhotoAttachments.prepare(data: MockGmailFixtures.jpegWithLocation(caption: "Terrace"), type: .jpeg, baseName: "Terrace", keepOriginals: false)
        XCTAssertEqual(item.filename, "Terrace.jpg")
        XCTAssertEqual(type(of: item.data), UTType.jpeg.identifier)
        XCTAssertFalse(PhotoAttachments.hasLocation(item.data))
    }

    func testKeepOriginalsLeavesPhotoUntouched() throws {
        let original = MockGmailFixtures.heicWithLocation
        let item = try PhotoAttachments.prepare(data: original, type: .heic, baseName: "Harbour", keepOriginals: true)
        XCTAssertEqual(item.filename, "Harbour.heic")
        XCTAssertEqual(item.mimeType, "image/heic")
        XCTAssertEqual(item.data, original)
    }

    func testItemProvidersLoadInOrder() async {
        let heic = NSItemProvider(item: MockGmailFixtures.heicWithLocation as NSData, typeIdentifier: UTType.heic.identifier)
        heic.suggestedName = "Harbour"
        let broken = NSItemProvider(item: Data("not an image".utf8) as NSData, typeIdentifier: UTType.png.identifier)
        broken.suggestedName = "Broken"
        let (items, failed) = await PhotoAttachments.load([heic, broken], keepOriginals: false)
        XCTAssertEqual(items.map(\.filename), ["Harbour.jpg"])
        XCTAssertEqual(failed, ["Broken"])
    }

    func testFilesOverTheLimitAreRefusedBeforeReading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: small)
        let big = folder.appendingPathComponent("video.mov")
        try Data(count: 20_000_000).write(to: big)

        let result = FileAttachments.load([small, big], alreadyAttached: 6_000_000)
        XCTAssertEqual(result.attachments.map(\.filename), ["notes.txt"])
        XCTAssertEqual(result.attachments.first?.mimeType, "text/plain")
        XCTAssertEqual(result.tooLarge, ["video.mov"])
    }

    @MainActor
    func testComposeEnforcesTheLimit() {
        let model = ComposeModel(account: "elena@example.com", context: .new)
        let twenty = OutgoingAttachment(filename: "a.bin", mimeType: "application/octet-stream", data: Data(count: 20_000_000))
        let five = OutgoingAttachment(filename: "b.bin", mimeType: "application/octet-stream", data: Data(count: 5_000_000))
        let one = OutgoingAttachment(filename: "c.bin", mimeType: "application/octet-stream", data: Data(count: 1))
        model.add([twenty, five])
        XCTAssertEqual(model.attachmentsTotal, 25_000_000)
        XCTAssertNil(model.attachmentNotice, "Exactly 25 MB is allowed")
        model.add([one])
        XCTAssertEqual(model.attachments.count, 2)
        XCTAssertEqual(model.attachmentNotice,
                       "\u{201C}c.bin\u{201D} is too large to add. Gmail allows 25 MB of attachments per message, and this message has no room left. To send something bigger, share a link to it from Files or Google Drive.")
    }

    @MainActor
    func testSendRefusesOverLimit() async {
        let model = ComposeModel(account: "elena@example.com", context: .new)
        model.to = "sofia@example.org"
        model.attachments = [OutgoingAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: Data(count: 30_000_000))]
        let sent = await model.send()
        XCTAssertFalse(sent)
        XCTAssertEqual(model.errorMessage, "Attachments total 30 MB, over Gmail's 25 MB limit. Remove some to send.")
    }
}
