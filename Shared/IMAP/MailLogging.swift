import Logging

/// SwiftMail logs through swift-log, whose default handler writes to the console. Aeolet logs nothing about mail:
/// every swift-log message is dropped, so no command, server reply, address or credential can reach a log.
enum MailLogging {
    private static let installed: Void = {
        LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }
    }()

    static func silence() { _ = installed }
}
