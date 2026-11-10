import SwiftUI
import WebKit

/// Sandboxed message renderer: no scripts, no persistent storage, remote content blocked unless explicitly allowed.
struct MessageWebView: UIViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    @Binding var height: CGFloat
    let onLink: (URL) -> Void

    private static let blockRules = """
    [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}}]
    """

    static func document(from body: String, allowRemote: Bool) -> String {
        let images = allowRemote ? "data: https:" : "data:"
        let policy = "default-src 'none'; img-src \(images); style-src 'unsafe-inline'; font-src data:"
        return """
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <style>html{-webkit-text-size-adjust:100%}body{font:-apple-system-body;margin:0;word-wrap:break-word;overflow-wrap:anywhere}img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap;font:inherit}</style>
        </head><body>\(body)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .clear
        context.coordinator.observe(view)
        context.coordinator.load(into: view, html: html, allowRemote: allowRemoteContent)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: view, html: html, allowRemote: allowRemoteContent)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MessageWebView
        private var observation: NSKeyValueObservation?
        private var loadedKey: String?

        init(parent: MessageWebView) { self.parent = parent }

        func observe(_ view: WKWebView) {
            observation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let height = change.newValue?.height, height > 0 else { return }
                Task { @MainActor in
                    guard let self, abs(self.parent.height - height) > 1 else { return }
                    self.parent.height = height
                }
            }
        }

        func load(into view: WKWebView, html: String, allowRemote: Bool) {
            let key = "\(allowRemote)|\(html.hashValue)"
            guard key != loadedKey else { return }
            loadedKey = key
            let document = MessageWebView.document(from: html, allowRemote: allowRemote)
            view.configuration.userContentController.removeAllContentRuleLists()
            if allowRemote {
                view.loadHTMLString(document, baseURL: nil)
                return
            }
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "aeolet.block-remote", encodedContentRuleList: MessageWebView.blockRules
            ) { list, _ in
                // Fails closed: if the rule cannot be compiled the CSP above still blocks remote content.
                Task { @MainActor in
                    if let list { view.configuration.userContentController.add(list) }
                    view.loadHTMLString(document, baseURL: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                parent.onLink(url)
            }
        }
    }
}

extension MailBody {
    var renderableHTML: String {
        if let html { return html }
        let escaped = (text ?? "").htmlEscaped
        let linked = escaped.replacingOccurrences(of: "(https?://[^\\s<>\"]+)", with: "<a href=\"$1\">$1</a>", options: .regularExpression)
        return "<pre>\(linked)</pre>"
    }
}
