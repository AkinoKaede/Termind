import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

nonisolated struct MCPDownloadRequest: Sendable {
    var hostID: UUID
    var remotePath: String
    var expectedSHA256: String?

    init(_ invocation: AgentToolInvocation) throws {
        let arguments = try Arguments(invocation)
        hostID = try arguments.uuid("host_id")
        let raw = try arguments.string("remote_path")
        remotePath = try AgentToolSupport.normalizeRemotePath(raw)
        guard remotePath != "/", !raw.hasSuffix("/"), raw.utf8.count <= 4_096 else {
            throw MCPDownloadError.invalidRequest
        }
        expectedSHA256 = arguments.optionalString("expected_sha256")?.lowercased()
        if let digest = expectedSHA256 {
            guard digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw MCPDownloadError.invalidRequest }
        }
    }
}

@MainActor
final class MCPDownloadCoordinator {
    typealias Transfer =
        @Sendable (
            MCPDownloadRequest, UUID, UUID, String, TransferCancellationToken,
            @escaping @Sendable (any SFTPDownloadStream) async throws -> Void
        ) async throws -> Void

    private struct Ticket {
        var id: UUID
        var token: String
        var request: MCPDownloadRequest
        var runID: UUID
        var clientName: String
        var invocationID: UUID
        var expiresAt: Date
        var state = "waiting"
        var byteCount: Int64?
        var sentBytes: Int64 = 0
        var actualSHA256: String?
        var errorCode: String?
        var finishedAt: Date?
        var cancellation = TransferCancellationToken()
        var observer: UUID?
        var cancelTransport: (@Sendable () -> Void)?
        var cancelRequested = false
        var timedOut = false
        var reader: MCPDownloadReader?
        var task: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var auditID: UUID?
        var live: Bool { state == "connecting" || state == "transferring" }
    }

    private let hosts: AgentHostResolver
    private let history: ToolAuditModel
    private let budget: MCPTransferBudget
    private let transfer: Transfer
    private let now: @Sendable () -> Date
    private let idleTimeout: Duration
    private var tickets: [UUID: Ticket] = [:]
    private var clients: [UUID: String] = [:]
    private var port: UInt16?
    private var enabled = true

    init(
        hosts: AgentHostResolver, history: ToolAuditModel, budget: MCPTransferBudget = MCPTransferBudget(),
        now: @escaping @Sendable () -> Date = { Date() }, idleTimeout: Duration = .seconds(60),
        transfer: @escaping Transfer
    ) {
        self.hosts = hosts
        self.history = history
        self.budget = budget
        self.now = now
        self.idleTimeout = idleTimeout
        self.transfer = transfer
    }

