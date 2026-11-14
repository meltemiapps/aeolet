import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The message body. A plain-text NSTextView that turns dropped files into attachments: files from Finder,
/// and attachments dragged out of a message (here or in another mail app), which arrive as file promises or data.
/// Dropped text is still inserted as text.
struct ComposeBodyEditor: NSViewRepresentable {
    @Binding var text: String
    let onFile: (Data, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let old = scroll.documentView as! NSTextView
        let view = DropTextView(frame: old.frame, textContainer: old.textContainer)
        view.autoresizingMask = old.autoresizingMask
        view.minSize = old.minSize
        view.maxSize = old.maxSize
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.drawsBackground = false
        view.string = text
        view.delegate = context.coordinator
        view.onFile = { onFile($0, $1) }
        view.setAccessibilityIdentifier("compose-body")
        view.setAccessibilityLabel("Message body")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? DropTextView else { return }
        view.onFile = { onFile($0, $1) }
        if view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeBodyEditor
        init(_ parent: ComposeBodyEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class DropTextView: NSTextView {
    var onFile: ((Data, String) -> Void)?

    private static let fileTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + Self.fileTypes + [NSPasteboard.PasteboardType(UTType.data.identifier)]
    }

    private func carriesFiles(_ info: NSDraggingInfo) -> Bool {
        let pasteboard = info.draggingPasteboard
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return true }
        return Self.dataType(in: pasteboard) != nil
    }

    /// A dragged attachment's own type, such as com.adobe.pdf; text types are left to the text view.
    private static func dataType(in pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        pasteboard.pasteboardItems?.first?.types.first { type in
            guard let uti = UTType(type.rawValue) else { return false }
            return uti.conforms(to: .data) && !uti.conforms(to: .text) && !uti.conforms(to: .url) && !type.rawValue.hasPrefix("dyn.")
        }
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        carriesFiles(info) ? .copy : super.draggingEntered(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        carriesFiles(info) ? .copy : super.draggingUpdated(info)
    }

    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool {
        carriesFiles(info) ? true : super.prepareForDragOperation(info)
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard carriesFiles(info) else { return super.performDragOperation(info) }
        let pasteboard = info.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { deliver(url) }
            return true
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { [weak self] url, error in
                    guard error == nil else { return }
                    self?.deliver(url)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            return true
        }
        if let type = Self.dataType(in: pasteboard), let data = pasteboard.data(forType: type) {
            let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "dat"
            onFile?(data, "Attachment.\(ext)")
            return true
        }
        return false
    }

    private func deliver(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
              let data = try? Data(contentsOf: url) else { return }
        onFile?(data, url.lastPathComponent)
    }
}
