import Foundation
import TermindApplication
import TermindDomain

nonisolated struct QuickConnectInput: Equatable, Sendable {
    struct Endpoint: Equatable, Sendable {
        var host: String
        var username: String?
        var port: Int?
    }

    var destination: Endpoint
    var hostname: String?
    /// nil inherits the saved route; an empty array explicitly clears it.
    var jumps: [Endpoint]?
    var isCommand: Bool
    var connectionProtocol: HostTerminalProtocol = .ssh
}

nonisolated enum QuickConnectParseResult: Equatable, Sendable {
    case search
    case incomplete(String)
    case connection(QuickConnectInput)
    case invalid(String)
}

/// A small SSH argument parser, never a shell evaluator or an OpenSSH launcher.
nonisolated enum QuickConnectParser {
    static func isCommand(_ input: String) -> Bool {
        let first = input.split(whereSeparator: \.isWhitespace).first
        return first == "ssh" || first == "/usr/bin/ssh"
            || first == "telnet" || first == "/usr/bin/telnet"
    }

    static func parse(_ input: String, locale: Locale = .current) -> QuickConnectParseResult {
        let first = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).first
        if first == "telnet" || first == "/usr/bin/telnet" {
            return TelnetInputParser(locale: locale).parse(input)
        }
        return SSHInputParser(locale: locale).parse(input)
    }
}

