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
