import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

@Suite(.serialized)
@MainActor
struct SFTPCopyToolTests {
    @Test(arguments: [Data(), Data([0, 255, 128, 10]), Data(count: AgentScratchWorkspace.Limits.fileBytes + 1)])
    func copiesBytesWithoutScratchOrInlineIO(_ bytes: Data) async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: bytes)
        let result = try await fixture.copy()
        #expect(!result.isError)
        #expect(await fixture.destination.data["/target/a.bin"] == bytes)
        #expect(await fixture.source.data["/source/a.bin"] == bytes)
        let object = try fixture.object(result)
        #expect(object["bytes"]?.integerValue == bytes.count)
        #expect(object["copied_files"]?.integerValue == 1)
        #expect(await fixture.backend.opens == 2)
        #expect(await fixture.backend.disconnects == 0)
        #expect(await fixture.pool.openConnectionCount == 2)
    }

    @Test
    func preservesHierarchyAndEmptyDirectories() async throws {
        let fixture = CopyFixture()
        await fixture.source.directory("/source/tree")
        await fixture.source.directory("/source/tree/empty")
        await fixture.source.directory("/source/tree/nested")
        await fixture.source.put("/source/tree/nested/a", bytes: Data([1, 2]))
        let result = try await fixture.copy(path: "/source/tree")
        let object = try fixture.object(result)
        #expect(!result.isError)
        #expect(object["created_directories"]?.integerValue == 3)
        #expect(await fixture.destination.nodes["/target/tree/empty"]?.isDirectory == true)
        #expect(await fixture.destination.data["/target/tree/nested/a"] == Data([1, 2]))
    }

    @Test(arguments: ["skip", "replace", "keep_both"])
    func resolvesSameNameFilesUsingBrowserPolicies(_ policy: String) async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.destination.put("/target/a.bin", bytes: Data([2]))
        let result = try await fixture.copy(policy: policy)
        #expect(!result.isError)
        let object = try fixture.object(result)
        #expect(object["skipped_items"]?.integerValue == (policy == "skip" ? 1 : 0))
        let target = policy == "keep_both" ? "/target/a.2.bin" : "/target/a.bin"
        #expect(await fixture.destination.data[target] == Data([policy == "skip" ? 2 : 1]))
        #expect(object["actual_destination_path"]?.stringValue == target)
    }

    @Test(arguments: ["skip", "replace", "keep_both"])
    func resolvesFileOverDirectoryConflicts(_ policy: String) async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.destination.directory("/target/a.bin")
        await fixture.destination.put("/target/a.bin/old", bytes: Data([2]))
        let result = try await fixture.copy(policy: policy)
        #expect(!result.isError)
        if policy == "replace" {
            #expect(await fixture.destination.nodes["/target/a.bin/old"] == nil)
            #expect(await fixture.destination.data["/target/a.bin"] == Data([1]))
        } else {
            #expect(await fixture.destination.data["/target/a.bin/old"] == Data([2]))
        }
    }

    @Test(arguments: ["skip", "replace", "keep_both"])
    func resolvesDirectoryOverFileAndMapsDescendants(_ policy: String) async throws {
        let fixture = CopyFixture()
        await fixture.source.directory("/source/tree")
        await fixture.source.directory("/source/tree/empty")
        await fixture.source.put("/source/tree/a", bytes: Data([1]))
        await fixture.destination.put("/target/tree", bytes: Data([2]))
        let result = try await fixture.copy(path: "/source/tree", policy: policy)
        #expect(!result.isError)
        let object = try fixture.object(result)
        if policy == "skip" {
            #expect(object["skipped_items"]?.integerValue == 3)
            #expect(await fixture.destination.data["/target/tree"] == Data([2]))
        } else {
            let target = policy == "keep_both" ? "/target/tree.2" : "/target/tree"
            #expect(object["actual_destination_path"]?.stringValue == target)
            #expect(await fixture.destination.nodes[target + "/empty"]?.isDirectory == true)
            #expect(await fixture.destination.data[target + "/a"] == Data([1]))
        }
    }

    @Test
    func mergesDirectoriesAndKeepsUnrelatedDestinationFiles() async throws {
        let fixture = CopyFixture()
        await fixture.source.directory("/source/tree")
        await fixture.source.put("/source/tree/a", bytes: Data([1]))
        await fixture.destination.directory("/target/tree")
        await fixture.destination.put("/target/tree/old", bytes: Data([2]))
        #expect(try await !fixture.copy(path: "/source/tree", policy: "replace").isError)
        #expect(await fixture.destination.data["/target/tree/old"] == Data([2]))
    }

    @Test(arguments: [RemoteFile.Kind.symbolicLink, .special, .unknown])
    func rejectsUnsupportedDescendantsBeforeWriting(_ kind: RemoteFile.Kind) async throws {
        let fixture = CopyFixture()
        await fixture.source.directory("/source/tree")
        await fixture.source.put("/source/tree/a", bytes: Data([1]))
        await fixture.source.node("/source/tree/z", kind: kind)
        let result = try await fixture.copy(path: "/source/tree")
        #expect(result.isError)
        #expect(await fixture.destination.nodes.count == 1)
    }

    @Test(arguments: ["relative", "/../escape", "/a\nb", "/a\0b", "/"])
    func rejectsInvalidSourcePathsWithoutConnecting(_ path: String) async throws {
        let fixture = CopyFixture()
        await #expect(throws: (any Error).self) { _ = try await fixture.copy(path: path) }
        #expect(await fixture.backend.opens == 0)
    }

    @Test
    func sameHostUsesIndependentConnectionsAndRejectsSelfCopies() async throws {
        let fixture = CopyFixture(sameHost: true, strategy: .connectionsPreferred)
        await fixture.source.directory("/target")
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        #expect(try await !fixture.copy().isError)
        #expect(await fixture.source.data["/target/a.bin"] == Data([1]))
        #expect(await fixture.backend.opens == 2)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.copy(destination: "/source")
        }
        await fixture.source.directory("/source/tree")
        await fixture.source.directory("/source/tree/nested")
        #expect(try await fixture.copy(path: "/source/tree", destination: "/source/tree/nested").isError)
        #expect(await fixture.source.nodes["/source/tree/nested/tree"] == nil)
    }

    @Test
    func smartUnknownSameHostCopyUsesOneChannel() async throws {
        let fixture = CopyFixture(sameHost: true)
        await fixture.source.directory("/target")
        await fixture.source.put("/source/a.bin", bytes: Data([1]))

        #expect(try await !fixture.copy().isError)
        #expect(await fixture.backend.opens == 1)
        #expect(await fixture.backend.siblingSessions == 0)
    }

    @Test
    func detectsChangedSourceAndReportsPartialCompletionWithoutRetry() async throws {
        let fixture = CopyFixture()
        await fixture.source.directory("/source/tree")
        await fixture.source.put("/source/tree/a", bytes: Data([1]))
        await fixture.source.put("/source/tree/b", bytes: Data([2]))
        await fixture.source.changeOnSecondStat("/source/tree/b")
        let result = try await fixture.copy(path: "/source/tree")
        #expect(result.isError)
        let object = try fixture.object(result)
        #expect(object["copied_files"]?.integerValue == 1)
        #expect(object["failed_path"]?.stringValue == "/source/tree/b")
        #expect(await fixture.destination.data["/target/tree/a"] == Data([1]))
        #expect(await fixture.backend.opens == 2)
    }

    @Test
    func copyFailureDoesNotReplayAndReturnsBothConnectionsToThePool() async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.source.failCopy()
        #expect(try await fixture.copy().isError)
        #expect(await fixture.source.copyAttempts == 1)
        #expect(await fixture.backend.disconnects == 0)
        #expect(await fixture.pool.openConnectionCount == 2)
    }

    @Test
    func sourceAndDestinationAncestorsCannotAliasThroughSymlinks() async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.source.node("/source", kind: .symbolicLink)
        #expect(try await fixture.copy().isError)
        #expect(await fixture.destination.nodes.count == 1)
        await fixture.source.directory("/source")
        await fixture.destination.node("/alias", kind: .symbolicLink)
        await fixture.destination.directory("/alias/target")
        #expect(try await fixture.copy(destination: "/alias/target").isError)
        #expect(await fixture.destination.data.isEmpty)
    }

    @Test
    func activeTransfersSurviveIdleSweepAndHostDeletionCancelsThem() async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.source.blockCopy()
        let task = Task { try await fixture.copy() }
        try await copyWait { await fixture.source.copyAttempts == 1 }
        _ = await fixture.pool.sweepIdle(now: .now.advanced(by: .seconds(1_000)))
        #expect(await fixture.pool.openConnectionCount == 2)
        await fixture.pool.disconnect(hostID: fixture.destinationID)
        #expect(try await task.value.isError)
        #expect(await fixture.pool.openConnectionCount == 1)
        #expect(await fixture.destination.data["/target/a.bin"] == nil)
    }

    @Test
    func taskCancellationReleasesLeasesButKeepsPooledConnections() async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.source.blockCopy()
        let task = Task { try await fixture.copy() }
        try await copyWait { await fixture.source.copyAttempts == 1 }
        task.cancel()
        #expect(try await task.value.isError)
        #expect(await fixture.backend.disconnects == 0)
        #expect(await fixture.pool.openConnectionCount == 2)
    }

    @Test
    func mcpExportsSharedSchemaAndHonorsDisabledTools() async throws {
        let fixture = CopyFixture()
        let server = fixture.server()
        let descriptor = try #require(server.descriptors.first { $0.name == "sftp_copy" })
        #expect(descriptor.inputSchema == fixture.tool.descriptor.inputSchema)
        #expect(descriptor.approvalPolicy == .ask)
        #expect(descriptor.concurrency == .sequential)
        let disabled = fixture.server(disabled: ["sftp_copy"])
        #expect(!disabled.contains("sftp_copy"))
        await #expect(throws: MCPServerToolsError.unknownTool("sftp_copy")) {
            _ = try await disabled.call(
                name: "sftp_copy", arguments: fixture.invocation().call.arguments,
                runID: UUID(), clientName: "Tests", callID: "1", secretBroker: SecretBroker()
            )
        }
    }

    @Test
    func mcpCopiesWithFullAccessAndRecordsMetadataOnly() async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data("PRIVATE-CONTENT".utf8))
        let audit = ToolAuditModel()
        let server = fixture.server(audit: audit)
        let result = try await server.call(
            name: "sftp_copy", arguments: fixture.invocation().call.arguments,
            runID: UUID(), clientName: "External Client", callID: "1", secretBroker: SecretBroker()
        )
        #expect(!result.isError)
        #expect(!result.content.contains("PRIVATE-CONTENT"))
        try await copyWait { audit.entries().first?.finishedAt != nil }
        let row = try #require(audit.entries().first)
        #expect(row.clientName == "External Client")
        #expect(row.bytesRead == 15)
        #expect(row.bytesWritten == 15)
        #expect(row.summary.contains(fixture.sourceID.uuidString))
        #expect(!row.summary.contains("PRIVATE-CONTENT"))
    }

    @Test
    func endingMcpSessionCancelsItsActiveCopy() async throws {
        let fixture = CopyFixture()
        await fixture.source.put("/source/a.bin", bytes: Data([1]))
        await fixture.source.blockCopy()
        let server = fixture.server()
        let runID = UUID()
        let broker = SecretBroker()
        let task = Task {
            try await server.call(
                name: "sftp_copy", arguments: fixture.invocation().call.arguments,
                runID: runID, clientName: "Tests", callID: "1", secretBroker: broker
            )
        }
        try await copyWait { await fixture.source.copyAttempts == 1 }
        await server.endSession(runID: runID, secretBroker: broker)
        #expect(try await task.value.isError)
        #expect(await fixture.pool.openConnectionCount == 2)
    }

    @Test
    func manualDenialPreventsConnections() async throws {
        let fixture = CopyFixture()
        let runtime = AgentRuntime(
            model: CopyCallingModel(arguments: fixture.invocation().call.arguments),
            tools: [AnyAgentTool(fixture.tool)],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("Denied") })
        )
        for await _ in await runtime.start(
            AgentRunRequest(conversationID: UUID(), prompt: "copy", permissionMode: .askForApproval)
        ) {}
        #expect(await fixture.backend.opens == 0)
    }

    @Test(arguments: ["skip", "replace", "keep_both"], ["en", "zh-Hans", "zh-Hant"])
    func approvalDetailsRetainEndpointsAndWarnOnlyForReplacement(_ policy: String, _ language: String) throws {
        let fixture = CopyFixture()
        let items = SFTPCopyTool.presentArguments(
            .init(
                arguments: try #require(fixture.invocation(policy: policy).call.arguments.objectValue),
                locale: Locale(identifier: language)
            ))
        let values = items.compactMap { item -> String? in
            if case .field(let field) = item { return field.value }
            return nil
        }
        #expect(values.contains(fixture.sourceID.uuidString))
        #expect(values.contains(fixture.destinationID.uuidString))
        #expect(
            items.contains {
                if case .message(_, .warning) = $0 { return true }
                return false
            } == (policy == "replace"))
    }
}

