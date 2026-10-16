import CSSH2
import Foundation
import TermindApplication
import TermindDomain

nonisolated enum SSHTailscaleAuthentication {
    enum Step: Equatable, Sendable {
        case authenticated
        case methods(Set<String>)
        case pending(String?)
    }

    static func isTailscaleServer(_ banner: String?) -> Bool {
        guard let banner, banner.hasPrefix("SSH-2.0-") else { return false }
        let software = banner.dropFirst("SSH-2.0-".count).split(whereSeparator: \.isWhitespace).first ?? ""
        return software == "Tailscale" || software.hasPrefix("Tailscale_")
    }

    static func query(
        username: String, session: OpaquePointer, exchange: SSHKeyboardInteractiveExchange?
    ) throws -> Step {
        let blocking = libssh2_session_get_blocking(session)
        let readTimeout = libssh2_session_get_read_timeout(session)
        libssh2_session_set_blocking(session, 0)
        // The application deadline owns approval expiry, not the default 60-second packet timeout.
        libssh2_session_set_read_timeout(session, max(readTimeout, 601))
        defer {
            libssh2_session_set_blocking(session, blocking)
            libssh2_session_set_read_timeout(session, readTimeout)
        }
        return try run(exchange: exchange) {
            let methods = username.withCString { libssh2_userauth_list(session, $0, UInt32(username.utf8.count)) }
            if libssh2_userauth_authenticated(session) != 0 { return .authenticated }
            if let methods {
                return .methods(Set(String(cString: methods).split(separator: ",").map(String.init)))
            }
            // Reading a missing banner changes last_errno, so capture the authentication result first.
            let code = libssh2_session_last_errno(session)
            guard code == LIBSSH2_ERROR_EAGAIN else {
                throw failure(code: code)
            }
            var banner: UnsafeMutablePointer<CChar>?
            _ = libssh2_userauth_banner(session, &banner)
            return .pending(banner.map { String(cString: $0) })
        }
    }

    static func run(
        exchange: SSHKeyboardInteractiveExchange?,
        timeout: Duration = .seconds(600),
        now: () -> ContinuousClock.Instant = { .now },
        pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
        step: () throws -> Step
    ) throws -> Step {
        let deadline = now().advanced(by: timeout)
        var presentedBanners: Set<String> = []
        defer { exchange?.endTailscaleApproval() }
        while true {
            try exchange?.checkTailscaleApproval()
            guard now() < deadline else { throw TailscaleConfigurationError.approvalTimedOut }
            let result = try step()
            try exchange?.checkTailscaleApproval()
            switch result {
            case .authenticated, .methods:
                return result
            case .pending(let banner):
                if let banner, !banner.isEmpty, presentedBanners.insert(banner).inserted {
                    guard let exchange else { throw SSHInteractionRequired() }
                    try exchange.presentTailscaleApproval(banner)
                }
                pause()
            }
        }
    }

    static func failure(code: Int32) -> TermindSSHError {
        // Authentication banners may contain one-time approval URLs; keep them out of errors and logs.
        .authenticationFailed(String(localized: "Tailscale SSH authentication failed.") + " [libssh2 \(code)]")
    }
}