    func configure(port: UInt16) { self.port = port }
    func register(runID: UUID, clientName: String) { clients[runID] = String(clientName.prefix(160)) }
    func hasDownloadActivity(runID: UUID) -> Bool {
        let date = now()
        return tickets.values.contains {
            $0.runID == runID
                && ($0.live || ($0.auditID != nil && $0.finishedAt.map { date.timeIntervalSince($0) < 1_800 } == true))
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { for id in Array(tickets.keys) { cancel(id) } }
    }

    func create(_ invocation: AgentToolInvocation) throws -> AgentJSONValue {
        let request = try MCPDownloadRequest(invocation)
        guard hosts.listing().hosts.contains(where: { $0.id == request.hostID }) else {
            throw AgentToolError.invalidHost
        }
        sweep()
        guard enabled, let port, let client = clients[invocation.runID], !Task.isCancelled else {
            throw MCPDownloadError.unavailable
        }
        guard tickets.values.filter({ $0.state == "waiting" }).count < 64 else { throw MCPDownloadError.capacity }
        let id = UUID()
        let token = try MCPUploadToken.make()
        let expiry = now().addingTimeInterval(600)
        tickets[id] = Ticket(
            id: id, token: token, request: request, runID: invocation.runID,
            clientName: client, invocationID: invocation.id, expiresAt: expiry
        )
        return .object([
            "download_id": .string(id.uuidString), "download_token": .string(token),
            "download_url": .string("http://127.0.0.1:\(port)/downloads/\(id.uuidString)"),
            "expires_at": .string(expiry.ISO8601Format()), "method": .string("GET"),
            "headers": .object(["Authorization": .string("Bearer \(token)")]),
        ])
    }

    func status(id: UUID, runID: UUID) throws -> AgentJSONValue {
        sweep()
        guard let ticket = tickets[id], ticket.runID == runID, clients[runID] != nil else {
            throw MCPDownloadError.unknown
        }
        return payload(ticket)
    }

    func prepare(
        _ request: HTTPRequest, cancellation: TransferCancellationToken,
        cancelTransport: @escaping @Sendable () -> Void
    ) async -> HTTPResponse {
        sweep()
        guard enabled, port != nil else { return Self.error(503, "download_unavailable") }
        guard LoopbackHTTPServer.allowedOrigin(request.header("origin")) else {
            return Self.error(403, "invalid_origin")
        }
        guard request.method == "GET" else { return Self.error(405, "method_not_allowed") }
        guard let components = URLComponents(string: request.target), components.query == nil,
            components.fragment == nil,
            components.path.hasPrefix("/downloads/"),
            let id = UUID(uuidString: String(components.path.dropFirst("/downloads/".count))), var ticket = tickets[id]
        else { return Self.error(404, "unknown_download") }
        guard let authorization = request.header("authorization"), authorization.hasPrefix("Bearer "),
            LoopbackHTTPServer.constantTimeEqual(String(authorization.dropFirst(7)), ticket.token)
        else { return Self.error(401, "invalid_download_token") }
        guard clients[ticket.runID] != nil else { return Self.error(410, "download_revoked") }
        guard ticket.state != "expired" else { return Self.error(410, "download_expired") }
        guard ticket.state == "waiting" else { return Self.error(409, "download_already_claimed") }
        guard request.header("range") == nil else { return Self.error(400, "range_not_supported") }
        guard request.body.isEmpty, request.header("transfer-encoding") == nil else {
            return Self.error(400, "request_body_not_allowed")
        }
        if let length = request.header("content-length") {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), Int64(length) == 0 else {
                return Self.error(400, "request_body_not_allowed")
            }
        }
        guard !cancellation.isCancelled else { return Self.error(410, "download_cancelled") }
        guard budget.claim(id) else { return Self.error(429, "transfer_capacity") }
        ticket.state = "connecting"
        ticket.cancellation = cancellation
        ticket.cancelTransport = cancelTransport
        ticket.auditID = history.beginDownload(
            runID: ticket.runID, clientName: ticket.clientName, hostID: ticket.request.hostID,
            remotePath: ticket.request.remotePath
        )
        ticket.observer = cancellation.observeCancellation { [weak self] in Task { @MainActor in self?.cancel(id) } }
        tickets[id] = ticket
        let exchange = MCPDownloadExchange()
        let task = Task { [self] in
            do {
                try await transfer(ticket.request, ticket.runID, ticket.invocationID, ticket.clientName, cancellation) {
                    [self] stream in
                    try await serve(id: id, stream: stream, exchange: exchange)
                }
                await finish(id: id, state: "succeeded")
            } catch {
                let (status, code) = failure(error, id: id)
                await finish(id: id, state: code == "download_cancelled" ? "cancelled" : "failed", error: code)
                await exchange.publish(Self.error(status, code))
            }
        }
        tickets[id]?.task = task
        return await withTaskCancellationHandler {
            await exchange.response()
        } onCancel: {
            cancellation.cancel()
            cancelTransport()
            task.cancel()
        }
    }