private struct CopyCallingModel: AgentModelStreaming {
    var arguments: AgentJSONValue
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            if request.messages.contains(where: { $0.role == .tool }) {
                continuation.yield(.finished(.completed))
            } else {
                continuation.yield(
                    .toolCallSnapshot(
                        id: "1", providerItemID: nil, name: "sftp_copy", arguments: arguments.encodedString
                    ))
                continuation.yield(.finished(.toolCalls))
            }
            continuation.finish()
        }
    }
}

@MainActor
private final class CopyFixture {
    let sourceID = UUID()
    let destinationID: UUID
    let source = CopyFileSystem()
    let destination = CopyFileSystem(target: true)
    let backend: CopyBackend
    let pool: AgentConnectionPool
    let resolver: AgentHostResolver
    let authentication: AgentSSHAuthenticationRegistry
    var tool: SFTPCopyTool { .init(hosts: resolver, authentication: authentication, connections: pool) }

    init(
        sameHost: Bool = false,
        strategy: SFTPConcurrencyStrategy = .smart
    ) {
        destinationID = sameHost ? sourceID : UUID()
        let sourceID = sourceID
        let destinationID = destinationID
        let ids = Set([sourceID, destinationID])
        @Sendable nonisolated func configuration(_ id: UUID) -> SSHConnectionConfiguration {
            SSHConnectionConfiguration(
                hostID: id, host: id.uuidString, port: 22, username: "test",
                credentials: [.password("test")], expectedHostKeys: [], proxy: nil, jumps: []
            )
        }
        resolver = AgentHostResolver(
            store: HostLibraryModel(),
            temporaryTargets: {
                ids.map {
                    .init(
                        id: $0, displayName: $0 == sourceID ? "Source" : "Destination", address: "test",
                        tags: [], connectionState: "connected", isTemporary: true)
                }
            },
            temporaryConfiguration: { configuration($0) }
        )
        authentication = AgentSSHAuthenticationRegistry(resolver: resolver)
        let backend = CopyBackend(
            filesystems: sameHost ? [sourceID: source] : [sourceID: source, destinationID: destination])
        self.backend = backend
        pool = AgentConnectionPool(
            configuration: { configuration($0) }, routeFingerprint: { _ in "test" },
            openConnection: { try await backend.openConnection($0.configuration.hostID) },
            openSFTP: { try await backend.openAuxiliary($0.configuration.hostID) },
            sftpConcurrencyScheduler: SFTPConcurrencyScheduler(
                preferences: SFTPPreferences(strategy: strategy)),
            sweepInterval: nil
        )
    }

