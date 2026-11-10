import Foundation

struct PGPContactKey: Codable, Identifiable, Hashable {
    var id: String { email }
    let email: String
    let fingerprint: String
    let armored: String
    var isVerified: Bool
}

struct PGPOwnKey: Codable, Identifiable, Hashable {
    var id: String { account }
    let account: String
    let fingerprint: String
    let publicKey: String
}

private struct PGPStoreFile: Codable {
    var enabled = false
    var own: [PGPOwnKey] = []
    var contacts: [PGPContactKey] = []
}

/// PGP is off until the person turns it on. Private keys are Keychain-only and locked by their passphrase.
@MainActor
final class PGPStore: ObservableObject {
    static let shared = PGPStore()

    @Published private(set) var isEnabled = false
    @Published private(set) var ownKeys: [PGPOwnKey] = []
    @Published private(set) var contacts: [PGPContactKey] = []

    private var passphrases: [String: String] = [:]
    private let fileName = "pgp-public.json"

    private init() {
        if let data = PrivateFile.read(name: fileName),
           let file = try? JSONDecoder().decode(PGPStoreFile.self, from: data) {
            isEnabled = file.enabled
            ownKeys = file.own
            contacts = file.contacts
        }
    }

    private func persist() {
        let file = PGPStoreFile(enabled: isEnabled, own: ownKeys, contacts: contacts)
        if let data = try? JSONEncoder().encode(file) { try? PrivateFile.write(data, name: fileName) }
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        if !value { forgetPassphrases() }
        persist()
    }

    // MARK: Passphrases are held in memory only and cleared when the app leaves the foreground.

    func cachedPassphrase(for account: String) -> String? { passphrases[account] }
    func remember(passphrase: String, for account: String) { passphrases[account] = passphrase }
    func forgetPassphrases() { passphrases = [:] }

    // MARK: Own keys

    private func privateKeyName(_ account: String) -> String { "pgp.private.\(account.lowercased())" }

    func ownKey(for account: String) -> PGPOwnKey? { ownKeys.first { $0.account == account } }

    func privateKey(for account: String) throws -> String {
        guard let data = try KeychainStore.load(privateKeyName(account)) else { throw PGPError.noPrivateKey }
        return String(decoding: data, as: UTF8.self)
    }

    func generateKey(account: String, name: String, passphrase: String) async throws {
        let key = try await PGPEngine.shared.generateKey(name: name, email: account, passphrase: passphrase)
        try KeychainStore.save(Data(key.privateKey.utf8), key: privateKeyName(account), protection: .whenUnlocked)
        setOwn(PGPOwnKey(account: account, fingerprint: key.fingerprint, publicKey: key.publicKey))
    }

    func importPrivateKey(account: String, armored: String) async throws {
        let details = try await PGPEngine.shared.inspect(armored: armored)
        guard details.isPrivate else { throw PGPError.operation("That is a public key. Import your private key here.") }
        guard details.isLocked else { throw PGPError.operation("Protect this key with a passphrase before importing it.") }
        guard details.canEncrypt else { throw PGPError.operation("This key has expired or cannot encrypt.") }
        try KeychainStore.save(Data(armored.utf8), key: privateKeyName(account), protection: .whenUnlocked)
        setOwn(PGPOwnKey(account: account, fingerprint: details.fingerprint, publicKey: details.publicKey))
    }

    private func setOwn(_ key: PGPOwnKey) {
        ownKeys.removeAll { $0.account == key.account }
        ownKeys.append(key)
        persist()
    }

    func deleteOwnKey(account: String) {
        KeychainStore.delete(privateKeyName(account))
        ownKeys.removeAll { $0.account == account }
        passphrases[account] = nil
        persist()
    }

    // MARK: Contact keys

    /// Adds a public key under every email address it claims. Replaced fingerprints must be re-verified.
    func addContact(armored: String, verified: Bool) async throws -> [String] {
        let details = try await PGPEngine.shared.inspect(armored: armored)
        guard details.canEncrypt else { throw PGPError.operation("This key has expired or cannot encrypt.") }
        let emails = details.userIDs.map(\.emailAddressOnly).filter { $0.contains("@") }
        guard !emails.isEmpty else { throw PGPError.operation("This key has no email address.") }
        for email in emails {
            contacts.removeAll { $0.email == email }
            contacts.append(PGPContactKey(email: email, fingerprint: details.fingerprint, armored: details.publicKey, isVerified: verified))
        }
        contacts.sort { $0.email < $1.email }
        persist()
        return emails
    }

    func setVerified(_ contact: PGPContactKey, _ value: Bool) {
        guard let index = contacts.firstIndex(of: contact) else { return }
        contacts[index].isVerified = value
        persist()
    }

    func removeContact(_ contact: PGPContactKey) {
        contacts.removeAll { $0 == contact }
        persist()
    }

    func publicKey(forEmail email: String) -> String? {
        let address = email.emailAddressOnly
        if let own = ownKeys.first(where: { $0.account.lowercased() == address }) { return own.publicKey }
        return contacts.first { $0.email == address }?.armored
    }

    func isVerified(email: String) -> Bool {
        let address = email.emailAddressOnly
        return ownKeys.contains { $0.account.lowercased() == address } || contacts.first { $0.email == address }?.isVerified == true
    }

    /// Person-initiated lookup only. It reveals the address searched to keys.openpgp.org, so it never runs automatically.
    func fetchFromKeyServer(email: String) async throws -> [String] {
        let address = email.emailAddressOnly
        guard let url = URL(string: "https://keys.openpgp.org/vks/v1/by-email/\(address.formEncoded)") else {
            throw PGPError.operation("That email address is not valid.")
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PGPError.operation("No published key found for \(address).")
        }
        return try await addContact(armored: String(decoding: data, as: UTF8.self), verified: false)
    }

    // MARK: Outgoing

    func protect(entity: Data, account: String, recipients: [String], encrypt: Bool, sign: Bool, passphrase: String?) async throws -> Data {
        guard encrypt || sign else { return entity }
        var signingKey: String?
        if sign {
            guard passphrase != nil else { throw PGPError.passphraseRequired }
            signingKey = try privateKey(for: account)
        }
        if encrypt {
            let missing = recipients.filter { publicKey(forEmail: $0) == nil }
            guard missing.isEmpty else { throw PGPError.missingRecipientKeys(missing) }
            guard let own = ownKey(for: account) else { throw PGPError.noPrivateKey }
            var keys = recipients.compactMap { publicKey(forEmail: $0) }
            keys.append(own.publicKey)
            let armored = try await PGPEngine.shared.encrypt(entity, recipients: keys, signingKey: signingKey, passphrase: passphrase)
            return MIMEBuilder.encryptedEntity(armored: armored)
        }
        let result = try await PGPEngine.shared.signDetached(entity, privateKey: signingKey ?? "", passphrase: passphrase ?? "")
        return MIMEBuilder.signedEntity(content: entity, signature: result.signature, micalg: result.micalg)
    }
}
