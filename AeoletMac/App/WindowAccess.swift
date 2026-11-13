import AppKit
import SwiftUI

/// Hands the view's NSWindow to a closure once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class ProbeView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Asks before a window closes. SwiftUI keeps its own window delegate, so this sits in front of it
/// and passes every other delegate message straight through.
@MainActor
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: () -> Bool

    init(window: NSWindow, shouldClose: @escaping () -> Bool) {
        original = window.delegate
        self.shouldClose = shouldClose
        super.init()
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }
}

#if DEBUG
/// Mock runs only: `-AeoletWindowSize 1440x900` sizes the first viewer window for App Store screenshots.
@MainActor
enum MacWindowSizing {
    static var launchSize: CGSize? {
        guard MockGmail.isActive else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AeoletWindowSize"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    static func apply(to window: NSWindow) {
        guard let size = launchSize, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.minX + max(0, (visible.width - size.width) / 2),
                             y: visible.maxY - size.height)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}
#endif
