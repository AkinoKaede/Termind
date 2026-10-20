// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MoshBootstrap
import MoshCore
import TermindApplication
import TermindDomain

actor MoshTerminalEngine: ResumableTerminalEngine {
    private let receive: EventHandler
    private var session: MoshClientSession?
    private var reader: Task<Void, Never>?
    private var accessCheck: HostOperationAccessCheck?
    private var beforeConnect: ConnectionWakeAction?
    private var rollbackPID: Int32?
    private var closed = false

    init(receive: @escaping EventHandler) {
        self.receive = receive
    }

    func prepare(_ context: ResumableTerminalEngineContext) async throws -> ResumableTerminalEnginePreparation {
        accessCheck = context.request.configuration.accessCheck
        beforeConnect = context.request.configuration.beforeConnect
        if let payload = context.checkpoint {
            let restored = try await MoshClientSession.restore(from: Self.decodeCheckpoint(payload))
            guard !closed else {
                await restored.stop()
                throw CancellationError()
            }
            session = restored
        } else {
            let range = context.options.moshUDPPortRange.replacingOccurrences(of: "-", with: ":")
            var command = "mosh-server new -s -c 256"
            if !range.isEmpty { command += " -p \(range)" }
            command += try context.startup.moshArguments
            let variables = context.environment.map {
                "'\($0.variable)=\($0.value.replacingOccurrences(of: "'", with: "'\\''"))'"
            }
            command = (["env"] + variables + ["LANG=C.UTF-8", "LC_ALL=C.UTF-8", command]).joined(separator: " ")
            let result = try await context.bootstrap.execute(
                command, workingDirectory: nil, stdin: nil, timeout: 20, outputLimit: 65_536, onOutput: nil)
            let info: MoshServerConnectInfo
            do {
                info = try MoshServerOutputParser.parse(result.stdout + result.stderr)
            } catch {
                throw TerminalTransportError.bootstrapFailed
            }
            rollbackPID = info.serverPID
            try checkOpen()
            session = MoshClientSession(
                endpoint: .init(host: context.request.configuration.host, port: info.port, keyBase64_22: info.key))
        }
        return .init()
    }

    static func decodeCheckpoint(_ payload: Data) throws -> MoshSnapshot {
        try JSONDecoder().decode(MoshSnapshot.self, from: payload)
    }

    func start(columns: UInt16, rows: UInt16) async throws {
        try checkOpen()
        guard let session else { throw TerminalTransportError.sessionFailed }
        try await session.start()
        try await session.enqueue(.resize(cols: Int32(columns), rows: Int32(rows)))
        // An open UDP socket is not proof that the server is reachable.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            try checkOpen()
            let operations = await session.drainHostOps()
            if !operations.isEmpty {
                await deliver(operations)
                break
            }
            let state = await session.state
            if case .failed = state { throw TerminalTransportError.sessionFailed }
            if state == .stopped {
                rollbackPID = nil
                _ = await receivePoll(state: state, operations: session.drainHostOps())
                return
            }
            guard ContinuousClock.now < deadline else { throw TerminalTransportError.unreachable }
            try await Task.sleep(for: .milliseconds(20))
        }
        rollbackPID = nil
        await receive(.connected)
        try checkOpen()
        reader = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Sample state before draining so the final poll includes trailing output.
                let state = await session.state
                guard await self.receivePoll(state: state, operations: session.drainHostOps()) else { return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func receivePoll(state: MoshSessionState, operations: [MoshHostOp]) async -> Bool {
        guard !closed else { return false }
        await deliver(operations)
        switch state {
        case .stopped:
            await receive(.ended)
            return false
        case .failed:
            await receive(.failed)
            return false
        case .idle, .starting, .running, .suspending, .suspended, .stopping:
            return true
        }
    }

    private func deliver(_ operations: [MoshHostOp]) async {
        guard !closed else { return }
        if !operations.isEmpty { await receive(.activity) }
        for operation in operations {
            if case .hostBytes(let data) = operation { await receive(.output(data)) }
        }
    }

    func write(_ data: Data) async throws {
        try checkOpen()
        try await session?.enqueue(.keystrokes(data))
    }

    func resize(columns: UInt16, rows: UInt16) async throws {
        try checkOpen()
        try await session?.enqueue(.resize(cols: Int32(columns), rows: Int32(rows)))
    }

    func checkpoint(shell: @Sendable () async -> ResumableTerminalShellState) async throws -> Data {
        try checkOpen()
        guard let session else { throw TerminalTransportError.invalidCheckpoint }
        return try JSONEncoder().encode(await session.prepareForApplicationBackground())
    }

    func beforeResume() async throws {
        try accessCheck?()
        await beforeConnect?()
        try checkOpen()
    }

    func resume() async throws {
        try checkOpen()
        try await session?.resumeFromApplicationBackground()
    }

    func retry() async throws {
        try await beforeResume()
        _ = try await session?.prepareForApplicationBackground()
        try await session?.resumeFromApplicationBackground()
    }

    func rollback(using bootstrap: SSHConnection) async {
        guard let pid = rollbackPID, pid > 1 else { return }
        rollbackPID = nil
        // Undo only the server launched by this attempt, even if the caller was cancelled.
        await Task.detached {
            _ = try? await bootstrap.execute(
                "[ \"$(ps -p \(pid) -o comm=)\" = mosh-server ] && kill -TERM \(pid)",
                workingDirectory: nil, stdin: nil, timeout: 3, outputLimit: 1024, onOutput: nil)
        }.value
    }

    func close() async {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        beforeConnect = nil
        await session?.stop()
        session = nil
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
}
