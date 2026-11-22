// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

@testable import Termind

@Suite
struct LoopbackHTTPServerTests {
    @Test
    func constructsLoopbackListenersWithoutDuplicatingThePortArgument() async throws {
        let server = LoopbackHTTPServer()

        try await server.start(port: 57_391, token: "test-token") { _ in
            .text(200, "OK")
        }
        await server.stop()
    }

    @Test
    func mcpServerIsOffByDefault() {
        #expect(DesktopSettingsKey.defaultMCPServerEnabled == false)
        #expect(DesktopSettingsKey.defaultMCPServerPort == 7_391)
    }

    @Test
    func bearerTokensAreComparedWithoutLengthTruncation() {
        #expect(LoopbackHTTPServer.constantTimeEqual("same", "same"))
        #expect(!LoopbackHTTPServer.constantTimeEqual("same", "different"))

        // A UInt8 length accumulator used to lose this 256-byte difference.
        let zeroBytes = String(repeating: "\0", count: 256)
        #expect(!LoopbackHTTPServer.constantTimeEqual(zeroBytes, ""))
    }

    @Test(arguments: [
        "http://localhost", "https://localhost:7391",
        "http://127.0.0.1", "http://127.42.1.9:8080", "http://[::1]",
    ])
    func loopbackOriginsAreAllowed(_ origin: String) {
        #expect(LoopbackHTTPServer.allowedOrigin(origin))
    }

    @Test(arguments: [
        "null", "https://example.com", "http://192.168.1.2",
        "http://user@localhost", "http://localhost/path",
        "http://localhost?query", "http://localhost#fragment",
        "file://localhost", "http://127.0.0.1.attacker.com", "http://127.evil.0.0.1",
        "http://127..0.0.1", "http://127.0.0.1.", "http://127.0.0.999",
    ])
    func unsafeOrNonOriginValuesAreRejected(_ origin: String) {
        #expect(!LoopbackHTTPServer.allowedOrigin(origin))
    }

    @Test
    func clientsWithoutAnOriginRemainSupported() {
        #expect(LoopbackHTTPServer.allowedOrigin(nil))
    }

    @Test
    func acceptsMoreThanMaximumConcurrentConnectionsOverItsLifetime() async throws {
        let server = LoopbackHTTPServer()
        var port: UInt16 = 0
        for attempt in 0..<10 {
            let (states, continuation) = AsyncStream<LoopbackHTTPServer.State>.makeStream()
            port = UInt16.random(in: 49_152...60_000)
            try await server.start(
                port: port, token: "lifetime-test-token",
                stateHandler: { continuation.yield($0) },
                handler: { _ in .text(200, "OK", headers: ["Connection": "close"]) }
            )
            var ready = false
            for await state in states {
                if case .ready = state {
                    ready = true
                    break
                }
                if case .failed(let message) = state {
                    await server.stop()
                    if attempt == 9 { throw NSError(domain: message, code: 1) }
                    break
                }
            }
            if ready { break }
        }
        defer { Task { await server.stop() } }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpMaximumConnectionsPerHost = 1
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }

        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let totalRequests = LoopbackHTTPServer.maximumConnections + 12
        for index in 0..<totalRequests {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer lifetime-test-token", forHTTPHeaderField: "Authorization")
            request.setValue("close", forHTTPHeaderField: "Connection")
            let (_, response) = try await client.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200, "Failed on sequential connection #\(index + 1)")
        }
        await server.stop()
    }
}
