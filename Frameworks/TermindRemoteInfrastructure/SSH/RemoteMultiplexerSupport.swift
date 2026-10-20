// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated struct RemoteMultiplexerIdentity: Codable, Equatable, Sendable {
    var version = 1
    // Keep the legacy raw-string discriminator, independently of the public backend ID's Codable shape.
    private let kindValue: String
    var kind: SessionPersistenceBackendID { .init(rawValue: kindValue) }

    private enum CodingKeys: String, CodingKey {
        case version, root, socket, fingerprint, process, created, owner, helper, isolated
        case directoryFingerprint, daemonProcess, daemonStarted
        case kindValue = "kind"
    }
    let root: String
    let socket: String
    let fingerprint: String
    let process: String?
    let created: String?
    let owner: UUID?
    let helper: String?
    let isolated: Bool
    var directoryFingerprint: String? = nil
    var daemonProcess: String? = nil
    var daemonStarted: String? = nil

    init(
        kind: SessionPersistenceBackendID, root: String, socket: String, fingerprint: String,
        process: String?, created: String?, owner: UUID?, helper: String?, isolated: Bool,
        directoryFingerprint: String? = nil, daemonProcess: String? = nil, daemonStarted: String? = nil
    ) {
        kindValue = kind.rawValue
        self.root = root
        self.socket = socket
        self.fingerprint = fingerprint
        self.process = process
        self.created = created
        self.owner = owner
        self.helper = helper
        self.isolated = isolated
        self.directoryFingerprint = directoryFingerprint
        self.daemonProcess = daemonProcess
        self.daemonStarted = daemonStarted
    }

    static func decode(_ data: Data, kind: SessionPersistenceBackendID) throws -> Self {
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch {
            throw RemoteSessionFailure.invalidResponse
        }
        guard RemoteMultiplexerRegistry.dialect(value.kind) != nil else {
            throw RemoteSessionFailure.invalidResponse
        }
        guard value.version == 1, value.kind == kind,
            let dialect = RemoteMultiplexerRegistry.socketDialect(kind)
        else {
            throw RemoteSessionFailure.unsupported
        }
        guard RemoteMultiplexerCommands.validPath(value.root), RemoteMultiplexerCommands.validPath(value.socket),
            value.socket.hasPrefix(value.root + "/"),
            value.fingerprint.split(separator: ":").count == 3,
            value.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || $0 == 58 }),
            value.helper.map(RemoteMultiplexerCommands.validHelper) ?? true,
            value.process.map({ UInt64($0).map { $0 > 1 } ?? false }) ?? true,
            value.created.map({ UInt64($0) != nil }) ?? true,
            value.directoryFingerprint.map({
                $0.split(separator: ":").count == 2
                    && $0.utf8.allSatisfy { (48...57).contains($0) || $0 == 58 }
            }) ?? true
        else { throw RemoteSessionFailure.invalidResponse }
        try dialect.validateIdentity(value)
        return value
    }
}

nonisolated struct RemoteMultiplexerCandidate {
    let name: String
    let root: String
    let socket: String?
    var process: String? = nil
    var created: String? = nil
    var clients: Int? = nil
    var isolated = false
}

