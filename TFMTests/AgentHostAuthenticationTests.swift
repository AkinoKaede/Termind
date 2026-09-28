import AgentKit
import CryptoKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized)
@MainActor
struct AgentHostAuthenticationTests {
    @Test func webAuthnSigningUsesTheConversationAuthenticationForm() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        let host = Host(name: "Server", host: "server.example", identityID: identity.id)
        let store = HostLibraryModel(hosts: [host], identities: [identity])
        let conversation = ConversationModel()
        let invocationID = UUID()
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id, invocationID: invocationID,
            interaction: WeakAgentUserInteraction(conversation).sshInteraction)
        let attempt = try await session.configurationAttempt()
        let signing = try #require(attempt.request.securityKeySigning)
        let request = signingRequest(hostID: host.id)
        let task = Task { try await signing(request) }
        defer { task.cancel() }
        try await waitForAuthentication(in: conversation)
        let prompt = try #require(conversation.pendingSSHAuthentication)
        #expect(prompt.securityKey == request)
        #expect(prompt.invocationID == invocationID)
        let assertion = signingAssertion()
        conversation.respondToSSHAuthentication(.securityKey(assertion), requestID: prompt.id)
        #expect(try await task.value == assertion)
        #expect(conversation.pendingSSHAuthentication == nil)
        #expect(conversation.messages.isEmpty)
    }

    @Test func cancellingWebAuthnSigningClearsTheConversationForm() async throws {
        let conversation = ConversationModel()
        let interaction = WeakAgentUserInteraction(conversation).sshInteraction
        let task = Task { try await interaction.signSecurityKey(signingRequest(), invocationID: UUID()) }
        defer { task.cancel() }
        try await waitForAuthentication(in: conversation)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(conversation.pendingSSHAuthentication == nil)
    }

    @Test func unavailableOrSilentWebAuthnSigningNeverRequestsInteraction() async throws {
        await #expect(throws: SSHInteractionRequired.self) {
            try await AgentSSHInteraction.unavailable.signSecurityKey(signingRequest(), invocationID: UUID())
        }
        let interaction = AgentSSHInteraction(
            authenticate: { _ in
                Issue.record("Silent signing must not request authentication")
                return .cancelled
            }, confirmHostKey: { _ in .deny })
        var request = signingRequest()
        request.allowsUserInteraction = false
        await #expect(throws: SSHInteractionRequired.self) {
            try await interaction.signSecurityKey(request, invocationID: UUID())
        }
    }

    @Test(.requiresVisibleWindow)
    func externalMCPWebAuthnSigningUsesTheAuthenticationWindowQueue() async throws {
        let coordinator = ExternalAuthCoordinator()
        let runID = UUID()
        let interaction = coordinator.handler(clientName: "MCP test", runID: runID).sshInteraction
        let request = signingRequest()
        let task = Task { try await interaction.signSecurityKey(request, invocationID: UUID()) }
        defer {
            task.cancel()
            coordinator.cancelAll()
        }
        for _ in 0..<100 {
            if coordinator.current != nil { break }
            await Task.yield()
        }
        let pending = try #require(coordinator.current)
        guard case .ssh(let prompt) = pending.request else {
            Issue.record("Expected SSH authentication")
            return
        }
        #expect(prompt.securityKey == request)
        #expect(pending.clientName == "MCP test" && pending.runID == runID)
        let assertion = signingAssertion()
        coordinator.respondSSH(.securityKey(assertion), requestID: prompt.id)
        #expect(try await task.value == assertion)
        #expect(coordinator.current == nil)
    }

    private func signingRequest(hostID: UUID = UUID()) -> SecurityKeySigningRequest {
        SecurityKeySigningRequest(
            hostID: hostID, hostname: "server.example",
            credential: SecurityKeyCredential(
                credentialID: Data([1, 2, 3]), publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation),
            challenge: Data("ssh authentication challenge".utf8))
    }

    private func signingAssertion() -> SecurityKeyAssertion {
        SecurityKeyAssertion(
            credentialID: Data([1, 2, 3]), authenticatorData: Data([1]),
            clientDataJSON: Data([2]), signature: Data([3]))
    }

    @Test
    func proxyAuthenticationUsesTheAgentInteractionWithoutChangingItsUsername() async throws {
        let sshIdentity = Identity(name: "SSH", username: "deploy")
        let missingProxy = Identity(
            name: "Proxy", username: "identity-user",
            credentialRef: "termind.password.proxy-missing")
        let host = Host(
            name: "Server", host: "server.example", identityID: sshIdentity.id,
            proxy: HostProxy(
                hostname: "proxy.example", username: "proxy-user",
                identityID: missingProxy.id))
        let store = HostLibraryModel(
            hosts: [host], identities: [sshIdentity, missingProxy],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: MemoryHostSecretStore())
        let interaction = AuthenticationResponder { request in
            guard case .proxy(let ownerHostID) = request.mode else {
                return .cancelled
            }
            #expect(ownerHostID == host.id)
            #expect(request.selectedIdentityID == nil)
            #expect(request.username == "proxy-user")
            return .submit(
                AgentSSHAuthenticationAnswer(
                    username: request.username, password: "one-use", save: false))
        }
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction)

        let configuration = try await session.configuration()
        #expect(configuration.proxy?.username == "proxy-user")
        #expect(try #require(configuration.proxy?.password) == "one-use")
        #expect(store.host(host.id)?.proxy?.identityID == missingProxy.id)
    }

    @Test func usernameOnlyIdentityDoesNotRequireCredentialEntry() async throws {
        let identity = Identity(name: "OTP", username: "deploy")
        let host = Host(name: "Server", host: "server.example", identityID: identity.id)
        let store = HostLibraryModel(hosts: [host], identities: [identity])
        let resolver = AgentHostResolver(store: store)
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: host.id, invocationID: UUID(), interaction: .unavailable
        )
        let configuration = try await session.configuration()
        #expect(configuration.username == "deploy")
        #expect(configuration.credentials.isEmpty)
    }

    @Test
    func cancellingTheOnlyConfigurationWaiterClearsItsAuthenticationCard() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let conversation = ConversationModel()
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: WeakAgentUserInteraction(conversation).sshInteraction
        )
        let completion = AuthenticationCompletionProbe()
        let attempt = Task {
            defer { Task { await completion.finish() } }
            return try await session.configurationAttempt()
        }
        try await waitForAuthentication(in: conversation)

        attempt.cancel()
        let completedBeforeAnswer = await waitForCompletion(completion)
        let cardCleared = conversation.pendingSSHAuthentication == nil
        if !cardCleared {
            conversation.respondToSSHAuthentication(.cancelled)
        }

        #expect(completedBeforeAnswer)
        #expect(cardCleared)
        await #expect(throws: CancellationError.self) {
            _ = try await attempt.value
        }
    }

    @Test
    func cancellingOneSharedConfigurationWaiterKeepsTheOtherOwnerRunning() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let conversation = ConversationModel()
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: WeakAgentUserInteraction(conversation).sshInteraction
        )
        let firstCompletion = AuthenticationCompletionProbe()
        let first = Task {
            defer { Task { await firstCompletion.finish() } }
            return try await session.configurationAttempt()
        }
        try await waitForAuthentication(in: conversation)
        let second = Task { try await session.configurationAttempt() }
        for _ in 0..<100 { await Task.yield() }

        first.cancel()
        let firstCompletedBeforeAnswer = await waitForCompletion(firstCompletion)
        let request = try #require(conversation.pendingSSHAuthentication)
        conversation.respondToSSHAuthentication(
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "one-use", save: false
                )),
            requestID: request.id
        )

        #expect(firstCompletedBeforeAnswer)
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        let retained = try await second.value
        #expect(retained.configuration.username == "deploy")
        #expect(password(in: retained.configuration, matches: "one-use"))
        #expect(conversation.pendingSSHAuthentication == nil)
    }

    @Test func concurrentConnectionChallengesAreNeverCoalescedWithSavedCredentials() async throws {
        let identity = Identity(name: "OTP", username: "deploy")
        let host = Host(name: "Server", host: "server.example", identityID: identity.id)
        let store = HostLibraryModel(hosts: [host], identities: [identity])
        let interaction = AuthenticationResponder { request in
            let challenge = request.keyboardInteractive!
            return .keyboardInteractive([challenge.id.uuidString])
        }
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id, invocationID: UUID(),
            interaction: interaction.sshInteraction
        )
        let attempt = try await session.configurationAttempt()
        let responder = try #require(attempt.request.keyboardInteractive)
        let first = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: host.id, hostname: host.host, port: 22, username: "deploy",
            round: 1, name: "PAM", instruction: "", prompts: [.init(text: "OTP", echo: false)])
        var second = first
        second.id = UUID()
        second.connectionID = UUID()
        let secondChallenge = second
        async let firstAnswers = responder(first)
        async let secondAnswers = responder(secondChallenge)
        let answers = try await (firstAnswers, secondAnswers)
        #expect(answers.0 == [first.id.uuidString])
        #expect(answers.1 == [second.id.uuidString])
        #expect(store.identities == [identity])
    }

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
        let store = HostLibraryModel(
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
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        let interaction = AuthenticationResponder { request in
            #expect(request.hostID == host.id)
            return .submit(
                AgentSSHAuthenticationAnswer(
                    identityName: "Deploy", username: "deploy", password: "secret",
                    save: false
                ))
        }
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
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
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: secrets
        )
        let interaction = AuthenticationResponder { _ in
            .submit(
                AgentSSHAuthenticationAnswer(
                    identityName: "Production Deploy", username: "deploy",
                    password: "secret", save: true
                ))
        }
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let configuration = try await session.configuration()

        let saved = try #require(store.identities.first)
        defer { _ = store.delete(identityID: saved.id) }
        #expect(saved.name == "Production Deploy")
        #expect(saved.username == "deploy")
        #expect(saved.passwordStorage == .iCloud)
        #expect(store.host(host.id)?.identityID == saved.id)
        #expect(try store.passwordCredential(for: saved) == "secret")
        #expect(configuration.username == "deploy")
    }

    @Test(arguments: [false, true])
    func passwordAndProtectedKeyPassphraseAreBothRetainedForTheConnection(save: Bool) async throws {
        let keychain = MemoryHostSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let key = SSHKeyRef(
            label: "Protected", publicKey: "ssh-ed25519 test",
            fingerprint: "SHA256:key", credentialRef: reference,
            storage: .thisDevice, hasPassphrase: true
        )
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "encrypted")),
            for: reference, storage: .thisDevice
        )
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(
            hosts: [host], keys: [key],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: keychain
        )
        let interaction = AuthenticationResponder { request in
            switch request.mode {
            case .identity:
                return .submit(
                    AgentSSHAuthenticationAnswer(
                        username: "deploy", password: "fallback-password",
                        keyID: key.id, save: false
                    ))
            case .keyboardInteractive, .securityKey:
                return .cancelled
            case .proxy:
                return .cancelled
            case .passphrase(let keyID):
                #expect(keyID == key.id)
                return .submit(
                    AgentSSHAuthenticationAnswer(
                        username: request.username, passphrase: "one-use",
                        keyID: key.id, save: save
                    ))
            }
        }
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let configuration = try await session.configuration()

        guard case .privateKey(_, _, let passphrase, _) = configuration.credentials.first else {
            Issue.record("Expected a private-key credential")
            return
        }
        #expect(passphrase?.matches("one-use") == true)
        guard configuration.credentials.count == 2,
            case .password(let password) = configuration.credentials[1]
        else {
            Issue.record("Expected the password from the Identity step to remain available")
            return
        }
        #expect(password == "fallback-password")
        guard
            case .software(let stored)? = try keychain.keyCredential(
                for: reference, storage: .thisDevice
            )
        else {
            Issue.record("Expected the stored software key")
            return
        }
        #expect(stored.privateKey == "encrypted")
        #expect(stored.passphrase == (save ? "one-use" : nil))
        #expect(store.requiresPassphraseEntry(for: key) == !save)
        #expect(store.host(host.id)?.identityID == nil)
        configuration.clearSecrets()
        #expect(store.key(key.id)?.requiresPassphraseEntry == true)
    }

    @Test(.requiresVisibleWindow)
    func savedIdentityWithProtectedKeyRequestsOnlyPassphraseExternally() async throws {
        let keychain = MemoryHostSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let key = SSHKeyRef(
            label: "Protected", publicKey: "ssh-ed25519 test",
            fingerprint: "SHA256:key", credentialRef: reference,
            storage: .thisDevice, hasPassphrase: true
        )
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "encrypted")),
            for: reference, storage: .thisDevice
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(
            name: "Server", host: "server.example", identityID: identity.id
        )
        let store = HostLibraryModel(
            hosts: [host], keys: [key], identities: [identity],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: keychain
        )
        let coordinator = ExternalAuthCoordinator()
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(),
            interaction: coordinator.handler(clientName: "Codex", runID: UUID())
                .sshInteraction
        )
        let configuration = Task { try await session.configuration() }

        for _ in 0..<100 {
            if case .ssh? = coordinator.current?.request { break }
            await Task.yield()
        }
        guard case .ssh(let request)? = coordinator.current?.request else {
            Issue.record("Expected a Passphrase request")
            return
        }
        guard case .passphrase(let requestedKeyID) = request.mode else {
            Issue.record("Expected Passphrase without an Identity step")
            return
        }
        #expect(requestedKeyID == key.id)
        #expect(request.selectedIdentityID == identity.id)
        #expect(request.username == identity.username)
        #expect(request.selectedKeyID == key.id)

        coordinator.respondSSH(
            .submit(
                AgentSSHAuthenticationAnswer(
                    identityID: request.selectedIdentityID,
                    username: request.username, passphrase: "one-use",
                    keyID: request.selectedKeyID, save: false
                )))

        let resolved = try await configuration.value
        guard case .privateKey(_, _, let passphrase, _) = resolved.credentials.first else {
            Issue.record("Expected a private-key credential")
            return
        }
        #expect(passphrase?.matches("one-use") == true)
        #expect(coordinator.pending.isEmpty)
    }

    @Test
    func sftpCollectsJumpAndDestinationAuthenticationInRouteOrder() async throws {
        let jump = Host(name: "Bastion", host: "jump.example")
        var destination = Host(name: "Files", host: "files.example")
        destination.jumpHostID = jump.id
        let store = HostLibraryModel(
            hosts: [destination, jump],
            knownHosts: [
                KnownHostEntry(hostname: jump.host, fingerprint: "SHA256:jump"),
                KnownHostEntry(hostname: destination.host, fingerprint: "SHA256:files"),
            ]
        )
        let resolver = AgentHostResolver(store: store)
        let backend = AuthenticationConnectionBackend()
        let pool = authenticationPool(resolver: resolver, backend: backend)
        let registry = AgentSSHAuthenticationRegistry(resolver: resolver)
        var requestedHosts: [TermindDomain.Host.ID] = []
        let interaction = AuthenticationResponder { request in
            requestedHosts.append(request.hostID)
            return .submit(
                AgentSSHAuthenticationAnswer(
                    username: request.hostID == jump.id ? "jump-user" : "files-user",
                    password: request.hostID == jump.id ? "jump-secret" : "files-secret",
                    save: false
                ))
        }

        _ = try await registry.sftpChannel(
            hostID: destination.id, invocationID: UUID(),
            interaction: interaction.sshInteraction, pool: pool
        )

        #expect(requestedHosts == [jump.id, destination.id])
        let configuration = try #require(await backend.sftpConfigurations.first)
        let destinationPassword = try #require(await backend.observedDestinationPasswords.first)
        let jumpPasswords = try #require(await backend.observedJumpPasswords.first)
        #expect(configuration.username == "files-user")
        #expect(destinationPassword == "files-secret")
        #expect(configuration.jumps.count == 1)
        #expect(configuration.jumps[0].id == jump.id)
        #expect(configuration.jumps[0].username == "jump-user")
        guard case .password(let jumpPassword) = configuration.jumps[0].credentials.first
        else {
            Issue.record("Expected a jump-host password")
            return
        }
        #expect(jumpPasswords == ["jump-secret"])
        #expect(jumpPassword.isConsumed)
    }

    @Test
    func sftpToolCollectsMissingIdentityBeforeListing() async throws {
        let host = Host(name: "Files", host: "files.example")
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        let resolver = AgentHostResolver(store: store)
        let authentication = AgentSSHAuthenticationRegistry(resolver: resolver)
        let backend = AuthenticationConnectionBackend()
        let pool = authenticationPool(resolver: resolver, backend: backend)
        let interaction = AuthenticationResponder { _ in
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "secret", save: false
                ))
        }
        let tool = AnyAgentTool(
            SFTPListTool(
                authentication: authentication, connections: pool
            ))
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "sftp-list", name: "sftp_list",
                arguments: .object([
                    "host_id": .string(host.id.uuidString), "path": .string("/srv"),
                ])
            )
        )

        let result = try await tool.execute(
            invocation,
            context: AgentToolExecutionContext(
                runID: invocation.runID, userIntent: "list files",
                secretBroker: SecretBroker(),
                userInteraction: UnavailableAgentUserInteraction(),
                services: AgentToolServices()
                    .setting(interaction.sshInteraction, for: .sshInteraction),
                preflightMetadata: [:], authorize: { _ in .allow }
            )
        )

        #expect(!result.isError)
        #expect(await backend.sftpOpens == 1)
        let configuration = try #require(await backend.sftpConfigurations.first)
        let observedPassword = try #require(await backend.observedDestinationPasswords.first)
        #expect(configuration.username == "deploy")
        guard case .password(let password) = configuration.credentials.first else {
            Issue.record("Expected the one-use password in the SFTP configuration")
            return
        }
        #expect(observedPassword == "secret")
        #expect(password.isConsumed)
    }

    @Test
    func concurrentSFTPConnectionsShareOnePromptAndOnePendingConnection() async throws {
        let setup = authenticationSetup()
        let interaction = GatedAuthenticationResponder()

        async let first = setup.registry.sftpChannel(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction.sshInteraction, pool: setup.pool
        )
        async let second = setup.registry.sftpChannel(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction.sshInteraction, pool: setup.pool
        )
        while await interaction.requestCount == 0 { await Task.yield() }
        #expect(await interaction.requestCount == 1)
        await interaction.answer(
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "secret", save: false
                )))

        _ = try await (first, second)
        #expect(await interaction.requestCount == 1)
        #expect(await setup.backend.sftpOpens == 1)
    }

    @Test
    func concurrentExecAndSFTPShareOnePromptAndOneConnection() async throws {
        let setup = authenticationSetup()
        let interaction = GatedAuthenticationResponder()

        async let exec = setup.registry.connection(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction.sshInteraction, pool: setup.pool
        )
        async let sftp = setup.registry.sftpChannel(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction.sshInteraction, pool: setup.pool
        )
        while await interaction.requestCount == 0 { await Task.yield() }
        #expect(await interaction.requestCount == 1)
        await interaction.answer(
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "secret", save: false
                )))

        _ = try await (exec, sftp)
        #expect(await interaction.requestCount == 1)
        #expect(await setup.backend.execOpens == 1)
        #expect(await setup.backend.sftpOpens == 1)
        #expect(await setup.pool.openConnectionCount == 1)
    }

    @Test
    func cancellingSharedAuthenticationCancelsEveryWaiterBeforeSFTPOpens() async {
        let setup = authenticationSetup()
        let interaction = GatedAuthenticationResponder()
        let first = Task {
            try await setup.registry.sftpChannel(
                hostID: setup.host.id, invocationID: UUID(),
                interaction: interaction.sshInteraction, pool: setup.pool
            )
        }
        let second = Task {
            try await setup.registry.sftpChannel(
                hostID: setup.host.id, invocationID: UUID(),
                interaction: interaction.sshInteraction, pool: setup.pool
            )
        }
        while await interaction.requestCount == 0 { await Task.yield() }

        await interaction.answer(.cancelled)

        await #expect(throws: (any Error).self) { _ = try await first.value }
        await #expect(throws: (any Error).self) { _ = try await second.value }
        #expect(await interaction.requestCount == 1)
        #expect(await setup.backend.sftpOpens == 0)
        #expect(await setup.backend.sftpOperations == 0)
    }

    @Test
    func rejectedSFTPCredentialPromptsAgainAndUsesTheNewSecret() async throws {
        let setup = authenticationSetup(sftpAuthenticationFailures: 1)
        var requests: [AgentSSHAuthenticationRequest] = []
        let interaction = AuthenticationResponder { request in
            requests.append(request)
            let password = requests.count == 1 ? "old-secret" : "new-secret"
            return .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: password, save: false
                ))
        }

        _ = try await setup.registry.sftpChannel(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction.sshInteraction, pool: setup.pool
        )

        #expect(requests.count == 2)
        #expect(requests[0].failureMessage == nil)
        #expect(requests[1].failureMessage?.contains("Rejected") == true)
        #expect(requests[1].username == "deploy")
        #expect(await setup.backend.execOpens == 2)
        #expect(await setup.backend.sftpOpens == 1)
        let configurations = await setup.backend.sftpConfigurations
        #expect(await setup.backend.observedDestinationPasswords == ["old-secret", "new-secret"])
        #expect(
            configurations.allSatisfy { configuration in
                configuration.credentials.allSatisfy { credential in
                    guard case .password(let password) = credential else { return true }
                    return password.isConsumed
                }
            })
    }

    @Test
    func staleFailureCannotClearANewerAuthenticationGeneration() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        let interaction = GatedAuthenticationResponder()
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let firstTask = Task { try await session.configurationAttempt() }
        while await interaction.requestCount == 0 { await Task.yield() }
        await interaction.answer(
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "old-secret", save: false
                )))
        let first = try await firstTask.value
        await session.retry(
            after: .authenticationFailed("Rejected old credential"),
            generation: first.generation
        )

        let secondTask = Task { try await session.configurationAttempt() }
        while await interaction.requestCount < 2 { await Task.yield() }
        await interaction.answer(
            .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "new-secret", save: false
                )))
        let second = try await secondTask.value

        await session.retry(
            after: .authenticationFailed("Late rejection from old connection"),
            generation: first.generation
        )
        let retained = try await session.configurationAttempt()
        #expect(retained.generation == second.generation)
        #expect(password(in: retained.configuration, matches: "new-secret"))
        #expect(await interaction.requestCount == 2)
    }

    @Test
    func successfulAuthenticationConsumesAgentSecretsAndPromptsForAnotherConnection() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        var requests = 0
        let interaction = AuthenticationResponder { _ in
            requests += 1
            return .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "one-use-\(requests)", save: false
                ))
        }
        let session = AgentSSHAuthenticationContext(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let first = try await session.configurationAttempt()
        guard case .password(let firstPassword) = first.configuration.credentials.first else {
            Issue.record("Expected the first one-shot password")
            return
        }
        #expect(firstPassword.matches("one-use-1"))

        await session.didAuthenticate(generation: first.generation)
        #expect(firstPassword.isConsumed)

        let second = try await session.configurationAttempt()
        guard case .password(let secondPassword) = second.configuration.credentials.first else {
            Issue.record("Expected a newly entered password")
            return
        }
        #expect(requests == 2)
        #expect(secondPassword.matches("one-use-2"))
        #expect(!secondPassword.isConsumed)
    }

    @Test
    func connectionLossEvictsSFTPWithoutReplayingTheOperation() async throws {
        let setup = authenticationSetup(sftpOperationFailures: 1)
        var requestCount = 0
        let interaction = AuthenticationResponder { _ in
            requestCount += 1
            return .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "secret-\(requestCount)", save: false
                ))
        }
        let tool = AnyAgentTool(
            SFTPListTool(
                authentication: setup.registry, connections: setup.pool
            ))
        func invocation(_ id: String) -> AgentToolInvocation {
            AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: id, name: "sftp_list",
                    arguments: .object([
                        "host_id": .string(setup.host.id.uuidString),
                        "path": .string("/srv"),
                    ])
                )
            )
        }
        func context(for invocation: AgentToolInvocation) -> AgentToolExecutionContext {
            AgentToolExecutionContext(
                runID: invocation.runID, userIntent: "list files",
                secretBroker: SecretBroker(),
                userInteraction: UnavailableAgentUserInteraction(),
                services: AgentToolServices()
                    .setting(interaction.sshInteraction, for: .sshInteraction),
                preflightMetadata: [:], authorize: { _ in .allow }
            )
        }

        let first = invocation("first")
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(first, context: context(for: first))
        }
        #expect(await setup.backend.sftpOperations == 1)
        let remainedConnected = await setup.pool.isConnected(hostID: setup.host.id)
        #expect(!remainedConnected)

        let second = invocation("second")
        let result = try await tool.execute(second, context: context(for: second))
        #expect(!result.isError)
        #expect(await setup.backend.sftpOperations == 2)
        #expect(await setup.backend.sftpOpens == 2)
        #expect(requestCount == 2)
    }

    @Test
    func firstUseHostKeyCanContinueOnceWithoutPersisting() async throws {
        let host = Host(name: "Server", host: "server.example")
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port, algorithm: .ed25519,
            fingerprint: "SHA256:new"
        )
        let store = HostLibraryModel(hosts: [host])
        var requests: [AgentSSHHostKeyRequest] = []
        let interaction = AuthenticationResponder(
            answer: { _ in
                .submit(
                    AgentSSHAuthenticationAnswer(
                        username: "deploy", password: "secret", save: false
                    ))
            },
            hostKeyAnswer: { request in
                requests.append(request)
                return .continueOnce
            }
        )
        let resolver = AgentHostResolver(store: store)
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let attempt = try await session.configurationAttempt()
        let authorizer = try #require(attempt.request.authorizeHostKey)
        let decision = try await authorizer(
            SSHHostKeyChallenge(
                hostID: host.id, observation: observation,
                expectedHostKeys: attempt.configuration.expectedHostKeys
            )
        )

        #expect(decision == .accept)
        #expect(requests.count == 1)
        #expect(requests[0].prompt.kind == .firstUse)
        #expect(requests[0].allowsPersistentTrust)
        #expect(attempt.configuration.expectedHostKeys.isEmpty)
        #expect(store.knownHosts(for: host).isEmpty)
    }

    @Test
    func routeCollectsLocalCredentialsBeforeStartingEachHostsHandshake() async throws {
        let jump = Host(name: "Bastion", host: "jump.example")
        var destination = Host(name: "Files", host: "files.example")
        destination.jumpHostID = jump.id
        let store = HostLibraryModel(hosts: [jump, destination])
        var events: [String] = []
        let interaction = AuthenticationResponder(
            answer: { request in
                events.append("authenticate:\(request.hostID)")
                return .submit(
                    AgentSSHAuthenticationAnswer(
                        username: "deploy", password: "secret", save: false
                    ))
            },
            hostKeyAnswer: { request in
                events.append("verify:\(request.hostID)")
                return .continueOnce
            }
        )
        let resolver = AgentHostResolver(store: store)
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: destination.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let attempt = try await session.configurationAttempt()
        let authorizer = try #require(attempt.request.authorizeHostKey)
        for endpoint in [jump, destination] {
            let decision = try await authorizer(
                SSHHostKeyChallenge(
                    hostID: endpoint.id,
                    observation: SSHHostKeyObservation(
                        hostname: endpoint.host, port: endpoint.port,
                        algorithm: .ed25519,
                        fingerprint: "SHA256:\(endpoint.id)"
                    ),
                    expectedHostKeys: []
                )
            )
            #expect(decision == .accept)
        }

        #expect(
            events == [
                "authenticate:\(jump.id)",
                "authenticate:\(destination.id)",
                "verify:\(jump.id)",
                "verify:\(destination.id)",
            ])
    }

    @Test
    func directPassphraseIsPresentedBeforeAConnectionRequestIsReturned() async throws {
        let keychain = MemoryHostSecretStore()
        let reference = "termind.key.\(UUID().uuidString)"
        let key = SSHKeyRef(
            label: "Protected", publicKey: "ssh-ed25519 test",
            fingerprint: "SHA256:key", credentialRef: reference,
            storage: .thisDevice, hasPassphrase: true
        )
        try keychain.setKeyCredential(
            .software(SSHPrivateKeySecret(privateKey: "encrypted")),
            for: reference, storage: .thisDevice
        )
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "N1", host: "n1.example", identityID: identity.id)
        let store = HostLibraryModel(
            hosts: [host], keys: [key], identities: [identity], secrets: keychain
        )
        let probe = PassphraseRequestProbe()
        let interaction = AuthenticationResponder { request in
            guard case .passphrase(let keyID) = request.mode else {
                Issue.record("Expected Passphrase before opening the connection")
                return .cancelled
            }
            #expect(keyID == key.id)
            probe.wasRequested = true
            return .submit(
                AgentSSHAuthenticationAnswer(
                    identityID: identity.id, username: identity.username,
                    passphrase: "one-use", keyID: key.id, save: false
                ))
        }
        let resolver = AgentHostResolver(store: store)
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let attempt = try await session.configurationAttempt()
        #expect(probe.wasRequested)
        #expect(attempt.request.authorizeHostKey != nil)
    }

    @Test
    func changedHostKeyCanBeTrustedWithoutRemovingTheOldKey() async throws {
        let host = Host(name: "Server", host: "server.example")
        let old = KnownHostEntry(
            hostname: host.host, port: host.port, algorithm: .ed25519,
            fingerprint: "SHA256:old"
        )
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port, algorithm: .ed25519,
            fingerprint: "SHA256:new"
        )
        let store = HostLibraryModel(hosts: [host], knownHosts: [old])
        let interaction = AuthenticationResponder(
            answer: { _ in
                .submit(
                    AgentSSHAuthenticationAnswer(
                        username: "deploy", password: "secret", save: false
                    ))
            },
            hostKeyAnswer: { request in
                #expect(request.prompt.kind == .additionalKey(trustedKeyCount: 1))
                return .trustAndContinue
            }
        )
        let resolver = AgentHostResolver(store: store)
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let attempt = try await session.configurationAttempt()
        let authorizer = try #require(attempt.request.authorizeHostKey)
        let decision = try await authorizer(
            SSHHostKeyChallenge(
                hostID: host.id, observation: observation,
                expectedHostKeys: attempt.configuration.expectedHostKeys
            )
        )

        #expect(decision == .accept)
        #expect(attempt.configuration.expectedHostKeys == [old.identity])
        #expect(Set(store.knownHosts(for: host).map(\.identity)) == [old.identity, observation.identity])
    }

    @Test
    func denyingHostKeyRejectsTheInFlightConnection() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let resolver = AgentHostResolver(store: store)
        let interaction = AuthenticationResponder(
            answer: { _ in
                .submit(
                    AgentSSHAuthenticationAnswer(
                        username: "deploy", password: "secret", save: false
                    ))
            },
            hostKeyAnswer: { _ in .deny }
        )
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let attempt = try await session.configurationAttempt()
        let authorizer = try #require(attempt.request.authorizeHostKey)
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port, algorithm: .ed25519,
            fingerprint: "SHA256:denied"
        )
        let decision = try await authorizer(
            SSHHostKeyChallenge(
                hostID: host.id, observation: observation,
                expectedHostKeys: []
            )
        )
        #expect(decision == .reject)
        #expect(store.knownHosts(for: host).isEmpty)
    }

    @Test
    func concurrentConfigurationAttemptsShareOneHostKeyPrompt() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let interaction = GatedHostKeyResponder()
        let resolver = AgentHostResolver(store: store)
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: host.id,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )

        let firstAttempt = try await session.configurationAttempt()
        let secondAttempt = try await session.configurationAttempt()
        let firstAuthorizer = try #require(firstAttempt.request.authorizeHostKey)
        let secondAuthorizer = try #require(secondAttempt.request.authorizeHostKey)
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: host.port, algorithm: .ed25519,
            fingerprint: "SHA256:shared"
        )
        let challenge = SSHHostKeyChallenge(
            hostID: host.id, observation: observation,
            expectedHostKeys: []
        )
        async let first = firstAuthorizer(challenge)
        async let second = secondAuthorizer(challenge)
        while await interaction.hostKeyRequestCount == 0 { await Task.yield() }
        #expect(await interaction.hostKeyRequestCount == 1)
        await interaction.answerHostKey(.continueOnce)

        let decisions = try await [first, second]
        #expect(decisions.allSatisfy { $0 == .accept })
        #expect(await interaction.authenticationRequestCount == 1)
        #expect(await interaction.hostKeyRequestCount == 1)
    }

    @Test
    func temporaryTargetCanApproveChangedKeyOnlyForReplacementConnection() async throws {
        let hostID = UUID()
        let old = SSHHostKeyIdentity(
            algorithm: .ed25519, fingerprint: "SHA256:old"
        )
        let observation = SSHHostKeyObservation(
            hostname: "quick.example", port: 22, algorithm: .ed25519,
            fingerprint: "SHA256:new"
        )
        let target = AgentHostTarget(
            id: hostID, displayName: "Quick Connect", address: "quick.example",
            tags: [], connectionState: "connected", isTemporary: true,
            groupID: nil, groupPath: nil
        )
        let configuration = SSHConnectionConfiguration(
            hostID: hostID, host: observation.hostname, port: observation.port,
            username: "deploy", credentials: [.password("secret")],
            expectedHostKeys: [old], proxy: nil
        )
        var requests: [AgentSSHHostKeyRequest] = []
        let interaction = AuthenticationResponder(
            answer: { _ in .cancelled },
            hostKeyAnswer: { request in
                requests.append(request)
                return .continueOnce
            }
        )
        let resolver = AgentHostResolver(
            store: HostLibraryModel(), temporaryTargets: { [target] },
            temporaryConfiguration: { id in id == hostID ? configuration : nil }
        )
        let session = AgentSSHAuthenticationContext(
            resolver: resolver, hostID: hostID,
            invocationID: UUID(), interaction: interaction.sshInteraction
        )
        let initial = try await session.configurationAttempt()
        let authorizer = try #require(initial.request.authorizeHostKey)
        let challenge = SSHHostKeyChallenge(
            hostID: hostID, observation: observation,
            expectedHostKeys: [old]
        )
        let decision = try await authorizer(challenge)
        let repeatedDecision = try await authorizer(challenge)

        #expect(decision == .accept)
        #expect(repeatedDecision == .accept)
        #expect(requests.count == 1)
        #expect(!requests[0].allowsPersistentTrust)
        #expect(initial.configuration.expectedHostKeys == [old])
    }

    @Test
    func scratchPullAndPushUseAuthenticationAndTheSharedSFTPPool() async throws {
        let source = Data("server configuration\n".utf8)
        let setup = authenticationSetup(remoteFiles: ["/etc/app.conf": source])
        let base = FileManager.default.temporaryDirectory
            .appending(path: "termind-agent-auth-scratch/\(UUID().uuidString)")
        let workspace = AgentScratchWorkspace(conversationID: UUID(), base: base)
        let pull = ScratchPullTool(
            workspace: workspace, pool: setup.pool, authentication: setup.registry
        )
        let push = ScratchPushTool(
            workspace: workspace, pool: setup.pool, authentication: setup.registry
        )
        var requestCount = 0
        let interaction = AuthenticationResponder { _ in
            requestCount += 1
            return .submit(
                AgentSSHAuthenticationAnswer(
                    username: "deploy", password: "secret-\(requestCount)", save: false
                ))
        }
        func context(
            _ invocation: AgentToolInvocation,
            preflight: [String: AgentJSONValue] = [:]
        ) -> AgentToolExecutionContext {
            AgentToolExecutionContext(
                runID: invocation.runID, userIntent: "transfer configuration",
                secretBroker: SecretBroker(),
                userInteraction: UnavailableAgentUserInteraction(),
                services: AgentToolServices()
                    .setting(interaction.sshInteraction, for: .sshInteraction),
                preflightMetadata: preflight, authorize: { _ in .allow }
            )
        }
        let pullInvocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "pull", name: "scratch_pull",
                arguments: .object([
                    "host_id": .string(setup.host.id.uuidString),
                    "remote_path": .string("/etc/app.conf"),
                    "scratch_path": .string("app.conf"),
                ])
            )
        )

        _ = try await pull.execute(pullInvocation, context: context(pullInvocation))
        #expect(try await workspace.data(at: "app.conf").data == source)
        #expect(requestCount == 1)

        // A live SFTP channel is reused without another card. Once evicted, the
        // push is a new authentication wave and must not inherit Custom secrets.
        _ = await setup.pool.disconnect(hostID: setup.host.id)
        let pushInvocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "push", name: "scratch_push",
                arguments: .object([
                    "host_id": .string(setup.host.id.uuidString),
                    "scratch_path": .string("app.conf"),
                    "remote_path": .string("/etc/copy.conf"),
                ])
            )
        )
        let preflight = try await push.preflight(pushInvocation)
        _ = try await push.execute(
            pushInvocation,
            context: context(pushInvocation, preflight: preflight.executionMetadata)
        )

        #expect(await setup.backend.remoteFile(at: "/etc/copy.conf") == source)
        #expect(requestCount == 2)
        #expect(await setup.backend.execOpens == 2)
        #expect(await setup.backend.sftpOpens == 2)
    }

    @Test
    func pooledSFTPRetriesCredentialsOnlyBeforeTheOperation() async throws {
        let setup = authenticationSetup(sftpAuthenticationFailures: 1)
        var prompts = 0
        let interaction = AuthenticationResponder { _ in
            prompts += 1
            return .submit(.init(username: "deploy", password: "secret-\(prompts)", save: false))
        }
        let files = try await setup.registry.withSFTP(
            hostID: setup.host.id, invocationID: UUID(), interaction: interaction.sshInteraction,
            pool: setup.pool, cancellation: TransferCancellationToken()
        ) { client in try await client.listDirectory(at: "/") }
        #expect(files.isEmpty)
        #expect(prompts == 2)
        #expect(await setup.backend.execOpens == 2)
        #expect(await setup.backend.sftpOpens == 1)
        #expect(await setup.backend.sftpOperations == 1)
        #expect(await setup.pool.openConnectionCount == 1)
    }

    @Test
    func pooledSFTPOperationFailureNeverRetries() async throws {
        let setup = authenticationSetup(sftpOperationFailures: 1)
        let interaction = AuthenticationResponder { _ in
            .submit(.init(username: "deploy", password: "secret", save: false))
        }
        await #expect(throws: SFTPError.self) {
            _ = try await setup.registry.withSFTP(
                hostID: setup.host.id, invocationID: UUID(), interaction: interaction.sshInteraction,
                pool: setup.pool, cancellation: TransferCancellationToken()
            ) { client in try await client.listDirectory(at: "/") }
        }
        #expect(await setup.backend.sftpOpens == 1)
        #expect(await setup.backend.sftpOperations == 1)
        #expect(await setup.pool.openConnectionCount == 0)
    }

    @Test
    func sameHostLeasesFallBackToSiblingChannelsWithOneAuthenticationContext() async throws {
        let setup = authenticationSetup()
        var prompts = 0
        let interaction = AuthenticationResponder { _ in
            prompts += 1
            return .submit(.init(username: "deploy", password: "secret", save: false))
        }
        let registry = setup.registry
        let pool = setup.pool
        let hostID = setup.host.id
        let cancellation = TransferCancellationToken()
        _ = try await registry.withSFTP(
            hostID: hostID, invocationID: UUID(), interaction: interaction.sshInteraction,
            pool: pool, cancellation: cancellation
        ) { first in
            try await registry.withSFTP(
                hostID: hostID, invocationID: UUID(), interaction: interaction.sshInteraction,
                pool: pool, cancellation: cancellation
            ) { second in
                _ = try await first.listDirectory(at: "/")
                return try await second.listDirectory(at: "/")
            }
        }
        #expect(prompts == 1)
        #expect(await setup.backend.sftpOpens == 1)
        #expect(await setup.backend.sftpSiblingChannels == 1)
        #expect(await setup.pool.openConnectionCount == 1)
    }

    private func authenticationSetup(
        sftpAuthenticationFailures: Int = 0,
        sftpOperationFailures: Int = 0,
        remoteFiles: [String: Data] = [:]
    ) -> (
        host: TermindDomain.Host, registry: AgentSSHAuthenticationRegistry,
        pool: AgentConnectionPool, backend: AuthenticationConnectionBackend,
        resolver: AgentHostResolver
    ) {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        let resolver = AgentHostResolver(store: store)
        let backend = AuthenticationConnectionBackend(
            sftpAuthenticationFailures: sftpAuthenticationFailures,
            sftpOperationFailures: sftpOperationFailures,
            remoteFiles: remoteFiles
        )
        return (
            host, AgentSSHAuthenticationRegistry(resolver: resolver),
            authenticationPool(resolver: resolver, backend: backend), backend, resolver
        )
    }

    private func authenticationPool(
        resolver: AgentHostResolver, backend: AuthenticationConnectionBackend
    ) -> AgentConnectionPool {
        AgentConnectionPool(
            configuration: { try await resolver.configuration(for: $0) },
            routeFingerprint: { try await resolver.routeFingerprint(for: $0) },
            openConnection: { try await backend.openConnection(configuration: $0.configuration) },
            openSFTP: { try await backend.openSFTP(configuration: $0.configuration) },
            sweepInterval: nil
        )
    }

    private func password(
        in configuration: SSHConnectionConfiguration, matches expected: String
    ) -> Bool {
        for credential in configuration.credentials {
            if case .password(let password) = credential { return password.matches(expected) }
        }
        return false
    }

    private func waitForAuthentication(in conversation: ConversationModel) async throws {
        for _ in 0..<1_000 {
            if conversation.pendingSSHAuthentication != nil { return }
            await Task.yield()
        }
        throw AuthenticationCancellationTestError.timedOut
    }

    private func waitForCompletion(_ completion: AuthenticationCompletionProbe) async -> Bool {
        for _ in 0..<1_000 {
            if await completion.isFinished { return true }
            await Task.yield()
        }
        return await completion.isFinished
    }
}

