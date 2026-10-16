import CryptoKit
import Foundation
import TermindApplication
import TermindDomain

nonisolated enum RemoteMultiplexerKind: String, Codable, Sendable {
    case tmux, zellij, zmx, herdr

    var id: SessionPersistenceBackendID { .init(rawValue: rawValue) }

    func validateVersion(_ output: String) throws {
        if self == .tmux { return try RemoteTmuxCommands.validateVersion(output) }
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0].lowercased() == rawValue else {
            throw RemoteSessionFailure.invalidResponse
        }
        let components = fields[1].split(separator: ".")
        guard components.count == 3, let major = Int(components[0]), let minor = Int(components[1]),
            let patch = Int(components[2]), major >= 0, minor >= 0, patch >= 0
        else { throw RemoteSessionFailure.unsupported }
        let supported: Bool
        // Keep vvterm's supported baselines, not guessed theoretical minimums.
        // zmx 0.7 adds ownership labels; Zellij 0.44.3 and Herdr 0.8.2 include lifecycle fixes.
        switch self {
        case .tmux: supported = false
        case .zellij: supported = major > 0 || minor > 44 || (minor == 44 && patch >= 3)
        case .zmx: supported = major > 0 || minor >= 7
        case .herdr:
            supported = major > 0 || minor > 8 || (minor == 8 && patch >= 2) || (minor == 7 && patch >= 5)
        }
        guard supported else { throw RemoteSessionFailure.unsupported }
    }

    var discovery: String {
        """
        export LC_ALL=C
        exe=$(command -v \(rawValue) 2>/dev/null)
        case "$exe" in /*) ;; *) exe= ;; esac
        if [ -z "$exe" ]; then
            for dir in /opt/homebrew/bin /usr/local/bin /usr/bin /snap/bin "$HOME/.local/bin" "$HOME/.cargo/bin"; do
                if [ -f "$dir/\(rawValue)" ] && [ -x "$dir/\(rawValue)" ]; then exe="$dir/\(rawValue)"; break; fi
            done
        fi
        [ -n "$exe" ] && [ -x "$exe" ] || exit 77
        unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME ZMX_SESSION ZMX_SESSION_PREFIX
        unset HERDR_SESSION HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_PANE_ID HERDR_PANE_RUNTIME_ID
        unset HERDR_ACTIVE_PANE_ID HERDR_ACTIVE_TAB_ID HERDR_ACTIVE_WORKSPACE_ID HERDR_ACTIVE_PANE_CWD
        unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_STARTUP_CWD HERDR_BIN_PATH
        """
    }
}

