// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

/// A native directory is display-only. It never manufactures prompt or draft permissions.
nonisolated struct RemoteNativeMultiplexerRuntime {
    let client: RemoteTerminalProcessProbe.Client
    let execute: RemoteSessionCommandExecutor

    func inspect(terminal: String) async throws -> TerminalRuntimeUpdate {
        guard let endpoint = client.endpoint else { return unavailable(.clientUnbound) }
        let result = try await execute(command(terminal: terminal, endpoint: endpoint))
        guard result.exitCode == 0, !result.truncated else { return unavailable(.inspectionUnavailable) }
        let update = try Self.parse(result.stdout, client: client)
        guard try await RemoteTerminalProcessProbe(execute: execute).inspect(terminal: terminal) == client else {
            return unavailable(.clientUnbound)
        }
        return update
    }

    private func unavailable(_ issue: TerminalRuntimeIssue) -> TerminalRuntimeUpdate {
        .init(status: .multiplexer, clientIdentity: client.identity, backend: client.backend, issue: issue)
    }

    private func command(terminal: String, endpoint: String) throws -> String {
        let path = endpoint as NSString
        let name = path.lastPathComponent
        let root = path.deletingLastPathComponent
        let body: String
        switch client.backend {
        case .zellij:
            guard RemoteMultiplexerCommands.validName(name) else { throw TerminalRuntimeError.unsupported }
            body = """
                root=\(try RemoteMultiplexerCommands.quote(root))
                release=$(printf '%s' "$version" | awk '{print $2}')
                case "${root##*/}" in "$release"|contract_version_*) root=${root%/*} ;; esac
                export ZELLIJ_SOCKET_DIR="$root"
                focus=$("$exe" --session \(try RemoteMultiplexerCommands.quote(name)) action list-clients) || exit 79
                native=$("$exe" --session \(try RemoteMultiplexerCommands.quote(name)) action list-panes --json) || exit 79
                [ "$focus" = "$("$exe" --session \(try RemoteMultiplexerCommands.quote(name)) action list-clients)" ] || exit 79
                """
        case .zmx:
            guard RemoteMultiplexerCommands.validName(name) else { throw TerminalRuntimeError.unsupported }
            body = """
                export ZMX_DIR=\(try RemoteMultiplexerCommands.quote(root))
                native=$("$exe" list) || exit 79
                pid=$(printf '%s\\n' "$native" | awk -F '\\t' -v target=\(try RemoteMultiplexerCommands.quote(name)) '
                    {sub(/^ +/, "", $1); n=""; p=""; for(i=1;i<=NF;i++) {
                        if($i ~ /^name=/) n=substr($i,6)
                        if($i ~ /^pid=[0-9]+$/) p=substr($i,5)
                    } if(n==target) print p}')
                case "$pid" in ''|*[!0-9]*) exit 79 ;; esac
                parent=$(ps -p "$pid" -o ppid= | tr -d ' ')
                parent_name=$(ps -p "$parent" -o comm=)
                [ "${parent_name##*/}" = zmx ] || exit 79
                born=$(process_start "$pid")
                shell=$(ps -p "$pid" -o comm=); shell=${shell##*/}; shell=${shell#-}
                case "$shell" in bash|zsh|fish) ;; *) printf 'NESTED\\n'; exit 0 ;; esac
                tty=$(ps -p "$pid" -o tty= | tr -d ' ')
                foreground=$(ps -t "$tty" -o pgid= -o tpgid= -o comm= | awk '$1==$2 && $2>0 {n=$3; sub(/^.*\\//,"",n); print n}')
                case "$foreground" in *tmux*|*zellij*|*zmx*|*herdr*|ssh|mosh|et) printf 'NESTED\\n'; exit 0 ;; esac
                if [ -d "/proc/$pid" ]; then directory=$(readlink "/proc/$pid/cwd")
                elif command -v lsof >/dev/null 2>&1; then
                    directory=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
                fi
                [ -n "$born" ] && [ "$(process_start "$pid")" = "$born" ] || exit 79
                focus="$pid:$born"
                [ "$native" = "$("$exe" list)" ] || exit 79
                """
        case .herdr:
            guard name == "herdr-client.sock" else { throw TerminalRuntimeError.unsupported }
            body = """
                export HERDR_SOCKET_PATH=\(try RemoteMultiplexerCommands.quote(root + "/herdr.sock"))
                api_fp=$(fingerprint "$HERDR_SOCKET_PATH") || exit 79
                native=$("$exe" pane list) || exit 79
                [ "$(fingerprint "$HERDR_SOCKET_PATH")" = "$api_fp" ] || exit 79
                """
        default: throw TerminalRuntimeError.unsupported
        }
        let versionArgument = client.backend == .zmx ? "version" : "--version"
        return """
            \(RemoteMultiplexerCommands.discovery(client.backend))
            \(RemoteMultiplexerCommands.utilities)
            \(try RemoteTerminalProcessProbe.guardClient(client, terminal: terminal))
            endpoint=\(try RemoteMultiplexerCommands.quote(endpoint))
            fp=$(fingerprint "$endpoint") || exit 79
            version=$("$exe" \(versionArgument)) || exit 79
            native=; focus=; directory=
            \(body)
            [ "$(fingerprint "$endpoint")" = "$fp" ] || exit 79
            \(try RemoteTerminalProcessProbe.guardClient(client, terminal: terminal))
            printf 'V|%s\\nI|%s\\nN|%s\\nF|%s\\nD|%s\\nDONE\\n' \
                "$(hex "$version")" "$fp" "$(hex "$native")" "$(hex "$focus")" "$(hex "$directory")"
            """
    }

    static func parse(_ text: String, client: RemoteTerminalProcessProbe.Client) throws -> TerminalRuntimeUpdate {
        func unavailable(_ issue: TerminalRuntimeIssue) -> TerminalRuntimeUpdate {
            .init(status: .multiplexer, clientIdentity: client.identity, backend: client.backend, issue: issue)
        }
        if text == "NESTED\n" { return unavailable(.nestedMultiplexer) }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 7, lines[5] == "DONE", lines[6].isEmpty,
            zip(lines, ["V|", "I|", "N|", "F|", "D|"]).allSatisfy({ $0.hasPrefix($1) }),
            let endpoint = client.endpoint
        else { throw TerminalRuntimeError.invalidResponse }
        let version = try RemoteMultiplexerCommands.unhex(String(lines[0].dropFirst(2)))
        do {
            try RemoteMultiplexerRegistry.dialect(client.backend)?.validateVersion(version)
        } catch {
            return unavailable(.unsupportedVersion)
        }
        let fingerprint = String(lines[1].dropFirst(2))
        guard fingerprint.split(separator: ":").count == 3,
            fingerprint.utf8.allSatisfy({ (48...57).contains($0) || $0 == 58 })
        else { throw TerminalRuntimeError.invalidResponse }
        let native = try RemoteMultiplexerCommands.unhex(String(lines[2].dropFirst(2)), limit: 1024 * 1024)
        let focus = try RemoteMultiplexerCommands.unhex(String(lines[3].dropFirst(2)), limit: 262144)
        var directory = try RemoteMultiplexerCommands.unhex(String(lines[4].dropFirst(2)))
        let pane: String
        var source = TerminalDirectorySource.nativePane
        switch client.backend {
        case .zellij:
            guard let selected = zellijPane(focus) else { return unavailable(.paneAmbiguous) }
            struct Pane: Decodable {
                let id: Int
                let isPlugin: Bool
                let paneCwd: String?
                let paneCommand: String?
                let exited: Bool?

                enum CodingKeys: String, CodingKey {
                    case id, exited
                    case isPlugin = "is_plugin"
                    case paneCwd = "pane_cwd"
                    case paneCommand = "pane_command"
                }
            }
            let panes = try JSONDecoder().decode([Pane].self, from: Data(native.utf8))
            let matches = panes.filter { !$0.isPlugin && String($0.id) == selected && $0.exited != true }
            guard matches.count == 1, let selectedPane = matches.first else { return unavailable(.paneAmbiguous) }
            if isNested(selectedPane.paneCommand) { return unavailable(.nestedMultiplexer) }
            pane = selected
            directory = selectedPane.paneCwd ?? ""
        case .zmx:
            let path = endpoint as NSString
            let root = path.deletingLastPathComponent.utf8.map { String(format: "%02x", $0) }.joined()
            let sessions = try RemoteZmxCommands.parseList("ROOT|\(root)\n" + native + "\nEND\n")
            guard let session = sessions.first(where: { $0.name == path.lastPathComponent }),
                let process = session.process, focus.hasPrefix(process + ":"), session.clients.map({ $0 > 0 }) == true
            else { return unavailable(.clientUnbound) }
            pane = "shell"
            source = .process
        case .herdr:
            struct Response: Decodable {
                struct Result: Decodable {
                    struct Pane: Decodable {
                        let paneID: String
                        let foregroundCwd: String?

                        enum CodingKeys: String, CodingKey {
                            case paneID = "pane_id"
                            case foregroundCwd = "foreground_cwd"
                        }
                    }
                    let panes: [Pane]
                }
                let result: Result
            }
            let response = try JSONDecoder().decode(Response.self, from: Data(native.utf8))
            // Herdr clients can have independent tab locations. Global focus is not client focus.
            guard response.result.panes.count == 1, let selected = response.result.panes.first,
                RemoteHerdrDialect().validPane(selected.paneID)
            else { return unavailable(.paneAmbiguous) }
            pane = selected.paneID
            directory = selected.foregroundCwd ?? ""
            source = .process
        default: throw TerminalRuntimeError.unsupported
        }
        guard RemoteMultiplexerCommands.validPath(directory) else { return unavailable(.directoryUnavailable) }
        let identity = TerminalContextIdentity(
            backend: client.backend.rawValue, server: endpoint + ":" + fingerprint, session: endpoint,
            pane: pane, shellInstance: "native:" + (focus.isEmpty ? pane : focus))
        let context = TerminalShellContext(
            identity: identity, shell: "", directory: directory, home: nil, promptReady: false, sequence: 0,
            capabilities: [], directorySource: source)
        return .init(
            status: .multiplexer, clientIdentity: client.identity, active: identity, contexts: [context],
            backend: client.backend, issue: .shellIntegrationUnavailable)
    }

    static func zellijPane(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard lines.first == ["CLIENT_ID", "ZELLIJ_PANE_ID", "RUNNING_COMMAND"], lines.count > 1 else { return nil }
        var panes: Set<String> = []
        var clients: Set<String> = []
        for fields in lines.dropFirst() {
            guard fields.count >= 2, UInt64(fields[0]) != nil, clients.insert(fields[0]).inserted,
                fields[1].hasPrefix("terminal_")
            else { return nil }
            let pane = String(fields[1].dropFirst("terminal_".count))
            guard RemoteZellijDialect().validPane(pane) else { return nil }
            panes.insert(pane)
        }
        // Without a native TTY-to-client ID API, only a unanimous focus is safe for display.
        return panes.count == 1 ? panes.first : nil
    }

    static func isNested(_ command: String?) -> Bool {
        guard let command else { return false }
        let executable = (command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "") as NSString
        return SessionPersistenceBackendID.supported.contains(.init(rawValue: executable.lastPathComponent))
            || ["ssh", "mosh", "et"].contains(executable.lastPathComponent)
    }
}