    private func serve(id: UUID, stream: any SFTPDownloadStream, exchange: MCPDownloadExchange) async throws {
        guard let ticket = tickets[id], ticket.live, !ticket.cancellation.isCancelled else {
            throw AgentToolError.cancelled
        }
        guard stream.byteCount >= 0, stream.byteCount <= Int64(MCPUploadRequest.maximumBytes) else {
            throw SFTPDownloadFailure.tooLarge
        }
        let reader = MCPDownloadReader(
            stream: stream, expectedSHA256: ticket.request.expectedSHA256, cancellation: ticket.cancellation)
        tickets[id]?.byteCount = stream.byteCount
        tickets[id]?.reader = reader
        let idleTimeout = idleTimeout
        tickets[id]?.watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: min(.seconds(1), idleTimeout)) } catch { return }
                if await reader.idleDuration >= idleTimeout {
                    self?.tickets[id]?.timedOut = true
                    self?.cancel(id)
                    return
                }
            }
        }
        let body = HTTPFileBody(
            byteCount: stream.byteCount,
            read: { try await reader.readChunk() },
            sent: { [weak self] count in
                let bytes = await reader.didSend(count)
                await self?.progress(id: id, bytes: bytes)
            },
            finished: { [weak self] result in
                await exchange.complete(result)
                await self?.waitForTask(id)
            },
            cancel: {
                ticket.cancellation.cancel()
                ticket.cancelTransport?()
            }
        )
        await exchange.publish(
            HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/octet-stream", "Content-Length": String(stream.byteCount),
                    "Cache-Control": "no-store", "Connection": "close",
                ], file: body
            ))
        try await withTaskCancellationHandler {
            try await exchange.waitForCompletion()
        } onCancel: {
            Task { await exchange.complete(.failure(AgentToolError.cancelled)) }
        }
        try await reader.validateCompletion()
    }

    private func progress(id: UUID, bytes: Int64) {
        guard tickets[id]?.live == true else { return }
        tickets[id]?.state = "transferring"
        tickets[id]?.sentBytes = bytes
        if let audit = tickets[id]?.auditID { history.updateDownload(id: audit, bytes: bytes) }
    }

    private func finish(id: UUID, state: String, error: String? = nil) async {
        let actual = await tickets[id]?.reader?.actualSHA256
        guard var ticket = tickets[id] else { return }
        ticket.state = state
        ticket.actualSHA256 = actual
        ticket.errorCode = error
        ticket.finishedAt = now()
        ticket.watchdog?.cancel()
        ticket.watchdog = nil
        if let observer = ticket.observer { ticket.cancellation.removeObserver(observer) }
        ticket.observer = nil
        ticket.reader = nil
        ticket.task = nil
        ticket.cancelTransport = nil
        tickets[id] = ticket
        budget.release(id)
        if let audit = ticket.auditID {
            history.updateDownload(id: audit, bytes: ticket.sentBytes, succeeded: state == "succeeded")
        }
        sweep()
    }

    private func waitForTask(_ id: UUID) async { await tickets[id]?.task?.value }
    private func cancel(_ id: UUID) {
        guard let ticket = tickets[id], ticket.state == "waiting" || ticket.live else { return }
        tickets[id]?.cancelRequested = true
        ticket.cancellation.cancel()
        ticket.cancelTransport?()
        ticket.task?.cancel()
        if ticket.task == nil {
            tickets[id]?.state = "cancelled"
            tickets[id]?.errorCode = "download_cancelled"
            tickets[id]?.finishedAt = now()
            sweep()
        }
    }
    func revokeHost(_ hostID: UUID) {
        for id in tickets.values.filter({ $0.request.hostID == hostID }).map(\.id) { cancel(id) }
    }
    func cancelHost(_ hostID: UUID) async {
        await cancelAndWait(ids: tickets.values.filter { $0.request.hostID == hostID }.map(\.id))
    }
    func endSession(runID: UUID) async {
        clients[runID] = nil
        let ids = tickets.values.filter { $0.runID == runID }.map(\.id)
        await cancelAndWait(ids: ids)
        for id in ids { tickets[id] = nil }
    }
    func revokeSession(runID: UUID) {
        clients[runID] = nil
        for id in tickets.values.filter({ $0.runID == runID }).map(\.id) { cancel(id) }
    }
    func suspend() {
        port = nil
        clients.removeAll()
        for id in Array(tickets.keys) { cancel(id) }
    }
    func stop() async {
        port = nil
        clients.removeAll()
        await cancelAndWait(ids: Array(tickets.keys))
        tickets.removeAll()
    }
    private func cancelAndWait(ids: [UUID]) async {
        let tasks = ids.compactMap { tickets[$0]?.task }
        for id in ids { cancel(id) }
        for task in tasks { await task.value }
    }
    private func sweep() {
        let date = now()
        for id in Array(tickets.keys) {
            guard let ticket = tickets[id] else { continue }
            if ticket.state == "waiting", ticket.expiresAt <= date {
                tickets[id]?.state = "expired"
                tickets[id]?.finishedAt = date
                tickets[id]?.errorCode = "download_expired"
            } else if let finished = ticket.finishedAt, date.timeIntervalSince(finished) >= 1_800 {
                tickets[id] = nil
            }
        }
        let terminal = tickets.values.filter { $0.finishedAt != nil }.sorted { $0.finishedAt! < $1.finishedAt! }
        for ticket in terminal.prefix(max(0, terminal.count - 256)) { tickets[ticket.id] = nil }
    }
    private func payload(_ ticket: Ticket) -> AgentJSONValue {
        .object([
            "download_id": .string(ticket.id.uuidString), "status": .string(ticket.state),
            "remote_path": .string(ticket.request.remotePath),
            "byte_count": ticket.byteCount.map { .number(Double($0)) } ?? .null,
            "bytes": .number(Double(ticket.sentBytes)),
            "sha256": ticket.actualSHA256.map(AgentJSONValue.string) ?? .null,
            "error": ticket.errorCode.map(AgentJSONValue.string) ?? .null,
        ])
    }
    private func failure(_ error: any Error, id: UUID) -> (Int, String) {
        if tickets[id]?.timedOut == true { return (504, "download_timeout") }
        if let failure = error as? SFTPDownloadFailure {
            switch failure {
            case .missingFile: return (404, "missing_file")
            case .unsupportedType: return (422, "unsupported_file_type")
            case .tooLarge: return (413, "file_too_large")
            case .sourceChanged: return (422, "source_changed")
            case .invalidChunk: return (502, "invalid_source_chunk")
            case .closeFailed: return (502, "stream_close_failed")
            case .digestMismatch: return (422, "digest_mismatch")
            case .timedOut: return (504, "download_timeout")
            }
        }
        if tickets[id]?.cancelRequested == true || tickets[id]?.cancellation.isCancelled == true
            || error is CancellationError
        {
            return (410, "download_cancelled")
        }
        if case AgentToolError.cancelled = error { return (401, "authentication_cancelled") }
        if let ssh = error as? TermindSSHError {
            switch ssh {
            case .authenticationFailed, .missingCredential, .keyPassphraseRequired, .missingUsername,
                .untrustedHost, .mismatchedHostKey, .hostKeyChanged:
                return (401, "ssh_authentication_failed")
            case .routeHost(_, let auth, _, let hostKey, _) where auth || hostKey:
                return (401, "ssh_authentication_failed")
            default: break
            }
        }
        return (502, "sftp_download_failed")
    }
    nonisolated static func error(_ status: Int, _ code: String) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: Data(AgentJSONValue.object(["error": .string(code)]).encodedString.utf8))
    }
}

nonisolated enum MCPDownloadError: LocalizedError {
    case invalidRequest, unavailable, capacity, unknown
    var errorDescription: String? {
        switch self {
        case .invalidRequest: String(localized: "The download request is invalid.")
        case .unavailable: String(localized: "HTTP downloads are not available.")
        case .capacity: String(localized: "Too many downloads are waiting.")
        case .unknown: String(localized: "The download is unknown or expired.")
        }
    }
}
