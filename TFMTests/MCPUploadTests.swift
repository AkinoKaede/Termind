import AgentKit
import CryptoKit
import Darwin
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct MCPUploadTests {
    @Test
    func longUploadCompletionKeepsTheSessionQueryableForTheRetentionWindow() async throws {
        let clock = UploadClock()
        let fixture = UploadFixture(now: { clock.date })
        let ticket = try await fixture.ticket(Data())
        guard case .accept(let consume, _) = fixture.uploads.prepare(fixture.request(ticket, count: 0)) else {
            Issue.record("Valid ticket was rejected")
            return
        }
        clock.advance(3_600)
        #expect(fixture.uploads.hasUploadActivity(runID: fixture.runID))
        #expect(await consume { nil }.status == 200)
        #expect(!fixture.uploads.hasActiveUpload(runID: fixture.runID))
        #expect(fixture.uploads.hasUploadActivity(runID: fixture.runID))
        clock.advance(1_801)
        #expect(!fixture.uploads.hasUploadActivity(runID: fixture.runID))
    }

    @Test
    func digestFailureStillReportsCleanupFailureFromTheOtherTask() async throws {
        let fixture = UploadFixture()
        await fixture.client.failCleanupAfterRead()
        let ticket = try await fixture.ticket(Data([1]))
        #expect(try await fixture.consume(ticket, bytes: Data([2])).status == 422)
        let status = try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID)
        #expect(status.objectValue?["sha256"] == .string(uploadDigest(Data([2]))))
        #expect(status.objectValue?["temporary_file_may_remain"] == .string("/target/file.bin.part"))
        #expect(await fixture.client.committed == nil)
    }

    @Test
    func timeoutCancelsBlockedSourceAndNeverPublishes() async throws {
        let fixture = UploadFixture(idleTimeout: .milliseconds(20))
        let ticket = try await fixture.ticket(Data([1]))
        guard case .accept(let consume, _) = fixture.uploads.prepare(fixture.request(ticket, count: 1)) else {
            Issue.record("Valid ticket was rejected")
            return
        }
        let response = await consume {
            try await Task.sleep(for: .seconds(120))
            return Data([1])
        }
        #expect(response.status == 504)
        #expect(await fixture.client.committed == nil)
        #expect(!fixture.uploads.hasActiveUpload(runID: fixture.runID))
    }

    @Test
    func slowDestinationAppliesBackpressureInsteadOfDrainingTheSource() async throws {
        let fixture = UploadFixture()
        await fixture.client.delayReading()
        let bytes = Data(count: 5 * 1_024 * 1_024)
        let ticket = try await fixture.ticket(bytes)
        let source = UploadByteSource(bytes)
        guard case .accept(let consume, _) = fixture.uploads.prepare(fixture.request(ticket, count: bytes.count)) else {
            Issue.record("Valid ticket was rejected")
            return
        }
        let task = Task { await consume { await source.next() } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await source.readCount < bytes.count / SFTPStreamUploadOperation.chunkBytes)
        fixture.uploads.setEnabled(false)
        #expect(await task.value.status == 410)
        #expect(await fixture.client.committed == nil)
    }

    @Test
    func cleanupFailureReportsPossibleRemoteResidueWithoutFileBodies() async throws {
        let fixture = UploadFixture()
        await fixture.client.failCleanup()
        let ticket = try await fixture.ticket(Data([1]))
        let response = try await fixture.consume(ticket, bytes: Data([1]))
        #expect(response.status == 502)
        let status = try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID)
        #expect(status.objectValue?["temporary_file_may_remain"] == .string("/target/file.bin.part"))
        #expect(status.objectValue?["error"] == .string("sftp_upload_failed"))
        #expect(await fixture.client.committed == nil)
    }

    @Test
    func revokedTicketsAreNotRevivedWhenToolIsReenabled() async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data())
        fixture.uploads.setEnabled(false)
        fixture.uploads.setEnabled(true)
        guard case .reject(let response) = fixture.uploads.prepare(fixture.request(ticket, count: 0)) else {
            Issue.record("A revoked ticket was revived")
            return
        }
        #expect(response.status == 409)
        #expect(
            try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID).objectValue?["status"]
                == .string("cancelled"))
    }

    @Test
    func completedStateIsBoundedAndOldestRecordsAreEvicted() async throws {
        let fixture = UploadFixture()
        var first: UUID?
        for _ in 0..<257 {
            let ticket = try await fixture.ticket(Data())
            if first == nil { first = fixture.id(ticket) }
            guard case .accept = fixture.uploads.prepare(fixture.request(ticket, count: 0)) else {
                Issue.record("Valid ticket was rejected")
                return
            }
            await fixture.uploads.cancelHost(fixture.host.id)
        }
        #expect(throws: MCPUploadError.self) { try fixture.uploads.status(id: first!, runID: fixture.runID) }
        await fixture.uploads.stop()
    }

    @Test(arguments: [Data(), Data([0, 255, 128, 10]), Data(count: 4 * 1_024 * 1_024 + 1)])
    func streamsBinaryBytesAndOnlyCommitsAfterVerification(_ bytes: Data) async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(bytes)
        let result = try await fixture.consume(ticket, bytes: bytes)
        #expect(result.status == 200)
        #expect(await fixture.client.committed == bytes)
        let status = try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID)
        #expect(status.objectValue?["status"] == .string("succeeded"))
        #expect(status.objectValue?["sha256"] == .string(uploadDigest(bytes)))
        #expect(status.objectValue?["bytes"]?.integerValue == bytes.count)
        let history = fixture.history.entries(tool: "http_sftp_upload")
        #expect(history.count == 1)
        #expect(history.first?.status == .ok)
        #expect(history.first?.bytesWritten == bytes.count)
        #expect(!history.contains { $0.summary.contains(ticket["upload_token"]!.stringValue!) })
        if case .reject(let duplicate) = fixture.uploads.prepare(fixture.request(ticket, count: bytes.count)) {
            #expect(duplicate.status == 409)
        } else {
            Issue.record("A committed upload must never be replayed")
        }
    }

    @Test
    func digestMismatchDoesNotPublishRemoteFile() async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data([1, 2]))
        let result = try await fixture.consume(ticket, bytes: Data([3, 4]))
        #expect(result.status == 422)
        #expect(await fixture.client.committed == nil)
        #expect(
            try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID).objectValue?["error"]
                == .string("digest_mismatch"))
        #expect(fixture.history.entries(tool: "http_sftp_upload").first?.status == .error)
    }

    @Test
    func truncatedSourceDoesNotPublishRemoteFile() async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data([1, 2]))
        let request = fixture.request(ticket, count: 2)
        guard case .accept(let consume, _) = fixture.uploads.prepare(request) else {
            Issue.record("Valid headers were rejected")
            return
        }
        let source = UploadByteSource(Data([1]))
        let result = await consume { await source.next() }
        #expect(result.status == 400)
        #expect(await fixture.client.committed == nil)
    }

    @Test(arguments: ["authorization", "content-type", "content-length", "transfer-encoding", "expect", "origin"])
    func invalidHeadersAreRejectedWithoutConsumingTicket(_ header: String) async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data([1]))
        var request = fixture.request(ticket, count: 1)
        request.headers[header] =
            [
                "authorization": "Bearer wrong", "content-type": "multipart/form-data",
                "content-length": "2", "transfer-encoding": "chunked", "expect": "unsupported",
                "origin": "https://example.com",
            ][header]
        guard case .reject(let result) = fixture.uploads.prepare(request) else {
            Issue.record("Invalid headers were accepted")
            return
        }
        #expect(result.status >= 400)
        #expect(
            try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID).objectValue?["status"]
                == .string("waiting"))
        #expect(fixture.history.entries().isEmpty)
    }

    @Test(arguments: [nil, "-1", "1, 1", "18446744073709551616", "+1"] as [String?])
    func invalidLengthsAreRejected(_ length: String?) async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data([1]))
        var request = fixture.request(ticket, count: 1)
        request.headers["content-length"] = length
        guard case .reject(let result) = fixture.uploads.prepare(request) else {
            Issue.record("Invalid length was accepted")
            return
        }
        #expect(result.status == 411)
    }

    @Test
    func ticketsAreSessionScopedAndExpire() async throws {
        let clock = UploadClock()
        let fixture = UploadFixture(now: { clock.date })
        let ticket = try await fixture.ticket(Data())
        #expect(throws: MCPUploadError.self) {
            try fixture.uploads.status(id: fixture.id(ticket), runID: UUID())
        }
        clock.advance(601)
        guard case .reject(let result) = fixture.uploads.prepare(fixture.request(ticket, count: 0)) else {
            Issue.record("Expired ticket was accepted")
            return
        }
        #expect(result.status == 410)
        #expect(
            try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID).objectValue?["status"]
                == .string("expired"))
        clock.advance(1_801)
        #expect(throws: MCPUploadError.self) {
            try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID)
        }
    }

    @Test
    func claimingIsAtomicAndCapacityDoesNotConsumeAnotherTicket() async throws {
        let fixture = UploadFixture()
        for _ in 0..<4 {
            let ticket = try await fixture.ticket(Data())
            guard case .accept = fixture.uploads.prepare(fixture.request(ticket, count: 0)) else {
                Issue.record("Capacity was exhausted early")
                return
            }
            #expect(fixture.uploads.hasActiveUpload(runID: fixture.runID))
            guard case .reject(let duplicate) = fixture.uploads.prepare(fixture.request(ticket, count: 0)) else {
                Issue.record("Concurrent duplicate was accepted")
                return
            }
            #expect(duplicate.status == 409)
        }
        let fifth = try await fixture.ticket(Data())
        guard case .reject(let rejected) = fixture.uploads.prepare(fixture.request(fifth, count: 0)) else {
            Issue.record("An extra active upload was accepted")
            return
        }
        #expect(rejected.status == 429)
        #expect(
            try fixture.uploads.status(id: fixture.id(fifth), runID: fixture.runID).objectValue?["status"]
                == .string("waiting"))
        await fixture.uploads.stop()
        #expect(!fixture.uploads.hasActiveUpload(runID: fixture.runID))
    }

    @Test
    func pendingCapacityIsBounded() async throws {
        let fixture = UploadFixture()
        for _ in 0..<64 { _ = try await fixture.ticket(Data()) }
        await #expect(throws: MCPUploadError.self) { try await fixture.ticket(Data()) }
    }

    @Test(arguments: ["disabled", "session", "host", "stop", "disconnect"])
    func cancellationUnblocksBothSidesAndDoesNotCommit(_ reason: String) async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data([1]))
        guard case .accept(let consume, let disconnected) = fixture.uploads.prepare(fixture.request(ticket, count: 1))
        else {
            Issue.record("Valid ticket was rejected")
            return
        }
        let task = Task {
            await consume {
                try await Task.sleep(for: .seconds(120))
                return Data([1])
            }
        }
        for _ in 0..<100 {
            if await fixture.client.started { break }
            await Task.yield()
        }
        switch reason {
        case "disabled": fixture.uploads.setEnabled(false)
        case "session": await fixture.uploads.endSession(runID: fixture.runID)
        case "host": await fixture.uploads.cancelHost(fixture.host.id)
        case "disconnect": disconnected()
        default: await fixture.uploads.stop()
        }
        let response = await task.value
        #expect(response.status == 410)
        #expect(await fixture.client.committed == nil)
        #expect(!fixture.uploads.hasActiveUpload(runID: fixture.runID))
        #expect(fixture.history.entries(tool: "http_sftp_upload").first?.status == .error)
    }

    @Test(arguments: [true, false])
    func conflictHandlingNeverReplacesDirectories(_ directory: Bool) async throws {
        let fixture = UploadFixture()
        await fixture.client.setConflict(directory: directory)
        let ticket = try await fixture.ticket(Data([1]), overwrite: directory)
        let response = try await fixture.consume(ticket, bytes: Data([1]))
        #expect(response.status == 409)
        #expect(await fixture.client.committed == nil)
    }

    @Test
    func overwriteAllowsAnExistingRegularFile() async throws {
        let fixture = UploadFixture()
        await fixture.client.setConflict(directory: false)
        let ticket = try await fixture.ticket(Data([1]), overwrite: true)
        #expect(try await fixture.consume(ticket, bytes: Data([1])).status == 200)
    }

    @Test
    func successfulCommitSurvivesLateDisconnectAndStatusCanBeQueried() async throws {
        let fixture = UploadFixture()
        let ticket = try await fixture.ticket(Data())
        guard case .accept(let consume, let disconnected) = fixture.uploads.prepare(fixture.request(ticket, count: 0))
        else {
            Issue.record("Valid ticket was rejected")
            return
        }
        #expect(await consume { nil }.status == 200)
        disconnected()
        await Task.yield()
        #expect(
            try fixture.uploads.status(id: fixture.id(ticket), runID: fixture.runID).objectValue?["status"]
                == .string("succeeded"))
    }

    @Test
    func actualHTTPRouteStreamsAboveTheMCPBodyLimit() async throws {
        let fixture = UploadFixture()
        let server = LoopbackHTTPServer()
        let port = UInt16.random(in: 40_000...60_000)
        fixture.uploads.configure(port: port)
        let (states, continuation) = AsyncStream<LoopbackHTTPServer.State>.makeStream()
        try await server.start(
            port: port, token: "mcp-token", stateHandler: { continuation.yield($0) },
            streamingHandler: { request in await fixture.uploads.prepare(request) },
            handler: { _ in .text(200, "ordinary") }
        )
        for await state in states {
            if case .ready = state { break }
            if case .failed(let message) = state {
                Issue.record(Comment(rawValue: message))
                await server.stop()
                return
            }
        }
        let bytes = Data(repeating: 255, count: 4 * 1_024 * 1_024 + 10)
        let ticket = try await fixture.ticket(bytes)
        var request = URLRequest(url: URL(string: ticket["upload_url"]!.stringValue!)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(ticket["upload_token"]!.stringValue!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("100-continue", forHTTPHeaderField: "Expect")
        let (_, response) = try await URLSession.shared.upload(for: request, from: bytes)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(await fixture.client.committed == bytes)
        await server.stop()
        await fixture.uploads.stop()
        continuation.finish()
    }
}

@MainActor
private final class UploadFixture {
    let host = TermindDomain.Host(name: "Upload", host: "upload.example")
    let runID = UUID()
    let history = ToolAuditModel()
    let client = UploadSFTPClient()
    let uploads: MCPUploadCoordinator

    init(now: @escaping @Sendable () -> Date = { Date() }, idleTimeout: Duration = .seconds(60)) {
        let resolver = AgentHostResolver(store: HostLibraryModel(hosts: [host]))
        let client = client
        uploads = MCPUploadCoordinator(hosts: resolver, history: history, now: now) {
            request, _, _, _, read, token, report in
            try await SFTPStreamUploadOperation.run(
                client: client, remotePath: request.remotePath, byteCount: request.byteCount,
                sha256: request.sha256, overwrite: request.overwrite, cancellation: token,
                idleTimeout: idleTimeout, read: read, progress: report
            )
        }
        uploads.configure(port: 7391)
        uploads.register(runID: runID, clientName: "Upload tests")
    }

    func ticket(_ bytes: Data, overwrite: Bool = false) async throws -> [String: AgentJSONValue] {
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(
                id: UUID().uuidString, name: "sftp_upload",
                arguments: .object([
                    "host_id": .string(host.id.uuidString), "remote_path": .string("/target/file.bin"),
                    "byte_count": .number(Double(bytes.count)), "sha256": .string(uploadDigest(bytes)),
                    "overwrite": .bool(overwrite),
                ]))
        )
        return try #require(try await uploads.create(invocation).objectValue)
    }

    func id(_ ticket: [String: AgentJSONValue]) -> UUID { UUID(uuidString: ticket["upload_id"]!.stringValue!)! }

    func request(_ ticket: [String: AgentJSONValue], count: Int) -> HTTPRequest {
        HTTPRequest(
            method: "PUT", target: "/uploads/\(id(ticket))", version: "HTTP/1.1",
            headers: [
                "authorization": "Bearer \(ticket["upload_token"]!.stringValue!)",
                "content-type": "application/octet-stream", "content-length": String(count),
            ], body: Data()
        )
    }

    func consume(_ ticket: [String: AgentJSONValue], bytes: Data) async throws -> HTTPResponse {
        guard case .accept(let consume, _) = uploads.prepare(request(ticket, count: bytes.count)) else {
            throw MCPUploadError.invalidRequest
        }
        let source = UploadByteSource(bytes)
        return await consume { await source.next() }
    }
}

