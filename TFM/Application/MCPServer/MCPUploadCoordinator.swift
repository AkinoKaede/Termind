import AgentKit
import Foundation
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure

nonisolated struct MCPUploadRequest: Sendable {
    var hostID: UUID
    var remotePath: String
    var byteCount: Int64
    var sha256: String
    var overwrite: Bool
    let resume = SFTPResumeState()

    init(_ invocation: AgentToolInvocation) throws {
        let arguments = try Arguments(invocation)
        hostID = try arguments.uuid("host_id")
        let raw = try arguments.string("remote_path")
        remotePath = try AgentToolSupport.normalizeRemotePath(raw)
        guard remotePath != "/", !raw.hasSuffix("/"), raw.utf8.count <= 4_096,
            let count = arguments.optionalInt("byte_count"), count >= 0, count <= MCPTransferBudget.maximumBytes
        else { throw MCPUploadError.invalidRequest }
        byteCount = Int64(count)
        sha256 = try arguments.string("sha256").lowercased()
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw MCPUploadError.invalidRequest }
        overwrite = arguments.optionalBool("overwrite") ?? false
    }
}

@MainActor
final class MCPUploadCoordinator {
    typealias Transfer =
        @Sendable (
            MCPUploadRequest, UUID, UUID, String, @escaping SFTPStreamUploadOperation.ReadChunk,
            TransferCancellationToken, @escaping @Sendable (SFTPProgress) -> Void
        ) async throws -> String

    typealias Cleanup = @Sendable (MCPUploadRequest, UUID, UUID, String) async throws -> Void

    private struct Ticket: MCPTransferTicketEntry {
        var info: MCPTransferTicket
        var request: MCPUploadRequest
        var completedBytes: Int64 = 0
        var actualSHA256: String?
        var temporaryPath: String?
        var interrupted = false
        var attemptID = UUID()
        var attemptOffset: Int64 = 0
        var task: Task<HTTPResponse, Never>?
        var live: Bool { info.state == "connecting" || info.state == "transferring" || info.state == "cleaning" }
    }

    private let hosts: AgentHostResolver
    private let history: ToolAuditModel
    private let transfer: Transfer
    private let cleanup: Cleanup
    private let now: @Sendable () -> Date
    private let budget: MCPTransferBudget
    private var tickets: [UUID: Ticket] = [:]
    private var clients: [UUID: String] = [:]
    private var port: UInt16?
    private var enabled = true

    init(
        hosts: AgentHostResolver, history: ToolAuditModel,
        now: @escaping @Sendable () -> Date = { Date() }, budget: MCPTransferBudget = MCPTransferBudget(),
        cleanup: @escaping Cleanup = { _, _, _, _ in },
        transfer: @escaping Transfer
    ) {
        self.hosts = hosts
        self.history = history
        self.now = now
        self.transfer = transfer
        self.cleanup = cleanup
        self.budget = budget
    }

    func configure(port: UInt16) { self.port = port }
    func register(runID: UUID, clientName: String) { clients[runID] = String(clientName.prefix(160)) }
    func hasActiveUpload(runID: UUID) -> Bool { tickets.values.contains { $0.info.runID == runID && $0.live } }

    // A long upload is activity even if its final HTTP response never arrives.
    // Keep the owning session queryable for the retained completion window.
    func hasUploadActivity(runID: UUID) -> Bool {
        tickets.hasTransferActivity(runID: runID, at: now())
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { for id in Array(tickets.keys) { cancel(id) } }
    }

    func create(_ invocation: AgentToolInvocation) async throws -> AgentJSONValue {
        let request = try MCPUploadRequest(invocation)
        guard hosts.listing().hosts.contains(where: { $0.id == request.hostID }) else {
            throw AgentToolError.invalidHost
        }
        sweep()
        guard enabled, let port, let client = clients[invocation.runID], !Task.isCancelled else {
            throw MCPUploadError.unavailable
        }
        guard tickets.values.filter({ $0.info.finishedAt == nil }).count < 64 else { throw MCPUploadError.capacity }
        let info = try MCPTransferTicket(invocation, clientName: client, now: now())
        tickets[info.id] = Ticket(info: info, request: request)
        return .object([
            "upload_id": .string(info.id.uuidString),
            "upload_url": .string("http://127.0.0.1:\(port)/uploads/\(info.id.uuidString)"),
            "upload_token": .string(info.token), "expires_at": .string(info.expiresAt.ISO8601Format()),
            "method": .string("PUT"),
            "headers": .object([
                "Authorization": .string("Bearer \(info.token)"),
                "Content-Type": .string("application/octet-stream"),
                "Content-Length": .string(String(request.byteCount)),
                "Upload-Offset": .string("0"),
            ]),
        ])
    }

