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
                == MCPClient.preferredVersion
        )
        let instructions = try #require(
            initialized["result"]?.objectValue?["instructions"]?.stringValue
        )
        #expect(instructions.contains("request_user_secret"))
        #expect(instructions.contains("stdin_purpose"))
        #expect(instructions.contains("only once"))

        let notification = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                sessionID: sessionID, version: MCPClient.preferredVersion
            ))
        #expect(notification.status == 202)

        let listed = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
                sessionID: sessionID, version: MCPClient.preferredVersion
            ))
        let tools = try #require(
            try responseObject(listed)["result"]?.objectValue?["tools"]?.arrayValue
        )
        #expect(tools.count == 13)
        let readOnly = Set([
            "list_hosts", "get_metrics", "request_user_secret", "ssh_wait",
            "sftp_list", "sftp_stat", "sftp_read",
        ])
        for tool in tools {
            let name = try #require(tool.objectValue?["name"]?.stringValue)
            let hint = tool.objectValue?["annotations"]?.objectValue?["readOnlyHint"]
            #expect(hint == .bool(readOnly.contains(name)), "\(name)")
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
                sessionID: sessionID, version: MCPClient.preferredVersion
            ))
        #expect(initialized.status == 202)
        let listed = await server.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                sessionID: sessionID, version: MCPClient.preferredVersion))
        let tools = try #require(try responseObject(listed)["result"]?.objectValue?["tools"]?.arrayValue)
        let descriptor = try #require(tools.first { $0.objectValue?["name"]?.stringValue == "get_metrics" })
        #expect(descriptor.objectValue?["annotations"]?.objectValue?["readOnlyHint"] == .bool(true))
        let response = await server.handle(
            jsonRequest(
                """
                {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_metrics","arguments":{"host_id":"\(host.id.uuidString)","include":["gpu"]}}}
                """, sessionID: sessionID, version: MCPClient.preferredVersion))
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
                sessionID: sessionID, version: MCPClient.preferredVersion
            ))

        let response = await protocolServer.handle(
            jsonRequest(
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"missing","arguments":{}}}"#,
                sessionID: sessionID, version: MCPClient.preferredVersion
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

    @Test
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
                sessionID: sessionID, version: MCPClient.preferredVersion
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
                    """, sessionID: sessionID, version: MCPClient.preferredVersion))
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
                sessionID: sessionID, version: MCPClient.preferredVersion
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
