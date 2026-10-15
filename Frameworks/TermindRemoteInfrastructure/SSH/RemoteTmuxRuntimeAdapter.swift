import Foundation
import TermindApplication
import TermindDomain

public nonisolated struct RemoteTmuxRuntimeAdapter: TerminalRuntimeAdapter {
    private let execute: RemoteSessionCommandExecutor
    private let charset: RemoteCharset
    public init(execute: @escaping RemoteSessionCommandExecutor, charset: RemoteCharset = .utf8) {
        self.execute = execute
        self.charset = charset
    }

    public func inspect(terminal: String) async throws -> TerminalRuntimeUpdate {
        let result = try await execute(Self.command(terminal: terminal))
        guard result.exitCode == 0, !result.truncated else { throw TerminalRuntimeError.unsupported }
        return try Self.parse(result.stdout, terminal: terminal, charset: charset)
    }

    static func command(terminal: String) throws -> String {
        guard terminal.hasPrefix("/dev/"),
            terminal.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [47, 46, 95, 45].contains($0)
            })
        else { throw TerminalRuntimeError.invalidResponse }
        return """
            export LC_ALL=C
            command -v tmux >/dev/null 2>&1 || exit 77
            tmux -V || exit 77
            client=$(tmux list-clients -F 'C|#{client_tty}|#{client_pid}|#{client_created}|#{pid}|#{session_id}|#{session_created}|#{pane_id}|#{client_flags}|#{client_key_table}' 2>/dev/null | \
            while IFS='|' read -r tag tty cp cc sp sid sc pane flags table; do
                if [ "$tty" = \(try RemoteTmuxCommands.quote(terminal)) ]; then
                    printf 'C|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' "$tty" "$cp" "$cc" "$sp" "$sid" "$sc" "$pane" "$flags" "$table"
                fi
            done)
            if [ -z "$client" ]; then printf 'NONE\\n'; exit 0; fi
            printf '%s\\n' "$client"
            sid=$(printf '%s' "$client" | cut -d '|' -f6)
            tmux list-panes -s -t "$sid" -F 'P|#{pane_id}|#{pane_pid}|#{pane_in_mode}|#{synchronize-panes}|#{?#{==:#{pane_current_command},bash},bash,#{?#{==:#{pane_current_command},zsh},zsh,#{?#{==:#{pane_current_command},fish},fish,unknown}}}' || exit 78
            helper=$(tmux show-environment -t "$sid" TERMIND_TMUX_HELPERS 2>/dev/null)
            helper=${helper#TERMIND_TMUX_HELPERS=}
            case "$helper" in /tmp/termind-shell.*) ;; *) printf 'DONE\\n'; exit 0 ;; esac
            suffix=${helper#/tmp/termind-shell.}
            case "$suffix" in ''|*[!a-zA-Z0-9]*) printf 'DONE\\n'; exit 0 ;; esac
            count=0
            for file in "$helper"/ctx.*/journal; do
                [ -f "$file" ] && [ ! -L "$file" ] || continue
                count=$((count + 1)); [ "$count" -le 128 ] || exit 78
                printf 'BEGIN\\n'
                cat "$file" || exit 78
                printf 'END\\n'
            done
            printf 'DONE\\n'
            """
    }

    static func parse(_ text: String, terminal: String, charset: RemoteCharset = .utf8) throws -> TerminalRuntimeUpdate
    {
        var lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { throw TerminalRuntimeError.invalidResponse }
        try RemoteTmuxCommands.validateVersion(lines.removeFirst())
        if lines == ["NONE", ""] { return .init(status: .unknown) }
        guard let first = lines.first else { throw TerminalRuntimeError.invalidResponse }
        let client = first.components(separatedBy: "|")
        guard client.count == 10, client[0] == "C", client[1] == terminal,
            [2, 3, 4, 6].allSatisfy({ UInt64(client[$0]) != nil }),
            client[5].hasPrefix("$"), UInt64(client[5].dropFirst()) != nil,
            RemoteShellContextRecord.validPane(client[7])
        else { throw TerminalRuntimeError.invalidResponse }
        let flags = Set(client[8].split(separator: ",").map(String.init))
        guard !flags.contains("active-pane"), !flags.contains("read-only") else {
            return .init(status: .unavailable)
        }
        let server = client[4]
        let session = client[5] + ":" + client[6]
        let clientIdentity = terminal + ":" + client[2] + ":" + client[3]
        var panes: [String: (process: String, interactive: Bool, foregroundShell: String)] = [:]
        var records: [RemoteShellContextRecord] = []
        var index = 1
        while index < lines.count {
            let line = lines[index]
            index += 1
            if line == "DONE" {
                guard index == lines.count - 1, lines.last == "" else {
                    throw TerminalRuntimeError.invalidResponse
                }
                break
            }
            if line == "BEGIN" {
                let start = index
                while index < lines.count, lines[index] != "END" { index += 1 }
                guard index < lines.count else { throw TerminalRuntimeError.invalidResponse }
                records.append(
                    try RemoteShellContextRecord(lines[start..<index].joined(separator: "\n"), charset: charset))
                index += 1
            } else {
                let fields = line.components(separatedBy: "|")
                guard fields.count == 6, fields[0] == "P", RemoteShellContextRecord.validPane(fields[1]),
                    UInt64(fields[2]) != nil, ["0", "1"].contains(fields[3]), ["0", "1"].contains(fields[4]),
                    ["bash", "zsh", "fish", "unknown"].contains(fields[5]),
                    panes[fields[1]] == nil
                else { throw TerminalRuntimeError.invalidResponse }
                panes[fields[1]] = (fields[2], fields[3] == "0" && fields[4] == "0", fields[5])
            }
        }
        guard lines.dropLast().last == "DONE", panes[client[7]] != nil else {
            throw TerminalRuntimeError.invalidResponse
        }
        var contexts: [TerminalShellContext] = []
        var events: [TerminalContextEvent] = []
        var active: TerminalContextIdentity?
        for record in records {
            guard let pane = panes[record.pane], pane.process == record.process else { continue }
            var context = record.context(server: server, session: session, backend: "tmux")
            if pane.interactive, pane.foregroundShell == record.shell, context.promptReady {
                // A prefix key table changes input routing, not the verified pane's directory.
                if client[9] == "root" {
                    context.capabilities.formUnion([.readDraft, .replaceDraft])
                }
            } else {
                context.capabilities.remove(.directory)
            }
            contexts.append(context)
            events.append(contentsOf: record.events(for: context))
            if record.pane == client[7] {
                guard active == nil else { throw TerminalRuntimeError.invalidResponse }
                active = context.identity
            }
        }
        if active == nil {
            let identity = TerminalContextIdentity(
                backend: "tmux", server: server, session: session, pane: client[7],
                shellInstance: "unintegrated:" + panes[client[7]]!.process)
            contexts.append(
                .init(
                    identity: identity, shell: "", directory: nil, home: nil, promptReady: false,
                    sequence: 0, capabilities: []))
            active = identity
        }
        return .init(
            status: .multiplexer, clientIdentity: clientIdentity, active: active, contexts: contexts, events: events)
    }
}
