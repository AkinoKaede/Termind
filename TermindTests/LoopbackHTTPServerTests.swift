import Foundation
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
        #expect(SettingsKey.defaultMCPServerEnabled == false)
        #expect(SettingsKey.defaultMCPServerPort == 7_391)
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
        "file://localhost",
    ])
    func unsafeOrNonOriginValuesAreRejected(_ origin: String) {
        #expect(!LoopbackHTTPServer.allowedOrigin(origin))
    }

    @Test
    func clientsWithoutAnOriginRemainSupported() {
        #expect(LoopbackHTTPServer.allowedOrigin(nil))
    }
}
