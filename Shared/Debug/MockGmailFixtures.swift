#if DEBUG
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Realistic, fictional mail for the mock Gmail server. Everything uses reserved example domains.
enum MockGmailFixtures {
    static let elena = "elena@example.com"
    static let nikos = "nikos@example.com"

    // Google's own wording for each failure, as returned by the Gmail API.
    static let message401 = "Request had invalid authentication credentials. Expected OAuth 2 access token, login cookie or other valid authentication credential. See https://developers.google.com/identity/sign-in/web/devconsole-project."
    static let message403 = "Gmail API has not been used in project 123456789012 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/gmail.googleapis.com/overview?project=123456789012 then retry."
    static let message429 = "Too many concurrent requests for user."
    static let message500 = "Backend Error"

    static let travelLabel = "Label_1"
    static let projectsLabel = "Label_2"

    private static let systemLabels: [MockGmailServer.Label] = [
        "INBOX", "STARRED", "IMPORTANT", "SENT", "DRAFT", "SPAM", "TRASH", "UNREAD",
        "CATEGORY_PERSONAL", "CATEGORY_UPDATES",
    ].map { MockGmailServer.Label(id: $0, name: $0, type: "system") }

    private static let userLabels = [
        MockGmailServer.Label(id: travelLabel, name: "Travel", type: "user"),
        MockGmailServer.Label(id: projectsLabel, name: "Projects", type: "user"),
    ]

    // MARK: Mail definitions

    private struct Mail {
        var from: String
        var to: [String]
        var cc: [String] = []
        var subject: String
        var text: String
        var html: String? = nil
        var attachments: [OutgoingAttachment] = []
        var labels: Set<String>
        var minutesAgo: Double
    }

    private struct Thread {
        var mails: [Mail]
    }

    static func mailboxes(server: MockGmailServer) -> [MockGmailServer.Mailbox] {
        let elenaBox = MockGmailServer.Mailbox(address: elena, displayName: "Elena Marinou", labels: systemLabels + userLabels)
        let nikosBox = MockGmailServer.Mailbox(address: nikos, displayName: "Nikos Andreou", labels: systemLabels + userLabels)
        load(elenaThreads(), into: elenaBox, server: server)
        load(nikosThreads(), into: nikosBox, server: server)
        return [elenaBox, nikosBox]
    }

    private static func load(_ threads: [Thread], into mailbox: MockGmailServer.Mailbox, server: MockGmailServer) {
        for thread in threads {
            var threadID: String?
            for mail in thread.mails {
                let raw = rfc822(mail)
                let stored = server.store(raw: raw, in: mailbox, labels: mail.labels, threadID: threadID,
                                                          date: Date(timeIntervalSinceNow: -mail.minutesAgo * 60))
                threadID = stored.threadID
            }
        }
    }

    private static func rfc822(_ mail: Mail) -> [UInt8] {
        let entity: Data
        if let html = mail.html {
            entity = alternative(text: mail.text, html: html)
        } else {
            entity = MIMEBuilder.contentEntity(text: mail.text, attachments: mail.attachments)
        }
        let headers = OutgoingHeaders(from: mail.from, to: mail.to, cc: mail.cc, subject: mail.subject)
        let domain = mail.from.emailAddressOnly.split(separator: "@").last.map(String.init) ?? "example.com"
        return [UInt8](MIMEBuilder.message(headers: headers, entity: entity, senderDomain: domain,
                                           date: Date(timeIntervalSinceNow: -mail.minutesAgo * 60)))
    }

    private static func alternative(text: String, html: String) -> Data {
        let mark = "alt-\(UUID().uuidString)"
        func part(_ type: String, _ body: String) -> String {
            "--\(mark)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                + Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                + "\r\n"
        }
        return Data(("Content-Type: multipart/alternative; boundary=\"\(mark)\"\r\n\r\n"
            + part("text/plain", text) + part("text/html", html) + "--\(mark)--\r\n").utf8)
    }

    // MARK: Elena's mailbox: 30 threads

    private static let nikosName = "Nikos Andreou <nikos@example.com>"
    private static let elenaName = "Elena Marinou <elena@example.com>"
    private static let sofia = "Sofia Papadaki <sofia@example.org>"
    private static let maria = "Maria Lekka <maria@example.org>"
    private static let dimitra = "Dimitra Kosta <dimitra@example.net>"

