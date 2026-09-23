import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

@Suite
struct AgentConnectionPoolTests {
    @Test
    func exclusiveConnectionAdapterAdmitsOnlyOneOperationAtATime() async throws {
        let firstGate = Gate()
        let secondGate = Gate()
        let adapter = SSHExclusiveConnectionAdapter(connection: 1) { _ in }
        let first = Task {
            try await adapter.withConnection { _ in
                await firstGate.wait()
                return 1
            }
        }
        while await firstGate.arrivals == 0 { await Task.yield() }
        let second = Task {
            try await adapter.withConnection { _ in
                await secondGate.wait()
                return 2
            }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await secondGate.arrivals == 0)
        await firstGate.open()
        while await secondGate.arrivals == 0 { await Task.yield() }
        await secondGate.open()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
    }

    @Test
    func repeatedCommandsOnOneHostShareASingleConnection() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        for index in 0..<5 {
            let result = try await pool.execute(
                "echo \(index)", workingDirectory: nil, stdin: nil,
                timeout: 60, outputLimit: 1_024, hostID: host
            )
            #expect(result.exitCode == 0)
        }

        // The whole point of the pool: five commands, one handshake.
        #expect(await backend.execOpens == 1)
        #expect(await backend.execDisconnects == 0)
    }

    @Test
    func concurrentCallersShareOneConnectionInsteadOfLeakingOne() async throws {
        let backend = StubBackend()
        let gate = Gate()
        let pool = makePool(backend, openerGate: gate)
        let host = UUID()

        async let first = pool.connection(hostID: host)
        // Only start the second caller once the first is parked mid-connect, so
        // it is guaranteed to find work already in flight rather than racing it.
        while await gate.arrivals == 0 { await Task.yield() }
        async let second = pool.connection(hostID: host)
        await gate.open()

        let connections = try await [first, second]
        #expect(try connections.map(serial) == [1, 1])
        #expect(await backend.execOpens == 1)
    }

    @Test
    func cancellingTheOnlyConnectionWaiterDoesNotWaitForTheSharedOpen() async throws {
        let backend = StubBackend()
        let gate = Gate()
        let pool = makePool(backend, openerGate: gate)
        let host = UUID()
        let completion = ConnectionCompletionProbe()
        let opening = Task {
            defer { Task { await completion.finish() } }
            return try await pool.connection(hostID: host)
        }
        while await gate.arrivals == 0 { await Task.yield() }

        opening.cancel()
        let completedBeforeOpenFinished = await waitForCompletion(completion)
        await gate.open()

        #expect(completedBeforeOpenFinished)
        await #expect(throws: CancellationError.self) {
            _ = try await opening.value
        }
        for _ in 0..<1_000 where await backend.execDisconnects == 0 {
            await Task.yield()
        }
        #expect(await backend.execDisconnects == 1)
        #expect(await pool.openConnectionCount == 0)
    }

    @Test
    func cancellingOneConnectionWaiterPreservesTheSharedOpenForAnotherWaiter() async throws {
        let backend = StubBackend()
        let gate = Gate()
        let pool = makePool(backend, openerGate: gate)
        let host = UUID()
        let firstCompletion = ConnectionCompletionProbe()
        let first = Task {
            defer { Task { await firstCompletion.finish() } }
            return try await pool.connection(hostID: host)
        }
        while await gate.arrivals == 0 { await Task.yield() }
        let second = Task { try await pool.connection(hostID: host) }
        for _ in 0..<100 { await Task.yield() }

        first.cancel()
        let firstCompletedBeforeOpenFinished = await waitForCompletion(firstCompletion)
        await gate.open()

        #expect(firstCompletedBeforeOpenFinished)
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(try serial(await second.value) == 1)
        #expect(await backend.execOpens == 1)
        #expect(await backend.execDisconnects == 0)
        #expect(await pool.openConnectionCount == 1)
    }

    @Test
    func execAndSFTPShareOneConnectionAndCloseTogether() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        _ = try await pool.connection(hostID: host)
        _ = try await pool.sftpChannel(hostID: host)
        #expect(await pool.openConnectionCount == 1)
        #expect(await backend.execOpens == 1)
        #expect(await backend.sftpOpens == 0)

        #expect(await pool.disconnect(hostID: host))
        #expect(await pool.isConnected(hostID: host) == false)
        #expect(await backend.execDisconnects == 1)
        #expect(await backend.sftpDisconnects == 1)
    }

    @Test
    func sftpThenExecReuseTheSamePrimaryConnection() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        _ = try await pool.sftpChannel(hostID: host)
        _ = try await pool.connection(hostID: host)

        #expect(await backend.execOpens == 1)
        #expect(await backend.sftpOpens == 0)
        #expect(await pool.openConnectionCount == 1)
    }

    @Test
    func concurrentExecAndSFTPJoinOnePrimaryConnection() async throws {
        let backend = StubBackend()
        let gate = Gate()
        let pool = makePool(backend, openerGate: gate)
        let host = UUID()

        async let exec = pool.connection(hostID: host)
        while await gate.arrivals == 0 { await Task.yield() }
        async let sftp = pool.sftpChannel(hostID: host)
        await gate.open()
        _ = try await (exec, sftp)

        #expect(await backend.execOpens == 1)
        #expect(await backend.sftpOpens == 0)
        #expect(await pool.openConnectionCount == 1)
    }

    @Test
    func disconnectingATwiceReportsThatNothingWasOpenTheSecondTime() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        _ = try await pool.connection(hostID: host)
        #expect(await pool.disconnect(hostID: host))
        #expect(await pool.disconnect(hostID: host) == false)
        #expect(await backend.execDisconnects == 1)
    }

    @Test
    func idleConnectionsCloseAndTheNextCommandReconnects() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        _ = try await pool.connection(hostID: host)
        let remaining = await pool.sweepIdle(
            now: .now.advanced(by: AgentConnectionPool.defaultIdleTimeout + .seconds(1))
        )

        #expect(remaining == 0)
        #expect(await backend.execDisconnects == 1)
        #expect(await pool.isConnected(hostID: host) == false)

        _ = try await pool.connection(hostID: host)
        #expect(await backend.execOpens == 2)
    }

    @Test
    func aRecentlyUsedConnectionSurvivesTheSweep() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        _ = try await pool.connection(hostID: host)
        let remaining = await pool.sweepIdle(now: .now)

        #expect(remaining == 1)
        #expect(await backend.execDisconnects == 0)
    }

    @Test
    func anActiveExecChannelSurvivesTheIdleSweep() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()
        let connection = try await pool.connection(hostID: host)
        let gate = Gate()
        let running = Task {
            try await pool.withExecLease(hostID: host, connection: connection) {
                await gate.wait()
                return 1
            }
        }
        while await gate.arrivals == 0 { await Task.yield() }

        let remaining = await pool.sweepIdle(
            now: .now.advanced(by: AgentConnectionPool.defaultIdleTimeout + .seconds(1)))

        #expect(remaining == 1)
        #expect(await backend.execDisconnects == 0)
        await gate.open()
        #expect(try await running.value == 1)
    }

    @Test
    func editingAHostsRouteRetiresTheConnectionBoundToTheOldOne() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        let before = try await pool.connection(hostID: host)
        await backend.setFingerprint("route-b", for: host)
        let after = try await pool.connection(hostID: host)

        // Not the same machine any more, so not the same connection — otherwise a
        // command aimed at the edited host would run on the old one.
        #expect(try serial(before) == 1)
        #expect(try serial(after) == 2)
        #expect(await backend.execOpens == 2)
        #expect(await pool.openConnectionCount == 1)
    }

    @Test
    func aHostThatNoLongerResolvesHasItsConnectionClosed() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        _ = try await pool.connection(hostID: host)
        await backend.forget(host)

        await #expect(throws: AgentToolError.self) { _ = try await pool.connection(hostID: host) }
        #expect(await backend.execDisconnects == 1)
        #expect(await pool.openConnectionCount == 0)
    }

    @Test
    func aConnectionThatDiedBetweenCommandsIsReplacedTransparently() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        await backend.queueExecFailures([
            SSHCommandExecutionError.connectionUnavailable(TermindSSHError.disconnected)
        ])
        let result = try await pool.execute(
            "uptime", workingDirectory: nil, stdin: nil,
            timeout: 60, outputLimit: 1_024, hostID: host
        )

        #expect(result.exitCode == 0)
        #expect(await backend.execOpens == 2)
        #expect(await backend.execDisconnects == 1)
    }

    @Test
    func aCommandThatFailedAfterItStartedIsNeverRunTwice() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)
        let host = UUID()

        // Not `connectionUnavailable`: the command reached the remote shell, so a
        // silent retry could delete something a second time.
        await backend.queueExecFailures([TermindSSHError.library("connection reset")])
        await #expect(throws: TermindSSHError.self) {
            _ = try await pool.execute(
                "rm -rf /srv//old", workingDirectory: nil, stdin: nil,
                timeout: 60, outputLimit: 1_024, hostID: host
            )
        }

        #expect(await backend.execOpens == 1)
        #expect(await backend.totalExecuteCount() == 1)
    }

    @Test
    func closeAllReleasesEveryHost() async throws {
        let backend = StubBackend()
        let pool = makePool(backend)

        for _ in 0..<3 {
            let host = UUID()
            _ = try await pool.connection(hostID: host)
            _ = try await pool.sftpChannel(hostID: host)
        }
        await pool.closeAll()

        #expect(await pool.openConnectionCount == 0)
        #expect(await backend.execDisconnects == 3)
        #expect(await backend.sftpDisconnects == 3)
    }
}

