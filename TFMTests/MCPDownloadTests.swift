// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import CryptoKit
import Foundation
import Network
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct MCPDownloadTests {
    @Test
    func interruptedDownloadResumesFromClientOffsetAndHashesTheWholeFile() async throws {
        let bytes = Data((0..<(160 * 1024)).map { UInt8($0 % 251) })
        let fixture = DownloadFixture(bytes: bytes)
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        guard case .file(let body) = response.body else {
            Issue.record("Expected file")
            return
        }
        let chunk = try #require(try await body.read())
        await body.sent(chunk.count)
        body.cancel()
        await body.finished(.failure(LoopbackHTTPServerError.endOfStream))
        #expect(try fixture.status(ticket)["status"] == .string("paused"))
        // Only 137 bytes were saved, despite a full chunk being sent.
        var request = fixture.request(ticket)
        request.headers["range"] = "bytes=137-"
        let resumed = await fixture.prepare(ticket, request: request)
        #expect(resumed.status == 206)
        #expect(resumed.headers["Content-Range"] == "bytes 137-\(bytes.count - 1)/\(bytes.count)")
        #expect(resumed.headers["Content-Length"] == String(bytes.count - 137))
        let suffix = try await consumeDownload(resumed)
        #expect(Data(chunk.prefix(137)) + suffix == bytes)
        #expect(try fixture.status(ticket)["sha256"] == .string(downloadDigest(bytes)))
        #expect(try fixture.status(ticket)["status"] == .string("succeeded"))
        #expect(await fixture.backend.closes == 2)
    }

    @Test
    func invalidRangeDoesNotConsumeTicketAndCompletedDownloadCanReplayARange() async throws {
        let fixture = DownloadFixture(bytes: Data([1, 2, 3]))
        let ticket = try fixture.ticket()
        var request = fixture.request(ticket)
        request.headers["range"] = "bytes=3-"
        let rejected = await fixture.prepare(ticket, request: request)
        #expect(rejected.status == 416)
        #expect(rejected.headers["Content-Range"] == "bytes */3")
        #expect(try fixture.status(ticket)["status"] == .string("waiting"))
        #expect(try await consumeDownload(await fixture.prepare(ticket)) == Data([1, 2, 3]))
        request.headers["range"] = "bytes=1-"
        #expect(try await consumeDownload(await fixture.prepare(ticket, request: request)) == Data([2, 3]))
        #expect(try fixture.status(ticket)["sha256"] == .string(downloadDigest(Data([1, 2, 3]))))
    }

    @Test
    func changedPrefixRejectsResumeBeforeHeadersEvenWhenSizeIsUnchanged() async throws {
        let fixture = DownloadFixture(bytes: Data(repeating: 1, count: 128 * 1024))
        let ticket = try fixture.ticket()
        guard case .file(let body) = await fixture.prepare(ticket).body else {
            Issue.record("Expected file")
            return
        }
        _ = try await body.read()
        body.cancel()
        await body.finished(.failure(LoopbackHTTPServerError.endOfStream))
        await fixture.backend.replaceSource(Data(repeating: 2, count: 128 * 1024))
        var request = fixture.request(ticket)
        request.headers["range"] = "bytes=17-"
        let response = await fixture.prepare(ticket, request: request)
        #expect(response.status == 409)
        #expect(try fixture.status(ticket)["error"] == .string("source_changed"))
        #expect(try fixture.status(ticket)["status"] == .string("failed"))
    }

    @Test
    func deliveredFileResponseDoesNotRemainRetainedByItsExchange() async {
        let exchange = MCPDownloadExchange()
        var prepared: (HTTPResponse, WeakDownloadReader)? = weakFileResponse(exchange: exchange)
        let weakReader = prepared!.1
        await exchange.publish(prepared!.0)
        prepared = nil
        var published: HTTPResponse? = await exchange.response()
        #expect(published?.status == 200)
        #expect(weakReader.reader != nil)
        published = nil
        #expect(weakReader.reader == nil)
    }

    @Test
    func actualHTTPPostHeaderFailureClosesWithoutAppendingJSON() async throws {
        let fixture = DownloadFixture(bytes: Data(repeating: 255, count: 128 * 1_024))
        await fixture.backend.failSecondRead()
        let server = LoopbackHTTPServer()
        let port = UInt16.random(in: 40_000...60_000)
        fixture.downloads.configure(port: port)
        let (states, continuation) = AsyncStream<LoopbackHTTPServer.State>.makeStream()
        try await server.start(
            port: port, token: "root", stateHandler: { continuation.yield($0) },
            downloadHandler: { request, token, cancel in
                await fixture.downloads.prepare(request, cancellation: token, cancelTransport: cancel)
            },
            handler: { _ in .text(404, "ordinary") })
        for await state in states {
            if case .ready = state { break }
            if case .failed(let message) = state {
                Issue.record(Comment(rawValue: message))
                await server.stop()
                return
            }
        }
        let ticket = try fixture.ticket()
        let wire = try await rawDownload(
            port: port, id: fixture.id(ticket), token: ticket["download_token"]!.stringValue!)
        let separator = try #require(wire.range(of: Data("\r\n\r\n".utf8)))
        #expect(String(decoding: wire.prefix(separator.lowerBound), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let body = wire[separator.upperBound...]
        #expect(!body.isEmpty)
        #expect(body.count < 128 * 1_024)
        #expect(body.allSatisfy { $0 == 255 })
        #expect(try fixture.status(ticket)["status"] == .string("paused"))
        #expect(await fixture.backend.closes == 1)
        await fixture.backend.allowReads()
        let resumed = try await rawDownload(
            port: port, id: fixture.id(ticket), token: ticket["download_token"]!.stringValue!, range: "bytes=137-")
        let resumedSeparator = try #require(resumed.range(of: Data("\r\n\r\n".utf8)))
        let headers = String(decoding: resumed.prefix(resumedSeparator.lowerBound), as: UTF8.self)
        #expect(headers.hasPrefix("HTTP/1.1 206 Partial Content"))
        #expect(headers.contains("Content-Range: bytes 137-131071/131072"))
        #expect(resumed[resumedSeparator.upperBound...].count == 128 * 1024 - 137)
        #expect(
            try fixture.status(ticket)["sha256"] == .string(downloadDigest(Data(repeating: 255, count: 128 * 1024))))
        await fixture.downloads.stop()
        await server.stop()
        continuation.finish()
    }

    @Test(arguments: [Data(), Data([0, 255, 128, 10]), Data(count: 4 * 1_024 * 1_024 + 1)])
    func downloadsBinaryFilesWithoutStagingAndOnlyMarksSuccessAfterClosing(_ bytes: Data) async throws {
        let fixture = DownloadFixture(bytes: bytes)
        let ticket = try fixture.ticket(expected: downloadDigest(bytes).uppercased())
        #expect(await fixture.backend.opens == 0)
        #expect(try fixture.status(ticket)["byte_count"] == .null)
        let response = await fixture.prepare(ticket)
        #expect(response.status == 200)
        #expect(response.headers["Content-Length"] == String(bytes.count))
        #expect(response.headers["Content-Disposition"] == nil)
        #expect(try await consumeDownload(response) == bytes)
        let status = try fixture.status(ticket)
        #expect(status["status"] == .string("succeeded"))
        #expect(status["sha256"] == .string(downloadDigest(bytes)))
        #expect(status["bytes"]?.integerValue == bytes.count)
        #expect(await fixture.backend.closes == 1)
        let audit = fixture.history.entries(tool: "http_sftp_download")
        #expect(audit.first?.status == .ok)
        #expect(audit.first?.bytesRead == bytes.count)
        #expect(audit.first?.bytesWritten == nil)
        #expect(audit.first?.risk == .readOnly)
        #expect(audit.first?.summary.contains(ticket["download_token"]!.stringValue!) == false)
        #expect(await fixture.prepare(ticket).status == 409)
    }

    @Test
    func mismatchedDigestIsNotSuccessfulEvenIfAllHTTPBytesWereSent() async throws {
        let fixture = DownloadFixture(bytes: Data([1]))
        let ticket = try fixture.ticket(expected: downloadDigest(Data([2])))
        let response = await fixture.prepare(ticket)
        #expect(response.status == 200)
        await #expect(throws: SFTPDownloadFailure.self) { try await consumeDownload(response) }
        let status = try fixture.status(ticket)
        #expect(status["status"] == .string("failed"))
        #expect(status["error"] == .string("digest_mismatch"))
        #expect(status["sha256"] == .string(downloadDigest(Data([1]))))
        #expect(await fixture.backend.closes == 1)
    }

    @Test(arguments: [SFTPDownloadFailure.missingFile, .unsupportedType, .tooLarge])
    func preHeaderSourceFailuresReturnJSONAndConsumeTheTicket(_ failure: SFTPDownloadFailure) async throws {
        let fixture = DownloadFixture(bytes: Data())
        await fixture.backend.setOpenFailure(failure)
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        #expect(response.status == (failure.expectedStatus))
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(try fixture.status(ticket)["status"] == .string("failed"))
        #expect(await fixture.prepare(ticket).status == 409)
    }

    @Test
    func authenticationFailureIsSanitizedAndNeverExposesTheUnderlyingMessage() async throws {
        let fixture = DownloadFixture(bytes: Data())
        await fixture.backend.setOpenFailure(TermindSSHError.authenticationFailed("PRIVATE-AUTHENTICATION-MESSAGE"))
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        #expect(response.status == 401)
        guard case .data(let body) = response.body else {
            Issue.record("Expected JSON error")
            return
        }
        #expect(!String(decoding: body, as: UTF8.self).contains("PRIVATE-AUTHENTICATION-MESSAGE"))
    }

    @Test(arguments: ["authorization", "origin", "range", "content-length", "transfer-encoding"])
    func invalidHeadersDoNotOpenTheSourceOrConsumeTheTicket(_ header: String) async throws {
        let fixture = DownloadFixture(bytes: Data())
        let ticket = try fixture.ticket()
        var request = fixture.request(ticket)
        request.headers[header] =
            [
                "authorization": "Bearer wrong", "origin": "https://example.com", "range": "bytes=0-1",
                "content-length": "1", "transfer-encoding": "chunked",
            ][header]
        let response = await fixture.prepare(ticket, request: request)
        #expect(response.status >= 400)
        #expect(try fixture.status(ticket)["status"] == .string("waiting"))
        #expect(await fixture.backend.opens == 0)
        #expect(fixture.history.entries().isEmpty)
    }

    @Test(arguments: ["HEAD", "POST", "query", "body"])
    func unsupportedRequestsAreRejectedBeforeClaiming(_ kind: String) async throws {
        let fixture = DownloadFixture(bytes: Data())
        let ticket = try fixture.ticket()
        var request = fixture.request(ticket)
        if kind == "query" {
            request.target += "?token=not-allowed"
        } else if kind == "body" {
            request.body = Data([1])
        } else {
            request.method = kind
        }
        #expect(await fixture.prepare(ticket, request: request).status >= 400)
        #expect(try fixture.status(ticket)["status"] == .string("waiting"))
        #expect(await fixture.backend.opens == 0)
    }

    @Test(arguments: ["", "xyz", String(repeating: "0", count: 63)])
    func invalidExpectedDigestsAreRejected(_ digest: String) {
        let fixture = DownloadFixture(bytes: Data())
        #expect(throws: MCPDownloadError.self) { try fixture.ticket(expected: digest) }
    }

    @Test
    func sessionIsolationExpiryAndDisabledTicketsRemainEnforced() async throws {
        let clock = DownloadClock()
        let fixture = DownloadFixture(bytes: Data(), now: { clock.date })
        let ticket = try fixture.ticket()
        #expect(throws: MCPDownloadError.self) { try fixture.downloads.status(id: fixture.id(ticket), runID: UUID()) }
        clock.advance(601)
        #expect(await fixture.prepare(ticket).status == 410)
        #expect(try fixture.status(ticket)["status"] == .string("expired"))
        let disabled = try fixture.ticket()
        fixture.downloads.setEnabled(false)
        fixture.downloads.setEnabled(true)
        #expect(await fixture.prepare(disabled).status == 410)
        #expect(try fixture.status(disabled)["status"] == .string("cancelled"))
        await fixture.downloads.endSession(runID: fixture.runID)
        #expect(throws: MCPDownloadError.self) { try fixture.status(disabled) }
    }

    @Test
    func waitingAndCompletedRecordsHaveIndependentBounds() async throws {
        let fixture = DownloadFixture(bytes: Data())
        var first: [String: AgentJSONValue]?
        for _ in 0..<257 {
            let ticket = try fixture.ticket()
            if first == nil { first = ticket }
            await fixture.downloads.cancelHost(fixture.host.id)
        }
        #expect(throws: MCPDownloadError.self) { try fixture.status(first!) }
        for _ in 0..<64 { _ = try fixture.ticket() }
        #expect(throws: MCPDownloadError.self) { try fixture.ticket() }
        await fixture.downloads.stop()
    }

    @Test
    func uploadAndDownloadShareFourSlotsUntilCleanupFinishes() async throws {
        let fixture = DownloadFixture(bytes: Data())
        let uploads = MCPUploadCoordinator(hosts: fixture.resolver, history: fixture.history, budget: fixture.budget) {
            _, _, _, _, _, _, _ in throw SFTPError.cancelled
        }
        uploads.configure(port: 7391)
        uploads.register(runID: fixture.runID, clientName: "Tests")
        for _ in 0..<4 {
            let invocation = AgentToolInvocation(
                runID: fixture.runID,
                call: AgentToolCall(
                    id: UUID().uuidString, name: "sftp_upload",
                    arguments: .object([
                        "host_id": .string(fixture.host.id.uuidString), "remote_path": .string("/target/a"),
                        "byte_count": .number(0), "sha256": .string(downloadDigest(Data())),
                    ])))
            let ticket = try #require(try await uploads.create(invocation).objectValue)
            let request = HTTPRequest(
                method: "PUT", target: "/uploads/\(ticket["upload_id"]!.stringValue!)", version: "HTTP/1.1",
                headers: [
                    "authorization": "Bearer \(ticket["upload_token"]!.stringValue!)", "content-length": "0",
                    "content-type": "application/octet-stream",
                ], body: Data())
            guard case .accept = uploads.prepare(request) else {
                Issue.record("Valid upload rejected")
                return
            }
        }
        let ticket = try fixture.ticket()
        #expect(await fixture.prepare(ticket).status == 429)
        #expect(try fixture.status(ticket)["status"] == .string("waiting"))
        await uploads.stop()
        let response = await fixture.prepare(ticket)
        #expect(response.status == 200)
        for _ in 0..<3 { #expect(fixture.budget.claim(UUID())) }
        #expect(!fixture.budget.claim(UUID()))
        _ = try await consumeDownload(response)
        #expect(fixture.budget.claim(UUID()))
    }

    @Test(arguments: ["disabled", "session", "host", "stop", "disconnect"])
    func cancellationClosesTheSourceAndReleasesCapacity(_ reason: String) async throws {
        let fixture = DownloadFixture(bytes: Data([1]))
        let ticket = try fixture.ticket()
        let cancellation = TransferCancellationToken()
        let response = await fixture.prepare(ticket, cancellation: cancellation)
        switch reason {
        case "disabled": fixture.downloads.setEnabled(false)
        case "session": await fixture.downloads.endSession(runID: fixture.runID)
        case "host": await fixture.downloads.cancelHost(fixture.host.id)
        case "disconnect": cancellation.cancel()
        default: await fixture.downloads.stop()
        }
        guard case .file(let file) = response.body else {
            Issue.record("Expected file response")
            return
        }
        await file.finished(.failure(AgentToolError.cancelled))
        #expect(await fixture.backend.closes == 1)
        #expect(fixture.history.entries(tool: "http_sftp_download").first?.status == .error)
        #expect(fixture.budget.claim(UUID()))
    }

    @Test
    func interruptedHTTPConnectionPausesWithoutPublishingAFileResponse() async throws {
        let fixture = DownloadFixture(bytes: Data())
        await fixture.backend.delayOpening()
        let ticket = try fixture.ticket()
        let token = TransferCancellationToken()
        let task = Task { await fixture.prepare(ticket, cancellation: token) }
        for _ in 0..<100 {
            if await fixture.backend.opens > 0 { break }
            await Task.yield()
        }
        token.cancel()
        #expect(await task.value.status == 410)
        #expect(try fixture.status(ticket)["status"] == .string("paused"))
        #expect(fixture.budget.claim(UUID()))
    }

    @Test
    func stalledHTTPConsumerTimesOutAndClosesTheDedicatedSource() async throws {
        let fixture = DownloadFixture(bytes: Data([1]), idleTimeout: .milliseconds(20))
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        try await Task.sleep(for: .milliseconds(60))
        guard case .file(let file) = response.body else {
            Issue.record("Expected file response")
            return
        }
        await file.finished(.failure(AgentToolError.cancelled))
        #expect(try fixture.status(ticket)["error"] == .string("download_timeout"))
        #expect(await fixture.backend.closes == 1)
    }

    @Test
    func closeFailurePreventsSuccessAfterCompleteHTTPBytes() async throws {
        let fixture = DownloadFixture(bytes: Data([1]))
        await fixture.backend.failClosing()
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        #expect(try await consumeDownload(response) == Data([1]))
        #expect(try fixture.status(ticket)["status"] == .string("failed"))
        #expect(try fixture.status(ticket)["error"] == .string("stream_close_failed"))
    }

    @Test(arguments: ["grown", "truncated", "modified", "read_error", "send_error"])
    func postHeaderFailuresNeverBecomeSuccessfulOrAppendJSON(_ kind: String) async throws {
        let fixture = DownloadFixture(bytes: Data([1]))
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        let stream = try #require(await fixture.backend.streams.first)
        if kind == "grown" { await stream.replace(Data([1, 2])) }
        if kind == "truncated" { await stream.replace(Data()) }
        if kind == "modified" { await stream.markModified() }
        if kind == "read_error" { await stream.failRead() }
        if kind == "send_error" {
            guard case .file(let file) = response.body else {
                Issue.record("Expected file body")
                return
            }
            await file.finished(.failure(SFTPError.connectionLost("send failed")))
        } else {
            await #expect(throws: (any Error).self) { try await consumeDownload(response) }
        }
        #expect(
            try fixture.status(ticket)["status"]
                == .string(kind == "read_error" || kind == "send_error" ? "paused" : "failed"))
        #expect(await fixture.backend.closes == 1)
        #expect(response.headers["Content-Type"] == "application/octet-stream")
    }

    @Test
    func pullResponsesDoNotPrefetchAndLongCompletionRetainsQueryableStatus() async throws {
        let clock = DownloadClock()
        let fixture = DownloadFixture(bytes: Data(count: 128 * 1_024), now: { clock.date })
        let ticket = try fixture.ticket()
        let response = await fixture.prepare(ticket)
        let stream = try #require(await fixture.backend.streams.first)
        #expect(await stream.reads == 0)
        guard case .file(let file) = response.body else {
            Issue.record("Expected file body")
            return
        }
        let first = try #require(try await file.read())
        #expect(await stream.reads == 1)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await stream.reads == 1)
        await file.sent(first.count)
        clock.advance(3_600)
        #expect(fixture.downloads.hasDownloadActivity(runID: fixture.runID))
        _ = try await consumeDownload(response, initiallySent: first.count)
        #expect(fixture.downloads.hasDownloadActivity(runID: fixture.runID))
        clock.advance(1_801)
        #expect(!fixture.downloads.hasDownloadActivity(runID: fixture.runID))
        #expect(throws: MCPDownloadError.self) { try fixture.status(ticket) }
    }

    @Test(arguments: [Data(), Data([0, 255, 128]), Data(count: 4 * 1_024 * 1_024 + 1)])
    func actualHTTPGETStreamsBinaryFilesUsingOnlyTheScopedToken(_ bytes: Data) async throws {
        let fixture = DownloadFixture(bytes: bytes)
        let server = LoopbackHTTPServer()
        let port = UInt16.random(in: 40_000...60_000)
        fixture.downloads.configure(port: port)
        let (states, continuation) = AsyncStream<LoopbackHTTPServer.State>.makeStream()
        try await server.start(
            port: port, token: "ROOT-MCP-TOKEN", stateHandler: { continuation.yield($0) },
            downloadHandler: { request, token, cancel in
                await fixture.downloads.prepare(request, cancellation: token, cancelTransport: cancel)
            },
            handler: { _ in .text(404, "ordinary") })
        for await state in states {
            if case .ready = state { break }
            if case .failed(let message) = state {
                Issue.record(Comment(rawValue: message))
                await server.stop()
                return
            }
        }
        let ticket = try fixture.ticket(expected: downloadDigest(bytes))
        var request = URLRequest(url: URL(string: ticket["download_url"]!.stringValue!)!)
        request.setValue("Bearer \(ticket["download_token"]!.stringValue!)", forHTTPHeaderField: "Authorization")
        let (received, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(received == bytes)
        for _ in 0..<100 {
            if try fixture.status(ticket)["status"] == .string("succeeded") { break }
            await Task.yield()
        }
        #expect(try fixture.status(ticket)["status"] == .string("succeeded"))
        #expect(try fixture.status(ticket)["sha256"] == .string(downloadDigest(bytes)))
        var bad = request
        bad.setValue("Bearer ROOT-MCP-TOKEN", forHTTPHeaderField: "Authorization")
        let (_, rejected) = try await URLSession.shared.data(for: bad)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 401)
        await fixture.downloads.stop()
        await server.stop()
        continuation.finish()
    }
}