    func invocation(path: String = "/source/a.bin", destination: String = "/target", policy: String? = nil)
        -> AgentToolInvocation
    {
        var arguments: [String: AgentJSONValue] = [
            "source_host_id": .string(sourceID.uuidString), "source_path": .string(path),
            "destination_host_id": .string(destinationID.uuidString), "destination_path": .string(destination),
        ]
        if let policy { arguments["conflict_policy"] = .string(policy) }
        return .init(runID: UUID(), call: .init(id: "1", name: "sftp_copy", arguments: .object(arguments)))
    }

    func copy(path: String = "/source/a.bin", destination: String = "/target", policy: String? = nil) async throws
        -> AgentToolResult
    {
        let invocation = invocation(path: path, destination: destination, policy: policy)
        let preflight = try await tool.preflight(invocation)
        return try await tool.execute(
            preflight.invocation,
            context: .init(
                runID: invocation.runID, userIntent: "copy", secretBroker: SecretBroker(),
                userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: preflight.executionMetadata,
                authorize: { _ in .allow }
            ))
    }

    func object(_ result: AgentToolResult) throws -> [String: AgentJSONValue] {
        let payload = try #require(result.untrustedPayload)
        let value = try AgentJSONValue.decode(Data(payload.utf8))
        return try #require(value.objectValue)
    }

