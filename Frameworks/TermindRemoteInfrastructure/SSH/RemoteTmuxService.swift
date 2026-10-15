import CryptoKit
import Foundation
import TermindApplication
import TermindDomain

/// Control operations run serially before the terminal channel occupies a server session slot.
public nonisolated struct RemoteTmuxService: RemoteSessionBackend, Sendable {
    public typealias Executor = RemoteSessionCommandExecutor
    private let execute: Executor
    public var id: SessionPersistenceBackendID { .tmux }
    public var capabilities: RemoteSessionCapabilities {
        .init(windowCount: true, clientCount: true, shellIntegration: true)
    }

    public init(execute: @escaping Executor) { self.execute = execute }

    public func validate(_ reference: RemoteSessionReference) throws {
        guard reference.version == 1, reference.backend == id else { throw RemoteSessionFailure.unsupported }
        _ = try TmuxSessionIdentity.decode(reference.session.identity)
    }

    public func matches(_ reference: RemoteSessionReference, session: RemoteSessionDescriptor) -> Bool {
        guard reference.version == 1, reference.backend == id,
            reference.session.id == session.id,
            let saved = try? TmuxSessionIdentity.decode(reference.session.identity),
            let current = try? TmuxSessionIdentity.decode(session.identity),
            saved.created == current.created, saved.serverPID == current.serverPID
        else { return false }
        return reference.ownershipToken.map { current.owner == $0.uuidString } ?? true
    }

    public func probe() async throws -> RemoteSessionCapabilities {
        let version = try await execute("command -v tmux >/dev/null 2>&1 || exit 77; tmux -V")
        if version.exitCode == 77 { throw RemoteSessionFailure.missing }
        try Self.check(version)
        try RemoteTmuxCommands.validateVersion(version.stdout)
        return capabilities
    }

    public func sessions() async throws -> [RemoteSessionDescriptor] {
        let result = try await execute(RemoteTmuxCommands.list)
        try Self.check(result)
        return try RemoteTmuxCommands.parseSessions(result.stdout)
    }

    public func create(
        token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable] = []
    ) async throws
        -> RemoteSessionDescriptor
    {
        let result = try await execute(
            RemoteTmuxCommands.create(
                token: token, startupCommand: startupCommand, shellIntegration: shellIntegration,
                environment: environment))
        if result.exitCode == 80 { throw RemoteSessionFailure.unsupported }
        try Self.check(result)
        let confirmed = try RemoteTmuxCommands.parseSessions(result.stdout)
        guard confirmed.count == 1, let session = confirmed.first,
            try TmuxSessionIdentity.decode(session.identity).owner == token.uuidString
        else {
            throw RemoteSessionFailure.ownershipMismatch
        }
        return session
    }

    public func launch(_ attachment: RemoteSessionReference, created: Bool) throws -> RemoteSessionLaunch {
        RemoteSessionLaunch(
            command: try RemoteTmuxCommands.attach(attachment), attachment: attachment, created: created)
    }

    public func terminate(_ attachment: RemoteSessionReference) async throws {
        guard attachment.isManaged else { throw RemoteSessionFailure.ownershipMismatch }
        let result = try await execute(RemoteTmuxCommands.terminate(attachment))
        if result.exitCode == 79 { throw RemoteSessionFailure.ownershipMismatch }
        try Self.check(result)
        guard result.stdout == "TERMIND_ENDED\n" else { throw RemoteSessionFailure.ownershipMismatch }
    }

    private static func check(_ result: RemoteSessionCommandResult) throws {
        guard !result.truncated else { throw RemoteSessionFailure.invalidResponse }
        guard result.exitCode == 0 else {
            throw RemoteSessionFailure.commandFailed(result.stderr)
        }
    }
}

extension RemoteSessionBackendRegistry {
    public static var live: Self { Self([.tmux: { RemoteTmuxService(execute: $0) }]) }
}

