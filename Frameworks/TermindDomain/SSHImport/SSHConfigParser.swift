// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Evaluates each concrete alias against the original ordered file tree.
/// Includes share the current Host/Match scope, just as textual configuration does.
public nonisolated struct SSHConfigParser {
    public let root: URL
    public let home: URL
    public let username: String
    public let files: [String: String]
    public let entryPaths: [String]
    public var externalPaths: Set<String> = []
    public var diagnostics: [SSHImportItem] = []

    public func expandedPath(_ path: String, host: SSHImportedHost? = nil) -> String {
        var value = path
        let replacements = [
            "%d": home.path, "%u": username, "%h": host?.hostname ?? "",
            "%n": host?.alias ?? "", "%r": host?.username ?? username,
            "%p": String(host?.port ?? 22),
        ]
        value = value.replacingOccurrences(of: "%%", with: "\u{1}")
        for (token, replacement) in replacements { value = value.replacingOccurrences(of: token, with: replacement) }
        value = value.replacingOccurrences(of: "\u{1}", with: "%")
        if value == "~/.ssh" {
            value = root.path
        } else if value.hasPrefix("~/.ssh/") {
            value = root.appendingPathComponent(String(value.dropFirst(7))).path
        } else if value.hasPrefix("~/") {
            value = home.appendingPathComponent(String(value.dropFirst(2))).path
        }
        if !value.hasPrefix("/") { value = root.appendingPathComponent(value).path }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    public mutating func parse() -> [SSHImportItem] {
        var result: [SSHImportItem] = []
        for config in rootEntryPaths() {
            var aliases: [String] = []
            discover(config, stack: [], aliases: &aliases)
            for alias in aliases {
                var state = Evaluation()
                state.warnings = diagnostics.map { $0.source + ": " + $0.issue }
                evaluate(config, alias: alias, stack: [], state: &state)
                var host = SSHImportedHost(
                    alias: alias, hostname: state.values["hostname"] ?? alias,
                    username: state.values["user"] ?? username)
                host.hostname = host.hostname.replacingOccurrences(of: "%h", with: alias).replacingOccurrences(
                    of: "%n", with: alias)
                var issue = ""
                if let value = state.values["port"] {
                    if let port = Int(value), (1...65_535).contains(port) {
                        host.port = port
                    } else {
                        issue = String(localized: "Invalid SSH port.")
                    }
                }
                let identities =
                    state.identities.isEmpty
                    ? ["~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ed25519"] : state.identities
                host.usesDefaultIdentityFiles = state.identities.isEmpty
                host.identityPaths = identities.filter { $0 != "none" }.map { expandedPath($0, host: host) }
                host.certificatePaths = state.certificates.filter { $0 != "none" }.map { expandedPath($0, host: host) }
                if let jump = state.values["proxyjump"], jump != "none" {
                    host.jumps = jump.split(separator: ",").map(String.init)
                }
                let source = state.source.isEmpty ? config : state.source
                result.append(
                    SSHImportItem(
                        category: .hosts, name: alias, source: source,
                        issue: issue, warnings: state.warnings, host: host))
            }
        }
        return result + diagnostics
    }

    /// A recursively discovered Include fragment is evaluated through its
    /// parent, not a second time as an independent configuration root.
    private mutating func rootEntryPaths() -> [String] {
        let candidates = entryPaths.filter { files[$0] != nil }
        guard !candidates.isEmpty else { return [] }
        let candidateSet = Set(candidates)
        var included: Set<String> = []
        for path in candidates {
            for line in lines(path) where line.keyword == "include" {
                included.formUnion(includes(line).filter { candidateSet.contains($0) })
            }
        }
        let roots = candidates.filter { !included.contains($0) }
        return (roots.isEmpty ? candidates : roots).sorted()
    }

    private struct Evaluation {
        public var active = true
        public var inMatch = false
        public var values: [String: String] = [:]
        public var identities: [String] = []
        public var certificates: [String] = []
        public var warnings: [String] = []
        public var source = ""
        public init(
            active: Bool = true, inMatch: Bool = false, values: [String: String] = [:], identities: [String] = [],
            certificates: [String] = [], warnings: [String] = [], source: String = ""
        ) {
            self.active = active
            self.inMatch = inMatch
            self.values = values
            self.identities = identities
            self.certificates = certificates
            self.warnings = warnings
            self.source = source
        }

    }

    private mutating func lines(_ path: String) -> [SSHConfigLine] {
        guard let content = files[path] else {
            externalPaths.insert(path)
            return []
        }
        return content.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            do {
                let tokens = try SSHImportParser.tokens(raw)
                guard let keyword = tokens.first else { return nil }
                guard tokens.count > 1 else { throw ImportParseError.invalid }
                return SSHConfigLine(
                    keyword: keyword.lowercased(), values: Array(tokens.dropFirst()), source: path, line: index + 1)
            } catch {
                let location = "\(path):\(index + 1)"
                if !diagnostics.contains(where: { $0.source == location }) {
                    diagnostics.append(
                        SSHImportItem(
                            category: .hosts, name: URL(fileURLWithPath: path).lastPathComponent,
                            source: location, selected: false, issue: String(localized: "Invalid SSH record."),
                            unavailable: true))
                }
                return nil
            }
        }
    }

    private mutating func includes(_ line: SSHConfigLine) -> [String] {
        line.values.flatMap { value -> [String] in
            let pattern = expandedPath(value)
            if pattern.contains("*") || pattern.contains("?") {
                let matches = files.keys.filter { SSHImportParser.glob(pattern, matches: $0, path: true) }.sorted()
                if matches.isEmpty && !pattern.hasPrefix(root.path + "/") { externalPaths.insert(pattern) }
                return matches
            }
            if files[pattern] == nil { externalPaths.insert(pattern) }
            return [pattern]
        }
    }

    private mutating func discover(_ path: String, stack: [String], aliases: inout [String]) {
        guard !stack.contains(path), stack.count < 32 else {
            diagnostics.append(
                SSHImportItem(
                    category: .hosts, name: "Include", source: path, selected: false,
                    issue: String(localized: "Include cycle or nesting limit reached."), unavailable: true))
            return
        }
        for line in lines(path) {
            if line.keyword == "host" {
                for alias in line.values where SSHImportParser.concrete(alias) && !aliases.contains(alias) {
                    aliases.append(alias)
                }
            } else if line.keyword == "include" {
                for file in includes(line) { discover(file, stack: stack + [path], aliases: &aliases) }
            }
        }
    }

    private mutating func evaluate(_ path: String, alias: String, stack: [String], state: inout Evaluation) {
        guard !stack.contains(path), stack.count < 32 else {
            state.warnings.append(String(localized: "Include cycle or nesting limit reached."))
            return
        }
        for line in lines(path) {
            let location = "\(line.source):\(line.line)"
            if line.keyword == "host" {
                state.active = SSHImportParser.matches(line.values, alias: alias)
                state.inMatch = false
                if line.values.contains(alias) && state.source.isEmpty { state.source = location }
                continue
            }
            if line.keyword == "match" {
                state.inMatch = true
                state.active = false
                state.warnings.append("\(location): Match")
                continue
            }
            guard state.active && !state.inMatch else { continue }
            if line.keyword == "include" {
                for file in includes(line) {
                    if files[file] == nil { state.warnings.append("\(location): Include \(file)") }
                    evaluate(file, alias: alias, stack: stack + [path], state: &state)
                }
            } else if ["hostname", "port", "user", "proxyjump"].contains(line.keyword) {
                if state.values[line.keyword] == nil { state.values[line.keyword] = line.values.first }
            } else if line.keyword == "identityfile" {
                if let value = line.values.first, !state.identities.contains(value) { state.identities.append(value) }
            } else if line.keyword == "certificatefile" {
                if let value = line.values.first { state.certificates.append(value) }
            } else {
                state.warnings.append("\(location): \(line.keyword)")
            }
        }
    }
    public init(
        root: URL, home: URL, username: String, files: [String: String], entryPaths: [String]? = nil,
        externalPaths: Set<String> = [],
        diagnostics: [SSHImportItem] = []
    ) {
        self.root = root
        self.home = home
        self.username = username
        self.files = files
        self.entryPaths = entryPaths ?? [root.appendingPathComponent("config").path]
        self.externalPaths = externalPaths
        self.diagnostics = diagnostics
    }

}
