import XCTest
@testable import Aeolet

/// Runs the real OpenPGP.js bridge inside the app, the way the app uses it.
@MainActor
final class PGPEngineTests: XCTestCase {
    func testGenerateEncryptDecryptRoundTrip() async throws {
        let engine = PGPEngine.shared
        let alice = try await engine.generateKey(name: "Alice", email: "alice@example.org", passphrase: "alice passphrase")
        let bob = try await engine.generateKey(name: "Bob", email: "bob@example.org", passphrase: "bob passphrase!")
        XCTAssertEqual(alice.fingerprint.count, 40)
        let armored = try await engine.encrypt(Data("hello".utf8), recipients: [bob.publicKey], signingKey: alice.privateKey, passphrase: "alice passphrase")
        let result = try await engine.decrypt(armored: armored, privateKey: bob.privateKey, passphrase: "bob passphrase!", verificationKeys: [alice.publicKey])
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "hello")
        XCTAssertEqual(result.signature, .valid)
        do {
            _ = try await engine.decrypt(armored: armored, privateKey: alice.privateKey, passphrase: "alice passphrase", verificationKeys: [])
            XCTFail("A key the message was not encrypted to must not decrypt it")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This message was encrypted to a different key, so it can't be decrypted with yours.")
        }
        do {
            _ = try await engine.decrypt(armored: armored, privateKey: bob.privateKey, passphrase: "not my passphrase", verificationKeys: [])
            XCTFail("A wrong passphrase must not decrypt")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Wrong passphrase, or this message was not encrypted to your key.")
        }
    }
}
