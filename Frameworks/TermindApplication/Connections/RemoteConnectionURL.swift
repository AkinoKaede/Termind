import Foundation
import TermindDomain

public nonisolated struct RemoteConnectionURL: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case ssh
        case sftp
        case telnet

        public var defaultPort: Int {
            switch self {
            case .ssh, .sftp: 22
            case .telnet: 23
            }
        }
    }

    public enum SFTPType: String, Equatable, Sendable {
        case binary = "i"
        case directory = "d"
    }

    public var kind: Kind
    public var username: String?
    /// RFC 4248 credentials are advisory. SSH and SFTP URL passwords are rejected.
    public var advisoryPassword: String?
    public var host: String
    public var port: Int
    public var path: String?
    public var sftpType: SFTPType?
    public var hostKeyFingerprint: SSHURIHostKeyFingerprint?

    public init(
        kind: Kind, username: String?, advisoryPassword: String?, host: String, port: Int,
        path: String?, sftpType: SFTPType?, hostKeyFingerprint: SSHURIHostKeyFingerprint?
    ) {
        self.kind = kind
        self.username = username
        self.advisoryPassword = advisoryPassword
        self.host = host
        self.port = port
        self.path = path
        self.sftpType = sftpType
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

public nonisolated struct SSHURIHostKeyFingerprint: Equatable, Sendable {
    public enum Algorithm: String, Equatable, Sendable {
        case rsa = "ssh-rsa"
        case dsa = "ssh-dss"
    }

    public var algorithm: Algorithm
    public var md5: Data

    public init(algorithm: Algorithm, md5: Data) {
        self.algorithm = algorithm
        self.md5 = md5
    }

    public func matches(_ observation: SSHHostKeyObservation) -> Bool {
        let algorithmMatches =
            switch algorithm {
            case .rsa: observation.algorithm == .rsa
            case .dsa: false // The current transport deliberately does not negotiate ssh-dss.
            }
        guard algorithmMatches, let candidate = observation.legacyMD5Fingerprint,
            candidate.count == md5.count
        else { return false }
        return zip(candidate, md5).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public nonisolated enum RemoteConnectionURLParseError: LocalizedError, Equatable, Sendable {
    case unsupportedScheme
    case invalidURL
    case invalidHost
    case invalidPort
    case invalidCredentials
    case invalidFingerprint
    case unsupportedSFTPTextMode
    case unsupportedParameter

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme: String(localized: "This connection link uses an unsupported protocol.")
        case .invalidURL: String(localized: "This connection link is invalid.")
        case .invalidHost: String(localized: "This connection link does not contain a valid host.")
        case .invalidPort: String(localized: "This connection link does not contain a valid port.")
        case .invalidCredentials:
            String(localized: "SSH and SFTP connection links cannot contain passwords.")
        case .invalidFingerprint: String(localized: "This connection link contains an invalid host-key fingerprint.")
        case .unsupportedSFTPTextMode:
            String(localized: "SFTP text transfer mode is not supported.")
        case .unsupportedParameter:
            String(localized: "This connection link contains an unsupported standard parameter.")
        }
    }
}

public nonisolated enum RemoteConnectionURLParser {
    public static func parse(_ url: URL) throws -> RemoteConnectionURL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let rawScheme = components.scheme,
            let kind = RemoteConnectionURL.Kind(rawValue: rawScheme.lowercased())
        else { throw RemoteConnectionURLParseError.unsupportedScheme }
        guard components.query == nil, components.fragment == nil else {
            throw RemoteConnectionURLParseError.invalidURL
        }
        guard var host = components.host, !host.isEmpty else {
            throw RemoteConnectionURLParseError.invalidHost
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
            throw RemoteConnectionURLParseError.invalidHost
        }
        let port = components.port ?? kind.defaultPort
        guard (1...65_535).contains(port) else { throw RemoteConnectionURLParseError.invalidPort }

        let credentials = try parseCredentials(components, kind: kind)
        let resource = try parseResource(components.percentEncodedPath, kind: kind)
        return RemoteConnectionURL(
            kind: kind,
            username: credentials.username,
            advisoryPassword: credentials.password,
            host: host,
            port: port,
            path: resource.path,
            sftpType: resource.type,
            hostKeyFingerprint: credentials.fingerprint
        )
    }

    private static func parseCredentials(
        _ components: URLComponents, kind: RemoteConnectionURL.Kind
    ) throws -> (username: String?, password: String?, fingerprint: SSHURIHostKeyFingerprint?) {
        let password = try decode(components.percentEncodedPassword)
        if kind != .telnet, password != nil { throw RemoteConnectionURLParseError.invalidCredentials }

        guard kind != .telnet else {
            let username = try nonempty(decode(components.percentEncodedUser))
            return (username, try nonempty(password), nil)
        }

        let pieces = (components.percentEncodedUser ?? "").split(
            separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let username = try nonempty(decode(String(pieces.first ?? "")))
        guard pieces.count == 2 else { return (username, nil, nil) }

        var fingerprint: SSHURIHostKeyFingerprint?
        for parameter in pieces[1].split(separator: ",", omittingEmptySubsequences: false) {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty else {
                throw RemoteConnectionURLParseError.invalidURL
            }
            guard pair[0] == "fingerprint" else { continue }
            guard fingerprint == nil else { throw RemoteConnectionURLParseError.invalidFingerprint }
            fingerprint = try parseFingerprint(String(pair[1]))
        }
        return (username, nil, fingerprint)
    }

    private static func parseResource(
        _ encodedPath: String, kind: RemoteConnectionURL.Kind
    ) throws -> (path: String?, type: RemoteConnectionURL.SFTPType?) {
        switch kind {
        case .ssh:
            return (nil, nil)
        case .telnet:
            guard encodedPath.isEmpty || encodedPath == "/" else {
                throw RemoteConnectionURLParseError.invalidURL
            }
            return (nil, nil)
        case .sftp:
            let pathAndParameters = encodedPath.split(
                separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard let decodedPath = try decode(String(pathAndParameters[0])), decodedPath.hasPrefix("/") else {
                throw RemoteConnectionURLParseError.invalidURL
            }
            var type: RemoteConnectionURL.SFTPType?
            if pathAndParameters.count == 2 {
                for parameter in pathAndParameters[1].split(separator: ",", omittingEmptySubsequences: false) {
                    let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2, !pair[0].isEmpty else {
                        throw RemoteConnectionURLParseError.invalidURL
                    }
                    guard pair[0] == "type" else { continue }
                    guard type == nil else { throw RemoteConnectionURLParseError.unsupportedParameter }
                    if pair[1] == "a" { throw RemoteConnectionURLParseError.unsupportedSFTPTextMode }
                    guard let parsed = RemoteConnectionURL.SFTPType(rawValue: String(pair[1])) else {
                        throw RemoteConnectionURLParseError.unsupportedParameter
                    }
                    type = parsed
                }
            }
            return (decodedPath.isEmpty ? "/" : decodedPath, type)
        }
    }

    private static func parseFingerprint(_ value: String) throws -> SSHURIHostKeyFingerprint {
        let algorithm: SSHURIHostKeyFingerprint.Algorithm
        let digest: Substring
        if value.hasPrefix("ssh-rsa-") {
            algorithm = .rsa
            digest = value.dropFirst("ssh-rsa-".count)
        } else if value.hasPrefix("ssh-dss-") {
            algorithm = .dsa
            digest = value.dropFirst("ssh-dss-".count)
        } else {
            throw RemoteConnectionURLParseError.invalidFingerprint
        }
        let octets = digest.split(separator: "-", omittingEmptySubsequences: false)
        guard octets.count == 16 else { throw RemoteConnectionURLParseError.invalidFingerprint }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for octet in octets {
            guard octet.count == 2, let byte = UInt8(octet, radix: 16) else {
                throw RemoteConnectionURLParseError.invalidFingerprint
            }
            bytes.append(byte)
        }
        return SSHURIHostKeyFingerprint(algorithm: algorithm, md5: Data(bytes))
    }

    private static func decode(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let decoded = value.removingPercentEncoding,
            !decoded.contains(where: { $0 == "\0" || $0.isNewline || $0.isASCII && $0.asciiValue! < 0x20 })
        else { throw RemoteConnectionURLParseError.invalidURL }
        return decoded
    }

    private static func nonempty(_ value: String?) throws -> String? {
        guard let value else { return nil }
        return value.isEmpty ? nil : value
    }
}
