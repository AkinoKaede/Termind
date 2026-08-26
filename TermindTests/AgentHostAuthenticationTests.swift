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
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: secrets
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
        #expect(saved.passwordStorage == .iCloud)
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
        let store = HostLibraryModel(
            hosts: [host], keys: [key],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: keychain
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
        var requestedHosts: [Termind.Host.ID] = []
        let interaction = AuthenticationResponder { request in
            requestedHosts.append(request.hostID)
            return .submit(AgentSSHAuthenticationAnswer(
                username: request.hostID == jump.id ? "jump-user" : "files-user",
                password: request.hostID == jump.id ? "jump-secret" : "files-secret",
                save: false
            ))
        }

        _ = try await registry.sftp(
            hostID: destination.id, invocationID: UUID(),
            interaction: interaction, pool: pool
        )

        #expect(requestedHosts == [jump.id, destination.id])
        let configuration = try #require(await backend.sftpConfigurations.first)
        #expect(configuration.username == "files-user")
        #expect(password(in: configuration) == "files-secret")
        #expect(configuration.jumps.count == 1)
        #expect(configuration.jumps[0].id == jump.id)
        #expect(configuration.jumps[0].username == "jump-user")
        guard case .password(let jumpPassword) = configuration.jumps[0].credentials.first
        else {
            Issue.record("Expected a jump-host password")
            return
        }
        #expect(jumpPassword == "jump-secret")
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
            .submit(AgentSSHAuthenticationAnswer(
                username: "deploy", password: "secret", save: false
            ))
        }
        let tool = try #require(
            AgentBuiltInTools.make(
                hosts: resolver, connections: pool, authentication: authentication
            ).first { $0.descriptor.name == "sftp_list" }
        )
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
                secretBroker: SecretBroker(), userInteraction: interaction,
                preflightMetadata: [:], authorize: { _ in .allow }
            )
        )

        #expect(!result.isError)
        #expect(await backend.sftpOpens == 1)
        let configuration = try #require(await backend.sftpConfigurations.first)
        #expect(configuration.username == "deploy")
        guard case .password(let password) = configuration.credentials.first else {
            Issue.record("Expected the one-use password in the SFTP configuration")
            return
        }
        #expect(password == "secret")
    }

    @Test
    func concurrentSFTPConnectionsShareOnePromptAndOnePendingConnection() async throws {
        let setup = authenticationSetup()
        let interaction = GatedAuthenticationResponder()

        async let first = setup.registry.sftp(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction, pool: setup.pool
        )
        async let second = setup.registry.sftp(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction, pool: setup.pool
        )
        while await interaction.requestCount == 0 { await Task.yield() }
        #expect(await interaction.requestCount == 1)
        await interaction.answer(.submit(AgentSSHAuthenticationAnswer(
            username: "deploy", password: "secret", save: false
        )))

        _ = try await (first, second)
        #expect(await interaction.requestCount == 1)
        #expect(await setup.backend.sftpOpens == 1)
    }

    @Test
    func concurrentExecAndSFTPShareOnePromptButOpenSeparateSessions() async throws {
        let setup = authenticationSetup()
        let interaction = GatedAuthenticationResponder()

        async let exec = setup.registry.exec(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction, pool: setup.pool
        )
        async let sftp = setup.registry.sftp(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction, pool: setup.pool
        )
        while await interaction.requestCount == 0 { await Task.yield() }
        #expect(await interaction.requestCount == 1)
        await interaction.answer(.submit(AgentSSHAuthenticationAnswer(
            username: "deploy", password: "secret", save: false
        )))

        _ = try await (exec, sftp)
        #expect(await interaction.requestCount == 1)
        #expect(await setup.backend.execOpens == 1)
        #expect(await setup.backend.sftpOpens == 1)
    }

    @Test
    func cancellingSharedAuthenticationCancelsEveryWaiterBeforeSFTPOpens() async {
        let setup = authenticationSetup()
        let interaction = GatedAuthenticationResponder()
        let first = Task {
            try await setup.registry.sftp(
                hostID: setup.host.id, invocationID: UUID(),
                interaction: interaction, pool: setup.pool
            )
        }
        let second = Task {
            try await setup.registry.sftp(
                hostID: setup.host.id, invocationID: UUID(),
                interaction: interaction, pool: setup.pool
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
            return .submit(AgentSSHAuthenticationAnswer(
                username: "deploy", password: password, save: false
            ))
        }

        _ = try await setup.registry.sftp(
            hostID: setup.host.id, invocationID: UUID(),
            interaction: interaction, pool: setup.pool
        )

        #expect(requests.count == 2)
        #expect(requests[0].failureMessage == nil)
        #expect(requests[1].failureMessage?.contains("Rejected") == true)
        #expect(requests[1].username == "deploy")
        #expect(await setup.backend.sftpOpens == 2)
        let configurations = await setup.backend.sftpConfigurations
        #expect(password(in: configurations[0]) == "old-secret")
        #expect(password(in: configurations[1]) == "new-secret")
    }

    @Test
    func staleFailureCannotClearANewerAuthenticationGeneration() async throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        let interaction = GatedAuthenticationResponder()
        let session = AgentSSHConfigurationSession(
            resolver: AgentHostResolver(store: store), hostID: host.id,
            invocationID: UUID(), interaction: interaction
        )

        let firstTask = Task { try await session.configurationAttempt() }
        while await interaction.requestCount == 0 { await Task.yield() }
        await interaction.answer(.submit(AgentSSHAuthenticationAnswer(
            username: "deploy", password: "old-secret", save: false
        )))
        let first = try await firstTask.value
        await session.retry(
            after: .authenticationFailed("Rejected old credential"),
            generation: first.generation
        )

        let secondTask = Task { try await session.configurationAttempt() }
        while await interaction.requestCount < 2 { await Task.yield() }
        await interaction.answer(.submit(AgentSSHAuthenticationAnswer(
            username: "deploy", password: "new-secret", save: false
        )))
        let second = try await secondTask.value

        await session.retry(
            after: .authenticationFailed("Late rejection from old connection"),
            generation: first.generation
        )
        let retained = try await session.configurationAttempt()
        #expect(retained.generation == second.generation)
        #expect(password(in: retained.configuration) == "new-secret")
        #expect(await interaction.requestCount == 2)
    }

    @Test
    func connectionLossEvictsSFTPWithoutReplayingTheOperation() async throws {
        let setup = authenticationSetup(sftpOperationFailures: 1)
        var requestCount = 0
        let interaction = AuthenticationResponder { _ in
            requestCount += 1
            return .submit(AgentSSHAuthenticationAnswer(
                username: "deploy", password: "secret-\(requestCount)", save: false
            ))
        }
        let tool = try #require(
            AgentBuiltInTools.make(
                hosts: setup.resolver, connections: setup.pool,
                authentication: setup.registry
            ).first { $0.descriptor.name == "sftp_list" }
        )
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
                secretBroker: SecretBroker(), userInteraction: interaction,
                preflightMetadata: [:], authorize: { _ in .allow }
            )
        }

        let first = invocation("first")
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(first, context: context(for: first))
        }
        #expect(await setup.backend.sftpOperations == 1)
        let remainedConnected = await setup.pool.isConnected(
            hostID: setup.host.id, kind: .sftp
        )
        #expect(!remainedConnected)

        let second = invocation("second")
        let result = try await tool.execute(second, context: context(for: second))
        #expect(!result.isError)
        #expect(await setup.backend.sftpOperations == 2)
        #expect(await setup.backend.sftpOpens == 2)
        #expect(requestCount == 2)
    }

    @Test
    func scratchPullAndPushUseAuthenticationAndTheSharedSFTPPool() async throws {
        let source = Data("server configuration\n".utf8)
        let setup = authenticationSetup(remoteFiles: ["/etc/app.conf": source])
        let base = FileManager.default.temporaryDirectory
            .appending(path: "termind-agent-auth-scratch/\(UUID().uuidString)")
        let workspace = AgentScratchWorkspace(conversationID: UUID(), base: base)
        let tools = AgentScratchTools.make(
            workspace: workspace, connections: setup.pool,
            authentication: setup.registry
        )
        let pull = try #require(tools.first { $0.descriptor.name == "scratch_pull" })
        let push = try #require(tools.first { $0.descriptor.name == "scratch_push" })
        var requestCount = 0
        let interaction = AuthenticationResponder { _ in
            requestCount += 1
            return .submit(AgentSSHAuthenticationAnswer(
                username: "deploy", password: "secret-\(requestCount)", save: false
            ))
        }
        func context(
            _ invocation: AgentToolInvocation,
            preflight: [String: AgentJSONValue] = [:]
        ) -> AgentToolExecutionContext {
            AgentToolExecutionContext(
                runID: invocation.runID, userIntent: "transfer configuration",
                secretBroker: SecretBroker(), userInteraction: interaction,
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

        // A live SFTP session is reused without another card. Once evicted, the
        // push is a new authentication wave and must not inherit Custom secrets.
        _ = await setup.pool.disconnect(hostID: setup.host.id, kind: .sftp)
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
        #expect(await setup.backend.sftpOpens == 2)
    }

    private func authenticationSetup(
        sftpAuthenticationFailures: Int = 0,
        sftpOperationFailures: Int = 0,
        remoteFiles: [String: Data] = [:]
    ) -> (
        host: Termind.Host, registry: AgentSSHAuthenticationRegistry,
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
            openExec: { await backend.openExec(configuration: $0) },
            openSFTP: { try await backend.openSFTP(configuration: $0) },
            sweepInterval: nil
        )
    }

    private func password(in configuration: SSHConnectionConfiguration) -> String? {
        for credential in configuration.credentials {
            if case .password(let password) = credential { return password }
        }
        return nil
    }
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

private actor GatedAuthenticationResponder: AgentUserInteractionHandling {
    private(set) var requestCount = 0
    private var waiters:
        [CheckedContinuation<AgentSSHAuthenticationResponse, Never>] = []

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        .cancelled
    }

    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        requestCount += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    func answer(_ response: AgentSSHAuthenticationResponse) {
        let answering = waiters
        waiters.removeAll()
        for waiter in answering { waiter.resume(returning: response) }
    }
}

