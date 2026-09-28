import CryptoKit
import Foundation
import OpenSSL
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHAgentForwardingTests {
    @Test func framesSurviveFragmentationAndCoalescing() throws {
        let first = SSHAgentProtocol.frame(Data([11]))
        let second = SSHAgentProtocol.frame(Data([13, 0, 0, 0, 0]))
        var decoder = SSHAgentProtocol()
        for byte in first.dropLast() {
            try decoder.append(Data([byte]))
            #expect(try decoder.next() == nil)
        }
        try decoder.append(Data(first.suffix(1)) + second)
        #expect(try decoder.next() == Data([11]))
        #expect(try decoder.next() == Data([13, 0, 0, 0, 0]))
        #expect(try decoder.next() == nil)
    }

    @Test func oversizedAndEmptyFramesAreRejected() {
        for length: UInt32 in [0, UInt32(SSHAgentProtocol.maximumPacket + 1), UInt32.max] {
            var decoder = SSHAgentProtocol()
            #expect(throws: (any Error).self) { try decoder.append(SSHAgentProtocol.uint32(length)) }
        }
    }

    @Test @MainActor func managementAndMalformedSignRequestsNeverReachSigner() async {
        let provider = RecordingAgent()
        for packet in [Data([17]), Data([18]), Data([19]), Data([13]), Data([11, 0])] {
            #expect(
                await SSHAgentProtocol.response(to: packet, provider: provider) == SSHAgentProtocol.frame(Data([5])))
        }
        #expect(provider.signCalls == 0)
    }

    @Test @MainActor func signatureFlagsAndDataArePreserved() async {
        let provider = RecordingAgent()
        let payload =
            Data([13]) + SSHAgentProtocol.field(Data([1, 2]))
            + SSHAgentProtocol.field(Data([3, 4])) + SSHAgentProtocol.uint32(4)
        #expect(
            await SSHAgentProtocol.response(to: payload, provider: provider)
                == SSHAgentProtocol.frame(Data([14]) + SSHAgentProtocol.field(Data([9]))))
        #expect(provider.signCalls == 1)
        #expect(provider.lastFlags == 4)
        #expect(provider.lastData == Data([3, 4]))
    }

    @Test(arguments: [
        SSHKeyMaterial.Generation.ed25519, .ecdsa(bits: 256), .ecdsa(bits: 384), .ecdsa(bits: 521), .rsa(bits: 2048),
    ])
    func signaturesVerifyIndependently(_ generation: SSHKeyMaterial.Generation) throws {
        let material = try SSHKeyMaterial.generate(generation, comment: "fixture", passphrase: nil)
        let data = Data("SSH agent independent verification".utf8)
        let flags: [UInt32] = material.algorithm == .rsa ? [0, 2, 4] : [0]
        for flag in flags {
            let blob = try SSHAgentKeySigner.sign(
                credential: .software(SSHSecret(material.privateKey)), passphrase: nil,
                algorithm: material.algorithm, data: data, flags: flag)
            try verify(blob, data: data, material: material)
        }
    }

    @Test func encryptedKeyUsesSavedPassphraseAndClearsSecrets() throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "fixture", passphrase: "fixture-password")
        let key = SSHSecret(material.privateKey)
        let password = SSHSecret("fixture-password")
        let data = Data("encrypted agent key".utf8)
        let signature = try SSHAgentKeySigner.sign(
            credential: .software(key, passphrase: password), passphrase: nil,
            algorithm: material.algorithm, data: data, flags: 0)
        #expect(key.isConsumed && password.isConsumed)
        try verify(signature, data: data, material: material, password: "fixture-password")
    }

    @Test @MainActor func disablingAndReenablingDoesNotReviveOldCapability() async throws {
        var host = Host(name: "fixture", host: "localhost", agentForwardingEnabled: true)
        let library = HostLibraryModel(hosts: [host])
        let factory = VaultSSHAgent.factory(library: library)
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host, port: 22, username: "fixture", credentials: [], expectedHostKeys: []))
        let agent = try #require(try await factory(request))
        #expect(try await agent.identities().isEmpty)
        host.agentForwardingEnabled = false
        library.upsert(host)
        host.agentForwardingEnabled = true
        library.upsert(host)
        await #expect(throws: (any Error).self) { try await agent.identities() }
        #expect(try await factory(request) != nil)
    }

    @Test @MainActor func forbiddenInteractionUsesSavedPasswordButNeverPrompts() async throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "fixture", passphrase: "fixture-password")
        let host = Host(name: "fixture", host: "localhost", agentForwardingEnabled: true)
        let key = SSHKeyRef(
            label: "Protected", algorithm: .ed25519, publicKey: material.publicKey,
            credentialRef: "fixture", storage: .thisDevice, hasPassphrase: true)
        let secrets = InMemorySecretStore()
        try secrets.setKeyCredential(
            .software(.init(privateKey: material.privateKey)), for: "fixture", storage: .thisDevice)
        let library = HostLibraryModel(hosts: [host], keys: [key], secrets: secrets)
        let factory = VaultSSHAgent.factory(
            library: library,
            unlock: { _ in
                Issue.record("Forbidden request opened an unlock prompt")
                return ["fixture-password"]
            })
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host, port: 22,
                username: "fixture", credentials: [], expectedHostKeys: []), interactionPolicy: .forbidden)
        let agent = try #require(try await factory(request))
        let identity = try #require(try await agent.identities().first)
        await #expect(throws: SSHInteractionRequired.self) {
            try await agent.sign(key: identity.blob, data: Data([1]), flags: 0)
        }
        try secrets.setKeyCredential(
            .software(.init(privateKey: material.privateKey, passphrase: "fixture-password")),
            for: "fixture", storage: .thisDevice)
        #expect(try await !agent.sign(key: identity.blob, data: Data([1]), flags: 0).isEmpty)
        try library.delete(keyID: key.id)
        #expect(try await agent.identities().isEmpty)
        await #expect(throws: (any Error).self) { try await agent.sign(key: identity.blob, data: Data([1]), flags: 0) }
    }

    @Test @MainActor func revocationDuringUnlockDiscardsTheAnswer() async throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "fixture", passphrase: "fixture-password")
        let host = Host(name: "fixture", host: "localhost", agentForwardingEnabled: true)
        let key = SSHKeyRef(
            label: "Protected", algorithm: .ed25519, publicKey: material.publicKey,
            credentialRef: "fixture", storage: .thisDevice, hasPassphrase: true)
        let secrets = InMemorySecretStore()
        try secrets.setKeyCredential(
            .software(.init(privateKey: material.privateKey)), for: "fixture", storage: .thisDevice)
        let library = HostLibraryModel(hosts: [host], keys: [key], secrets: secrets)
        let factory = VaultSSHAgent.factory(
            library: library,
            unlock: { _ in
                await MainActor.run {
                    var disabled = host
                    disabled.agentForwardingEnabled = false
                    library.upsert(disabled)
                }
                return ["fixture-password"]
            })
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host, port: 22,
                username: "fixture", credentials: [], expectedHostKeys: []))
        let agent = try #require(try await factory(request))
        let identity = try #require(try await agent.identities().first)
        await #expect(throws: (any Error).self) { try await agent.sign(key: identity.blob, data: Data([1]), flags: 0) }
        await agent.close()
        await #expect(throws: (any Error).self) { try await agent.identities() }
    }

    @Test func hostLegacyDecodeDefaultsOffAndRoundTrips() throws {
        let host = Host(name: "fixture", host: "localhost", agentForwardingEnabled: true)
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(host)
        #expect(try JSONDecoder().decode(Host.self, from: encoded).agentForwardingEnabled)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "agentForwardingEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        #expect(try !JSONDecoder().decode(Host.self, from: legacy).agentForwardingEnabled)
    }

    private func verify(_ blob: Data, data: Data, material: SSHKeyMaterial, password: String = "") throws {
        var reader = SSHAgentProtocol.Reader(blob)
        let name = String(decoding: try reader.field(), as: UTF8.self)
        var signature = try reader.field()
        #expect(reader.isEmpty)
        if name.hasPrefix("ecdsa-") {
            var fields = SSHAgentProtocol.Reader(signature)
            let r = try fields.field()
            let s = try fields.field()
            let pair = try #require(ECDSA_SIG_new())
            defer { ECDSA_SIG_free(pair) }
            let rb = r.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count), nil) }
            let sb = s.withUnsafeBytes { BN_bin2bn($0.bindMemory(to: UInt8.self).baseAddress, Int32($0.count), nil) }
            #expect(ECDSA_SIG_set0(pair, rb, sb) == 1)
            var der: UnsafeMutablePointer<UInt8>?
            let length = i2d_ECDSA_SIG(pair, &der)
            let pointer = try #require(der)
            signature = Data(bytes: pointer, count: Int(length))
            CRYPTO_free(pointer, nil, 0)
        }
        let bio = try #require(BIO_new(BIO_s_mem()))
        defer { BIO_free(bio) }
        _ = material.privateKey.withCString { BIO_write(bio, $0, Int32(material.privateKey.utf8.count)) }
        let key = try #require(
            password.withCString {
                PEM_read_bio_PrivateKey(bio, nil, nil, UnsafeMutableRawPointer(mutating: $0))
            })
        defer { EVP_PKEY_free(key) }
        let digest: OpaquePointer? =
            switch name {
            case "ssh-ed25519": nil
            case "ssh-rsa": EVP_sha1()
            case "rsa-sha2-512", "ecdsa-sha2-nistp521": EVP_sha512()
            case "ecdsa-sha2-nistp384": EVP_sha384()
            default: EVP_sha256()
            }
        let context = try #require(EVP_MD_CTX_new())
        defer { EVP_MD_CTX_free(context) }
        #expect(EVP_DigestVerifyInit(context, nil, digest, nil, key) == 1)
        let result = signature.withUnsafeBytes { sig in
            data.withUnsafeBytes { message in
                EVP_DigestVerify(
                    context, sig.bindMemory(to: UInt8.self).baseAddress, sig.count,
                    message.bindMemory(to: UInt8.self).baseAddress, message.count)
            }
        }
        #expect(result == 1)
    }
}

@MainActor
private final class RecordingAgent: SSHAgentForwarding {
    var signCalls = 0
    var lastFlags: UInt32 = 0
    var lastData = Data()
    func identities() async throws -> [SSHAgentIdentity] { [] }
    func sign(key: Data, data: Data, flags: UInt32) async throws -> Data {
        signCalls += 1
        lastFlags = flags
        lastData = data
        return Data([9])
    }
    func close() async {}
}