private nonisolated struct TmuxSessionIdentity: Codable {
    var version = 1
    let created: String
    let serverPID: String
    let owner: String?

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw RemoteSessionFailure.unsupported }
        return value
    }
}

public nonisolated enum RemoteTmuxCommands {
    public static func quote(_ value: String) throws -> String {
        guard !value.contains("\0") else { throw RemoteSessionFailure.invalidResponse }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func validateVersion(_ output: String) throws {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("tmux ") else { throw RemoteSessionFailure.invalidResponse }
        let digits = value.dropFirst(5).prefix { $0.isNumber || $0 == "." }.split(separator: ".")
        guard digits.count >= 2, let major = Int(digits[0]), let minor = Int(digits[1]),
            major > 3 || (major == 3 && minor >= 3)
        else { throw RemoteSessionFailure.unsupported }
    }

    // Names and ownership values are hex-encoded, never interpolated into shell syntax or split on whitespace.
    private static let describe = #"""
        describe() {
            id=$1
            fields=$(tmux display-message -p -t "$id" '#{session_id} #{session_created} #{pid} #{session_windows} #{session_attached}') || return
            name=$(tmux display-message -p -t "$id" '#{session_name}' | od -An -v -tx1 | tr -d ' \n')
            owner=$(tmux show-environment -t "$id" TERMIND_TMUX_OWNER 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
            printf 'S %s %s %s\n' "$fields" "$name" "${owner:--}"
        }
        """#

    public static var list: String {
        """
        export LC_ALL=C
        \(describe)
        ids=$(tmux list-sessions -F '#{session_id}' 2>&1)
        code=$?
        if [ "$code" -ne 0 ]; then
            case "$ids" in
                "no server running on "*|*" (No such file or directory)") printf 'TERMIND_TMUX_1\\n'; exit 0 ;;
                *) printf '%s\\n' "$ids" >&2; exit "$code" ;;
            esac
        fi
        printf 'TERMIND_TMUX_1\\n'
        for id in $ids; do describe "$id" || exit 78; done
        """
    }

    public static func parseSessions(_ text: String) throws -> [RemoteSessionDescriptor] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "TERMIND_TMUX_1", lines.last == "" else { throw RemoteSessionFailure.invalidResponse }
        lines.removeFirst()
        lines.removeLast()
        var seen: Set<String> = []
        return try lines.map { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8, fields[0] == "S", validID(fields[1]),
                seen.insert(fields[1]).inserted,
                UInt64(fields[2]) != nil, UInt64(fields[3]) != nil,
                let windows = Int(fields[4]), windows > 0, let clients = Int(fields[5]), clients >= 0,
                let name = decodeLine(fields[6])
            else { throw RemoteSessionFailure.invalidResponse }
            let owner: String?
            if fields[7] == "-" {
                owner = nil
            } else {
                guard let value = decodeLine(fields[7]), value.hasPrefix("TERMIND_TMUX_OWNER=") else {
                    throw RemoteSessionFailure.invalidResponse
                }
                owner = String(value.dropFirst("TERMIND_TMUX_OWNER=".count))
            }
            return RemoteSessionDescriptor(
                id: fields[1], name: name,
                identity: try JSONEncoder().encode(
                    TmuxSessionIdentity(created: fields[2], serverPID: fields[3], owner: owner)),
                windows: windows, clients: clients)
        }
    }

    private static func decodeLine(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<end], radix: 16) else { return nil }
            bytes.append(byte)
            cursor = end
        }
        guard bytes.popLast() == 10 else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func validID(_ id: String) -> Bool {
        id.first == "$" && !id.dropFirst().isEmpty && id.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    static func managedSessionName(token: UUID) -> String {
        // Keep 64 bits of a one-way digest: short to display, stable on retry, not an ownership credential.
        "termind-"
            + SHA256.hash(data: Data(token.uuidString.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func create(
        token: UUID, startupCommand: String?, shellIntegration: Bool, environment: [HostEnvironmentVariable] = []
    ) throws -> String {
        let owner = token.uuidString
        let name = managedSessionName(token: token)
        let wrapper = try RemoteTmuxShellStartup.install(
            token: token, startupCommand: startupCommand, shellIntegration: shellIntegration)
        guard environment.allSatisfy({ $0.isValid && !$0.variable.hasPrefix("TERMIND_") && $0.variable != "TMUX" })
        else {
            throw RemoteSessionFailure.invalidResponse
        }
        let variables = try environment.map { "-e \(try quote("\($0.variable)=\($0.value)"))" }.joined(separator: " ")
        let shell =
            try environment.last(where: { $0.variable == "SHELL" }).map { try quote($0.value) }
            ?? "\"${SHELL:-/bin/sh}\""
        let checkShell =
            startupCommand == nil
            ? ""
            : """
            case \(shell) in */bash|*/zsh|*/fish) ;; *) exit 80 ;; esac
            """
        return """
            \(describe)
            session_shell=\(shell)
            id=$(tmux list-sessions -f '#{==:#{session_name},\(name)}' -F '#{session_id}' 2>/dev/null)
            if [ -n "$id" ]; then
                [ "$(tmux show-environment -t "$id" TERMIND_TMUX_OWNER)" = 'TERMIND_TMUX_OWNER=\(owner)' ] || exit 79
                helper=$(tmux show-environment -t "$id" TERMIND_TMUX_HELPERS) || exit 78
                helper=${helper#TERMIND_TMUX_HELPERS=}
                session_shell=$(tmux show-environment -t "$id" TERMIND_TMUX_SHELL) || exit 78
                session_shell=${session_shell#TERMIND_TMUX_SHELL=}
            else
                \(checkShell)
                \(wrapper)
                id=$(tmux new-session -d -P -F '#{session_id}' -s '\(name)' \(variables) -e 'TERMIND_TMUX_OWNER=\(owner)' \
            -e "TERMIND_TMUX_SHELL=$session_shell" -e "TERMIND_TMUX_HELPERS=$helper" "$helper/first" --) || exit $?
            fi
            tmux set-option -t "$id" default-shell "$helper/shell" || exit $?
            tmux set-option -t "$id" default-command '' || exit $?
            printf 'TERMIND_TMUX_1\\n'
            describe "$id"
            """
    }

    private static func identityCondition(_ attachment: RemoteSessionReference) throws -> String {
        let session = attachment.session
        let identity = try TmuxSessionIdentity.decode(session.identity)
        guard attachment.version == 1, attachment.backend == .tmux else { throw RemoteSessionFailure.unsupported }
        guard validID(session.id), UInt64(identity.created) != nil, UInt64(identity.serverPID) != nil else {
            throw RemoteSessionFailure.invalidResponse
        }
        var condition = "#{&&:#{==:#{session_created},\(identity.created)},#{==:#{pid},\(identity.serverPID)}}"
        if let token = attachment.ownershipToken {
            condition = "#{&&:\(condition),#{==:#{TERMIND_TMUX_OWNER},\(token.uuidString)}}"
        }
        return condition
    }

    public static func attach(_ attachment: RemoteSessionReference) throws -> String {
        let target = try quote(attachment.session.id)
        // The guard and attach share tmux's command queue; never use -d, -A, or a name prefix.
        let command = "attach-session -t \(target)"
        return
            "exec tmux if-shell -t \(target) -F \(try quote(identityCondition(attachment))) \(try quote(command)) 'display-message -p TERMIND_IDENTITY_MISMATCH'"
    }

    public static func terminate(_ attachment: RemoteSessionReference) throws -> String {
        guard attachment.ownershipToken != nil else { throw RemoteSessionFailure.ownershipMismatch }
        let target = try quote(attachment.session.id)
        return """
            [ "$(tmux display-message -p -t \(target) \(try quote(identityCondition(attachment))))" = 1 ] || exit 79
            tmux if-shell -t \(target) -F \(try quote(identityCondition(attachment))) \
            \(try quote("kill-session -t \(target) ; display-message -p TERMIND_ENDED"))
            """
    }
}
