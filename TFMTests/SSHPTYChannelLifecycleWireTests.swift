import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

/// Run against Scripts/ssh-pty-lifecycle-fixture.py. The peer deliberately never
/// acknowledges exec CLOSE; disposing the connection must not wait for that reply.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_PTY_LIFECYCLE_FIXTURE"] != nil), .serialized)
@MainActor
struct SSHPTYChannelLifecycleWireTests {
    private struct Fixture: Decodable {
        let port: Int
        let hostFingerprint: String
    }

    @Test func cancelledHistoryCannotKeepAnUnownedTransportAlive() async throws {
        var channel: SSHPTYChannel? = try await connect()
        weak let released = channel
        let token = try await cancelHistoryWhileNativeCloseIsPending(on: channel!)
        await channel!.disconnect()
        await channel!.disconnect()
        // Explicit disconnect must retire the transport even while its public
        // owner is still retained, independently of the deinit safety net.
        try await waitForEvent("transport-closed \(token)")
        channel = nil
        #expect(released == nil)
    }

    @Test func droppingAConnectedPTYWithoutDisconnectRetiresItsSources() async throws {
        var channel: SSHPTYChannel? = try await connect()
        weak let released = channel
        let token = try await cancelHistoryWhileNativeCloseIsPending(on: channel!)
        channel = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while released != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
        try await waitForEvent("transport-closed \(token)")
    }

    @Test func sftpSiblingSurvivesPTYReleaseAndLastCloseDisposesCancelledExec() async throws {
        var channel: SSHPTYChannel? = try await connect()
        var client: (any SFTPChannelProtocol)? = try await channel!.openSFTPChannel()
        let sibling = try await client!.openSiblingChannel()
        let token = try await cancelHistoryWhileNativeCloseIsPending(on: channel!)
        await channel!.disconnect()
        channel = nil
        #expect(try await client!.attributes(at: "/fixture.txt")?.size == 8)
        await client!.disconnect()
        client = nil
        #expect(try await sibling.readFile(at: "/fixture.txt", maximumBytes: 100) == Data("fixture\n".utf8))
        await sibling.disconnect()
        try await waitForEvent("transport-closed \(token)")
    }

    private func cancelHistoryWhileNativeCloseIsPending(on channel: SSHPTYChannel) async throws -> String {
        let token = UUID().uuidString
        let read = Task {
            _ = try? await channel.executeHistoryRead("fixture-stalled-close \(token)", outputLimit: 1024)
        }
        defer { read.cancel() }
        try await waitForEvent("exec \(token)")
        read.cancel()
        await read.value
        // The Swift caller has returned, but the native channel is demonstrably
        // still closing. This is the build 69 crash's lifetime gap.
        try await waitForEvent("close \(token)")
        return token
    }

    private func connect() async throws -> SSHPTYChannel {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_PTY_LIFECYCLE_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let channel = SSHPTYChannel(output: { _ in }, exit: { _ in })
        try await channel.connect(
            using: SSHConnectionRequest(
                configuration: .init(
                    hostID: UUID(), host: "127.0.0.1", port: fixture.port, username: "none",
                    credentials: [], expectedHostKeys: [.init(algorithm: .rsa, fingerprint: fixture.hostFingerprint)])),
            shellIntegrationEnabled: false, columns: 80, rows: 24)
        return channel
    }

    private func waitForEvent(_ event: String) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_PTY_LIFECYCLE_FIXTURE"])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let events = try String(contentsOfFile: path + ".events", encoding: .utf8).split(separator: "\n")
            if events.contains(Substring(event)) { return }
            try #require(ContinuousClock.now < deadline, "SSH fixture did not report \(event)")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
