import AppKit
import SwiftUI
import WebKit

/// Sandboxed message renderer, the Mac twin of the iOS one, with the same policy from MessageHTML:
/// no scripts, no persistent storage, remote content blocked unless the person allows it.
struct MacMessageWebView: NSViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    @Binding var height: CGFloat
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MessageWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = MessageWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.onResize = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.measure(view) }
        }
        context.coordinator.load(into: view, html: html, allowRemote: allowRemoteContent)
        return view
    }

    func updateNSView(_ view: MessageWKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: view, html: html, allowRemote: allowRemoteContent)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MacMessageWebView
        private var loadedKey: String?

        init(parent: MacMessageWebView) { self.parent = parent }

        func load(into view: WKWebView, html: String, allowRemote: Bool) {
            let key = "\(allowRemote)|\(html.hashValue)"
            guard key != loadedKey else { return }
            loadedKey = key
            let document = MessageHTML.document(from: html, allowRemote: allowRemote)
            view.configuration.userContentController.removeAllContentRuleLists()
            if allowRemote {
                view.loadHTMLString(document, baseURL: nil)
                return
            }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "aeolet.block-remote", encodedContentRuleList: MessageHTML.blockRules
            ) { list, _ in
                // Fails closed: if the rule cannot be compiled the CSP still blocks remote content.
                Task { @MainActor in
                    if let list { view.configuration.userContentController.add(list) }
                    view.loadHTMLString(document, baseURL: nil)
                }
            }
        }

        /// Sizes the view to its content. Runs in the app's own script world; the message's scripts stay off.
        func measure(_ view: WKWebView) {
            view.evaluateJavaScript("document.documentElement.scrollHeight", in: nil, in: .defaultClient) { [weak self] result in
                guard let self, case let .success(value) = result, let height = (value as? NSNumber)?.doubleValue, height > 0 else { return }
                if abs(self.parent.height - height) > 1 { self.parent.height = height }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Images decode a moment after the document loads.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak webView] in
                if let webView { self?.measure(webView) }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let url = action.request.url, MessageHTML.isOpenableLink(url) {
                parent.onLink(url)
            }
        }
    }
}

/// Lets the conversation scroll as one page, and keeps only copying in the right-click menu
/// (no reload, no opening links in a new web view, no image downloads).
final class MessageWKWebView: WKWebView {
    var onResize: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            onResize?()
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let keep: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierLookUp",
                                 "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierShareMenu"]
        for item in menu.items where !(item.identifier.map { keep.contains($0.rawValue) } ?? false) {
            menu.removeItem(item)
        }
        super.willOpenMenu(menu, with: event)
    }
}
