import Foundation

/// The sandbox policy for showing a message, shared by the iOS and Mac web views:
/// no scripts, no persistent storage, remote content blocked unless the person asks for it.
enum MessageHTML {
    /// A WebKit content rule that blocks every http(s) load. A second layer under the CSP.
    static let blockRules = """
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

    /// Message links the app will offer to open. Everything else is refused.
    static func isOpenableLink(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    static func hasRemoteContent(_ html: String?) -> Bool {
        guard let html else { return false }
        return html.range(of: "src\\s*=\\s*[\"']?https?:", options: [.regularExpression, .caseInsensitive]) != nil
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