private func downloadDigest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

@MainActor
private final class WeakDownloadReader {
    weak var reader: MCPDownloadReader?
    init(_ reader: MCPDownloadReader) { self.reader = reader }
}

@MainActor
private func weakFileResponse(exchange: MCPDownloadExchange) -> (HTTPResponse, WeakDownloadReader) {
    let reader = MCPDownloadReader(
        stream: MockDownloadStream(bytes: Data()), expectedSHA256: nil, cancellation: TransferCancellationToken())
    return (
        HTTPResponse(
            status: 200,
            file: HTTPFileBody(
                byteCount: 0, read: { try await reader.readChunk() }, sent: { _ in },
                finished: { result in await exchange.complete(result) }, cancel: {})), WeakDownloadReader(reader)
    )
}

private func rawDownload(port: UInt16, id: UUID, token: String, range: String? = nil) async throws -> Data {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: DispatchQueue(label: "termind.tests.download.raw"))
    let timer = Task {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        connection.cancel()
    }
    defer {
        timer.cancel()
        connection.cancel()
    }
    let rangeHeader = range.map { "Range: \($0)\r\n" } ?? ""
    let request = Data(
        "GET /downloads/\(id) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\(rangeHeader)Connection: close\r\n\r\n"
            .utf8)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(
            content: request,
            completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
    }
    var wire = Data()
    while true {
        let (bytes, complete) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Data, Bool), Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
                continuation.resume(returning: (data ?? Data(), complete || error != nil))
            }
        }
        wire.append(bytes)
        if complete { return wire }
        guard wire.count <= 1_024 * 1_024 else { throw SFTPDownloadFailure.tooLarge }
    }
}

