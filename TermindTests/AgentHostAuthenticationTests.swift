import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct AgentHostAuthenticationTests {
    @Test
    func listingIncludesNestedAndEmptyGroupsAndHostPaths() throws {
        let root = HostGroup(name: "Production", sortIndex: 0)
        let child = HostGroup(name: "Web", parentID: root.id, sortIndex: 0)
        let empty = HostGroup(name: "Empty", sortIndex: 1)
        let grouped = Host(name: "Web 01", host: "web.example", groupID: child.id)
        let ungrouped = Host(name: "Loose", host: "loose.example")
        let temporary = AgentHostTarget(
            id: UUID(), displayName: "Pane", address: "pane.example", tags: [],
            connectionState: "connected", isTemporary: true,
            groupID: UUID(), groupPath: "must be cleared"
        )
        let store = HostStore(
            hosts: [grouped, ungrouped], groups: [empty, child, root]
        )
        let resolver = AgentHostResolver(store: store, temporaryTargets: { [temporary] })

        let listing = resolver.listing()

        #expect(listing.groups.map(\.name) == ["Production", "Empty"])
        #expect(listing.groups[0].children.map(\.name) == ["Web"])
        #expect(listing.groups[1].children.isEmpty)
        #expect(listing.hosts.first { $0.id == grouped.id }?.groupID == child.id)
        #expect(
            listing.hosts.first { $0.id == grouped.id }?.groupPath
                == "Production / Web"
        )
        #expect(listing.hosts.first { $0.id == ungrouped.id }?.groupPath == nil)
        #expect(listing.hosts.first { $0.id == temporary.id }?.groupID == nil)
        #expect(listing.hosts.first { $0.id == temporary.id }?.groupPath == nil)
    }

    @Test
    func inlineIdentityCanBeUsedOnceWithoutChangingTheVault() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostStore(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        let interaction = AuthenticationResponder { request in
            #expect(request.hostID == host.id)
            return .submit(AgentSSHAuthenticationAnswer(
                identityName: "Deploy", username: "deploy", password: "secret",
                save: false
            ))
        }
        let session = AgentSSHConfigurationSession(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction
        )

        let configuration = try await session.configuration()

        #expect(configuration.username == "deploy")
        #expect(configuration.credentials.count == 1)
        #expect(store.host(host.id)?.identityID == nil)
        #expect(store.identities.isEmpty)
    }

    @Test
    func inlineIdentityCanBeCreatedAndBound() async throws {
        let host = Host(name: "Server", host: "server.example")
        let secrets = MemoryHostSecretStore()
        let store = HostStore(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            keychain: secrets
        )
        let interaction = AuthenticationResponder { _ in
            .submit(AgentSSHAuthenticationAnswer(
                identityName: "Production Deploy", username: "deploy",
                password: "secret", save: true
            ))
        }
        let session = AgentSSHConfigurationSession(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction
        )

        let configuration = try await session.configuration()

        let saved = try #require(store.identities.first)
        defer { _ = store.delete(identityID: saved.id) }
        #expect(saved.name == "Production Deploy")
        #expect(saved.username == "deploy")
        #expect(saved.passwordStorage == .iCloudKeychain)
        #expect(store.host(host.id)?.identityID == saved.id)
        #expect(try store.passwordCredential(for: saved) == "secret")
        #expect(configuration.username == "deploy")
    }

    @Test
    func passwordAndProtectedKeyPassphraseAreBothRetainedForTheConnection() async throws {
        let keychain = MemoryHostSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let key = SSHKeyRef(
            label: "Protected", publicKey: "ssh-ed25519 test",
            fingerprint: "SHA256:key", credentialRef: reference,
            storage: .thisDevice, hasPassphrase: true
        )
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "encrypted", passphrase: nil)),
            for: reference, storage: .thisDevice
        )
        let host = Host(name: "Server", host: "server.example")
        let store = HostStore(
            hosts: [host], keys: [key],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            keychain: keychain
        )
        let interaction = AuthenticationResponder { request in
            switch request.mode {
            case .identity:
                return .submit(AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "fallback-password",
                    keyID: key.id, save: false
                ))
            case .passphrase(let keyID):
                #expect(keyID == key.id)
                return .submit(AgentSSHAuthenticationAnswer(
                    username: request.username, passphrase: "one-use",
                    keyID: key.id, save: false
                ))
            }
        }
        let session = AgentSSHConfigurationSession(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction
        )

        let configuration = try await session.configuration()

        guard case .privateKey(_, _, let passphrase) = configuration.credentials.first else {
            Issue.record("Expected a private-key credential")
            return
        }
        #expect(passphrase == "one-use")
        guard configuration.credentials.count == 2,
            case .password(let password) = configuration.credentials[1]
        else {
            Issue.record("Expected the password from the Identity step to remain available")
            return
        }
        #expect(password == "fallback-password")
        guard case .software(let stored)? = try keychain.keyCredential(
            for: reference, storage: .thisDevice
        ) else {
            Issue.record("Expected the stored software key")
            return
        }
        #expect(stored.passphrase == nil)
        #expect(store.key(key.id)?.storesPassphrase == false)
    }
}

private final class MemoryHostSecretStore: HostSecretStoring, @unchecked Sendable {
    private struct PasswordKey: Hashable {
        var account: String
        var storage: PasswordStorage
    }
    private struct KeyKey: Hashable {
        var account: String
        var storage: KeyStorage
    }

    private var passwords: [PasswordKey: String] = [:]
    private var keys: [KeyKey: StoredSSHKeyCredential] = [:]

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        passwords[PasswordKey(account: account, storage: storage)]
    }

    func setString(
        _ value: String?, for account: String, storage: PasswordStorage
    ) throws {
        passwords[PasswordKey(account: account, storage: storage)] = value
    }

    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential? {
        keys[KeyKey(account: account, storage: storage)]
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        keys[KeyKey(account: account, storage: storage)] = value
    }

    func removePassword(_ account: String, storage: PasswordStorage) throws {
        passwords[PasswordKey(account: account, storage: storage)] = nil
    }

    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        keys[KeyKey(account: account, storage: storage)] = nil
    }
}

private final class AuthenticationResponder: AgentUserInteractionHandling, @unchecked Sendable {
    private let answer:
        @MainActor (AgentSSHAuthenticationRequest) -> AgentSSHAuthenticationResponse

    init(
        answer: @escaping @MainActor
            (AgentSSHAuthenticationRequest) -> AgentSSHAuthenticationResponse
    ) {
        self.answer = answer
    }

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        .cancelled
    }

    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        await answer(request)
    }
}
