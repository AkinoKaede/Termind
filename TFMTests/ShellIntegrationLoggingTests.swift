// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Logging
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct ShellIntegrationLoggingTests {
    @Test
    func lifecycleLogsAreCorrelatedAndExcludeRemoteValues() throws {
        let capture = ShellIntegrationLogCapture()
        let logger = Logger(label: "termind.shell-integration-test") { _ in
            ShellIntegrationCaptureHandler(capture: capture)
        }
        let hostID = UUID()
        var lifecycle = RemoteShellIntegrationLifecycleLogger(logger: logger)
        lifecycle.begin(hostID: hostID, enabled: true)

        var bootstrap = RemoteShellIntegrationBootstrap(token: "LOGGING")
        _ = bootstrap.receive(
            Data(
                ("__TRMD_LOGGING_SYSTEM__sensitive-system||1|SensitiveKernel|1|arm64__\r\n"
                    + "__TRMD_LOGGING_SHELL__/sensitive/shell/bash__\r\n").utf8
            )
        )
        let completed = bootstrap.receive(
            Data(
                "__TRMD_LOGGING_HOME__%2Fsensitive%2Fhome\r\n__TRMD_LOGGING_DONE__\r\n".utf8
            )
        )
        lifecycle.record(try #require(completed.diagnostic), hostID: hostID)
        lifecycle.sessionEnded(hostID: hostID)

        let entries = capture.entries
        try #require(entries.map(\.message) == ["ssh.shell_integration.started", "ssh.shell_integration.completed"])
        #expect(entries.map(\.level) == [.info, .info])
        #expect(entries[1].metadata["outcome"] == "success")
        #expect(entries[1].metadata["home_resolution"] == "resolved")
        #expect(entries[1].metadata["system_info"] == "available")
        #expect(entries[0].metadata["operation_id"] == entries[1].metadata["operation_id"])
        #expect(entries.allSatisfy { $0.metadata["host_id"] == hostID.uuidString.lowercased() })
        let serialized = entries.map { "\($0.message) \($0.metadata)" }.joined(separator: "\n")
        #expect(!serialized.localizedCaseInsensitiveContains("sensitive"))
        #expect(!serialized.contains("LOGGING"))
    }

    @Test
    func delayedTimeoutDisabledAndSessionEndUseStableReasonsWithoutDuplicates() {
        let capture = ShellIntegrationLogCapture()
        let logger = Logger(label: "termind.shell-integration-test") { _ in
            ShellIntegrationCaptureHandler(capture: capture)
        }
        let hostID = UUID()
        var lifecycle = RemoteShellIntegrationLifecycleLogger(logger: logger)

        lifecycle.begin(hostID: hostID, enabled: false)
        lifecycle.begin(hostID: hostID, enabled: true)
        lifecycle.record(.probeDelayed, hostID: hostID)
        lifecycle.record(.timedOut(stage: .installation, late: true), hostID: hostID)
        lifecycle.sessionEnded(hostID: hostID)
        lifecycle.begin(hostID: hostID, enabled: true)
        lifecycle.sessionEnded(hostID: hostID)
        lifecycle.sessionEnded(hostID: hostID)

        let entries = capture.entries
        #expect(
            entries.map(\.message) == [
                "ssh.shell_integration.skipped",
                "ssh.shell_integration.started",
                "ssh.shell_integration.delayed",
                "ssh.shell_integration.timed_out",
                "ssh.shell_integration.started",
                "ssh.shell_integration.skipped",
            ])
        #expect(entries.map(\.level) == [.info, .info, .warning, .warning, .info, .info])
        #expect(entries[0].metadata["reason"] == "disabled")
        #expect(entries[2].metadata["reason"] == "probe_timeout")
        #expect(entries[3].metadata["reason"] == "timeout")
        #expect(entries[3].metadata["stage"] == "installation")
        #expect(entries[5].metadata["reason"] == "session_ended")
    }
}

private nonisolated struct ShellIntegrationLogEntry: Sendable {
    let level: Logger.Level
    let message: String
    let metadata: [String: String]
}

private nonisolated final class ShellIntegrationLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ShellIntegrationLogEntry] = []

    var entries: [ShellIntegrationLogEntry] { lock.withLock { storage } }

    func append(_ event: LogEvent, metadata: Logger.Metadata) {
        lock.withLock {
            storage.append(
                ShellIntegrationLogEntry(
                    level: event.level,
                    message: event.message.description,
                    metadata: metadata.mapValues(\.description)
                )
            )
        }
    }
}

private nonisolated struct ShellIntegrationCaptureHandler: LogHandler {
    let capture: ShellIntegrationLogCapture
    var metadataProvider: Logger.MetadataProvider?
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var combined = metadata
        if let provided = metadataProvider?.get() {
            combined.merge(provided) { _, provided in provided }
        }
        if let explicit = event.metadata {
            combined.merge(explicit) { _, explicit in explicit }
        }
        capture.append(event, metadata: combined)
    }
}