    private static func elenaThreads() -> [Thread] {
        let inbox: Set<String> = ["INBOX"]
        let unread: Set<String> = ["INBOX", "UNREAD"]
        return [
            Thread(mails: [
                Mail(from: elenaName, to: [nikosName], subject: "Dinner on Friday?",
                     text: "Hi Nikos,\n\nAre you free for dinner on Friday? I was thinking of the taverna by the harbour.\n\nElena",
                     labels: ["SENT"], minutesAgo: 190),
                Mail(from: nikosName, to: [elenaName], cc: [sofia, maria], subject: "Re: Dinner on Friday?",
                     text: "Friday works. I've asked Sofia and Maria too, the more the merrier.\n\nNikos",
                     labels: inbox, minutesAgo: 120),
                Mail(from: nikosName, to: [elenaName], cc: [sofia, maria], subject: "Re: Dinner on Friday?",
                     text: "Booked a table for four at 8pm. Bring your appetite!\n\nNikos",
                     labels: unread, minutesAgo: 14),
            ]),
            Thread(mails: [Mail(from: "Aegean Ferries <tickets@aegeanferries.example>", to: [elena], subject: "Your ferry tickets: Piraeus to Naxos",
                                text: "Thank you for booking with Aegean Ferries.\n\nDeparture: Saturday 07:25 from Piraeus, gate E7.\nYour boarding passes are attached.",
                                attachments: [OutgoingAttachment(filename: "Boarding passes.pdf", mimeType: "application/pdf", data: pdf(title: "Boarding passes"))],
                                labels: ["INBOX", "UNREAD", "STARRED", travelLabel], minutesAgo: 35)]),
            Thread(mails: [Mail(from: sofia, to: [elena], subject: "Photos from the weekend",
                                text: "Here's my favourite from Hydra. The light was perfect!\n\nSofia",
                                attachments: [OutgoingAttachment(filename: "Hydra harbour.jpg", mimeType: "image/jpeg", data: jpeg(caption: "Hydra"))],
                                labels: unread, minutesAgo: 62)]),
            Thread(mails: [Mail(from: "Aegean Weekly <newsletter@aegeanweekly.example>", to: [elena], subject: "This week: hidden beaches of Milos",
                                text: "Hidden beaches of Milos, a ferry guide and the best loukoumades in Plaka.",
                                html: """
                                <h2>Hidden beaches of Milos</h2>
                                <img src="https://images.aegeanweekly.example/milos-hero.jpg" alt="Sarakiniko beach at sunset" width="600">
                                <p>Five coves you can only reach on foot, a ferry guide for the season, and the best loukoumades in Plaka.</p>
                                <img src="https://track.aegeanweekly.example/open.gif?id=reader-482" width="1" height="1" alt="">
                                <p><a href="https://aegeanweekly.example/milos">Read the full story</a></p>
                                """,
                                labels: inbox, minutesAgo: 95)]),
            Thread(mails: [Mail(from: dimitra, to: [elena], subject: "Confidential: contract draft",
                                text: encryptedForStranger, labels: unread, minutesAgo: 140)]),
            Thread(mails: [Mail(from: dimitra, to: [elena], subject: "Signed release notes",
                                text: signedByStranger, labels: inbox, minutesAgo: 210)]),
            Thread(mails: [Mail(from: "Studio Kalimera <hello@kalimera.example>", to: [elena], subject: "Invoice 2026-114",
                                text: "Hi Elena,\n\nPlease find the invoice for the October design work attached. Payment within 30 days.\n\nThank you!",
                                attachments: [OutgoingAttachment(filename: "Invoice 2026-114.pdf", mimeType: "application/pdf", data: pdf(title: "Invoice 2026-114"))],
                                labels: ["INBOX", projectsLabel], minutesAgo: 300)]),
            Thread(mails: [
                Mail(from: elenaName, to: [maria], subject: "Logo sketches",
                     text: "Maria, here are my notes on the three logo directions. I like the wind motif best.", labels: ["SENT", projectsLabel], minutesAgo: 1500),
                Mail(from: maria, to: [elenaName], subject: "Re: Logo sketches",
                     text: "Agreed, the wind one has the most character. I'll refine it this week.", labels: ["INBOX", projectsLabel], minutesAgo: 420),
            ]),
            Thread(mails: [Mail(from: "Yannis Vlachos <yannis@example.org>", to: [elena], subject: "Sailing on Saturday",
                                text: "Forecast says 4 Beaufort from the north. Perfect for a day out to Aegina. Meet at the marina at 9?",
                                labels: ["INBOX", travelLabel], minutesAgo: 600)]),
            Thread(mails: [Mail(from: "Athens Library <noreply@library.example>", to: [elena], subject: "Your reservation is ready",
                                text: "The book you reserved, \"The Colossus of Maroussi\", is ready to collect until Thursday.", labels: inbox, minutesAgo: 900)]),
            Thread(mails: [Mail(from: "Olive Grove Co-op <hello@olivegrove.example>", to: [elena], subject: "Harvest volunteers needed",
                                text: "We're picking from the 20th. Lunch and a bottle of this year's oil for every volunteer.", labels: unread, minutesAgo: 1300)]),
            Thread(mails: [Mail(from: "Thanasis Georgiou <thanasis@example.org>", to: [elena], subject: "Quick question about the API",
                                text: "Does the sync endpoint page results, or do we get everything at once?", labels: ["INBOX", "STARRED", projectsLabel], minutesAgo: 1700)]),
            Thread(mails: [Mail(from: "Kymanet Mobile <billing@kymanet.example>", to: [elena], subject: "Your November bill",
                                text: "Your bill for November is €18.40 and will be collected on the 28th.", labels: inbox, minutesAgo: 2200)]),
            Thread(mails: [Mail(from: "Mum <anna.marinou@example.org>", to: [elena], subject: "Sunday lunch",
                                text: "Gemista on Sunday, come hungry. Bring the good bread from the bakery on the corner.", labels: ["INBOX", "STARRED"], minutesAgo: 2600)]),
            Thread(mails: [Mail(from: "Dev Days <speakers@devdays.example>", to: [elena], subject: "Speaker confirmation: Thessaloniki Dev Days",
                                text: "You're confirmed for the 14:00 slot in Hall B. Travel and two nights' hotel are covered.", labels: ["INBOX", travelLabel], minutesAgo: 3100)]),
            Thread(mails: [Mail(from: "Lycabettus Runners <club@runners.example>", to: [elena], subject: "Route for Sunday",
                                text: "10 km loop, meeting at the bottom of the funicular at 7:30.", labels: inbox, minutesAgo: 3600)]),
            Thread(mails: [Mail(from: "Kostas Ioannou <kostas@example.org>", to: [elena], subject: "Apartment viewing",
                                text: "The flat in Koukaki is free to view on Tuesday at 6pm. Balcony faces the Acropolis!", labels: inbox, minutesAgo: 4200)]),
            Thread(mails: [Mail(from: "Light & Lens <workshop@lightlens.example>", to: [elena], subject: "Workshop materials",
                                text: "Attached is the kit list for Saturday's street photography workshop.",
                                attachments: [OutgoingAttachment(filename: "Kit list.pdf", mimeType: "application/pdf", data: pdf(title: "Kit list"))],
                                labels: inbox, minutesAgo: 5000)]),
            Thread(mails: [Mail(from: "Recipe Box <recipes@recipebox.example>", to: [elena], subject: "Your saved recipes",
                                text: "Spanakopita, fasolada and portokalopita are waiting in your recipe box.", labels: inbox, minutesAgo: 6200)]),
            Thread(mails: [Mail(from: "Maria Lekka <maria@example.org>", to: [elena], subject: "Sprint planning notes",
                                text: "Notes from today: ship offline mode first, then the widget.", labels: ["INBOX", projectsLabel], minutesAgo: 7000)]),
            Thread(mails: [Mail(from: "Accountant <office@taxhelp.example>", to: [elena], subject: "Old tax documents",
                                text: "I've archived your 2024 documents. Nothing else needed from you.", labels: [projectsLabel], minutesAgo: 9000)]),
            Thread(mails: [Mail(from: elenaName, to: ["Landlord <landlord@example.org>"], subject: "Repair request",
                                text: "The kitchen tap is dripping again. Could someone take a look this week?", labels: ["SENT"], minutesAgo: 1100)]),
            Thread(mails: [Mail(from: elenaName, to: ["Dev Days <speakers@devdays.example>"], subject: "Travel details",
                                text: "I'll arrive on the morning train and leave on Sunday evening.", labels: ["SENT", travelLabel], minutesAgo: 2900)]),
            Thread(mails: [Mail(from: elenaName, to: [sofia], subject: "Can you send the photos?",
                                text: "Would love a copy of the Hydra pictures when you have a moment!", labels: ["SENT"], minutesAgo: 1400)]),
            Thread(mails: [Mail(from: "Passport Office <appointments@passport.example>", to: [elena], subject: "Passport renewal appointment",
                                text: "Your appointment is confirmed for 3 December at 10:15.", labels: ["STARRED"], minutesAgo: 8000)]),
            Thread(mails: [Mail(from: "Chania Old Town Hotel <stay@chaniahotel.example>", to: [elena], subject: "Hotel booking in Chania",
                                text: "Two nights, sea-view room, breakfast included.", labels: [travelLabel], minutesAgo: 9500)]),
            Thread(mails: [Mail(from: "Totally Real Prize <winner@prize.example>", to: [elena], subject: "You have won!!!",
                                text: "Click to claim.", labels: ["SPAM"], minutesAgo: 400)]),
            Thread(mails: [Mail(from: "Old News <news@oldnews.example>", to: [elena], subject: "Last month's newsletter",
                                text: "Nothing to see here.", labels: ["TRASH"], minutesAgo: 20000)]),
            Thread(mails: [Mail(from: "Nikos Andreou <nikos@example.com>", to: [elena], subject: "Team offsite in Delphi",
                                text: "Proposed dates: 12 to 14 March. Let me know what works.", labels: ["INBOX", travelLabel, projectsLabel], minutesAgo: 1900)]),
            Thread(mails: [Mail(from: "Maria Lekka <maria@example.org>", to: [elena], subject: "Brochure proofs",
                                text: "Proofs are back from the printer, they look great.", labels: ["INBOX", "STARRED", projectsLabel], minutesAgo: 5600)]),
        ]
    }

