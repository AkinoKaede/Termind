import Foundation
import Logging
import TermindApplication
import TermindDomain

nonisolated enum RemoteLogging {
    static func hostID(_ id: UUID) -> Logger.Metadata.Value {
        "\(id.uuidString.lowercased())"
    }

    static func errorCode(_ error: any Error) -> Logger.Metadata.Value {
        if error is CancellationError { return "cancelled" }
        if error is SSHInteractionRequired { return "interaction_required" }
        guard let error = error as? TermindSSHError else { return "unexpected" }
        switch error {
        case .socket: return "socket"
        case .proxy: return "proxy"
        case .proxyAuthentication: return "proxy_authentication"
        case .route: return "route"
        case .routeHost(_, let authentication, _, let hostKey, _):
            if authentication { return "route_authentication" }
            if hostKey { return "route_host_key" }
            return "route"
        case .library: return "library"
        case .handshake(let failure): return "handshake_\(failure.kind.rawValue)"
        case .authenticationFailed: return "authentication_failed"
        case .hostKeyChanged: return "host_key_changed"
        case .missingCredential: return "missing_credential"
        case .keyPassphraseRequired: return "passphrase_required"
        case .missingUsername: return "missing_username"
        case .untrustedHost: return "untrusted_host"
        case .mismatchedHostKey: return "mismatched_host_key"
        case .disconnected: return "disconnected"
        }
    }

    static func forwardingKind(_ kind: PortForwardingRule.Kind) -> Logger.Metadata.Value {
        switch kind {
        case .local: "local"
        case .remote: "remote"
        case .dynamic: "dynamic"
        }
    }
}

nonisolated struct RemoteShellIntegrationLifecycleLogger: Sendable {
    private let logger: Logger
    private var operationID: String?

    init(logger: Logger) {
        self.logger = logger
    }

    mutating func begin(hostID: UUID, enabled: Bool) {
        let operationID = UUID().uuidString.lowercased()
        if enabled {
            self.operationID = operationID
            logger.info(
                "ssh.shell_integration.started",
                metadata: metadata(
                    hostID: hostID, operationID: operationID,
                    stage: "probing", outcome: "pending"
                )
            )
        } else {
            logger.info(
                "ssh.shell_integration.skipped",
                metadata: metadata(
                    hostID: hostID, operationID: operationID,
                    stage: "configuration", outcome: "skipped",
                    reason: "disabled"
                )
            )
        }
    }

    mutating func record(
        _ diagnostic: RemoteShellIntegrationBootstrap.Diagnostic,
        hostID: UUID
    ) {
        guard let operationID else { return }
        switch diagnostic {
        case .probeDelayed:
            logger.warning(
                "ssh.shell_integration.delayed",
                metadata: metadata(
                    hostID: hostID, operationID: operationID,
                    stage: "probing", outcome: "pending",
                    reason: "probe_timeout"
                )
            )
        case .installed(let late, let homeResolved, let systemInfoAvailable):
            var fields = metadata(
                hostID: hostID, operationID: operationID,
                stage: "completed", outcome: "success"
            )
            fields["home_resolution"] = homeResolved ? "resolved" : "unavailable"
            fields["late"] = "\(late)"
            fields["system_info"] = systemInfoAvailable ? "available" : "unavailable"
            logger.info("ssh.shell_integration.completed", metadata: fields)
            self.operationID = nil
        case .skipped(let reason):
            logger.info(
                "ssh.shell_integration.skipped",
                metadata: metadata(
                    hostID: hostID, operationID: operationID,
                    stage: "completed", outcome: "skipped",
                    reason: reason.rawValue
                )
            )
            self.operationID = nil
        case .timedOut(let stage, let late):
            var fields = metadata(
                hostID: hostID, operationID: operationID,
                stage: stage.rawValue, outcome: "failure",
                reason: "timeout"
            )
            fields["late"] = "\(late)"
            logger.warning("ssh.shell_integration.timed_out", metadata: fields)
            self.operationID = nil
        }
    }

    mutating func sessionEnded(hostID: UUID) {
        guard let operationID else { return }
        logger.info(
            "ssh.shell_integration.skipped",
            metadata: metadata(
                hostID: hostID, operationID: operationID,
                stage: "completed", outcome: "skipped",
                reason: "session_ended"
            )
        )
        self.operationID = nil
    }

    private func metadata(
        hostID: UUID, operationID: String, stage: String,
        outcome: String, reason: String? = nil
    ) -> Logger.Metadata {
        var fields: Logger.Metadata = [
            "host_id": RemoteLogging.hostID(hostID),
            "operation_id": "\(operationID)",
            "outcome": "\(outcome)",
            "protocol": "ssh",
            "stage": "\(stage)",
        ]
        if let reason { fields["reason"] = "\(reason)" }
        return fields
    }
}
