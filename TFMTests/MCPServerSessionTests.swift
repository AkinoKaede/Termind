import AgentKit
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
struct MCPServerSessionTests {
    @Test(arguments: ["2025-11-25", "2025-06-18", "2026-07-28"], [false, true])
    func realHTTPTransportSupportsInspectorRequests(_ version: String, closeConnection: Bool) async throws {
        let http = LoopbackHTTPServer()
        let server = MCPServerProtocol(tools: makeMCPServerTools())
        var port: UInt16 = 0
        for attempt in 0..<10 {
            let (states, continuation) = AsyncStream<LoopbackHTTPServer.State>.makeStream()
            port = UInt16.random(in: 49_152...60_000)
            try await http.start(
                port: port, token: "integration-test-token", stateHandler: { continuation.yield($0) },
                handler: { await server.handle($0) }
            )
            var ready = false
            for await state in states {
                if case .ready = state {
                    ready = true
                    break
                }
                if case .failed(let message) = state {
                    await http.stop()
                    if attempt == 9 { throw NSError(domain: message, code: 1) }
                    break
                }
            }
            if ready { break }
        }
        defer {
            Task {
                await http.stop()
                await server.stop()
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpMaximumConnectionsPerHost = 1
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        func post(_ method: String, id: Int?, sessionID: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var params: [String: AgentJSONValue] = [:]
            if method == "initialize" {
                params = [
                    "protocolVersion": .string(version),
                    "clientInfo": .object(["name": .string("inspector-test"), "version": .string("1")]),
                    "capabilities": .object([:]),
                ]
            } else {
                params["_meta"] = .object(["progressToken": .string("inspector-progress")])
            }
            if version == "2026-07-28" {
                params["_meta"] = .object([
                    "io.modelcontextprotocol/protocolVersion": .string(version),
                    "io.modelcontextprotocol/clientCapabilities": .object([:]),
                ])
            }
            var message: [String: AgentJSONValue] = [
                "jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params),
            ]
            if let id { message["id"] = .number(Double(id)) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = AgentJSONValue.object(message).encodedData
            if closeConnection { request.setValue("close", forHTTPHeaderField: "Connection") }
            request.setValue("Bearer integration-test-token", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("http://localhost:6274", forHTTPHeaderField: "Origin")
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            let (data, response) = try await client.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }
        var sessionID: String?
        if version != "2026-07-28" {
            let (_, initialized) = try await post("initialize", id: 1)
            #expect(initialized.statusCode == 200)
            #expect(
                initialized.value(forHTTPHeaderField: "Access-Control-Expose-Headers")?.contains("Mcp-Session-Id")
                    == true)
            let assigned: String = try #require(initialized.value(forHTTPHeaderField: "Mcp-Session-Id"))
            sessionID = assigned
            let (data, notified) = try await post("notifications/initialized", id: nil, sessionID: sessionID)
            #expect(notified.statusCode == 202)
            #expect(data.isEmpty)
        }
        let (listed, response) = try await post("tools/list", id: 2, sessionID: sessionID)
        #expect(response.statusCode == 200)
        let envelope = try AgentJSONValue.decode(listed).objectValue
        #expect(envelope?["result"]?.objectValue?["tools"]?.arrayValue?.count == 18)
        if version == "2026-07-28" {
            #expect(envelope?["result"]?.objectValue?["ttlMs"] == .number(0))
            #expect(envelope?["result"]?.objectValue?["cacheScope"] == .string("private"))
            let (discovered, _) = try await post("server/discover", id: 3)
            let discovery = try AgentJSONValue.decode(discovered).objectValue?["result"]?.objectValue
            #expect(discovery?["ttlMs"] == .number(0))
            #expect(discovery?["cacheScope"] == .string("private"))
            if !closeConnection {
                Attachment.record(discovered, named: "mcp-modern-discover.json")
                Attachment.record(listed, named: "mcp-modern-tools-list.json")
            }
        }
        #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "http://localhost:6274")
        var preflight = URLRequest(url: url)
        preflight.httpMethod = "OPTIONS"
        preflight.setValue("http://localhost:6274", forHTTPHeaderField: "Origin")
        preflight.setValue("POST", forHTTPHeaderField: "Access-Control-Request-Method")
        preflight.setValue(
            "authorization,content-type,mcp-session-id,mcp-protocol-version,mcp-method",
            forHTTPHeaderField: "Access-Control-Request-Headers")
        let (_, raw) = try await client.data(for: preflight)
        #expect((raw as? HTTPURLResponse)?.statusCode == 204)
        #expect(
            (raw as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
                == "http://localhost:6274")
        preflight.setValue("http://127.0.0.1.attacker.com", forHTTPHeaderField: "Origin")
        let (_, rejectedOrigin) = try await client.data(for: preflight)
        #expect((rejectedOrigin as? HTTPURLResponse)?.statusCode == 403)
        #expect((rejectedOrigin as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
        preflight.setValue("http://localhost:6274", forHTTPHeaderField: "Origin")
        preflight.setValue("x-unrecognized-policy", forHTTPHeaderField: "Access-Control-Request-Headers")
        let (_, rejectedHeader) = try await client.data(for: preflight)
        #expect((rejectedHeader as? HTTPURLResponse)?.statusCode == 400)
        preflight.httpMethod = "POST"
        let (_, unauthorized) = try await client.data(for: preflight)
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
        #expect(
            (unauthorized as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin")
                == "http://localhost:6274")
        preflight.httpMethod = "OPTIONS"
        preflight.url = URL(string: "http://127.0.0.1:\(port)/uploads/not-a-ticket")!
        let (_, uploadPreflight) = try await client.data(for: preflight)
        #expect((uploadPreflight as? HTTPURLResponse)?.statusCode != 204)
        #expect((uploadPreflight as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil)
        await http.stop()
        await server.stop()
    }

    @Test
    func modernUploadHandleSupportsCrossRequestStatusAndIsRevokedOnStop() async throws {
        let host = Host(name: "Upload", host: "upload.example")
        let tools = makeMCPServerTools(hosts: [host])
        tools.uploads.configure(port: 7391)
        let server = MCPServerProtocol(tools: tools)
        func call(_ name: String, _ arguments: [String: AgentJSONValue]) async -> HTTPResponse {
            let body: AgentJSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object([
                    "name": .string(name), "arguments": .object(arguments),
                    "_meta": .object([
                        "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
                        "io.modelcontextprotocol/clientInfo": .object([
                            "name": .string("same-name"), "version": .string("1"),
                        ]),
                        "io.modelcontextprotocol/clientCapabilities": .object([:]),
                    ]),
                ]),
            ])
            return await server.handle(
                HTTPRequest(
                    method: "POST", target: "/mcp", version: "HTTP/1.1",
                    headers: [
                        "content-type": "application/json", "mcp-protocol-version": "2026-07-28",
                        "mcp-method": "tools/call", "mcp-name": name,
                    ], body: body.encodedData))
        }
        // Invalid stateful calls must not exhaust the 64-operation capacity.
        for _ in 0..<70 {
            let failed = await call("sftp_upload", [:])
            #expect(failed.status == 200)
            #expect(try responseObject(failed)["result"]?.objectValue?["isError"] == .bool(true))
        }
        let ordinary = await call("list_hosts", [:])
        #expect(try responseObject(ordinary)["result"]?.objectValue?["isError"] == .bool(false))
        let created = await call(
            "sftp_upload",
            [
                "host_id": .string(host.id.uuidString), "remote_path": .string("/tmp/test"),
                "byte_count": .number(0), "sha256": .string(String(repeating: "0", count: 64)),
            ])
        let result = try #require(try responseObject(created)["result"]?.objectValue)
        #expect(result["isError"] == .bool(false))
        let payload = try #require(result["structuredContent"]?.objectValue)
        let handle = try #require(payload["operation_handle"])
        let uploadID = try #require(payload["upload_id"])
        let isolated = await call("sftp_upload_status", ["upload_id": uploadID])
        #expect(try responseObject(isolated)["result"]?.objectValue?["isError"] == .bool(true))
        let failedRelated = await call("sftp_upload", ["operation_handle": handle])
        #expect(try responseObject(failedRelated)["result"]?.objectValue?["isError"] == .bool(true))
        let status = await call("sftp_upload_status", ["upload_id": uploadID, "operation_handle": handle])
        #expect(try responseObject(status)["result"]?.objectValue?["isError"] == .bool(false))
        await server.stop()
        let revoked = await call("sftp_upload_status", ["upload_id": uploadID, "operation_handle": handle])
        #expect(try responseObject(revoked)["error"]?.objectValue?["code"] == .number(-32602))
    }

    @Test
    func modernRequestsAreIndependentAndValidateMirroredHeaders() async throws {
        let server = MCPServerProtocol(tools: makeMCPServerTools())
        func request(_ method: String, mirrored: String? = nil) -> HTTPRequest {
            let body: AgentJSONValue = .object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method),
                "params": .object([
                    "_meta": .object([
                        "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
                        "io.modelcontextprotocol/clientCapabilities": .object([:]),
                    ])
                ]),
            ])
            return HTTPRequest(
                method: "POST", target: "/mcp", version: "HTTP/1.1",
                headers: [
                    "content-type": "application/json", "mcp-protocol-version": "2026-07-28",
                    "mcp-method": mirrored ?? method,
                ], body: body.encodedData)
        }
        let discover = await server.handle(request("server/discover"))
        #expect(discover.status == 200)
        #expect(discover.headers["Mcp-Session-Id"] == nil)
        let result = try #require(try responseObject(discover)["result"]?.objectValue)
        #expect(result["resultType"] == .string("complete"))
        #expect(result["supportedVersions"]?.arrayValue?.count == 4)
        let listed = await server.handle(request("tools/list"))
        #expect(try responseObject(listed)["result"]?.objectValue?["tools"]?.arrayValue?.count == 18)
        let mismatch = await server.handle(request("tools/list", mirrored: "tools/call"))
        #expect(mismatch.status == 400)
        #expect(try responseObject(mismatch)["error"]?.objectValue?["code"] == .number(-32020))
        await server.stop()
    }

    @Test(arguments: ["2024-11-05", "2025-06-18", "2025-11-25"])
    func initializePreservesEachSupportedLegacyVersion(_ version: String) async throws {
        let server = MCPServerProtocol(tools: makeMCPServerTools())
        let response = await server.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(version)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}
                """))
        #expect(response.status == 200)
        #expect(try responseObject(response)["result"]?.objectValue?["protocolVersion"] == .string(version))
        #expect(response.headers["Mcp-Session-Id"] != nil)
        await server.stop()
    }

    @Test
    func streamableHandshakeMintsASessionAndPreservesStringIDs() async throws {
        let protocolServer = MCPServerProtocol(tools: makeMCPServerTools())
        let initialize = await protocolServer.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":"request-001","method":"initialize","params":{
                  "protocolVersion":"1900-01-01","clientInfo":{"name":"Tests","version":"1"},
                  "capabilities":{}
                }}
                """))
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let initialized = try responseObject(initialize)

        #expect(initialized["id"]?.stringValue == "request-001")
        #expect(
            initialized["result"]?.objectValue?["protocolVersion"]?.stringValue
                == "2025-11-25"
        )
        let instructions = try #require(
            initialized["result"]?.objectValue?["instructions"]?.stringValue
        )
        #expect(instructions.contains("request_user_secret"))
        #expect(instructions.contains("stdin_purpose"))
        #expect(instructions.contains("only once"))
        #expect(instructions.contains("not required for SSH login or ordinary commands"))
        #expect(instructions.contains("no open interactive terminal is required"))

        let notification = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                sessionID: sessionID, version: "2025-11-25"
            ))
        #expect(notification.status == 202)

        let listed = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
                sessionID: sessionID, version: "2025-11-25"
            ))
        let tools = try #require(
            try responseObject(listed)["result"]?.objectValue?["tools"]?.arrayValue
        )
        #expect(tools.count == 18)
        let readOnly = Set([
            "list_hosts", "get_metrics", "request_user_secret", "ssh_wait",
            "sftp_list", "sftp_stat", "sftp_read", "sftp_upload_status", "sftp_download", "sftp_download_status",
        ])
        for tool in tools {
            let name = try #require(tool.objectValue?["name"]?.stringValue)
            let hint = tool.objectValue?["annotations"]?.objectValue?["readOnlyHint"]
            #expect(hint == .bool(readOnly.contains(name)), "\(name)")
            if name == "sftp_upload_status" || name == "sftp_download_status" {
                #expect(tool.objectValue?["annotations"]?.objectValue?["openWorldHint"] == .bool(false))
            }
            if name == "sftp_download" {
                let annotations = try #require(tool.objectValue?["annotations"]?.objectValue)
                #expect(annotations["readOnlyHint"] == .bool(true))
                #expect(annotations["destructiveHint"] == .bool(false))
                #expect(annotations["idempotentHint"] == .bool(false))
                #expect(annotations["openWorldHint"] == .bool(true))
            }
            if name == "sftp_copy" {
                let annotations = try #require(tool.objectValue?["annotations"]?.objectValue)
                #expect(annotations["destructiveHint"] == .bool(true))
                #expect(annotations["idempotentHint"] == .bool(false))
                #expect(annotations["openWorldHint"] == .bool(true))
            }
        }
    }

    @Test
    func getMetricsIsListedAndReturnsStructuredCachedData() async throws {
        let host = Host(name: "Monitor", host: "monitor.example")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = TestMetricsReader(
            MetricsSnapshot(capturedAt: now, state: .live, point: MetricsPoint(date: now, cpu: 33)))
        let server = MCPServerProtocol(tools: makeMCPServerTools(hosts: [host], metrics: reader))
        let initialize = await server.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Tests","version":"1"},"capabilities":{}}}"#
            ))
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        let initialized = await server.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                sessionID: sessionID, version: "2025-06-18"
            ))
        #expect(initialized.status == 202)
        let listed = await server.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                sessionID: sessionID, version: "2025-06-18"))
        let tools = try #require(try responseObject(listed)["result"]?.objectValue?["tools"]?.arrayValue)
        let descriptor = try #require(tools.first { $0.objectValue?["name"]?.stringValue == "get_metrics" })
        #expect(descriptor.objectValue?["annotations"]?.objectValue?["readOnlyHint"] == .bool(true))
        let response = await server.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_metrics","arguments":{"host_id":"\(host.id.uuidString)","include":["gpu"]}}}
                """, sessionID: sessionID, version: "2025-06-18"))
        let result = try #require(try responseObject(response)["result"]?.objectValue)
        #expect(result["isError"] == .bool(false))
        let data = try #require(result["structuredContent"]?.objectValue)
        #expect(data["overview"]?.objectValue?["cpu_percent"] == .number(33))
        #expect(data["gpu"]?.objectValue?["status"] == .string("probing"))
        #expect(data["processes"] == nil)
        #expect(reader.reads == [host.id])
    }

    @Test
    func establishedSessionsRequireTheirVersionHeader() async throws {
        let protocolServer = MCPServerProtocol(tools: makeMCPServerTools())
        let initialize = await protocolServer.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
                  "protocolVersion":"2025-06-18","clientInfo":{"name":"Tests","version":"1"},
                  "capabilities":{}
                }}
                """))
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])

        let missing = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#, sessionID: sessionID
            ))
        #expect(missing.status == 400)

        let wrong = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
                sessionID: sessionID, version: MCPClient.legacyVersion
            ))
        #expect(wrong.status == 400)
    }

    @Test
    func malformedToolCallsUseInvalidParams() async throws {
        let protocolServer = MCPServerProtocol(tools: makeMCPServerTools())
        let initialize = await protocolServer.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
                  "protocolVersion":"2025-06-18","clientInfo":{"name":"Tests","version":"1"},
                  "capabilities":{}
                }}
                """))
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        _ = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                sessionID: sessionID, version: "2025-06-18"
            ))

        let response = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"missing","arguments":{}}}"#,
                sessionID: sessionID, version: "2025-06-18"
            ))
        let code = try responseObject(response)["error"]?.objectValue?["code"]?.integerValue
        #expect(code == -32602)
    }

    @Test
    func legacySSEEmitsEndpointBeforeMessages() async throws {
        let protocolServer = MCPServerProtocol(tools: makeMCPServerTools())
        let opened = await protocolServer.handle(
            HTTPRequest(
                method: "GET", target: "/sse", version: "HTTP/1.1", headers: [:], body: Data()
            ))
        guard case .stream(let stream) = opened.body else {
            Issue.record("Expected an SSE stream")
            return
        }
        var iterator = stream.makeAsyncIterator()
        let endpoint = String(decoding: try #require(await iterator.next()), as: UTF8.self)
        #expect(endpoint.hasPrefix("event: endpoint\n"))
        let marker = "sessionId="
        let sessionID = try #require(endpoint.components(separatedBy: marker).last)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let posted = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
                target: "/messages?sessionId=\(sessionID)"
            ))
        #expect(posted.status == 202)
        let message = String(decoding: try #require(await iterator.next()), as: UTF8.self)
        #expect(message.hasPrefix("event: message\n"))
        #expect(message.contains("\"id\":1"))
    }

    @Test(.requiresVisibleWindow)
    func deletingASessionCancelsItsSecretPopupWithoutResurrectingTheSession() async throws {
        let authentication = ExternalAuthCoordinator()
        let protocolServer = MCPServerProtocol(
            tools: makeMCPServerTools(
                externalAuthentication: authentication
            ))
        let initialize = await protocolServer.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
                  "protocolVersion":"2025-06-18","clientInfo":{"name":"Tests","version":"1"},
                  "capabilities":{}
                }}
                """))
        let sessionID = try #require(initialize.headers["Mcp-Session-Id"])
        _ = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                sessionID: sessionID, version: "2025-06-18"
            ))
        let hostID = UUID()
        let call = Task {
            await protocolServer.handle(
                jsonRequest(
                    """
                    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
                      "name":"request_user_secret","arguments":{
                        "prompt":"Password for sudo","host_id":"\(hostID.uuidString)",
                        "consumer_tool":"ssh_exec","purpose":"sudo password"
                      }
                    }}
                    """, sessionID: sessionID, version: "2025-06-18"))
        }
        try await waitForProtocolCondition {
            if case .secret? = authentication.current?.request { return true }
            return false
        }

        let deleted = await protocolServer.handle(
            HTTPRequest(
                method: "DELETE", target: "/mcp", version: "HTTP/1.1",
                headers: [MCPServerProtocol.sessionHeader: sessionID], body: Data()
            ))
        #expect(deleted.status == 200)
        #expect(authentication.current == nil)
        let cancelled = await call.value
        let cancelledResult = try #require(
            responseObject(cancelled)["result"]?.objectValue
        )
        #expect(cancelledResult["isError"]?.boolValue == true)
        #expect(cancelledResult["structuredContent"] == nil)

        let afterCancellation = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
                sessionID: sessionID, version: "2025-06-18"
            ))
        #expect(afterCancellation.status == 404)
    }
}

private func jsonRequest(
    _ json: String, target: String = "/mcp", sessionID: String? = nil,
    version: String? = nil
) -> HTTPRequest {
    var headers = ["content-type": "application/json"]
    if let sessionID { headers[MCPServerProtocol.sessionHeader] = sessionID }
    if let version { headers[MCPServerProtocol.versionHeader] = version }
    return HTTPRequest(
        method: "POST", target: target, version: "HTTP/1.1",
        headers: headers, body: Data(json.utf8)
    )
}

private func responseObject(_ response: HTTPResponse) throws -> [String: AgentJSONValue] {
    guard case .data(let data) = response.body else {
        throw MCPProtocolTestFailure.streamingResponse
    }
    return try #require(try AgentJSONValue.decode(data).objectValue)
}

private enum MCPProtocolTestFailure: Error { case streamingResponse, conditionTimedOut }

@MainActor
private func waitForProtocolCondition(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    throw MCPProtocolTestFailure.conditionTimedOut
}
