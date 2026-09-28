import CryptoKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

struct WebAuthnSSHTests {
    private struct Fixture {
        let key = P256.Signing.PrivateKey()
        let challenge = Data("ssh authentication message".utf8)
        var credential: SecurityKeyCredential {
            SecurityKeyCredential(credentialID: Data([1, 2, 3]), publicKeyX963: key.publicKey.x963Representation)
        }
        var request: SecurityKeySigningRequest {
            SecurityKeySigningRequest(
                hostID: UUID(), hostname: "fixture.invalid", credential: credential, challenge: challenge)
        }
        func assertion(flags: UInt8 = 1, extensions: Data = Data()) throws -> SecurityKeyAssertion {
            let encoded = challenge.base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let client = Data(
                "{\"type\":\"webauthn.get\",\"challenge\":\"\(encoded)\",\"origin\":\"https://\(SecurityKeyCredential.relyingParty)\",\"crossOrigin\":false}"
                    .utf8)
            let auth =
                Data(SHA256.hash(data: Data(SecurityKeyCredential.relyingParty.utf8)))
                + Data([flags, 0, 0, 0, 7]) + extensions
            return SecurityKeyAssertion(
                credentialID: credential.credentialID, authenticatorData: auth,
                clientDataJSON: client,
                signature: try key.signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation)
        }
    }

    @Test func verifiesAndPreservesSignedWebAuthnFields() throws {
        let fixture = Fixture()
        let assertion = try fixture.assertion(flags: 5)
        let signature = try WebAuthnSSH.signature(assertion, for: fixture.request)
        var reader = Reader(data: signature)
        #expect(try reader.field() == Data(WebAuthnSSH.signatureAlgorithm.utf8))
        var pair = Reader(data: try reader.field())
        let r = try pair.field()
        let s = try pair.field()
        #expect(!r.isEmpty && !s.isEmpty && pair.offset == pair.data.count)
        #expect(signature[reader.offset] == 5)
        reader.offset += 5
        #expect(try reader.field() == Data("https://\(SecurityKeyCredential.relyingParty)".utf8))
        #expect(try reader.field() == assertion.clientDataJSON)
        #expect(try reader.field().isEmpty)
        #expect(reader.offset == signature.count)
        #expect(assertion.userPresent && assertion.userVerified)
    }

    @Test func rejectsTamperingAndMissingUserVerification() throws {
        let fixture = Fixture()
        let assertion = try fixture.assertion()
        var request = fixture.request
        request.credential.userVerification = .required
        #expect(throws: (any Error).self) { try WebAuthnSSH.signature(assertion, for: request) }
        request = fixture.request
        request.challenge.append(0)
        #expect(throws: (any Error).self) { try WebAuthnSSH.signature(assertion, for: request) }
        var changed = assertion
        changed.credentialID.append(0)
        #expect(throws: (any Error).self) { try WebAuthnSSH.signature(changed, for: fixture.request) }
        changed = assertion
        changed.authenticatorData[0] ^= 1
        #expect(throws: (any Error).self) { try WebAuthnSSH.signature(changed, for: fixture.request) }
        changed = assertion
        changed.authenticatorData[36] ^= 1
        #expect(throws: (any Error).self) { try WebAuthnSSH.signature(changed, for: fixture.request) }
        for length in 0..<37 {
            changed.authenticatorData = Data(assertion.authenticatorData.prefix(length))
            #expect(throws: (any Error).self) { try WebAuthnSSH.signature(changed, for: fixture.request) }
        }
        let noPresence = try fixture.assertion(flags: 0)
        #expect(throws: (any Error).self) { try WebAuthnSSH.signature(noPresence, for: fixture.request) }
        request = fixture.request
        request.credential.requiresUserPresence = false
        #expect(throws: Never.self) { try WebAuthnSSH.signature(noPresence, for: request) }
    }

    @Test func validatesExtensionsAndRejectsDuplicateCBORKeys() throws {
        let fixture = Fixture()
        let assertion = try fixture.assertion(flags: 0x81, extensions: Data([0xA1, 1, 2]))
        #expect(throws: Never.self) { try WebAuthnSSH.signature(assertion, for: fixture.request) }
        for extensions in [Data(), Data([0xA2, 1, 2, 1, 3]), Data([0xA0, 0]), Data([0xBF, 0xFF])] {
            let malformed = try fixture.assertion(flags: 0x81, extensions: extensions)
            #expect(throws: (any Error).self) { try WebAuthnSSH.signature(malformed, for: fixture.request) }
        }
    }

    @Test func credentialReferencesRoundTripAndRejectOtherFormats() throws {
        let credential = Fixture().credential
        let reference = try WebAuthnSSH.exportReference(credential)
        #expect(try WebAuthnSSH.importReference(reference) == credential)
        #expect(throws: (any Error).self) { try WebAuthnSSH.importReference("-----BEGIN OPENSSH PRIVATE KEY-----") }
        let key = try WebAuthnSSH.keyReference(credential, label: "Fixture")
        #expect(key.algorithm == .securityKey && key.requiresUserPresence)
        #expect(SSHImportParser.validPublicKey(try WebAuthnSSH.publicBlob(credential), algorithm: .securityKey))
    }

    @Test func credentialEnvelopesPreserveLegacySoftwareKeys() throws {
        var software = Data("{\"privateKey\":\"legacy-key\",\"passphrase\":\"legacy-passphrase\"}".utf8)
        guard case .software(let key, let phrase) = try KeychainSecretStore.decodeKeySecrets(from: &software) else {
            Issue.record("Expected the legacy software envelope")
            return
        }
        defer {
            key.clear()
            phrase?.clear()
        }
        #expect(key.matches("legacy-key"))
        #expect(phrase?.matches("legacy-passphrase") == true)
        #expect(software.isEmpty)
    }

    @Test func registrationsParseCOSEAndRejectEveryTruncation() throws {
        let fixture = Fixture()
        let raw = fixture.key.publicKey.x963Representation
        let cose =
            Data([0xA5, 1, 2, 3, 0x26, 0x20, 1, 0x21, 0x58, 32]) + raw[1..<33]
            + Data([0x22, 0x58, 32]) + raw[33..<65]
        let auth =
            Data(SHA256.hash(data: Data(SecurityKeyCredential.relyingParty.utf8)))
            + Data([0x41, 0, 0, 0, 0]) + Data(repeating: 0, count: 16) + Data([0, 3, 1, 2, 3]) + cose
        let attestation = Data([0xA1, 0x68]) + Data("authData".utf8) + Data([0x58, UInt8(auth.count)]) + auth
        let client = Data(
            "{\"type\":\"webauthn.create\",\"challenge\":\"AQ\",\"origin\":\"https://\(SecurityKeyCredential.relyingParty)\"}"
                .utf8)
        func decode(_ attestation: Data) throws -> SecurityKeyCredential {
            try WebAuthnSSH.registration(
                credentialID: fixture.credential.credentialID, attestation: attestation,
                clientDataJSON: client, challenge: Data([1]), userVerification: .preferred)
        }
        #expect(try decode(attestation) == fixture.credential)
        for length in 0..<attestation.count {
            #expect(throws: (any Error).self) { try decode(Data(attestation.prefix(length))) }
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0
        mutating func field() throws -> Data {
            guard data.count - offset >= 4 else { throw WebAuthnSSH.Failure.invalidResponse }
            let count = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard count <= data.count - offset else { throw WebAuthnSSH.Failure.invalidResponse }
            defer { offset += count }
            return Data(data[offset..<offset + count])
        }
    }
}