private func consumeDownload(_ response: HTTPResponse, initiallySent: Int = 0) async throws -> Data {
    guard case .file(let file) = response.body else { throw SFTPDownloadFailure.invalidChunk }
    var received = Data()
    var sent = Int64(initiallySent)
    do {
        while let chunk = try await file.read() {
            guard Int64(chunk.count) <= file.byteCount - sent else { throw SFTPDownloadFailure.sourceChanged }
            received.append(chunk)
            sent += Int64(chunk.count)
            await file.sent(chunk.count)
        }
        guard sent == file.byteCount else { throw SFTPDownloadFailure.sourceChanged }
        await file.finished(.success(()))
        return received
    } catch {
        await file.finished(.failure(error))
        throw error
    }
}

@MainActor
private final class DownloadFixture {
    let host = TermindDomain.Host(name: "Download", host: "download.example")
    let runID = UUID()
    let history = ToolAuditModel()
    let budget = MCPTransferBudget()
    let resolver: AgentHostResolver
    let backend: DownloadBackend
    let downloads: MCPDownloadCoordinator
    init(bytes: Data, now: @escaping @Sendable () -> Date = { Date() }, idleTimeout: Duration = .seconds(60)) {
        resolver = AgentHostResolver(store: HostLibraryModel(hosts: [host]))
        backend = DownloadBackend(bytes: bytes)
        let backend = backend
        downloads = MCPDownloadCoordinator(
            hosts: resolver, history: history, budget: budget, now: now, idleTimeout: idleTimeout
        ) {
            _, _, _, _, token, serve in
            let stream = try await backend.open(token)
            do { try await serve(stream) } catch {
                try await backend.close(stream)
                throw error
            }
            try await backend.close(stream)
        }
        downloads.configure(port: 7391)
        downloads.register(runID: runID, clientName: "Download tests")
    }
    func ticket(expected: String? = nil) throws -> [String: AgentJSONValue] {
        var arguments: [String: AgentJSONValue] = [
            "host_id": .string(host.id.uuidString), "remote_path": .string("/source/a.bin"),
        ]
        if let expected { arguments["expected_sha256"] = .string(expected) }
        return try #require(
            try downloads.create(
                AgentToolInvocation(
                    runID: runID,
                    call: AgentToolCall(id: UUID().uuidString, name: "sftp_download", arguments: .object(arguments)))
            ).objectValue)
    }
    func id(_ ticket: [String: AgentJSONValue]) -> UUID { UUID(uuidString: ticket["download_id"]!.stringValue!)! }
    func status(_ ticket: [String: AgentJSONValue]) throws -> [String: AgentJSONValue] {
        try #require(try downloads.status(id: id(ticket), runID: runID).objectValue)
    }
    func request(_ ticket: [String: AgentJSONValue]) -> HTTPRequest {
        HTTPRequest(
            method: "GET", target: "/downloads/\(id(ticket))", version: "HTTP/1.1",
            headers: ["authorization": "Bearer \(ticket["download_token"]!.stringValue!)"], body: Data())
    }
    func prepare(
        _ ticket: [String: AgentJSONValue], request: HTTPRequest? = nil,
        cancellation: TransferCancellationToken = TransferCancellationToken()
    ) async -> HTTPResponse {
        await downloads.prepare(request ?? self.request(ticket), cancellation: cancellation, cancelTransport: {})
    }
}

