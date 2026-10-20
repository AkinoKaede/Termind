// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import TermindRemoteInfrastructure

@Suite
struct HardwareSigningTests {
    @Test func secureEnclaveCancellationIsPreservedThroughFrameworkWrappers() {
        for error in [
            NSError(domain: NSOSStatusErrorDomain, code: Int(errSecUserCanceled)),
            NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue),
            NSError(domain: LAError.errorDomain, code: LAError.appCancel.rawValue),
            NSError(domain: LAError.errorDomain, code: LAError.systemCancel.rawValue),
        ] {
            #expect(SecureEnclaveKey.signingError(error) is CancellationError)
            let wrapper = NSError(domain: "CryptoKit", code: 1, userInfo: [NSUnderlyingErrorKey: error])
            #expect(SecureEnclaveKey.signingError(wrapper) is CancellationError)
        }
        #expect(
            !(SecureEnclaveKey.signingError(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecAuthFailed)))
                is CancellationError))
    }

    @Test @MainActor func securityKeyForwardingUsesVaultNameAndCancelReturnsAgentFailure() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let credential = SecurityKeyCredential(
            credentialID: Data([1]), publicKeyX963: privateKey.publicKey.x963Representation)
        let key = try WebAuthnSSH.keyReference(credential, label: "My YubiKey")
        let host = Host(name: "Fixture", host: "fixture.invalid", agentForwardingEnabled: true)
        let library = HostLibraryModel(hosts: [host], keys: [key])
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host, port: 22, username: "user", credentials: [], expectedHostKeys: []))
        let factory = VaultSSHAgent.factory(
            library: library,
            securityKeySigning: { request in
                #expect(request.keyName == "My YubiKey")
                #expect(request.credential == credential)
                throw CancellationError()
            })
        let agent = try #require(try await factory(request))
        let identity = try #require(try await agent.identities().first)
        #expect(identity.comment == key.label)
        let packet =
            Data([13]) + SSHAgentProtocol.field(identity.blob)
            + SSHAgentProtocol.field(Data([9])) + SSHAgentProtocol.uint32(0)
        #expect(await SSHAgentProtocol.response(to: packet, provider: agent) == SSHAgentProtocol.frame(Data([5])))
        await agent.close()
    }

    @Test @MainActor func hardwareForwardingNeverPromptsUnderSilentPolicy() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let credential = SecurityKeyCredential(
            credentialID: Data([1]), publicKeyX963: privateKey.publicKey.x963Representation,
            requiresUserPresence: false)
        let securityKey = try WebAuthnSSH.keyReference(credential, label: "Hardware")
        let enclave = SSHKeyRef(
            label: "Enclave", algorithm: .ecdsa256,
            publicKey: "ecdsa-sha2-nistp256 " + Data([1, 2, 3]).base64EncodedString(), credentialRef: "enclave",
            storage: .secureEnclave, requiresUserPresence: true)
        let secrets = InMemorySecretStore()
        try secrets.setKeyCredential(
            .secureEnclave(.init(dataRepresentation: Data([1]))), for: enclave.credentialRef, storage: .secureEnclave)
        let host = Host(name: "Fixture", host: "fixture.invalid", agentForwardingEnabled: true)
        let library = HostLibraryModel(hosts: [host], keys: [securityKey, enclave], secrets: secrets)
        let factory = VaultSSHAgent.factory(
            library: library,
            securityKeySigning: { _ in
                Issue.record("Silent forwarding must not prompt")
                throw CancellationError()
            })
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host, port: 22, username: "user", credentials: [], expectedHostKeys: []),
            interactionPolicy: .forbidden)
        let agent = try #require(try await factory(request))
        let identities = try await agent.identities()
        #expect(identities.count == 2)
        for identity in identities {
            await #expect(throws: SSHInteractionRequired.self) {
                try await agent.sign(key: identity.blob, data: Data([1]), flags: 0)
            }
        }
        await agent.close()
    }
    @Test(.enabled(if: SecureEnclaveKey.isAvailable)) @MainActor
    func secureEnclaveForwardingProducesVerifiableSignature() async throws {
        let material = try SecureEnclaveKey.generate(comment: "Agent test", requiresUserPresence: false)
        let key = SSHKeyRef(
            label: "Enclave", algorithm: .ecdsa256, publicKey: material.publicKey,
            credentialRef: "enclave-test", storage: .secureEnclave)
        let secrets = InMemorySecretStore()
        try secrets.setKeyCredential(.secureEnclave(material.credential), for: key.credentialRef, storage: key.storage)
        let host = Host(name: "Fixture", host: "fixture.invalid", agentForwardingEnabled: true)
        let library = HostLibraryModel(hosts: [host], keys: [key], secrets: secrets)
        let factory = VaultSSHAgent.factory(library: library)
        let request = SSHConnectionRequest(
            configuration: .init(
                hostID: host.id, host: host.host,
                port: 22, username: "user", credentials: [], expectedHostKeys: []))
        let agent = try #require(try await factory(request))
        let identity = try #require(try await agent.identities().first)
        let data = Data("Secure Enclave agent signing test".utf8)
        let signature = try await agent.sign(key: identity.blob, data: data, flags: 0)
        var wire = SSHAgentProtocol.Reader(signature)
        #expect(try wire.field() == Data("ecdsa-sha2-nistp256".utf8))
        var pair = SSHAgentProtocol.Reader(try wire.field())
        let r = try pair.field().drop(while: { $0 == 0 })
        let s = try pair.field().drop(while: { $0 == 0 })
        let raw = Data(repeating: 0, count: 32 - r.count) + r + Data(repeating: 0, count: 32 - s.count) + s
        var publicKey = SSHAgentProtocol.Reader(identity.blob)
        _ = try publicKey.field()
        _ = try publicKey.field()
        let verifier = try P256.Signing.PublicKey(x963Representation: publicKey.field())
        #expect(try verifier.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: raw), for: data))
        await agent.close()
    }

}