private actor AuthenticationConnectionBackend {
    private(set) var execOpens = 0
    private(set) var sftpOpens = 0
    private(set) var sftpOperations = 0
    private(set) var sftpConfigurations: [SSHConnectionConfiguration] = []
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

    func openExec(configuration: SSHConnectionConfiguration) -> AuthenticationExecSession {
        execOpens += 1
        return AuthenticationExecSession()
    }

    func openSFTP(
        configuration: SSHConnectionConfiguration
    ) throws -> AuthenticationSFTPClient {
        sftpOpens += 1
        sftpConfigurations.append(configuration)
        if sftpAuthenticationFailures > 0 {
            sftpAuthenticationFailures -= 1
            throw TermindSSHError.authenticationFailed("Rejected credential")
        }
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

private actor AuthenticationExecSession: SSHExecSessionProtocol {
    func connect(using configuration: SSHConnectionConfiguration) async throws {}
    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        SSHExecResult(
            stdout: "", stderr: "", exitCode: 0, signal: nil,
            stdoutTruncated: false, stderrTruncated: false
        )
    }
    func disconnect() async {}
}

private actor AuthenticationSFTPClient: SFTPClientProtocol {
    private let backend: AuthenticationConnectionBackend

    init(backend: AuthenticationConnectionBackend) { self.backend = backend }

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