private func waitForCompletion(_ completion: ConnectionCompletionProbe) async -> Bool {
    for _ in 0..<1_000 {
        if await completion.isFinished { return true }
        await Task.yield()
    }
    return await completion.isFinished
}

private actor ConnectionCompletionProbe {
    private(set) var isFinished = false

    func finish() { isFinished = true }
}

/// Which stub connection the pool handed back. Distinguishing "reused" from
/// "reconnected" is the whole subject of these tests.
private func serial(_ connection: any SSHConnectionProtocol) throws -> Int {
    try #require(connection as? StubSSHConnection).stubSerial
}

/// `sweepInterval: nil` keeps the background sweeper out of the tests; every
/// case here drives `sweepIdle` itself with a synthetic instant.
private func makePool(
    _ backend: StubBackend, openerGate: Gate? = nil
) -> AgentConnectionPool {
    AgentConnectionPool(
        configuration: { hostID in
            SSHConnectionConfiguration(
                hostID: hostID, host: "host.example", port: 22, username: "root",
                credentials: [], expectedHostKeys: [], proxy: nil, jumps: []
            )
        },
        routeFingerprint: { try await backend.fingerprint(for: $0) },
        openConnection: { _ in
            if let openerGate { await openerGate.wait() }
            return await backend.openConnection()
        },
        openSFTP: { _ in await backend.openSFTP() },
        sweepInterval: nil
    )
}

