// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import TermindApplication
@testable import TermindRemoteInfrastructure

struct KeyPassphraseEnvelopeTests {
    @Test(arguments: [
        #"{"privateKey":"encrypted","passphrase":"密语😀\n\"\\"}"#,
        #"{"passphrase":"\u5bc6\u8bed\ud83d\ude00\n\"\\","privateKey":"encrypted"}"#,
    ])
    func oldEnvelopeDecodesWithoutImmutableSecretStrings(_ json: String) throws {
        var data = Data(json.utf8)
        let observation = EnvelopeZeroization()
        let credential = try KeychainSecretStore.decodeKeySecrets(from: &data)
        guard case .software(let key, let passphrase) = credential else {
            Issue.record("Expected software key")
            return
        }
        let phrase = try #require(passphrase)
        for secret in [key, phrase] { secret.observeZeroization { observation.record($0) } }
        #expect(key.matches("encrypted"))
        #expect(phrase.matches("密语😀\n\"\\"))
        #expect(data.isEmpty)
        var encoded = try KeychainSecretStore.encodeKeySecrets(privateKey: key, passphrase: phrase)
        let editor = try JSONDecoder().decode(SSHPrivateKeySecret.self, from: encoded)
        #expect(editor.privateKey == "encrypted" && editor.passphrase == "密语😀\n\"\\")
        SecretMemory.clear(&encoded)
        #expect(observation.count == 2 && observation.allZero)
    }

    @Test(arguments: [
        #"{"privateKey":"key"}"#, #"{"privateKey":"key","passphrase":null}"#, #"{"passphrase":"","privateKey":"key"}"#,
    ])
    func envelopesWithoutSavedPassphraseRemainCompatible(_ json: String) throws {
        var data = Data(json.utf8)
        let credential = try KeychainSecretStore.decodeKeySecrets(from: &data)
        defer { credential.clearSecrets() }
        #expect(!credential.hasSavedPassphrase)
        #expect(data.isEmpty)
    }

    @Test(arguments: [
        #"{"privateKey":"key","privateKey":"duplicate"}"#,
        #"{"privateKey":"key","passphrase":"first","passphrase":"second"}"#,
        #"{"privateKey":"key","passphrase":12}"#,
        #"{"privateKey":"key","passphrase":"\ud800"}"#,
        #"{"privateKey":"key","passphrase":"saved"} trailing"#,
        #"{"passphrase":"saved"}"#,
        #"{"privateKey":"key","extra":"saved"}"#,
        #"{"privateKey":"key","passphrase":"saved",}"#,
    ])
    func malformedEnvelopeZeroesEveryDecodedBuffer(_ json: String) {
        let observation = EnvelopeZeroization()
        var data = Data(json.utf8)
        #expect(throws: KeychainSecretError.self) {
            _ = try KeychainSecretStore.decodeKeySecrets(from: &data) { secret in
                secret.observeZeroization { observation.record($0) }
            }
        }
        #expect(data.isEmpty)
        #expect(observation.count > 0 && observation.allZero)
    }

    @Test func keychainSourceBytesAreZeroedOnParseFailure() {
        let observation = EnvelopeZeroization()
        let bytes = Array(
            (#"{"privateKey":"key","passphrase":"saved"} invalid"# + String(repeating: " ", count: 4096)).utf8)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
        bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        var data = Data(
            bytesNoCopy: pointer, count: bytes.count,
            deallocator: .custom { pointer, count in
                observation.record(UnsafeRawBufferPointer(start: pointer, count: count))
                pointer.deallocate()
            })
        #expect(throws: KeychainSecretError.self) { _ = try KeychainSecretStore.decodeKeySecrets(from: &data) }
        #expect(observation.count == 1 && observation.allZero)
    }

    @Test func serializationFailureStillZeroesTheUnusedPassphrase() {
        let observation = EnvelopeZeroization()
        let consumed = SSHSecret("key")
        consumed.clear()
        let phrase = SSHSecret("saved")
        phrase.observeZeroization { observation.record($0) }
        #expect(throws: SSHSecret.Consumed.self) {
            _ = try KeychainSecretStore.encodeKeySecrets(privateKey: consumed, passphrase: phrase)
        }
        #expect(observation.count == 1 && observation.allZero)
    }
}

private nonisolated final class EnvelopeZeroization: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [Bool] = []
    var count: Int { lock.withLock { observations.count } }
    var allZero: Bool { lock.withLock { observations.allSatisfy { $0 } } }
    func record(_ bytes: UnsafeRawBufferPointer) {
        lock.withLock { observations.append(!bytes.isEmpty && bytes.allSatisfy { $0 == 0 }) }
    }
}
