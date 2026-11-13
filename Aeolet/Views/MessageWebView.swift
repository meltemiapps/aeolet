import SwiftUI
import WebKit

/// Sandboxed message renderer: no scripts, no persistent storage, remote content blocked unless explicitly allowed.
struct MessageWebView: UIViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    @Binding var height: CGFloat
    let onLink: (URL) -> Void

    static func document(from body: String, allowRemote: Bool) -> String {
        MessageHTML.document(from: body, allowRemote: allowRemote)
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
                forIdentifier: "aeolet.block-remote", encodedContentRuleList: MessageHTML.blockRules
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
               MessageHTML.isOpenableLink(url) {
                parent.onLink(url)
            }
        }
    }
}