    // MARK: Nikos's mailbox

    private static func nikosThreads() -> [Thread] {
        [
            Thread(mails: [Mail(from: elenaName, to: [nikosName], subject: "Dinner on Friday?",
                                text: "Hi Nikos,\n\nAre you free for dinner on Friday?\n\nElena", labels: ["INBOX"], minutesAgo: 190)]),
            Thread(mails: [Mail(from: "Aeolet <hello@aeolet.example>", to: [nikos], subject: "Welcome to Aeolet",
                                text: "Your mail, on your device, private by design.", labels: ["INBOX", "UNREAD"], minutesAgo: 30)]),
            Thread(mails: [Mail(from: "Sofia Papadaki <sofia@example.org>", to: [nikos], subject: "Football on Thursday",
                                text: "Five-a-side at 8. We need a goalkeeper!", labels: ["INBOX"], minutesAgo: 240)]),
            Thread(mails: [Mail(from: "Delphi Lodge <stay@delphilodge.example>", to: [nikos], subject: "Group booking request",
                                text: "We can host twelve people from 12 to 14 March.", labels: ["INBOX", travelLabel], minutesAgo: 800)]),
            Thread(mails: [Mail(from: nikosName, to: ["Delphi Lodge <stay@delphilodge.example>"], subject: "Offsite enquiry",
                                text: "Could you host a team of twelve in March?", labels: ["SENT"], minutesAgo: 1600)]),
            Thread(mails: [Mail(from: "Bike Shop <service@bikeshop.example>", to: [nikos], subject: "Your bike is ready",
                                text: "New chain and brake pads fitted.", labels: ["INBOX", "STARRED"], minutesAgo: 3000)]),
        ]
    }