    func status(id: UUID, runID: UUID) throws -> AgentJSONValue {
        sweep()
        guard let ticket = tickets[id], ticket.info.runID == runID, clients[runID] != nil else {
            throw MCPUploadError.unknown
        }
        return payload(ticket)
    }

    func prepare(_ request: HTTPRequest) -> HTTPStreamingDecision {
        sweep()
        guard enabled, port != nil else { return .reject(Self.error(503, "upload_unavailable")) }
        guard request.method == "PUT" else { return .reject(Self.error(405, "method_not_allowed")) }
        guard let components = URLComponents(string: request.target), components.query == nil,
            components.fragment == nil, components.path.hasPrefix("/uploads/"),
            let id = UUID(uuidString: String(components.path.dropFirst("/uploads/".count))),
            var ticket = tickets[id]
        else { return .reject(Self.error(404, "unknown_upload")) }
        guard LoopbackHTTPServer.allowedOrigin(request.header("origin")) else {
            return .reject(Self.error(403, "invalid_origin"))
        }
        guard let authorization = request.header("authorization"), authorization.hasPrefix("Bearer "),
            LoopbackHTTPServer.constantTimeEqual(String(authorization.dropFirst(7)), ticket.info.token)
        else { return .reject(Self.error(401, "invalid_upload_token")) }
        guard clients[ticket.info.runID] != nil else { return .reject(Self.error(410, "upload_revoked")) }
        guard ticket.info.expiresAt > now(), ticket.info.state != "expired" else {
            return .reject(Self.error(410, "upload_expired"))
        }
        guard ticket.info.state == "waiting" || ticket.info.state == "paused" else {
            return .reject(Self.error(409, "upload_already_claimed"))
        }
        guard request.header("transfer-encoding") == nil else {
            return .reject(Self.error(411, "chunked_upload_not_supported"))
        }
        guard request.header("content-type")?.lowercased() == "application/octet-stream" else {
            return .reject(Self.error(415, "invalid_content_type"))
        }
        guard let rawLength = request.header("content-length"), !rawLength.isEmpty,
            rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int64(rawLength)
        else { return .reject(Self.error(411, "content_length_required")) }
        let rawOffset = request.header("upload-offset") ?? "0"
        guard !rawOffset.isEmpty, rawOffset.utf8.allSatisfy({ (48...57).contains($0) }),
            let offset = Int64(rawOffset), offset == ticket.request.resume.snapshot.offset
        else { return .reject(Self.error(409, "upload_offset_mismatch")) }
        guard length == ticket.request.byteCount - offset else {
            return .reject(Self.error(400, "length_mismatch"))
        }
        if let expect = request.header("expect"), expect.lowercased() != "100-continue" {
            return .reject(Self.error(417, "unsupported_expectation"))
        }
        guard budget.claim(id) else { return .reject(Self.error(429, "upload_capacity")) }
        ticket.info.state = "connecting"
        ticket.info.cancellation = TransferCancellationToken()
        ticket.interrupted = false
        ticket.info.errorCode = nil
        ticket.attemptID = UUID()
        ticket.attemptOffset = offset
        let attempt = ticket.attemptID
        ticket.info.auditID = history.beginUpload(
            runID: ticket.info.runID, clientName: ticket.info.clientName, hostID: ticket.request.hostID,
            remotePath: ticket.request.remotePath, overwrite: ticket.request.overwrite
        )
        let cancellation = ticket.info.cancellation
        // The transfer cancels its own token on any failure, so track HTTP disconnect provenance separately.
        let disconnection = TransferCancellationToken()
        tickets[id] = ticket
        return .accept(
            { [weak self] read in
                guard let self else { return Self.error(503, "upload_unavailable") }
                return await self.receive(id: id, attempt: attempt, disconnection: disconnection, read: read)
            },
            disconnected: { [weak self] in
                disconnection.cancel()
                cancellation.cancel()
                Task { @MainActor in self?.interrupt(id, attempt: attempt) }
            }
        )
    }

    func cancelHost(_ hostID: UUID) async {
        await cancelAndWait(ids: tickets.values.filter { $0.request.hostID == hostID }.map(\.info.id))
    }

    func revokeHost(_ hostID: UUID) {
        for id in tickets.values.filter({ $0.request.hostID == hostID }).map(\.info.id) { cancel(id) }
    }

    func endSession(runID: UUID) async {
        clients[runID] = nil
        let ids = tickets.values.filter { $0.info.runID == runID }.map(\.info.id)
        await cancelAndWait(ids: ids)
        for id in ids { tickets[id] = nil }
    }

