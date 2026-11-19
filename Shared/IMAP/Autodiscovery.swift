import Foundation

/// Finds IMAP and SMTP settings from an email address, in this order:
/// 1. Mozilla autoconfig published by the mail domain (https://autoconfig.<domain>/…, then https://<domain>/.well-known/…).
/// 2. DNS SRV records: _imaps._tcp for IMAP, _submissions._tcp then _smtps._tcp for SMTP (RFC 6186, RFC 8314).
/// 3. The domain itself on the implicit-TLS ports.
///
/// Discovery never sends the password or the full address: the autoconfig requests carry only the domain in the
/// host name, over HTTPS. Plain-text servers in a published configuration are skipped. Whatever is found is shown
/// in editable fields before the account is added.
enum Autodiscovery {
    enum Source: Equatable {
        case autoconfig(host: String)
        case dns
        case guess
        /// A consumer domain whose settings Aeolet already knows (Gmail, Yahoo). No network request is made.
        case known(MailAccount.Provider)
    }

    struct Result {
        var account: MailAccount
        var source: Source
    }

    static func discover(email: String) async -> Result {
        let fallback = MailAccount.defaults(for: email)
        let domain = fallback.domain
        guard !domain.isEmpty else { return Result(account: fallback, source: .guess) }
        if let provider = MailAccount.knownProvider(forDomain: domain), let preset = MailAccount.preset(provider, email: email) {
            return Result(account: preset, source: .known(provider))
        }

        for url in autoconfigURLs(domain: domain) {
            if let data = await fetch(url), let found = AutoconfigParser.parse(data, email: email) {
                return Result(account: found, source: .autoconfig(host: url.host ?? domain))
            }
        }
        if let found = await fromSRV(email: email, domain: domain) {
            return Result(account: found, source: .dns)
        }
        return Result(account: fallback, source: .guess)
    }

    static func autoconfigURLs(domain: String) -> [URL] {
        [
            URL(string: "https://autoconfig.\(domain)/mail/config-v1.1.xml"),
            URL(string: "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml"),
        ].compactMap { $0 }
    }

    // MARK: Autoconfig over HTTPS

    private static let session: URLSession = {
        let configuration = Network.configuration(.ephemeral)
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }()

    private static func fetch(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/xml, text/xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", data.count < 512 * 1024 else { return nil }
        return data
    }

    /// Follows a redirect only to another https URL.
    private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }
    }

    // MARK: DNS SRV

    private static func fromSRV(email: String, domain: String) async -> MailAccount? {
        #if DEBUG
        if MockGmail.isActive { return nil }
        #endif
        async let imaps = SRVLookup.query("_imaps._tcp.\(domain)")
        async let submissions = SRVLookup.query("_submissions._tcp.\(domain)")
        async let smtps = SRVLookup.query("_smtps._tcp.\(domain)")
        let (imapRecords, submissionRecords, smtpsRecords) = await (imaps, submissions, smtps)
        guard let imap = SRVLookup.best(imapRecords) else { return nil }
        var account = MailAccount.defaults(for: email)
        account.imap = ServerEndpoint(host: imap.target, port: imap.port, security: .tls)
        if let smtp = SRVLookup.best(submissionRecords) ?? SRVLookup.best(smtpsRecords) {
            account.smtp = ServerEndpoint(host: smtp.target, port: smtp.port, security: .tls)
        }
        return account
    }
}

/// Reads a Mozilla autoconfig file (config-v1.1.xml). Takes the first IMAP server and the first SMTP server that
/// use SSL/TLS or STARTTLS; plain-text entries are ignored.
final class AutoconfigParser: NSObject, XMLParserDelegate {
    private struct Server {
        var kind = ""
        var hostname = ""
        var port = 0
        var socketType = ""
        var username = ""
    }

    private var current: Server?
    private var text = ""
    private var incoming: [Server] = []
    private var outgoing: [Server] = []

    static func parse(_ data: Data, email: String) -> MailAccount? {
        let delegate = AutoconfigParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        func security(_ socketType: String) -> ConnectionSecurity? {
            switch socketType.uppercased() {
            case "SSL", "TLS": return .tls
            case "STARTTLS": return .startTLS
            default: return nil
            }
        }
        func usable(_ servers: [Server], kind: String) -> (Server, ConnectionSecurity)? {
            for server in servers where server.kind.lowercased() == kind {
                guard let security = security(server.socketType), !server.hostname.isEmpty,
                      (1...65535).contains(server.port) else { continue }
                return (server, security)
            }
            return nil
        }
        guard let (imap, imapSecurity) = usable(delegate.incoming, kind: "imap"),
              let (smtp, smtpSecurity) = usable(delegate.outgoing, kind: "smtp") else { return nil }

        var account = MailAccount.defaults(for: email)
        account.imap = ServerEndpoint(host: substitute(imap.hostname, email: email), port: imap.port, security: imapSecurity)
        account.smtp = ServerEndpoint(host: substitute(smtp.hostname, email: email), port: smtp.port, security: smtpSecurity)
        let username = substitute(imap.username, email: email)
        if !username.isEmpty { account.username = username }
        return account.imap.isValid && account.smtp.isValid ? account : nil
    }

    /// Fills in %EMAILADDRESS%, %EMAILLOCALPART% and %EMAILDOMAIN%.
    static func substitute(_ value: String, email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        return value
            .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
            .replacingOccurrences(of: "%EMAILLOCALPART%", with: parts.first ?? "")
            .replacingOccurrences(of: "%EMAILDOMAIN%", with: parts.count > 1 ? parts[1] : "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        if elementName == "incomingServer" || elementName == "outgoingServer" {
            current = Server(kind: attributes["type"] ?? "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "hostname": current?.hostname = value
        case "port": current?.port = Int(value) ?? 0
        case "socketType": current?.socketType = value
        case "username": current?.username = value
        case "incomingServer": if let current { incoming.append(current) }; current = nil
        case "outgoingServer": if let current { outgoing.append(current) }; current = nil
        default: break
        }
        text = ""
    }
}
