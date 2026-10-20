// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

public nonisolated enum SSHImportContentKind: Equatable, Sendable {
    case privateKey
    case userCertificate
    case knownHosts
    case configuration
    case unknown
}

public nonisolated enum SSHImportParser {
    private static let privateKeyHeaders = [
        "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----",
        "-----BEGIN EC PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN ENCRYPTED PRIVATE KEY-----", "-----BEGIN DSA PRIVATE KEY-----",
    ]

    /// Classifies OpenSSH text by syntax rather than by the path that contains it.
    /// Private material wins before the line-oriented formats so a PEM body can
    /// never be mistaken for a configuration file.
    public static func contentKind(_ text: String) -> SSHImportContentKind {
        if privateKeyHeaders.contains(where: { text.hasPrefix($0) }) { return .privateKey }

        let meaningful = text.components(separatedBy: .newlines).compactMap { raw -> [String]? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return (try? tokens(raw)).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard !meaningful.isEmpty else { return .unknown }

        if meaningful.contains(where: { fields in
            fields.first?.contains("-cert-v01@openssh.com") == true && fields.count >= 2
        }) {
            return .userCertificate
        }
        if meaningful.contains(where: resemblesKnownHostRecord) { return .knownHosts }
        if meaningful.contains(where: { fields in
            fields.first.map { configurationKeywords.contains($0.lowercased()) } == true
        }) {
            return .configuration
        }
        return .unknown
    }

    private static func resemblesKnownHostRecord(_ fields: [String]) -> Bool {
        let algorithmIndex = fields.first?.hasPrefix("@") == true ? 2 : 1
        guard fields.indices.contains(algorithmIndex), fields.indices.contains(algorithmIndex + 1) else {
            return false
        }
        let algorithm = fields[algorithmIndex]
        return algorithm.hasPrefix("ssh-") || algorithm.hasPrefix("ecdsa-") || algorithm.hasPrefix("sk-")
    }

    /// Includes the directives Termind evaluates plus common OpenSSH options.
    /// Seeing any of these is enough to treat the file as configuration; the
    /// parser still reports unsupported directives as warnings.
    private static let configurationKeywords: Set<String> = [
        "addkeystoagent", "addressfamily", "batchmode", "bindaddress", "bindinterface",
        "canonicaldomains", "canonicalizefallbacklocal", "canonicalizehostname", "canonicalizemaxdots",
        "canonicalizepermittedcnames", "casignaturealgorithms", "certificatefile", "checkhostip", "ciphers",
        "clearallforwardings", "compression", "connectionattempts", "connecttimeout", "controlmaster",
        "controlpath", "controlpersist", "dynamicforward", "enableescapecommandline", "enablesshkeysign",
        "escapechar", "exitonforwardfailure", "fingerprinthash", "forkafterauthentication", "forwardagent",
        "forwardx11", "forwardx11timeout", "forwardx11trusted", "gatewayports", "globalknownhostsfile",
        "gssapiauthentication", "gssapidelegatecredentials", "hashknownhosts", "host", "hostbasedauthentication",
        "hostkeyalgorithms", "hostname", "identitiesonly", "identityagent", "identityfile", "ignoreunknown",
        "include", "ipqos", "kbdinteractiveauthentication", "kexalgorithms", "knownhostscommand", "localcommand",
        "localforward", "loglevel", "logverbose", "macs", "match", "nohostauthenticationforlocalhost",
        "numberofpasswordprompts", "obscurekeystroketiming", "passwordauthentication", "permitlocalcommand",
        "permitremoteopen", "pkcs11provider", "port", "preferredauthentications", "proxycommand", "proxyjump",
        "proxyusefdpass", "pubkeyacceptedalgorithms", "pubkeyauthentication", "remoteforward",
        "rekeylimit", "requesttty", "requiredrsasize", "sendenv", "serveralivecountmax", "serveraliveinterval",
        "sessiontype",
        "setenv", "stdinnull", "streamlocalbindmask", "streamlocalbindunlink", "stricthostkeychecking",
        "syslogfacility",
        "tcpkeepalive", "tunnel", "tunneldevice", "updatehostkeys", "user", "userknownhostsfile", "verifyhostkeydns",
        "visualhostkey", "xauthlocation",
    ]

    /// Tokenizes OpenSSH's quoted arguments without invoking a shell.
    public static func tokens(_ line: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                token.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", token.isEmpty {
                break
            } else if character.isWhitespace
                || (character == "=" && (result.isEmpty || (result.count == 1 && token.isEmpty)))
            {
                if !token.isEmpty {
                    result.append(token)
                    token = ""
                }
            } else {
                token.append(character)
            }
        }
        guard quote == nil, !escaping else { throw CocoaError(.fileReadCorruptFile) }
        if !token.isEmpty { result.append(token) }
        return result
    }

    public static func glob(_ pattern: String, matches value: String, path: Bool = false) -> Bool {
        let expression =
            "^"
            + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: path ? "[^/]*" : ".*").replacingOccurrences(
                of: "\\?", with: path ? "[^/]" : ".") + "$"
        return value.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func matches(_ patterns: [String], alias: String) -> Bool {
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), matches: alias) { return false }
            } else if glob(pattern, matches: alias) {
                positive = true
            }
        }
        return positive
    }

    public static func concrete(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.contains(where: { "*?!".contains($0) })
    }

    public static func endpoint(_ value: String) -> (String, Int)? {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"),
                value[value.index(after: close)...].hasPrefix(":"),
                let port = Int(value[value.index(close, offsetBy: 2)...]), (1...65_535).contains(port)
            else { return nil }
            return (String(value[value.index(after: value.startIndex)..<close]), port)
        }
        guard !value.isEmpty else { return nil }
        return (value, 22)
    }

    public static func knownHosts(_ text: String, source: String) -> [SSHImportItem] {
        var result: [SSHImportItem] = []
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            let location = "\(source):\(offset + 1)"
            do {
                guard !first.hasPrefix("@") else { throw ImportParseError.unsupported }
                guard fields.count >= 3, let algorithm = SSHKeyAlgorithm(rawValue: fields[1]),
                    let blob = Data(base64Encoded: fields[2]), validPublicKey(blob, algorithm: algorithm)
                else { throw ImportParseError.invalid }
                let fingerprint =
                    "SHA256:"
                    + Data(SHA256.hash(data: blob)).base64EncodedString()
                    .replacingOccurrences(of: "=", with: "")
                let addresses = first.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                // Negation belongs to the whole pattern list, not to one split entry.
                guard !addresses.contains(where: { $0.contains(where: { "*!?".contains($0) }) }) else {
                    throw ImportParseError.unsupported
                }
                for address in addresses {
                    let endpoint = address.hasPrefix("|") ? (address, 22) : endpoint(address)
                    guard let (hostname, port) = endpoint else { throw ImportParseError.invalid }
                    let entry = KnownHostEntry(
                        hostname: hostname, port: port, algorithm: algorithm, fingerprint: fingerprint, addedAt: Date()
                    )
                    guard entry.isValid else { throw ImportParseError.invalid }
                    result.append(
                        SSHImportItem(
                            category: .knownHosts, name: entry.displayAddress, source: location, knownHost: entry
                        ))
                }
            } catch {
                result.append(
                    SSHImportItem(
                        category: .knownHosts, name: first, source: location, selected: false,
                        issue: error.localizedDescription, unavailable: true
                    ))
            }
        }
        return result
    }

    /// Validate the wire key structure as well as its outer algorithm label.
    public static func validPublicKey(_ blob: Data, algorithm: SSHKeyAlgorithm) -> Bool {
        var cursor = 0
        func field() -> Data? {
            guard cursor + 4 <= blob.count else { return nil }
            let length = blob[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            cursor += 4
            guard Int(length) <= blob.count - cursor else { return nil }
            defer { cursor += Int(length) }
            return blob.subdata(in: cursor..<cursor + Int(length))
        }
        guard let name = field(), String(data: name, encoding: .utf8) == algorithm.rawValue else { return false }
        switch algorithm {
        case .unknown: return false
        case .securityKey:
            guard field() == Data("nistp256".utf8), let point = field(), point.count == 65,
                point.first == 4, let application = field(), !application.isEmpty
            else { return false }
        case .ed25519:
            guard field()?.count == 32 else { return false }
        case .rsa:
            guard let exponent = field(), !exponent.isEmpty, let modulus = field(), !modulus.isEmpty else {
                return false
            }
        case .ecdsa256, .ecdsa384, .ecdsa521:
            let curve = algorithm.rawValue.replacingOccurrences(of: "ecdsa-sha2-", with: "")
            guard let name = field(), String(data: name, encoding: .utf8) == curve,
                let point = field(), point.first == 4,
                point.count == (algorithm == .ecdsa256 ? 65 : algorithm == .ecdsa384 ? 97 : 133)
            else { return false }
        }
        return cursor == blob.count
    }
}

public nonisolated enum ImportParseError: LocalizedError {
    case invalid, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Invalid SSH record.")
        case .unsupported: String(localized: "This SSH record is not supported.")
        }
    }
}