    func revokeSession(runID: UUID) {
        clients[runID] = nil
        for id in tickets.values.filter({ $0.info.runID == runID }).map(\.info.id) { cancel(id) }
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

    private func receive(
        id: UUID, attempt: UUID, disconnection: TransferCancellationToken,
        read: @escaping SFTPStreamUploadOperation.ReadChunk
    ) async -> HTTPResponse {
        guard let ticket = tickets[id], ticket.attemptID == attempt, ticket.info.state == "connecting",
            !ticket.info.cancellation.isCancelled
        else {
            return Self.error(410, "upload_cancelled")
        }
        let task = Task { [self] in
            do {
                let actual = try await transfer(
                    ticket.request, ticket.info.runID, ticket.info.invocationID, ticket.info.clientName, read,
                    ticket.info.cancellation,
                    { [weak self] progress in
                        Task { @MainActor in self?.progress(id: id, attempt: attempt, progress: progress) }
                    }
                )
                // Returning from the transfer proves remote commit. Cancellation
                // arriving after that point must not erase the success.
                finish(id: id, state: "succeeded", actual: actual)
                guard let completed = tickets[id] else { return Self.error(410, "unknown_upload") }
                return Self.json(200, payload(completed))
            } catch {
                let cleanup = error as? SFTPTemporaryFileCleanupError
                let cancelRequested = tickets[id]?.info.cancelRequested == true
                let interrupted =
                    tickets[id]?.interrupted == true
                    || disconnection.isCancelled
                if interrupted { tickets[id]?.interrupted = true }
                let (status, code) = Self.failure(
                    cleanup?.cause ?? error,
                    cancelled: cancelRequested || disconnection.isCancelled)
                tickets[id]?.temporaryPath = cleanup?.path
                if let failure = (cleanup?.cause ?? error) as? SFTPStreamUploadOperation.Failure,
                    case .digestMismatch(let actual) = failure
                {
                    tickets[id]?.actualSHA256 = actual
                }
                let canResume =
                    !cancelRequested
                    && !Self.integrityFailure(cleanup?.cause ?? error)
                    && (interrupted || Self.recoverable(cleanup?.cause ?? error))
                    && ticket.info.expiresAt > now()
                if !canResume { await cleanupTicket(id) }
                finish(
                    id: id, state: canResume ? "paused" : (code == "upload_cancelled" ? "cancelled" : "failed"),
                    error: code)
                if let completed = tickets[id] { return Self.json(status, payload(completed)) }
                return Self.error(status, code)
            }
        }
        tickets[id]?.task = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func progress(id: UUID, attempt: UUID, progress: SFTPProgress) {
        guard var ticket = tickets[id], ticket.attemptID == attempt, ticket.live else { return }
        ticket.info.state = "transferring"
        ticket.completedBytes = max(ticket.completedBytes, progress.completedBytes)
        tickets[id] = ticket
        if let audit = ticket.info.auditID {
            history.updateUpload(id: audit, bytes: max(0, ticket.completedBytes - ticket.attemptOffset))
        }
    }

    private func finish(id: UUID, state: String, actual: String? = nil, error: String? = nil) {
        guard var ticket = tickets[id] else { return }
        ticket.info.state = state
        ticket.info.finishedAt = state == "paused" ? nil : now()
        if let actual { ticket.actualSHA256 = actual }
        ticket.info.errorCode = error
        ticket.completedBytes = max(ticket.completedBytes, ticket.request.resume.snapshot.offset)
        if state == "succeeded" { ticket.completedBytes = ticket.request.byteCount }
        ticket.task = nil
        budget.release(id)
        tickets[id] = ticket
        if let audit = ticket.info.auditID {
            history.updateUpload(
                id: audit, bytes: max(0, ticket.completedBytes - ticket.attemptOffset), succeeded: state == "succeeded")
        }
        sweep()
    }

    private func interrupt(_ id: UUID, attempt: UUID) {
        guard let ticket = tickets[id], ticket.attemptID == attempt, ticket.live, !ticket.info.cancelRequested else {
            return
        }
        tickets[id]?.interrupted = true
        ticket.info.cancellation.cancel()
        ticket.task?.cancel()
        if ticket.task == nil { finish(id: id, state: "paused", error: "upload_interrupted") }
    }

    private func cleanupTicket(_ id: UUID) async {
        guard let ticket = tickets[id], !ticket.request.resume.snapshot.committed,
            ticket.request.resume.snapshot.temporaryPath != nil
        else { return }
        do {
            // Teardown must not inherit the failed HTTP attempt's cancellation.
            let cleanup = cleanup
            try await Task {
                try await cleanup(ticket.request, ticket.info.runID, ticket.info.invocationID, ticket.info.clientName)
            }
            .value
        } catch {
            tickets[id]?.temporaryPath = ticket.request.resume.snapshot.temporaryPath
        }
    }

    private func cancel(_ id: UUID, state: String = "cancelled") {
        guard let ticket = tickets[id], ticket.info.state == "waiting" || ticket.info.state == "paused" || ticket.live,
            !ticket.info.cancelRequested
        else { return }
        tickets[id]?.info.cancelRequested = true
        ticket.info.cancellation.cancel()
        ticket.task?.cancel()
        if ticket.task == nil {
            if ticket.request.resume.snapshot.temporaryPath == nil {
                finish(id: id, state: state, error: "upload_" + state)
            } else {
                tickets[id]?.info.state = "cleaning"
                tickets[id]?.task = Task { [self] in
                    await cleanupTicket(id)
                    finish(id: id, state: state, error: "upload_" + state)
                    return Self.error(410, "upload_" + state)
                }
            }
        }
    }

    private func cancelAndWait(ids: [UUID]) async {
        for id in ids { cancel(id) }
        let tasks = ids.compactMap { tickets[$0]?.task }
        for task in tasks { _ = await task.value }
    }

    private nonisolated static func integrityFailure(_ error: any Error) -> Bool {
        if error is SFTPResumeFailure { return true }
        if let failure = error as? SFTPStreamUploadOperation.Failure {
            if case .timedOut = failure { return false }
            return true
        }
        return false
    }

    private nonisolated static func recoverable(_ error: any Error) -> Bool {
        switch error {
        case SFTPError.connectionLost, SFTPError.notConnected, SFTPStreamUploadOperation.Failure.timedOut,
            LoopbackHTTPServerError.endOfStream:
            true
        default: false
        }
    }

    private func sweep() {
        let date = now()
        for id in tickets.expiredTransferIDs(at: date) {
            cancel(id, state: "expired")
        }
        tickets.pruneTransferCompletions(at: date)
    }

    private func payload(_ ticket: Ticket) -> AgentJSONValue {
        .object([
            "upload_id": .string(ticket.info.id.uuidString), "status": .string(ticket.info.state),
            "remote_path": .string(ticket.request.remotePath), "byte_count": .number(Double(ticket.request.byteCount)),
            "bytes": .number(Double(ticket.completedBytes)),
            "upload_offset": .number(Double(ticket.request.resume.snapshot.offset)),
            "resumable": .bool(ticket.info.state == "paused" && ticket.info.expiresAt > now()),
            "sha256": ticket.actualSHA256.map(AgentJSONValue.string) ?? .null,
            "error": ticket.info.errorCode.map(AgentJSONValue.string) ?? .null,
            "temporary_file_may_remain": ticket.temporaryPath.map(AgentJSONValue.string) ?? .null,
        ])
    }

    private nonisolated static func failure(_ error: any Error, cancelled: Bool) -> (Int, String) {
        if let failure = error as? SFTPStreamUploadOperation.Failure {
            switch failure {
            case .digestMismatch: return (422, "digest_mismatch")
            case .invalidLength, .invalidChunk: return (400, "invalid_upload_body")
            case .targetConflict: return (409, "target_conflict")
            case .missingParent: return (409, "missing_parent_directory")
            case .timedOut: return (504, "upload_timeout")
            }
        }
        if error is SFTPResumeFailure { return (409, "upload_source_or_partial_changed") }
        if cancelled || error is CancellationError { return (410, "upload_cancelled") }
        return (502, "sftp_upload_failed")
    }

    nonisolated static func error(_ status: Int, _ code: String) -> HTTPResponse {
        json(status, .object(["error": .string(code)]))
    }

    private nonisolated static func json(_ status: Int, _ value: AgentJSONValue) -> HTTPResponse {
        HTTPResponse(
            status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: Data(value.encodedString.utf8)
        )
    }
}

nonisolated enum MCPUploadError: LocalizedError {
    case invalidRequest, unavailable, capacity, unknown
    var errorDescription: String? {
        switch self {
        case .invalidRequest: String(localized: AppStrings.MCP.theUploadRequestIsInvalid)
        case .unavailable: String(localized: AppStrings.MCP.httpUploadsAreNotAvailable)
        case .capacity: String(localized: AppStrings.MCP.tooManyUploadsAreWaiting)
        case .unknown: String(localized: AppStrings.MCP.theUploadIsUnknownOrExpired)
        }
    }
}