private nonisolated struct TelnetInputParser {
    let locale: Locale

    private func message(_ key: String.LocalizationValue) -> String {
        AppLocalization.string(key, locale: locale)
    }

    func parse(_ input: String) -> QuickConnectParseResult {
        do {
            let tokens = try tokenize(input.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !tokens.isEmpty else { return .search }
            var index = 1
            var username: String?
            if index < tokens.count, tokens[index].hasPrefix("-l") {
                let option = tokens[index]
                index += 1
                if option == "-l" {
                    guard index < tokens.count else {
                        return .incomplete(message("Enter a value for -l."))
                    }
                    username = tokens[index]
                    index += 1
                } else {
                    username = String(option.dropFirst(2))
                }
                guard username?.isEmpty == false else {
                    return .invalid(message("Invalid Telnet destination."))
                }
            } else if index < tokens.count, tokens[index].hasPrefix("-") {
                return .invalid(message("Unsupported Telnet option: \(tokens[index])."))
            }
            guard index < tokens.count else {
                return .incomplete(message("Enter a Telnet destination."))
            }
            var host = tokens[index]
            index += 1
            if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            guard validHost(host) else { return .invalid(message("Invalid Telnet destination.")) }
            var port: Int?
            if index < tokens.count {
                let value = tokens[index]
                index += 1
                guard value.allSatisfy({ $0.isASCII && $0.isNumber }),
                    let parsed = Int(value), (1...65_535).contains(parsed)
                else { return .invalid(message("Invalid Telnet port.")) }
                port = parsed
            }
            guard index == tokens.count else {
                return .invalid(message("Remote commands are not supported here."))
            }
            return .connection(
                QuickConnectInput(
                    destination: .init(host: host, username: username, port: port),
                    isCommand: true, connectionProtocol: .telnet))
        } catch let failure as Failure {
            switch failure {
            case .incomplete(let value): return .incomplete(value)
            case .invalid(let value): return .invalid(value)
            }
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private enum Failure: Error {
        case incomplete(String)
        case invalid(String)
    }

    private func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = []
        var token = ""
        var started = false
        var quote: Character?
        var escaping = false
        for character in text {
            if escaping {
                token.append(character)
                escaping = false
            } else if character == "\\", quote != "'" {
                escaping = true
                started = true
            } else if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { tokens.append(token) }
                token = ""
                started = false
            } else if ";|&<>`$".contains(character) {
                throw Failure.invalid(message("Shell expressions are not supported here."))
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil, !escaping else {
            throw Failure.incomplete(message("Finish the quoted or escaped argument."))
        }
        if started { tokens.append(token) }
        return tokens
    }

    private func validHost(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-")
            && value.contains(where: { $0.isLetter || $0.isNumber })
            && !value.contains(where: { $0.isNewline || "/@[];|&<>`$\\".contains($0) })
    }
}

private nonisolated struct SSHInputParser {
    let locale: Locale

    private func message(_ key: String.LocalizationValue) -> String {
        AppLocalization.string(key, locale: locale)
    }

    func parse(_ input: String) -> QuickConnectParseResult {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .search }
        let command = QuickConnectParser.isCommand(text)
        do {
            if !command {
                guard !text.contains(where: \.isWhitespace) else { return .search }
                guard let destination = try? endpoint(text) else { return .search }
                return .connection(QuickConnectInput(destination: destination, isCommand: false))
            }
            let tokens = try tokenize(text)
            var index = 1
            var destination: QuickConnectInput.Endpoint?
            var username: String?
            var port: Int?
            var hostname: String?
            var jumps: [QuickConnectInput.Endpoint]?
            var optionsEnded = false
            while index < tokens.count {
                let token = tokens[index]
                index += 1
                if token == "--", !optionsEnded {
                    optionsEnded = true
                    continue
                }
                if token.hasPrefix("-"), !optionsEnded {
                    guard token.count >= 2 else { throw Failure.invalid(unsupported(token)) }
                    let option = token[token.index(after: token.startIndex)]
                    guard "plJo".contains(option) else { throw Failure.invalid(unsupported(token)) }
                    let attached = String(token.dropFirst(2))
                    let value: String
                    if !attached.isEmpty {
                        value = attached
                    } else {
                        guard index < tokens.count else {
                            throw Failure.incomplete(message("Enter a value for \(token)."))
                        }
                        value = tokens[index]
                        index += 1
                    }
                    switch option {
                    case "p":
                        let parsed = try parsePort(value)
                        if port == nil { port = parsed }
                    case "l":
                        try validateUsername(value)
                        if username == nil { username = value }
                    case "J":
                        guard jumps == nil else {
                            throw Failure.invalid(
                                message("Use one -J option with comma-separated jump hosts."))
                        }
                        jumps = try parseJumps(value)
                    default:
                        let pair = value.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
                        guard let key = pair.first else { throw Failure.invalid(unsupported("-o")) }
                        let name = key.lowercased()
                        guard ["hostname", "user", "port", "proxyjump"].contains(name) else {
                            throw Failure.invalid(unsupported("-o \(key)"))
                        }
                        guard pair.count == 2 else {
                            throw Failure.incomplete(message("Enter a value for \(key)."))
                        }
                        let argument = pair[1].trimmingCharacters(in: .whitespaces)
                        guard !argument.isEmpty else {
                            throw Failure.incomplete(message("Enter a value for \(key)."))
                        }
                        switch name {
                        case "hostname":
                            try validateHost(argument)
                            if hostname == nil { hostname = argument }
                        case "user":
                            try validateUsername(argument)
                            if username == nil { username = argument }
                        case "port":
                            let parsed = try parsePort(argument)
                            if port == nil { port = parsed }
                        default:
                            let parsed = try parseJumps(argument)
                            if jumps == nil { jumps = parsed }
                        }
                    }
                } else {
                    guard destination == nil else {
                        throw Failure.invalid(message("Remote commands are not supported here."))
                    }
                    let parsed = try endpoint(token)
                    destination = parsed
                    if username == nil { username = parsed.username }
                }
            }
            guard var destination else {
                throw Failure.incomplete(message("Enter an SSH destination."))
            }
            destination.username = username
            destination.port = port ?? destination.port
            return .connection(
                QuickConnectInput(destination: destination, hostname: hostname, jumps: jumps, isCommand: true)
            )
        } catch Failure.incomplete(let message) {
            return .incomplete(message)
        } catch Failure.invalid(let message) {
            return .invalid(message)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private enum Failure: Error {
        case incomplete(String)
        case invalid(String)
    }

    private func unsupported(_ option: String) -> String {
        message("Unsupported SSH option: \(option).")
    }

    private func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = []
        var token = ""
        var started = false
        var quote: Character?
        var escaping = false
        for character in text {
            if escaping {
                if quote == "\"", character != "\"", character != "\\", character != "$", character != "`" {
                    token.append("\\")
                }
                token.append(character)
                escaping = false
            } else if character == "\\", quote != "'" {
                escaping = true
                started = true
            } else if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { tokens.append(token) }
                token = ""
                started = false
            } else if ";|&<>`$".contains(character) {
                throw Failure.invalid(message("Shell expressions are not supported here."))
            } else {
                token.append(character)
                started = true
            }
        }
        guard quote == nil, !escaping else {
            throw Failure.incomplete(message("Finish the quoted or escaped argument."))
        }
        if started { tokens.append(token) }
        return tokens
    }

    private func endpoint(_ text: String) throws -> QuickConnectInput.Endpoint {
        var remainder = text
        var username: String?
        if let at = remainder.lastIndex(of: "@") {
            username = String(remainder[..<at])
            if let username { try validateUsername(username) }
            remainder = String(remainder[remainder.index(after: at)...])
        }
        var port: Int?
        if remainder.hasPrefix("[") {
            guard let end = remainder.firstIndex(of: "]") else {
                throw Failure.incomplete(message("Finish the bracketed IPv6 address."))
            }
            let suffix = remainder[remainder.index(after: end)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":") else { throw invalidDestination() }
                port = try parsePort(String(suffix.dropFirst()))
            }
            remainder = String(remainder[remainder.index(after: remainder.startIndex)..<end])
        } else if remainder.filter({ $0 == ":" }).count == 1, let colon = remainder.firstIndex(of: ":") {
            port = try parsePort(String(remainder[remainder.index(after: colon)...]))
            remainder = String(remainder[..<colon])
        }
        try validateHost(remainder)
        return QuickConnectInput.Endpoint(host: remainder, username: username, port: port)
    }

    private func parsePort(_ value: String) throws -> Int {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
            let port = Int(value), (1...65_535).contains(port)
        else { throw Failure.invalid(message("Invalid SSH port.")) }
        return port
    }

    private func validateUsername(_ value: String) throws {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !value.contains(where: { $0.isWhitespace || ";|&<>`$".contains($0) })
        else {
            throw invalidDestination()
        }
    }

    private func validateHost(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            value.contains(where: { $0.isLetter || $0.isNumber }),
            !value.contains(where: { $0.isNewline || "/@[];|&<>`$\\".contains($0) })
        else { throw invalidDestination() }
    }

    private func parseJumps(_ value: String) throws -> [QuickConnectInput.Endpoint] {
        if value == "none" { return [] }
        return try value.split(separator: ",", omittingEmptySubsequences: false).map { try endpoint(String($0)) }
    }

    private func invalidDestination() -> Failure {
        .invalid(message("Invalid SSH destination."))
    }
}