    func server(disabled: Set<String> = [], audit: ToolAuditModel = ToolAuditModel()) -> MCPServerTools {
        MCPServerTools(
            hosts: resolver, metrics: TestMetricsReader(), connections: pool, authentication: authentication,
            background: AgentBackgroundCommands(sweepInterval: nil), externalAuthentication: ExternalAuthCoordinator(),
            history: audit, disabledTools: disabled
        )
    }
}

private actor CopyFileSystem {
    var nodes: [String: RemoteFile] = [:]
    var data: [String: Data] = [:]
    var copyAttempts = 0
    var blocked = false
    var failing = false
    var changing: String?
    var stats: [String: Int] = [:]

    init(target: Bool = false) {
        if target {
            nodes["/target"] = Self.file("/target", kind: .directory)
        } else {
            nodes["/source"] = Self.file("/source", kind: .directory)
        }
    }
    static func file(_ path: String, kind: RemoteFile.Kind, size: Int64 = 0) -> RemoteFile {
        .init(
            path: path, name: (path as NSString).lastPathComponent, kind: kind, size: size,
            permissions: 0o600, ownerUID: 0, ownerGID: 0)
    }
    func node(_ path: String, kind: RemoteFile.Kind) { nodes[path] = Self.file(path, kind: kind) }
    func directory(_ path: String) { node(path, kind: .directory) }
    func put(_ path: String, bytes: Data) {
        nodes[path] = Self.file(path, kind: .file, size: Int64(bytes.count))
        data[path] = bytes
    }
    func stat(_ path: String) -> RemoteFile? {
        stats[path, default: 0] += 1
        if changing == path && stats[path] == 2 { nodes[path]?.size += 1 }
        return nodes[path]
    }
    func children(_ path: String) -> [RemoteFile] {
        let children = nodes.values.filter { RemotePath.parent(of: $0.path) == path }.sorted { $0.path < $1.path }
        for child in children { stats[child.path, default: 0] += 1 }
        return children
    }
    func remove(_ path: String) {
        nodes[path] = nil
        data[path] = nil
    }
    func blockCopy() { blocked = true }
    func failCopy() { failing = true }
    func changeOnSecondStat(_ path: String) { changing = path }
    func startCopy() { copyAttempts += 1 }
}

