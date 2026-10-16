import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct TelnetConnectionConfiguration: Sendable {
    public var beforeConnect: ConnectionWakeAction?
    public var hostID: Host.ID
    public var host: String
    public var port: Int
    public var username: String?
    public var password: SSHSecret?
    public var charset: RemoteCharset
    public var proxy: TerminalTransportProxy?

    public init(
        hostID: Host.ID, host: String, port: Int, username: String? = nil,
        password: SSHSecret? = nil, charset: RemoteCharset = .utf8,
        proxy: TerminalTransportProxy? = nil
    ) {
        self.hostID = hostID
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.charset = charset
        self.proxy = proxy
    }

    public func clearSecret() {
        password?.clear()
        proxy?.clearSecret()
    }
}

public nonisolated enum TelnetConnectionEvent: Sendable {
    case openingTransport
    case negotiatingOptions
    case configuringCharset
    case waitingForUsernamePrompt
    case usernameSubmitted
    case waitingForPasswordPrompt
    case passwordSubmitted
    case continuingManually
    case connected
}

public nonisolated enum TelnetConnectionError: LocalizedError, Sendable {
    case unavailable
    case closed
    case invalidConfiguration

    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The Telnet server is unavailable.")
        case .closed: String(localized: "The Telnet connection closed.")
        case .invalidConfiguration: String(localized: "The Telnet configuration is invalid.")
        }
    }
}