private func uploadDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private actor UploadByteSource {
    var data: Data
    var readCount = 0
    init(_ data: Data) { self.data = data }
    func next() -> Data? {
        guard !data.isEmpty else { return nil }
        readCount += 1
        let chunk = Data(data.prefix(SFTPStreamUploadOperation.chunkBytes))
        data.removeFirst(chunk.count)
        return chunk
    }
}

private nonisolated final class UploadClock: @unchecked Sendable {
    let lock = NSLock()
    private var value = Date()
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor UploadSFTPClient: SFTPClientProtocol {
    var committed: Data?
    var started = false
    var conflict: RemoteFile.Kind?
    var delay = false
    var cleanupFails = false
    var cleanupFailsAfterRead = false
    func delayReading() { delay = true }
    func failCleanup() { cleanupFails = true }
    func failCleanupAfterRead() { cleanupFailsAfterRead = true }
    func setConflict(directory: Bool) { conflict = directory ? .directory : .file }
    func attributes(at path: String) async throws -> RemoteFile? {
        let kind: RemoteFile.Kind
        if path == "/target" { kind = .directory } else if let conflict { kind = conflict } else { return nil }
        return RemoteFile(
            path: path, name: (path as NSString).lastPathComponent, kind: kind, size: 0,
            permissions: 0o600, ownerUID: 0, ownerGID: 0
        )
    }
    func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        started = true
        if cleanupFails {
            throw SFTPTemporaryFileCleanupError(path: "/target/file.bin.part", cause: SFTPError.connectionLost("lost"))
        }
        if delay { try await Task.sleep(for: .seconds(120)) }
        let cleanupFailsAfterRead = cleanupFailsAfterRead
        let data = try await Task.detached {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: SFTPStreamUploadOperation.chunkBytes)
            while true {
                let count = Darwin.recv(socket, &buffer, buffer.count, 0)
                if count == 0 { break }
                guard count > 0 else { throw SFTPError.cancelled }
                data.append(contentsOf: buffer.prefix(count))
                progress(SFTPProgress(completedBytes: Int64(data.count), totalBytes: byteCount, bytesPerSecond: 0))
            }
            guard !cancellation.isCancelled, sourceSucceeded() else {
                if cleanupFailsAfterRead {
                    throw SFTPTemporaryFileCleanupError(path: "/target/file.bin.part", cause: SFTPError.cancelled)
                }
                throw SFTPError.cancelled
            }
            guard data.count == byteCount else { throw SFTPStreamUploadOperation.Failure.invalidLength }
            return data
        }.value
        committed = data
    }
    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func readFile(at path: String, maximumBytes: Int) async throws -> Data { throw MCPUploadError.invalidRequest }
    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws { throw MCPUploadError.invalidRequest }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw MCPUploadError.invalidRequest }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw MCPUploadError.invalidRequest }
}