nonisolated enum RemoteMultiplexerCommands {
    static func discovery(_ backend: SessionPersistenceBackendID) -> String {
        """
        export LC_ALL=C
        exe=$(command -v \(backend.rawValue) 2>/dev/null)
        case "$exe" in /*) ;; *) exe= ;; esac
        if [ -z "$exe" ]; then
            for dir in /opt/homebrew/bin /usr/local/bin /usr/bin /snap/bin "$HOME/.local/bin" "$HOME/.cargo/bin"; do
                if [ -f "$dir/\(backend.rawValue)" ] && [ -x "$dir/\(backend.rawValue)" ]; then exe="$dir/\(backend.rawValue)"; break; fi
            done
        fi
        [ -n "$exe" ] && [ -x "$exe" ] || exit 77
        unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME ZMX_SESSION ZMX_SESSION_PREFIX
        unset HERDR_SESSION HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_PANE_ID HERDR_PANE_RUNTIME_ID
        unset HERDR_ACTIVE_PANE_ID HERDR_ACTIVE_TAB_ID HERDR_ACTIVE_WORKSPACE_ID HERDR_ACTIVE_PANE_CWD
        unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_STARTUP_CWD HERDR_BIN_PATH
        """
    }

    static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw RemoteSessionFailure.invalidResponse }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.split(separator: "/").contains("..")
    }

    static func validHelper(_ value: String) -> Bool {
        value.hasPrefix("/tmp/termind-shell.") && value.count > "/tmp/termind-shell.".count
            && value.dropFirst("/tmp/termind-shell.".count).utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.first != "-"
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            } && value != "." && value != ".."
    }

    static func managedName(_ token: UUID) -> String {
        "termind-"
            + SHA256.hash(data: Data(token.uuidString.utf8)).prefix(8).map {
                String(format: "%02x", $0)
            }.joined()
    }

    static func unhex(_ value: String, limit: Int = 8192) throws -> String {
        guard value.count.isMultiple(of: 2), value.count <= limit else {
            throw RemoteSessionFailure.invalidResponse
        }
        var bytes: [UInt8] = []
        var cursor = value.startIndex
        while cursor != value.endIndex {
            let end = value.index(cursor, offsetBy: 2)
            guard let byte = UInt8(value[cursor..<end], radix: 16) else {
                throw RemoteSessionFailure.invalidResponse
            }
            bytes.append(byte)
            cursor = end
        }
        guard let result = String(bytes: bytes, encoding: .utf8) else {
            throw RemoteSessionFailure.invalidResponse
        }
        return result
    }

    static let utilities = #"""
        hex() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
        process_start() { LC_ALL=C TZ=UTC ps -p "$1" -o lstart= | sed 's/^ *//;s/ *$//'; }
        fingerprint() {
            [ -S "$1" ] && [ ! -L "$1" ] || return 1
            stat -c '%d:%i:%Z' "$1" 2>/dev/null || stat -f '%d:%i:%c' "$1"
        }
        private_dir() {
            [ -d "$1" ] || (umask 077; mkdir "$1") || return 1
            [ -d "$1" ] && [ ! -L "$1" ] || return 1
            owner=$(stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1") || return 1
            [ "$owner" = "$(id -u)" ] && chmod 700 "$1"
        }
        directory_fingerprint() {
            [ -d "$1" ] && [ ! -L "$1" ] || return 1
            stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
        }
        private_state() {
            for path in "/tmp/termind-sessions-$(id -u)" "$state" "$meta"; do
                [ -d "$path" ] && [ ! -L "$path" ] || return 1
                [ "$(stat -c '%u' "$path" 2>/dev/null || stat -f '%u' "$path")" = "$(id -u)" ] || return 1
            done
            for field in owner helper identity; do
                [ -f "$meta/$field" ] && [ ! -L "$meta/$field" ] || return 1
            done
        }
        """#

    static func stateRoot(_ kind: SessionPersistenceBackendID, create: Bool) -> String {
        """
        state="/tmp/termind-sessions-$(id -u)"
        \(create ? "private_dir \"$state\" || exit 78" : "")
        state="$state/\(kind.rawValue)"
        \(create ? "private_dir \"$state\" || exit 78" : "")
        """
    }

    static func environment(_ values: [HostEnvironmentVariable]) throws -> String {
        try values.map { value in
            guard value.isValid, !value.variable.hasPrefix("TERMIND_"),
                !["TMUX", "ZELLIJ", "ZMX", "HERDR"].contains(where: {
                    value.variable == $0 || value.variable.hasPrefix($0 + "_")
                })
            else { throw RemoteSessionFailure.invalidResponse }
            return "export \(value.variable)=\(try quote(value.value))"
        }.joined(separator: "\n")
    }

    static func routing(_ identity: RemoteMultiplexerIdentity) throws -> String {
        guard let dialect = RemoteMultiplexerRegistry.socketDialect(identity.kind) else {
            throw RemoteSessionFailure.unsupported
        }
        return try dialect.routing(identity)
    }

    static func guardIdentity(_ reference: RemoteSessionReference) throws -> String {
        let kind = reference.backend
        guard let dialect = RemoteMultiplexerRegistry.socketDialect(kind),
            reference.version == 1, validName(reference.session.name)
        else { throw RemoteSessionFailure.unsupported }
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        try validateRoute(identity, name: reference.session.name)
        if let owner = reference.ownershipToken, owner != identity.owner {
            throw RemoteSessionFailure.ownershipMismatch
        }
        let owned =
            try reference.ownershipToken.map { token in
                let labelGuard = try dialect.ownershipGuard(identity, name: reference.session.name, token: token)
                return """
                    \(stateRoot(kind, create: false))
                    meta="$state/\(reference.session.name)"
                    private_state || exit 79
                    [ "$(cat "$meta/owner" 2>/dev/null)" = '\(token.uuidString)' ] || exit 79
                    [ "$(cat "$meta/identity" 2>/dev/null)" = \(try quote(identity.fingerprint)) ] || exit 79
                    \(labelGuard)
                    """
            } ?? ""
        return """
            \(utilities)
            \(discovery(kind))
            \(try routing(identity))
            [ "$(fingerprint \(try quote(identity.socket)))" = \(try quote(identity.fingerprint)) ] || exit 79
            \(try dialect.identityGuard(identity, name: reference.session.name))
            \(owned)
            """
    }

    static func validateRoute(_ identity: RemoteMultiplexerIdentity, name: String) throws {
        guard let dialect = RemoteMultiplexerRegistry.socketDialect(identity.kind),
            dialect.validRoute(identity, name: name)
        else { throw RemoteSessionFailure.invalidResponse }
        _ = try routing(identity)
    }
}

/// Shared ownership and framing policy; native command dialects remain backend-owned.
nonisolated struct RemoteMultiplexerBackend: RemoteSessionBackend {
    let dialect: any RemoteSocketMultiplexerDialect
    var kind: SessionPersistenceBackendID { dialect.id }
    var id: SessionPersistenceBackendID { dialect.id }
    let execute: RemoteSessionCommandExecutor

    var capabilities: RemoteSessionCapabilities { dialect.capabilities }

    func probe() async throws -> RemoteSessionCapabilities { try await dialect.probe(execute: execute) }

    static func check(_ result: RemoteSessionCommandResult) throws {
        guard !result.truncated, result.stdout.utf8.count <= 1024 * 1024 else {
            throw RemoteSessionFailure.invalidResponse
        }
        switch result.exitCode {
        case 0: return
        case 77: throw RemoteSessionFailure.missing
        case 79: throw RemoteSessionFailure.ownershipMismatch
        case 80: throw RemoteSessionFailure.unsupported
        case 81: throw RemoteSessionFailure.startupUnavailable
        default: throw RemoteSessionFailure.commandFailed(result.stderr)
        }
    }

    func validate(_ reference: RemoteSessionReference) throws {
        guard reference.version == 1, reference.backend == kind,
            RemoteMultiplexerCommands.validName(reference.session.name)
        else { throw RemoteSessionFailure.unsupported }
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        try RemoteMultiplexerCommands.validateRoute(identity, name: reference.session.name)
        guard reference.session.id == (identity.isolated ? "managed:" : "user:") + reference.session.name,
            reference.ownershipToken == nil || reference.ownershipToken == identity.owner,
            reference.ownershipToken.map({ RemoteMultiplexerCommands.managedName($0) == reference.session.name })
                ?? true
        else { throw RemoteSessionFailure.ownershipMismatch }
    }

    func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool {
        guard (try? validate(reference)) != nil, reference.session.id == session.id,
            let saved = try? RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind),
            let current = try? RemoteMultiplexerIdentity.decode(session.identity, kind: kind)
        else { return false }
        return saved.root == current.root && saved.socket == current.socket
            && saved.fingerprint == current.fingerprint && saved.process == current.process
            && saved.created == current.created
            && saved.directoryFingerprint == current.directoryFingerprint
            && saved.daemonProcess == current.daemonProcess && saved.daemonStarted == current.daemonStarted
            && (reference.ownershipToken == nil || reference.ownershipToken == current.owner)
    }

    func sessions() async throws -> [RemoteSessionDescriptor] {
        let response = try await execute(dialect.list)
        try Self.check(response)
        let candidates = try dialect.parseList(response.stdout)
        guard candidates.count <= 256, Set(candidates.map { "\($0.isolated):\($0.name)" }).count == candidates.count
        else { throw RemoteSessionFailure.invalidResponse }
        guard !candidates.isEmpty else { return [] }
        let commands = try candidates.enumerated().map { index, candidate -> String in
            guard RemoteMultiplexerCommands.validName(candidate.name),
                RemoteMultiplexerCommands.validPath(candidate.root)
            else { throw RemoteSessionFailure.invalidResponse }
            let socket: String
            if let path = candidate.socket {
                guard RemoteMultiplexerCommands.validPath(path), path.hasPrefix(candidate.root + "/") else {
                    throw RemoteSessionFailure.invalidResponse
                }
                socket = "socket=\(try RemoteMultiplexerCommands.quote(path))"
            } else {
                socket = """
                    socket=$(find \(try RemoteMultiplexerCommands.quote(candidate.root)) -type s -name \
                    \(try RemoteMultiplexerCommands.quote(candidate.name)) -print 2>/dev/null) || exit 78
                    """
            }
            return """
                \(socket)
                fp=$(fingerprint "$socket") || exit 79
                owner=-; helper=-; directory=-; daemon=-; born=-
                meta="$state/\(candidate.name)"
                if private_state && [ "$(cat "$meta/identity" 2>/dev/null)" = "$fp" ]; then
                    owner=$(cat "$meta/owner") || exit 78
                    helper=$(cat "$meta/helper") || exit 78
                    \(try dialect.metadataOwnershipGuard(candidate))
                fi
                \(try dialect.metadataFields(candidate))
                printf 'F|\(index)|%s|%s|%s|%s|%s|%s|%s\\n' "$(hex "$socket")" "$fp" "$owner" "$helper" "$directory" "$daemon" "$born"
                """
        }.joined(separator: "\n")
        let metadata = try await execute(
            RemoteMultiplexerCommands.discovery(kind) + "\n" + RemoteMultiplexerCommands.utilities + "\n"
                + RemoteMultiplexerCommands.stateRoot(kind, create: false)
                + "\n" + commands)
        try Self.check(metadata)
        let lines = metadata.stdout.split(separator: "\n")
        guard metadata.stdout.hasSuffix("\n"), lines.count == candidates.count else {
            throw RemoteSessionFailure.invalidResponse
        }
        return try lines.enumerated().map { index, line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 9, fields[0] == "F", fields[1] == String(index),
                fields[4] == "-" || UUID(uuidString: fields[4]) != nil,
                fields[5] == "-" || RemoteMultiplexerCommands.validHelper(fields[5])
            else { throw RemoteSessionFailure.invalidResponse }
            let candidate = candidates[index]
            let identity = RemoteMultiplexerIdentity(
                kind: kind, root: candidate.root, socket: try RemoteMultiplexerCommands.unhex(fields[2]),
                fingerprint: fields[3], process: candidate.process, created: candidate.created,
                owner: UUID(uuidString: fields[4]), helper: fields[5] == "-" ? nil : fields[5],
                isolated: candidate.isolated, directoryFingerprint: fields[6] == "-" ? nil : fields[6],
                daemonProcess: fields[7] == "-" ? nil : fields[7],
                daemonStarted: fields[8] == "-" ? nil : try RemoteMultiplexerCommands.unhex(fields[8]))
            let data = try JSONEncoder().encode(identity)
            _ = try RemoteMultiplexerIdentity.decode(data, kind: kind)
            try RemoteMultiplexerCommands.validateRoute(identity, name: candidate.name)
            return RemoteSessionDescriptor(
                id: (candidate.isolated ? "managed:" : "user:") + candidate.name,
                name: candidate.name, identity: data, clients: candidate.clients)
        }
    }

    func create(
        token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable]
    ) async throws -> RemoteSessionDescriptor {
        let name = RemoteMultiplexerCommands.managedName(token)
        if let existing = try await sessions().first(where: { $0.name == name }) {
            let identity = try RemoteMultiplexerIdentity.decode(existing.identity, kind: kind)
            guard identity.owner == token else { throw RemoteSessionFailure.ownershipMismatch }
            let reference = RemoteSessionReference(
                backend: kind, session: existing, hostID: UUID(), endpoint: "", username: "", ownershipToken: token)
            let completion = try await execute(
                """
                \(try RemoteMultiplexerCommands.guardIdentity(reference))
                helper=$(cat "$meta/helper") || exit 79
                \(startupCommand?.isEmpty == false ? """
                [ -f "$helper/started" ] && [ ! -L "$helper/started" ] \
                    && [ "$(cat "$helper/started")" = '\(token.uuidString)' ] || exit 81
                """ : "")
                printf 'TERMIND_CREATED\\n'
                """)
            try Self.check(completion)
            guard completion.stdout == "TERMIND_CREATED\n" else { throw RemoteSessionFailure.invalidResponse }
            return existing
        }
        let native = dialect.create(name: name, token: token)
        let requireStartup = startupCommand?.isEmpty == false
        let shell =
            try environment.last(where: { $0.variable == "SHELL" }).map {
                try RemoteMultiplexerCommands.quote($0.value)
            } ?? "\"${SHELL:-/bin/sh}\""
        let result = try await execute(
            """
            export TERMIND_SHELL_LOCALE_SET="${LC_ALL+x}" TERMIND_SHELL_LOCALE="${LC_ALL-}"
            \(RemoteMultiplexerCommands.discovery(kind))
            \(RemoteMultiplexerCommands.utilities)
            \(RemoteMultiplexerCommands.stateRoot(kind, create: true))
            umask 077
            lock="$state/\(name).lock"
            mkdir "$lock" 2>/dev/null || exit 79
            reserved=0; native_started=0
            cleanup() {
                code=$?
                if [ "$reserved" = 1 ] && [ "$native_started" = 0 ]; then
                    rm -f "$meta/owner" "$meta/helper" "$meta/create-error"
                    rmdir "$meta" 2>/dev/null
                fi
                rmdir "$lock" 2>/dev/null
                exit "$code"
            }
            trap cleanup EXIT
            trap 'exit 78' HUP INT TERM
            session_shell=\(shell)
            \(requireStartup ? "case \"$session_shell\" in */bash|*/zsh|*/fish) [ -x \"$session_shell\" ] || exit 81 ;; *) exit 81 ;; esac" : "")
            \(try RemoteShellStartup.install(
                token: token, startupCommand: startupCommand, shellIntegration: shellIntegration, backend: kind.rawValue,
                environment: environment))
            meta="$state/\(name)"
            # A reservation with no confirmed incarnation is not permission to adopt a same-named session.
            mkdir "$meta" 2>/dev/null || exit 79
            reserved=1
            chmod 700 "$meta" || exit 78
            printf '%s\\n' '\(token.uuidString)' > "$meta/owner" || exit 78
            printf '%s\\n' "$helper" > "$meta/helper" || exit 78
            export TERMIND_TMUX_HELPERS="$helper" TERMIND_TMUX_SHELL="$session_shell"
            \(native)
            fp=$(fingerprint "$socket") || exit 79
            printf '%s\\n' "$fp" > "$meta/identity" || exit 78
            \(requireStartup ? """
            attempt=0
            while [ ! -f "$helper/started" ]; do
                attempt=$((attempt + 1))
                if [ "$attempt" -ge 50 ]; then
                    # A slow or bypassed user rc must not run the snippet after reporting failure.
                    mkdir "$helper/startup-decision" 2>/dev/null && exit 81
                    [ -f "$helper/started" ] || exit 81
                fi
                sleep 0.1
            done
            [ "$(cat "$helper/started")" = '\(token.uuidString)' ] || exit 81
            """ : "")
            printf 'TERMIND_CREATED\\n'
            """)
        try Self.check(result)
        guard result.stdout == "TERMIND_CREATED\n",
            let session = try await sessions().first(where: { $0.name == name }),
            try RemoteMultiplexerIdentity.decode(session.identity, kind: kind).owner == token
        else { throw RemoteSessionFailure.ownershipMismatch }
        return session
    }

    func launch(_ reference: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch {
        try validate(reference)
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        let name = try RemoteMultiplexerCommands.quote(reference.session.name)
        let attach = dialect.attach(name: name)
        let noResurrection = dialect.prepareAttachment()
        let bind: String
        if let helper = identity.helper {
            bind = """
                helper=\(try RemoteMultiplexerCommands.quote(helper))
                tty=$(tty) || exit 79
                key=$(printf '%s' "$tty" | od -An -v -tx1 | tr -d ' \\n')
                printf '%s|%s\\n' "$$" "$(process_start "$$")" > "$helper/client-$key"
                """
        } else {
            bind = ""
        }
        return .init(
            command: try RemoteMultiplexerCommands.guardIdentity(reference) + "\n" + noResurrection
                + "\n" + bind + "\nexec " + attach,
            attachment: reference, created: created)
    }

    func terminate(_ reference: RemoteSessionReference) async throws {
        try validate(reference)
        guard reference.isManaged else { throw RemoteSessionFailure.ownershipMismatch }
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        try dialect.validateTermination(reference, identity: identity)
        let name = try RemoteMultiplexerCommands.quote(reference.session.name)
        let stop = dialect.stop(name: name)
        let result = try await execute(
            """
            \(try RemoteMultiplexerCommands.guardIdentity(reference))
            \(stop) >/dev/null || exit 78
            attempt=0
            while [ -S \(try RemoteMultiplexerCommands.quote(identity.socket)) ]; do
                attempt=$((attempt + 1)); [ "$attempt" -lt 50 ] || exit 79
                sleep 0.1
            done
            \(try dialect.terminationCleanup(reference, identity: identity))
            printf 'TERMIND_ENDED\\n'
            """)
        try Self.check(result)
        guard result.stdout == "TERMIND_ENDED\n" else { throw RemoteSessionFailure.invalidResponse }
    }
}