private actor CopyBackend {
    var filesystems: [UUID: CopyFileSystem]
    var opens = 0
    var disconnects = 0
    var siblingSessions = 0
    init(filesystems: [UUID: CopyFileSystem]) { self.filesystems = filesystems }
    func openConnection(_ id: UUID) throws -> CopySSHConnection {
        opens += 1
        return CopySSHConnection(
            filesystem: try #require(filesystems[id]), backend: self)
    }
    func openAuxiliary(_ id: UUID) throws -> CopyClient {
        opens += 1
        return CopyClient(filesystem: try #require(filesystems[id]), backend: self)
    }
    func disconnected() { disconnects += 1 }
    func openedSibling() { siblingSessions += 1 }
}

private actor CopySSHConnection: SSHConnectionProtocol {
    let filesystem: CopyFileSystem
    let backend: CopyBackend

    init(filesystem: CopyFileSystem, backend: CopyBackend) {
        self.filesystem = filesystem
        self.backend = backend
    }

    func connect(using configuration: SSHConnectionConfiguration) async throws {}
    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?, timeout: TimeInterval,
        outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        throw AgentToolError.invalidArguments("Unexpected exec in SFTP copy test")
    }
    func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        CopyClient(filesystem: filesystem, backend: backend)
    }
    func disconnect() async { await backend.disconnected() }
}

private actor CopyClient: SFTPClientProtocol {
    let filesystem: CopyFileSystem
    let backend: CopyBackend
    init(filesystem: CopyFileSystem, backend: CopyBackend) {
        self.filesystem = filesystem
        self.backend = backend
    }
    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func openSiblingChannel() async throws -> any SFTPChannelProtocol {
        await backend.openedSibling()
        return CopyClient(filesystem: filesystem, backend: backend)
    }
    func disconnect() async { await backend.disconnected() }
    func homeDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { await filesystem.children(path) }
    func attributes(at path: String) async throws -> RemoteFile? { await filesystem.stat(path) }
    func createDirectory(at path: String) async throws { await filesystem.directory(path) }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        throw SFTPError.notConnected
    }
    func removeFile(at path: String) async throws { await filesystem.remove(path) }
    func removeDirectory(at path: String) async throws { await filesystem.remove(path) }
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw SFTPError.notConnected }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw SFTPError.notConnected }
    func copyFile(
        from sourcePath: String, to destinationPath: String, on destination: any SFTPChannelProtocol,
        byteCount: Int64, overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        await filesystem.startCopy()
        while await filesystem.blocked {
            guard !cancellation.isCancelled else { throw SFTPError.cancelled }
            try await Task.sleep(for: .milliseconds(10))
        }
        if await filesystem.failing { throw SFTPError.connectionLost("Disconnected") }
        let destination = try #require(destination as? CopyClient)
        let bytes = try #require(await filesystem.data[sourcePath])
        progress(.init(completedBytes: byteCount, totalBytes: byteCount, bytesPerSecond: 1))
        await destination.filesystem.put(destinationPath, bytes: bytes)
    }
}

@MainActor
private func copyWait(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw SFTPError.operation("Test timed out") }
        try await Task.sleep(for: .milliseconds(10))
    }
}
