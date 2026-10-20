// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

nonisolated struct RemoteTmuxRuntimeDialect: RemoteMultiplexerRuntime {
    private let execute: RemoteSessionCommandExecutor
    private let charset: RemoteCharset
    init(execute: @escaping RemoteSessionCommandExecutor, charset: RemoteCharset = .utf8) {
        self.execute = execute
        self.charset = charset
    }

    func inspect(terminal: String) async throws -> TerminalRuntimeUpdate {
        let result = try await execute(Self.command(terminal: terminal))
        guard result.exitCode == 0, !result.truncated else { throw TerminalRuntimeError.unsupported }
        return try Self.parse(result.stdout, terminal: terminal, charset: charset)
    }

    func draftTarget(
        context: TerminalShellContext, terminal: String, replacing: Bool
    ) async throws -> RemoteMultiplexerDraftTarget {
        let update = try await inspect(terminal: terminal)
        guard update.active == context.identity,
            update.contexts.first(where: { $0.identity == context.identity }) == context
        else { throw TerminalRuntimeError.staleContext }
        return try Self.draftTarget(
            context: context, terminal: terminal, clientIdentity: update.clientIdentity, replacing: replacing)
    }

    func refreshSize(of client: RemoteTmuxClientIdentity) async throws {
        let result = try await execute(Self.resizeCommand(client: client))
        guard result.exitCode == 0, !result.truncated, result.stdout == "TERMIND_RESIZED\n" else {
            throw TerminalRuntimeError.staleContext
        }
    }

    static func resizeCommand(client: RemoteTmuxClientIdentity) throws -> String {
        let identity = [
            client.terminal, client.process, client.created, client.server, client.session, client.sessionCreated,
        ].joined(separator: "|")
        // Revalidate on the server immediately before signalling. A detached client's TTY
        // may already contain a shell, so this operation must never write terminal input.
        return """
            \(RemoteTmuxCommands.executionPreamble)
            client=$(tmux list-clients -F '#{client_tty}|#{client_pid}|#{client_created}|#{pid}|#{session_id}|#{session_created}|#{client_flags}' 2>/dev/null | \
            while IFS='|' read -r tty cp cc sp sid sc flags; do
                if [ "$tty" = \(try RemoteTmuxCommands.quote(client.terminal)) ]; then
                    case ",$flags," in
                        (*,read-only,*|*,ignore-size,*|*,active-pane,*|*,control-mode,*) continue ;;
                    esac
                    printf '%s|%s|%s|%s|%s|%s\\n' "$tty" "$cp" "$cc" "$sp" "$sid" "$sc"
                fi
            done)
            [ "$client" = \(try RemoteTmuxCommands.quote(identity)) ] || exit 79
            kill -WINCH \(client.process) || exit 79
            printf 'TERMIND_RESIZED\\n'
            """
    }

    static func command(terminal: String) throws -> String {
        guard RemoteTmuxClientIdentity.validTerminal(terminal) else { throw TerminalRuntimeError.invalidResponse }
        return """
            \(RemoteTmuxCommands.executionPreamble)
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
            panes=$(tmux list-panes -s -t "$sid" -F 'P|#{pane_id}|#{pane_pid}|#{pane_in_mode}|#{synchronize-panes}|#{?#{==:#{pane_current_command},bash},bash,#{?#{==:#{pane_current_command},zsh},zsh,#{?#{==:#{pane_current_command},fish},fish,unknown}}}') || exit 78
            printf '%s\\n' "$panes"
            pane=$(printf '%s' "$client" | cut -d '|' -f8)
            cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}') || exit 78
            foreground=$(tmux display-message -p -t "$pane" '#{pane_current_command}') || exit 78
            printf 'D|%s|%s|%s\\n' "$pane" \
                "$(printf '%s' "$cwd" | od -An -v -tx1 | tr -d ' \\n')" \
                "$(printf '%s' "$foreground" | od -An -v -tx1 | tr -d ' \\n')"
            helper=$(tmux show-environment -t "$sid" TERMIND_TMUX_HELPERS 2>/dev/null)
            helper=${helper#TERMIND_TMUX_HELPERS=}
            case "$helper" in /tmp/termind-shell.*) ;; *) printf 'DONE\\n'; exit 0 ;; esac
            suffix=${helper#/tmp/termind-shell.}
            case "$suffix" in ''|*[!a-zA-Z0-9]*) printf 'DONE\\n'; exit 0 ;; esac
            count=0
            for file in "$helper"/ctx.*/journal; do
                [ -f "$file" ] && [ ! -L "$file" ] || continue
                IFS='|' read -r tag token pane instance shell home pid history backend < "$file" || continue
                case "$tag:$backend" in M1:|M2:tmux) ;; *) continue ;; esac
                [ "$token" = "$(cat "$helper/event-token")" ] || continue
                dir=${file%/journal}
                [ ! -L "$dir" ] && [ "${dir##*/}" = "$instance" ] || continue
                [ "$(printf '%s\\n' "$panes" | awk -F '|' -v pane="$pane" '$2 == pane {print $3}')" = "$pid" ] || continue
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
            return .init(status: .unavailable, backend: .tmux, issue: .paneAmbiguous)
        }
        let server = client[4]
        let session = client[5] + ":" + client[6]
        let clientIdentity = terminal + ":" + client[2] + ":" + client[3]
        var panes: [String: (process: String, interactive: Bool, foregroundShell: String)] = [:]
        var records: [RemoteShellContextRecord] = []
        var nativeDirectory: String?
        var nativeCommand: String?
        var hasNativeDirectory = false
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
            if line.hasPrefix("D|") {
                let fields = line.components(separatedBy: "|")
                guard !hasNativeDirectory, fields.count == 4, fields[1] == client[7] else {
                    throw TerminalRuntimeError.invalidResponse
                }
                hasNativeDirectory = true
                let directory = try RemoteMultiplexerCommands.unhex(fields[2])
                nativeDirectory = RemoteMultiplexerCommands.validPath(directory) ? directory : nil
                nativeCommand = try RemoteMultiplexerCommands.unhex(fields[3])
            } else if line == "BEGIN" {
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
        let nested = RemoteNativeMultiplexerRuntime.isNested(nativeCommand)
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
            if record.pane == client[7], !nested {
                guard active == nil else { throw TerminalRuntimeError.invalidResponse }
                active = context.identity
            }
        }
        if active == nil, !nested {
            let identity = TerminalContextIdentity(
                backend: "tmux", server: server, session: session, pane: client[7],
                shellInstance: "unintegrated:" + panes[client[7]]!.process)
            contexts.append(
                .init(
                    identity: identity, shell: "", directory: nativeDirectory, home: nil, promptReady: false,
                    sequence: 0, capabilities: [], directorySource: .nativePane))
            active = identity
        }
        return .init(
            status: .multiplexer, clientIdentity: clientIdentity, active: active, contexts: contexts, events: events,
            backend: .tmux,
            issue: nested
                ? .nestedMultiplexer
                : (active?.shellInstance.hasPrefix("unintegrated:") == true ? .shellIntegrationUnavailable : nil))
    }
}

extension RemoteTmuxRuntimeDialect {
    static func draftTarget(context: TerminalShellContext, terminal: String, clientIdentity: String?, replacing: Bool)
        throws -> RemoteMultiplexerDraftTarget
    {
        let identity = context.identity
        let key = replacing ? "\u{1B}[777;2~" : "\u{1B}[777;1~"
        let session = identity.session.split(separator: ":").map(String.init)
        let client = clientIdentity?.split(separator: ":").map(String.init) ?? []
        guard session.count == 2, session[0].hasPrefix("$"), UInt64(session[0].dropFirst()) != nil,
            UInt64(session[1]) != nil, UInt64(identity.server) != nil,
            RemoteShellContextRecord.validPane(identity.pane), client.count == 3, client[0] == terminal,
            UInt64(client[1]) != nil, UInt64(client[2]) != nil
        else { throw TerminalRuntimeError.staleContext }
        let target = try RemoteTmuxCommands.quote(session[0])
        let root = """
            \(RemoteTmuxCommands.executionPreamble)
            [ "$(tmux display-message -p -t \(target) '#{pid}:#{session_created}')" = '\(identity.server):\(session[1])' ] || exit 79
            [ "$(tmux list-clients -F '#{client_tty}|#{client_pid}|#{client_created}|#{pane_id}|#{client_flags}|#{client_key_table}|#{session_id}|#{session_created}' | \
            awk -F '|' -v tty=\(try RemoteTmuxCommands.quote(terminal)) '$1 == tty {print $2 ":" $3 ":" $4 ":" $6 ":" $7 ":" $8; if ($5 ~ /active-pane|read-only/) print "UNSUPPORTED"}')" \
            = '\(client[1]):\(client[2]):\(identity.pane):root:\(identity.session)' ] || exit 79
            helper=$(tmux show-environment -t \(target) TERMIND_TMUX_HELPERS) || exit 79
            helper=${helper#TERMIND_TMUX_HELPERS=}
            """
        let guardFormat =
            "#{&&:#{==:#{pane_in_mode},0},#{&&:#{==:#{synchronize-panes},0},#{&&:#{==:#{pane_dead},0},#{==:#{pane_current_command},\(context.shell)}}}}"
        let trigger = """
            tmux if-shell -t \(try RemoteTmuxCommands.quote(identity.pane)) -F \(try RemoteTmuxCommands.quote(guardFormat)) \
            \(try RemoteTmuxCommands.quote("send-keys -t \(identity.pane) -l \(try RemoteTmuxCommands.quote(key))")) || exit 79
            """
        return .init(root: root, trigger: trigger)
    }
}