private actor Gate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting.removeAll()
    }
}

private actor StubBackend {
    private(set) var execOpens = 0
    private(set) var sftpOpens = 0
    private(set) var execDisconnects = 0
    private(set) var sftpDisconnects = 0
    private var fingerprints: [UUID: String] = [:]
    private var forgotten: Set<UUID> = []
    private var nextExecFailures: [any Error] = []
    private var connections: [StubSSHConnection] = []

    func fingerprint(for hostID: UUID) throws -> String {
        guard !forgotten.contains(hostID) else { throw AgentToolError.invalidHost }
        return fingerprints[hostID] ?? "route-a"
    }

    func setFingerprint(_ value: String, for hostID: UUID) { fingerprints[hostID] = value }
    func forget(_ hostID: UUID) { forgotten.insert(hostID) }

    /// Applies to the next connection opened, so a test can arrange for a pooled
    /// connection to fail once and the replacement to succeed.
    func queueExecFailures(_ errors: [any Error]) { nextExecFailures = errors }

    func openConnection() -> StubSSHConnection {
        execOpens += 1
        let connection = StubSSHConnection(
            serial: execOpens, backend: self, failures: nextExecFailures
        )
        nextExecFailures = []
        connections.append(connection)
        return connection
    }

    func openSFTP() -> StubSFTPClient {
        sftpOpens += 1
        return StubSFTPClient(backend: self)
    }

    func openSFTPChannel() -> StubSFTPClient { StubSFTPClient(backend: self) }

    func noteExecDisconnect() { execDisconnects += 1 }
    func noteSFTPDisconnect() { sftpDisconnects += 1 }

    func totalExecuteCount() async -> Int {
        var total = 0
        for connection in connections { total += await connection.executeCount }
        return total
    }
}

private actor StubSSHConnection: SSHConnectionProtocol {
    nonisolated let stubSerial: Int
    private let backend: StubBackend
    private var failures: [any Error]
    private(set) var executeCount = 0

    init(serial: Int, backend: StubBackend, failures: [any Error]) {
        stubSerial = serial
        self.backend = backend
        self.failures = failures
    }

    func connect(using configuration: SSHConnectionConfiguration) async throws {}

    func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        executeCount += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        onOutput?(Data(command.utf8), false)
        return SSHExecResult(
            stdout: command, stderr: "", exitCode: 0, signal: nil,
            stdoutTruncated: false, stderrTruncated: false
        )
    }

    func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        await backend.openSFTPChannel()
    }

    func disconnect() async { await backend.noteExecDisconnect() }
}

private actor StubSFTPClient: SFTPClientProtocol {
    private let backend: StubBackend

    init(backend: StubBackend) { self.backend = backend }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async { await backend.noteSFTPDisconnect() }
    func homeDirectory() async throws -> String { "/root" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
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