private nonisolated final class DownloadClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor DownloadBackend {
    var bytes: Data
    var opens = 0
    var closes = 0
    var streams: [MockDownloadStream] = []
    var openFailure: (any Error)?
    var delay = false
    var closeFails = false
    var secondReadFails = false
    init(bytes: Data) { self.bytes = bytes }
    func replaceSource(_ bytes: Data) { self.bytes = bytes }
    func setOpenFailure(_ failure: any Error) { openFailure = failure }
    func delayOpening() { delay = true }
    func failClosing() { closeFails = true }
    func failSecondRead() { secondReadFails = true }
    func allowReads() { secondReadFails = false }
    func open(_ cancellation: TransferCancellationToken) async throws -> MockDownloadStream {
        opens += 1
        if delay { try await Task.sleep(for: .seconds(120)) }
        if let openFailure { throw openFailure }
        guard !cancellation.isCancelled else { throw AgentToolError.cancelled }
        let stream = MockDownloadStream(bytes: bytes, secondReadFails: secondReadFails)
        streams.append(stream)
        return stream
    }
    func close(_ stream: MockDownloadStream) async throws {
        closes += 1
        await stream.close()
        if closeFails { throw SFTPDownloadFailure.closeFailed }
    }
}

private actor MockDownloadStream: SFTPDownloadStream {
    nonisolated let byteCount: Int64
    var bytes: Data
    let original: Data
    var reads = 0
    var modified = false
    var readFails = false
    var closed = false
    let secondReadFails: Bool
    init(bytes: Data, secondReadFails: Bool = false) {
        self.bytes = bytes
        self.original = bytes
        self.secondReadFails = secondReadFails
        byteCount = Int64(bytes.count)
    }
    func seek(to offset: Int64) { bytes = Data(original.dropFirst(Int(offset))) }
    func replace(_ bytes: Data) { self.bytes = bytes }
    func markModified() { modified = true }
    func failRead() { readFails = true }
    func readChunk() async throws -> Data? {
        guard !closed else { throw SFTPError.notConnected }
        if readFails { throw SFTPError.connectionLost("private error") }
        if secondReadFails && reads > 0 {
            try await Task.sleep(for: .milliseconds(20))
            throw SFTPError.connectionLost("private read error")
        }
        reads += 1
        if bytes.isEmpty {
            if modified { throw SFTPDownloadFailure.sourceChanged }
            return nil
        }
        let chunk = Data(bytes.prefix(64 * 1_024))
        bytes.removeFirst(chunk.count)
        return chunk
    }
    func close() { closed = true }
}
nonisolated

    extension SFTPDownloadFailure
{
    fileprivate var expectedStatus: Int {
        switch self {
        case .missingFile: 404
        case .unsupportedType: 422
        default: 413
        }
    }
}