nonisolated struct RemoteMultiplexerIdentity: Codable, Equatable, Sendable {
    var version = 1
    let kind: RemoteMultiplexerKind
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

    static func decode(_ data: Data, kind: RemoteMultiplexerKind) throws -> Self {
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) } catch {
            throw RemoteSessionFailure.invalidResponse
        }
        guard value.version == 1, value.kind == kind, kind != .tmux else {
            throw RemoteSessionFailure.unsupported
        }
        guard RemoteMultiplexerCommands.validPath(value.root), RemoteMultiplexerCommands.validPath(value.socket),
            value.socket.hasPrefix(value.root + "/"),
            value.fingerprint.split(separator: ":").count == 3,
            value.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || $0 == 58 }),
            value.helper.map(RemoteMultiplexerCommands.validHelper) ?? true,
            value.process.map({ UInt64($0).map { $0 > 1 } ?? false }) ?? true,
            value.created.map({ UInt64($0) != nil }) ?? true,
            kind != .zmx || (value.process != nil && value.created != nil),
            kind != .zmx
                || (value.daemonProcess.flatMap(UInt64.init).map { $0 > 1 } == true
                    && value.daemonStarted?.isEmpty == false
                    && value.daemonStarted!.utf8.allSatisfy { (32...126).contains($0) }),
            value.directoryFingerprint.map({
                $0.split(separator: ":").count == 2
                    && $0.utf8.allSatisfy { (48...57).contains($0) || $0 == 58 }
            }) ?? true,
            kind == .zellij || !value.isolated
        else { throw RemoteSessionFailure.invalidResponse }
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

    static func stateRoot(_ kind: RemoteMultiplexerKind, create: Bool) -> String {
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
        switch identity.kind {
        case .tmux: throw RemoteSessionFailure.unsupported
        case .zellij:
            return """
                export ZELLIJ_SOCKET_DIR=\(try quote(identity.root))
                \(identity.isolated ? "export XDG_CACHE_HOME=\(try quote(identity.root + "/cache"))" : "")
                """
        case .zmx: return "export ZMX_DIR=\(try quote(identity.root))"
        case .herdr:
            let root = identity.root
            let config: String
            if root.hasSuffix("/herdr") {
                config = String(root.dropLast("/herdr".count))
            } else if let range = root.range(of: "/herdr/sessions/", options: .backwards),
                validName(String(root[range.upperBound...]))
            {
                config = String(root[..<range.lowerBound])
            } else {
                throw RemoteSessionFailure.invalidResponse
            }
            guard validPath(config) else { throw RemoteSessionFailure.invalidResponse }
            return "export XDG_CONFIG_HOME=\(try quote(config))"
        }
    }

    static func guardIdentity(_ reference: RemoteSessionReference) throws -> String {
        guard let kind = RemoteMultiplexerKind(rawValue: reference.backend.rawValue),
            reference.version == 1, validName(reference.session.name)
        else { throw RemoteSessionFailure.unsupported }
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        try validateRoute(identity, name: reference.session.name)
        if let owner = reference.ownershipToken, owner != identity.owner {
            throw RemoteSessionFailure.ownershipMismatch
        }
        let owned =
            try reference.ownershipToken.map { token in
                let labelGuard =
                    kind == .zmx
                    ? """
                    [ "$("$exe" get \(try quote(reference.session.name)) termind_owner)" = '\(token.uuidString)' ] || exit 79
                    [ "$(cat "$meta/native" 2>/dev/null)" = '\(identity.process!):\(identity.created!)' ] || exit 79
                    """ : ""
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
            \(kind.discovery)
            \(try routing(identity))
            [ "$(fingerprint \(try quote(identity.socket)))" = \(try quote(identity.fingerprint)) ] || exit 79
            \(kind == .zmx ? """
            [ "$(\(RemoteZmxCommands.nativeIdentity(name: reference.session.name)))" = '\(identity.process!):\(identity.created!)' ] || exit 79
            [ "$(ps -p '\(identity.process!)' -o ppid= | tr -d ' ')" = '\(identity.daemonProcess!)' ] || exit 79
            [ "$(process_start '\(identity.daemonProcess!)')" = \(try quote(identity.daemonStarted!)) ] || exit 79
            """ : "")
            \(owned)
            """
    }

    static func validateRoute(_ identity: RemoteMultiplexerIdentity, name: String) throws {
        let valid: Bool
        switch identity.kind {
        case .tmux: valid = false
        case .zmx: valid = identity.socket == identity.root + "/" + name
        case .zellij: valid = identity.socket.hasSuffix("/" + name)
        case .herdr:
            valid =
                identity.socket == identity.root + "/herdr.sock"
                && (name == "default"
                    ? identity.root.hasSuffix("/herdr") : identity.root.hasSuffix("/herdr/sessions/" + name))
        }
        guard valid else { throw RemoteSessionFailure.invalidResponse }
        _ = try routing(identity)
    }
}

/// Shared ownership and framing policy; native command dialects remain backend-owned.
nonisolated struct RemoteMultiplexerBackend: Sendable {
    let kind: RemoteMultiplexerKind
    let execute: RemoteSessionCommandExecutor

    var capabilities: RemoteSessionCapabilities {
        .init(windowCount: kind == .tmux, clientCount: kind == .tmux || kind == .zmx, shellIntegration: true)
    }

    func probe() async throws -> RemoteSessionCapabilities {
        let versionFlag = kind == .tmux ? "-V" : kind == .zmx ? "version" : "--version"
        let result = try await execute(kind.discovery + "\n\"$exe\" \(versionFlag)")
        try Self.check(result)
        try kind.validateVersion(result.stdout)
        return capabilities
    }

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
        guard reference.version == 1, reference.backend == kind.id else { throw RemoteSessionFailure.unsupported }
        if kind == .tmux {
            _ = try RemoteTmuxCommands.attach(reference)
            return
        }
        guard reference.version == 1, reference.backend == kind.id,
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
        if kind == .tmux {
            guard (try? validate(reference)) != nil, reference.session.id == session.id,
                let saved = try? TmuxSessionIdentity.decode(reference.session.identity),
                let current = try? TmuxSessionIdentity.decode(session.identity)
            else { return false }
            return saved.created == current.created && saved.serverPID == current.serverPID
                && (reference.ownershipToken.map { current.owner == $0.uuidString } ?? true)
        }
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
        let command: String
        switch kind {
        case .tmux: command = RemoteTmuxCommands.list
        case .zellij: command = RemoteZellijCommands.list
        case .zmx: command = RemoteZmxCommands.list
        case .herdr: command = RemoteHerdrCommands.list
        }
        let response = try await execute(command)
        try Self.check(response)
        let candidates: [RemoteMultiplexerCandidate]
        switch kind {
        case .tmux: return try RemoteTmuxCommands.parseSessions(response.stdout)
        case .zellij: candidates = try RemoteZellijCommands.parseList(response.stdout)
        case .zmx: candidates = try RemoteZmxCommands.parseList(response.stdout)
        case .herdr: candidates = try RemoteHerdrCommands.parseList(response.stdout)
        }
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
                    \(kind == .zmx ? """
                    export ZMX_DIR=\(try RemoteMultiplexerCommands.quote(candidate.root))
                    if [ "$("$exe" get '\(candidate.name)' termind_owner)" != "$owner" ] \
                        || [ "$(cat "$meta/native" 2>/dev/null)" != '\(candidate.process!):\(candidate.created!)' ]; then
                        owner=-; helper=-
                    fi
                    """ : "")
                fi
                \(kind == .herdr ? "directory=$(directory_fingerprint \(try RemoteMultiplexerCommands.quote(candidate.root))) || exit 79" : "")
                \(kind == .zmx ? """
                # zmx's list PID is the PTY child, not the daemon. Bind its parent separately.
                daemon=$(ps -p '\(candidate.process!)' -o ppid= | tr -d ' ') || exit 79
                comm=$(ps -p "$daemon" -o comm=)
                [ "${comm##*/}" = zmx ] || exit 79
                born=$(process_start "$daemon")
                [ -n "$born" ] || exit 79
                born=$(hex "$born")
                """ : "")
                printf 'F|\(index)|%s|%s|%s|%s|%s|%s|%s\\n' "$(hex "$socket")" "$fp" "$owner" "$helper" "$directory" "$daemon" "$born"
                """
        }.joined(separator: "\n")
        let metadata = try await execute(
            kind.discovery + "\n" + RemoteMultiplexerCommands.utilities + "\n"
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
        if kind == .tmux {
            let result = try await execute(
                RemoteTmuxCommands.create(
                    token: token, startupCommand: startupCommand, shellIntegration: shellIntegration,
                    environment: environment))
            try Self.check(result)
            let confirmed = try RemoteTmuxCommands.parseSessions(result.stdout)
            guard confirmed.count == 1, let session = confirmed.first,
                try TmuxSessionIdentity.decode(session.identity).owner == token.uuidString
            else { throw RemoteSessionFailure.ownershipMismatch }
            return session
        }
        let name = RemoteMultiplexerCommands.managedName(token)
        if let existing = try await sessions().first(where: { $0.name == name }) {
            let identity = try RemoteMultiplexerIdentity.decode(existing.identity, kind: kind)
            guard identity.owner == token else { throw RemoteSessionFailure.ownershipMismatch }
            // An interrupted response may leave a confirmed incarnation without its ready marker.
            // Only finish that same incarnation; never replay a startup command or adopt by name.
            let reference = RemoteSessionReference(
                backend: kind.id, session: existing, hostID: UUID(), endpoint: "", username: "", ownershipToken: token)
            let completion = try await execute(
                """
                \(try RemoteMultiplexerCommands.guardIdentity(reference))
                helper=$(cat "$meta/helper") || exit 79
                \(startupCommand?.isEmpty == false ? """
                [ -f "$helper/started" ] && [ ! -L "$helper/started" ] \
                    && [ "$(cat "$helper/started")" = '\(token.uuidString)' ] || exit 81
                """ : "")
                : > "$meta/ready"
                printf 'TERMIND_CREATED\\n'
                """)
            try Self.check(completion)
            guard completion.stdout == "TERMIND_CREATED\n" else { throw RemoteSessionFailure.invalidResponse }
            return existing
        }
        let native: String
        switch kind {
        case .tmux: throw RemoteSessionFailure.unsupported
        case .zellij: native = RemoteZellijCommands.create(name: name)
        case .zmx: native = RemoteZmxCommands.create(name: name, token: token)
        case .herdr: native = RemoteHerdrCommands.create(name: name)
        }
        let requireStartup = startupCommand?.isEmpty == false
        let shell =
            try environment.last(where: { $0.variable == "SHELL" }).map {
                try RemoteMultiplexerCommands.quote($0.value)
            } ?? "\"${SHELL:-/bin/sh}\""
        let result = try await execute(
            """
            export TERMIND_SHELL_LOCALE_SET="${LC_ALL+x}" TERMIND_SHELL_LOCALE="${LC_ALL-}"
            \(kind.discovery)
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
            : > "$meta/ready"
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
        if kind == .tmux {
            return .init(
                command: try RemoteTmuxCommands.attach(reference), attachment: reference, created: created)
        }
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        let name = try RemoteMultiplexerCommands.quote(reference.session.name)
        let attach: String
        switch kind {
        case .tmux: throw RemoteSessionFailure.unsupported
        case .zellij: attach = "\"$exe\" attach \(name)"
        case .zmx:
            // attach is an upsert. If the daemon disappears after validation, its replacement must exit,
            // not become an unrelated interactive shell (or replay the original startup command).
            attach = "\"$exe\" attach \(name) /bin/sh -c 'exit 79'"
        case .herdr: attach = "\"$exe\" --session \(name) client"
        }
        let noResurrection =
            kind == .zellij
            ? """
            # An attach command can otherwise resurrect a cached session after a disconnect race.
            cache="/tmp/termind-zellij-attach-cache-$(id -u)"
            private_dir "$cache" || exit 79
            export XDG_CACHE_HOME="$cache"
            """ : ""
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
        guard reference.isManaged, kind != .herdr || reference.session.name != "default" else {
            throw RemoteSessionFailure.ownershipMismatch
        }
        if kind == .tmux {
            let result = try await execute(RemoteTmuxCommands.terminate(reference))
            try Self.check(result)
            guard result.stdout == "TERMIND_ENDED\n" else { throw RemoteSessionFailure.ownershipMismatch }
            return
        }
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        if kind == .herdr, identity.directoryFingerprint == nil {
            throw RemoteSessionFailure.ownershipMismatch
        }
        let name = try RemoteMultiplexerCommands.quote(reference.session.name)
        let stop: String
        switch kind {
        case .tmux: throw RemoteSessionFailure.unsupported
        case .zellij: stop = "\"$exe\" kill-session \(name)"
        case .zmx: stop = "\"$exe\" kill \(name) --force"
        case .herdr: stop = "\"$exe\" session stop \(name) --json"
        }
        let result = try await execute(
            """
            \(try RemoteMultiplexerCommands.guardIdentity(reference))
            \(stop) >/dev/null || exit 78
            attempt=0
            while [ -S \(try RemoteMultiplexerCommands.quote(identity.socket)) ]; do
                attempt=$((attempt + 1)); [ "$attempt" -lt 50 ] || exit 79
                sleep 0.1
            done
            \(kind == .herdr ? """
            private_state || exit 79
            [ "$(cat "$meta/owner")" = '\(reference.ownershipToken!.uuidString)' ] || exit 79
            [ "$(cat "$meta/identity")" = \(try RemoteMultiplexerCommands.quote(identity.fingerprint)) ] || exit 79
            [ "$(directory_fingerprint \(try RemoteMultiplexerCommands.quote(identity.root)))" = '\(identity.directoryFingerprint!)' ] || exit 79
            [ ! -e \(try RemoteMultiplexerCommands.quote(identity.socket)) ] || exit 79
            "$exe" session delete \(name) --json >/dev/null || exit 78
            [ ! -e \(try RemoteMultiplexerCommands.quote(identity.root)) ] || exit 79
            """ : "")
            printf 'TERMIND_ENDED\\n'
            """)
        try Self.check(result)
        guard result.stdout == "TERMIND_ENDED\n" else { throw RemoteSessionFailure.invalidResponse }
    }
}
