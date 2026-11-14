import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Gmail's limit on attachments per message. Sizes are shown with ByteCountFormatter's decimal units,
/// so the limit is decimal too: what the screen calls 25 MB is exactly what is allowed.
enum AttachmentLimit {
    static let maxTotalBytes = 25_000_000

    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// The message shown when attachments are refused. Names what was refused and what to do instead.
    static func message(refused names: [String], currentTotal: Int) -> String {
        let what = names.count == 1 ? "\u{201C}\(names[0])\u{201D} is" : "\(names.count) files are"
        let room = max(0, maxTotalBytes - currentTotal)
        let left = room < 1000 ? "this message has no room left" : "this message has \(format(room)) left"
        return "\(what) too large to add. Gmail allows \(format(maxTotalBytes)) of attachments per message, and \(left). To send something bigger, share a link to it from Files or Google Drive."
    }
}

/// Turns picked photos into attachments. By default HEIC and HEIF become JPEG and location is removed
/// from every photo; with "Keep photo originals" on, photos go out exactly as they are in the library.
enum PhotoAttachments {
    enum Failure: Error { case unreadable }

    /// Reads each item provider (from PHPickerViewController, or the mock) and prepares it.
    /// Returns the attachments in picking order and the names of any that could not be read.
    static func load(_ providers: [NSItemProvider], keepOriginals: Bool) async -> (attachments: [OutgoingAttachment], failed: [String]) {
        var attachments: [OutgoingAttachment] = []
        var failed: [String] = []
        for (index, provider) in providers.enumerated() {
            let baseName = provider.suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? "Photo \(index + 1)"
            guard let type = imageType(of: provider), let data = await loadData(provider, type: type) else {
                failed.append(baseName)
                continue
            }
            do {
                attachments.append(try prepare(data: data, type: type, baseName: baseName, keepOriginals: keepOriginals))
            } catch {
                failed.append(baseName)
            }
        }
        return (attachments, failed)
    }

    /// The most specific image type the provider offers, so a HEIC arrives as HEIC rather than as a generic image.
    private static func imageType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .image) }
    }

    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    static func prepare(data: Data, type: UTType, baseName: String, keepOriginals: Bool) throws -> OutgoingAttachment {
        let stem = (baseName as NSString).deletingPathExtension
        if keepOriginals {
            let ext = type.preferredFilenameExtension ?? "jpg"
            return OutgoingAttachment(filename: "\(stem).\(ext)", mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data)
        }
        let converts = type.conforms(to: .heic) || type.conforms(to: .heif)
        let outType: UTType = converts ? .jpeg : type
        let cleaned = try withoutLocation(data, as: outType)
        let ext = outType == .jpeg ? "jpg" : (outType.preferredFilenameExtension ?? "jpg")
        return OutgoingAttachment(filename: "\(stem).\(ext)", mimeType: outType.preferredMIMEType ?? "image/jpeg", data: cleaned)
    }

    /// Re-encodes as `type` (lossless metadata copy when the type is unchanged), dropping GPS and XMP,
    /// where apps also store places. Orientation, dimensions and capture time are kept.
    static func withoutLocation(_ data: Data, as type: UTType) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else { throw Failure.unreadable }
        let output = NSMutableData()
        let count = CGImageSourceGetCount(source)
        guard count > 0, let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, type == sourceType ? count : 1, nil) else {
            throw Failure.unreadable
        }
        if type == sourceType {
            // Same format: copy the image data untouched and only rewrite the metadata.
            let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) {
                return output as Data
            }
            // Some formats can't be copied in place; fall back to re-encoding below.
            return try reencode(source, as: type)
        }
        return try reencode(source, as: type)
    }

    private static func reencode(_ source: CGImageSource, as type: UTType) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw Failure.unreadable }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImagePropertyGPSDictionary] = kCFNull
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return output as Data
    }

    /// True when the image carries GPS coordinates. Used by tests and the mock server's log.
    static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return false }
        return gps[kCGImagePropertyGPSLatitude] != nil || gps[kCGImagePropertyGPSLongitude] != nil
    }
}

/// Reads files picked in the document picker. Sizes are checked before reading, so a huge file
/// from Google Drive or iCloud is refused without being loaded into memory.
enum FileAttachments {
    struct Result {
        var attachments: [OutgoingAttachment] = []
        var tooLarge: [String] = []
        var unreadable: [String] = []
    }

    static func load(_ urls: [URL], alreadyAttached: Int) -> Result {
        var result = Result()
        var total = alreadyAttached
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, total + size > AttachmentLimit.maxTotalBytes {
                result.tooLarge.append(name)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                result.unreadable.append(name)
                continue
            }
            if total + data.count > AttachmentLimit.maxTotalBytes {
                result.tooLarge.append(name)
                continue
            }
            total += data.count
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            result.attachments.append(OutgoingAttachment(filename: name, mimeType: type, data: data))
        }
        return result
    }
}