    // MARK: New mail that arrives on refresh

    static let arrivalSubject = "Ferry delayed by 20 minutes"

    static func arrival(for account: String) -> [UInt8] {
        rfc822(Mail(from: "Aegean Ferries <tickets@aegeanferries.example>", to: [account], subject: arrivalSubject,
                    text: "Saturday's 07:25 sailing to Naxos will leave at 07:45. Sorry for the wait.", labels: [], minutesAgo: 0))
    }

    // MARK: Generated attachments

    #if os(iOS)
    static func pdf(title: String) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { context in
            context.beginPage()
            (title as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
            ("Sample document generated for Aeolet's test fixtures." as NSString)
                .draw(at: CGPoint(x: 60, y: 130), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
    }

    static func jpeg(caption: String) -> Data {
        let size = CGSize(width: 800, height: 533)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.05, green: 0.37, blue: 0.6, alpha: 1).cgColor, UIColor(red: 0.98, green: 0.82, blue: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            (caption as NSString).draw(at: CGPoint(x: 40, y: 440), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white])
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }
    #else
    static func pdf(title: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (title as NSString).draw(at: CGPoint(x: 60, y: 842 - 108), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
        ("Sample document generated for Aeolet's test fixtures." as NSString)
            .draw(at: CGPoint(x: 60, y: 842 - 147), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func jpeg(caption: String) -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 533, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let colors = [NSColor(red: 0.98, green: 0.82, blue: 0.55, alpha: 1).cgColor, NSColor(red: 0.05, green: 0.37, blue: 0.6, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        graphics.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 533), options: [])
        (caption as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? Data()
    }
    #endif

    // MARK: OpenPGP made with GnuPG for "Dimitra Kosta <dimitra@example.net>", a key no test account holds.

    static let encryptedForStranger = """
    -----BEGIN PGP MESSAGE-----

    hF4DOIOtdtKCy1ASAQdA92s5hNzI8M8Lgf2CbOOGE+iXHIiz1wSwmKZrSsPq6lsw
    R/iTi4RiUqbvlqJ6bBvFtYSrLAquV3QoJ9KXD4lvTG/E2JnCUzdFgILPtTCcpcMr
    1MCRAQkCEGZIXL4fwh4fY+m+enNV73VvrRt6GVeO7hJBRNbAQy4bWeeQzmurcqqi
    mVonqPuUcaPYqXtLP4P08h5qKKSkWH4Pix7HTRdaN+wKtwITVyuYmesND2oWYrSk
    bRvPO6FcH80zOUO8xVa6cpkpHjBVSauDqkMl0NvqGnsk8ndP3w9OipNMoJjSoTMI
    Isf2klNwrg/Nh0jJMg6oCOXFrOsjbanRidvyda2XAeKJZRO9+gy+en6BAFkLHtiT
    sFxvEZJrW21J1Zo7eTUfwKLRqomJCcIeo1V9a6rq6D4bew6sMf9ooBcxlwVlem6U
    952ka1Xc9bKtZ/GNAG8huFOWbZ6H3Y2i8ndM/x17AjRvCqvon9B1mCotiYWX0vW/
    tsq9qJIRYnfGSZpJM8prRN3a2iuChvipd2hL1w2LluABbUxz0oGXdhQohVn3tOQN
    LMmqzw==
    =WGwY
    -----END PGP MESSAGE-----
    """

    static let signedByStranger = """
    -----BEGIN PGP SIGNED MESSAGE-----
    Hash: SHA512

    Aeolet 0.1.0 release notes

    - - Native Gmail client for iPhone and iPad
    - - Optional OpenPGP encryption
    - - No server, no tracking
    -----BEGIN PGP SIGNATURE-----

    iKYEARYKAE4WIQRiPEf9uD/xwswOaTEamek0zcfJkgUCavN0GxsUgAAAAAAEAA5t
    YW51MiwyLjUrMS4xMiwwLDMUHGRpbWl0cmFAZXhhbXBsZS5uZXQACgkQGpnpNM3H
    yZLYuwEA3Zfym4dbKqg+sga663oKEUosqJCAHgkWK4q0EMMhY+sBAN7He1XglzLm
    mQvghDkf8y2pcAzBlcXEA5690NYkEToB
    =PgYp
    -----END PGP SIGNATURE-----
    """
}
#endif