private enum AuthenticationCancellationTestError: Error { case timedOut }

private actor AuthenticationCompletionProbe {
    private(set) var isFinished = false

    func finish() { isFinished = true }
}

private final class MemoryHostSecretStore: SecretStoring, @unchecked Sendable {
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

@MainActor
private final class PassphraseRequestProbe {
    var wasRequested = false
}

private final class AuthenticationResponder: @unchecked Sendable {
    private let answer: @MainActor (AgentSSHAuthenticationRequest) -> AgentSSHAuthenticationResponse
    private let hostKeyAnswer: @MainActor (AgentSSHHostKeyRequest) -> AgentSSHHostKeyResponse

    init(
        answer: @escaping @MainActor (AgentSSHAuthenticationRequest) -> AgentSSHAuthenticationResponse,
        hostKeyAnswer: @escaping @MainActor (AgentSSHHostKeyRequest) -> AgentSSHHostKeyResponse = { _ in .deny }
    ) {
        self.answer = answer
        self.hostKeyAnswer = hostKeyAnswer
    }

    var sshInteraction: AgentSSHInteraction {
        AgentSSHInteraction(
            authenticate: { [answer] in await answer($0) },
            confirmHostKey: { [hostKeyAnswer] in await hostKeyAnswer($0) }
        )
    }
}

private actor GatedAuthenticationResponder {
    private(set) var requestCount = 0
    private var waiters: [CheckedContinuation<AgentSSHAuthenticationResponse, Never>] = []

    nonisolated var sshInteraction: AgentSSHInteraction {
        AgentSSHInteraction(
            authenticate: { [self] _ in await authenticate() },
            confirmHostKey: { _ in .deny }
        )
    }

    private func authenticate() async -> AgentSSHAuthenticationResponse {
        requestCount += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    func answer(_ response: AgentSSHAuthenticationResponse) {
        let answering = waiters
        waiters.removeAll()
        for waiter in answering { waiter.resume(returning: response) }
    }
}

private actor GatedHostKeyResponder {
    private(set) var authenticationRequestCount = 0
    private(set) var hostKeyRequestCount = 0
    private var hostKeyWaiters: [CheckedContinuation<AgentSSHHostKeyResponse, Never>] = []

    nonisolated var sshInteraction: AgentSSHInteraction {
        AgentSSHInteraction(
            authenticate: { [self] _ in await authenticate() },
            confirmHostKey: { [self] _ in await confirmHostKey() }
        )
    }

    private func authenticate() -> AgentSSHAuthenticationResponse {
        authenticationRequestCount += 1
        return .submit(
            AgentSSHAuthenticationAnswer(
                username: "deploy", password: "secret", save: false
            ))
    }

    private func confirmHostKey() async -> AgentSSHHostKeyResponse {
        hostKeyRequestCount += 1
        return await withCheckedContinuation { hostKeyWaiters.append($0) }
    }

    func answerHostKey(_ response: AgentSSHHostKeyResponse) {
        let answering = hostKeyWaiters
        hostKeyWaiters.removeAll()
        for waiter in answering { waiter.resume(returning: response) }
    }
}

private actor AuthenticationConnectionBackend {
    private(set) var execOpens = 0
    private(set) var sftpOpens = 0
    private(set) var auxiliarySFTPOpens = 0
    private(set) var sftpSiblingChannels = 0
    private(set) var sftpOperations = 0
    private(set) var sftpConfigurations: [SSHConnectionConfiguration] = []
    private(set) var observedDestinationPasswords: [String?] = []
    private(set) var observedJumpPasswords: [[String?]] = []
    private var sftpAuthenticationFailures: Int
    private var sftpOperationFailures: Int
    private var remoteFiles: [String: Data]

    init(
        sftpAuthenticationFailures: Int = 0,
        sftpOperationFailures: Int = 0,
        remoteFiles: [String: Data] = [:]
    ) {
        self.sftpAuthenticationFailures = sftpAuthenticationFailures
        self.sftpOperationFailures = sftpOperationFailures
        self.remoteFiles = remoteFiles
    }

    func openConnection(configuration: SSHConnectionConfiguration) throws -> AuthenticationSSHConnection {
        execOpens += 1
        observedDestinationPasswords.append(Self.passwordLabel(in: configuration.credentials))
        observedJumpPasswords.append(
            configuration.jumps.map { Self.passwordLabel(in: $0.credentials) }
        )
        sftpConfigurations.append(configuration)
        if sftpAuthenticationFailures > 0 {
            sftpAuthenticationFailures -= 1
            throw TermindSSHError.authenticationFailed("Rejected credential")
        }
        return AuthenticationSSHConnection(backend: self)
    }

    private static func passwordLabel(in credentials: [SSHCredentials]) -> String? {
        guard
            case .password(let password)? = credentials.first(where: {
                if case .password = $0 { return true }
                return false
            })
        else { return nil }
        return ["files-secret", "jump-secret", "secret", "old-secret", "new-secret", "fallback-password"]
            .first(where: password.matches)
    }

    func openSFTP(
        configuration: SSHConnectionConfiguration
    ) throws -> AuthenticationSFTPClient {
        auxiliarySFTPOpens += 1
        return AuthenticationSFTPClient(backend: self)
    }

    func openPrimarySFTP() -> AuthenticationSFTPClient {
        sftpOpens += 1
        return AuthenticationSFTPClient(backend: self)
    }

    func openSFTPSibling() -> AuthenticationSFTPClient {
        sftpSiblingChannels += 1
        return AuthenticationSFTPClient(backend: self)
    }

    func listDirectory(at path: String) throws -> [RemoteFile] {
        sftpOperations += 1
        if sftpOperationFailures > 0 {
            sftpOperationFailures -= 1
            throw SFTPError.connectionLost("Connection lost during list")
        }
        return []
    }

    func readFile(at path: String) throws -> Data {
        sftpOperations += 1
        guard let data = remoteFiles[path] else {
            throw SFTPError.operation("Missing test file")
        }
        return data
    }

    func writeFile(_ data: Data, at path: String) {
        sftpOperations += 1
        remoteFiles[path] = data
    }

    func remoteFile(at path: String) -> Data? { remoteFiles[path] }
}

private actor AuthenticationSSHConnection: SSHConnectionProtocol {
    private let backend: AuthenticationConnectionBackend

    init(backend: AuthenticationConnectionBackend) { self.backend = backend }

    func connect(using configuration: SSHConnectionConfiguration) async throws {}
    func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        SSHExecResult(
            stdout: "", stderr: "", exitCode: 0, signal: nil,
            stdoutTruncated: false, stderrTruncated: false
        )
    }
    func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        await backend.openPrimarySFTP()
    }
    func disconnect() async {}
}

private actor AuthenticationSFTPClient: SFTPClientProtocol {
    private let backend: AuthenticationConnectionBackend

    init(backend: AuthenticationConnectionBackend) { self.backend = backend }

    func openSiblingChannel() async throws -> any SFTPChannelProtocol {
        await backend.openSFTPSibling()
    }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home/deploy" }
    func listDirectory(at path: String) async throws -> [RemoteFile] {
        try await backend.listDirectory(at: path)
    }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        let data = try await backend.readFile(at: path)
        guard data.count <= maximumBytes else {
            throw SFTPError.operation("Test file exceeds limit")
        }
        return data
    }
    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        await backend.writeFile(data, at: path)
    }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(
        from source: String, to destination: String, overwrite: Bool
    ) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}
