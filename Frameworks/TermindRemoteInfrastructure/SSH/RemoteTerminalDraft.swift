import Foundation
import TermindApplication
import TermindDomain

nonisolated enum RemoteTerminalDraft {
    static func command(
        context: TerminalShellContext, terminal: String, helper: String?,
        clientIdentity: String?, request: UUID, replacement: String?, original: String? = nil,
        charset: RemoteCharset = .utf8
    ) throws -> String {
        let identity = context.identity
        guard context.promptReady, ["bash", "zsh", "fish"].contains(context.shell),
            identity.shellInstance.hasPrefix("ctx."),
            identity.shellInstance.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
            }), replacement?.utf8.count ?? 0 <= 4096, replacement?.contains("\0") != true
        else { throw TerminalRuntimeError.staleContext }
        let root: String
        let trigger: String
        let key = replacement == nil ? "\u{1B}[777;1~" : "\u{1B}[777;2~"
        if identity.backend == "tmux" {
            let session = identity.session.split(separator: ":").map(String.init)
            let client = clientIdentity?.split(separator: ":").map(String.init) ?? []
            guard session.count == 2, session[0].hasPrefix("$"), UInt64(session[0].dropFirst()) != nil,
                UInt64(session[1]) != nil, UInt64(identity.server) != nil,
                RemoteShellContextRecord.validPane(identity.pane), client.count == 3, client[0] == terminal,
                UInt64(client[1]) != nil, UInt64(client[2]) != nil
            else { throw TerminalRuntimeError.staleContext }
            let target = try RemoteTmuxCommands.quote(session[0])
            root = """
                [ "$(tmux display-message -p -t \(target) '#{pid}:#{session_created}')" = '\(identity.server):\(session[1])' ] || exit 79
                [ "$(tmux list-clients -F '#{client_tty}|#{client_pid}|#{client_created}|#{pane_id}|#{client_flags}|#{client_key_table}|#{session_id}|#{session_created}' | \
                awk -F '|' -v tty=\(try RemoteTmuxCommands.quote(terminal)) '$1 == tty {print $2 ":" $3 ":" $4 ":" $6 ":" $7 ":" $8; if ($5 ~ /active-pane|read-only/) print "UNSUPPORTED"}')" \
                = '\(client[1]):\(client[2]):\(identity.pane):root:\(identity.session)' ] || exit 79
                helper=$(tmux show-environment -t \(target) TERMIND_TMUX_HELPERS) || exit 79
                helper=${helper#TERMIND_TMUX_HELPERS=}
                """
            let guardFormat =
                "#{&&:#{==:#{pane_in_mode},0},#{&&:#{==:#{synchronize-panes},0},#{&&:#{==:#{pane_dead},0},#{==:#{pane_current_command},\(context.shell)}}}}"
            trigger = """
                tmux if-shell -t \(try RemoteTmuxCommands.quote(identity.pane)) -F \(try RemoteTmuxCommands.quote(guardFormat)) \
                \(try RemoteTmuxCommands.quote("send-keys -t \(identity.pane) -l \(try RemoteTmuxCommands.quote(key))")) || exit 79
                """
        } else {
            guard identity.backend == "shell", let helper else { throw TerminalRuntimeError.staleContext }
            root = "helper=\(try RemoteTmuxCommands.quote(helper))"
            // The worker sends the negotiated widget key after this request is installed.
            trigger = "printf 'READY\\n'"
        }
        let bytes = try RemoteCharsetStreamConverter.encode(replacement ?? "", charset: charset)
        guard bytes.count <= 4096 else { throw TerminalRuntimeError.staleContext }
        let encoded = bytes.map { String(format: "%%%02X", $0) }.joined()
        let baseline =
            try original.map {
                try RemoteCharsetStreamConverter.encode($0, charset: charset).map { String(format: "%%%02X", $0) }
                    .joined()
            } ?? "-"
        return """
            umask 077
            \(root)
            case "$helper" in /tmp/termind-shell.*) ;; *) exit 79 ;; esac
            suffix=${helper#/tmp/termind-shell.}
            case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 79 ;; esac
            dir="$helper/\(identity.shellInstance)"
            [ -d "$dir" ] && [ ! -L "$dir" ] || exit 79
            IFS='|' read -r tag seq ready cwd < "$dir/state" || exit 79
            [ "$seq" = '\(context.sequence)' ] && [ "$ready" = 1 ] || exit 79
            printf '%s|%s|%s|%s|%s|%s\\n' '\(request.uuidString)' '\(context.sequence)' \
            '\(replacement == nil ? "read" : "replace")' '\(encoded)' "$(( $(date +%s) + 2 ))" '\(baseline)' > "$dir/request.tmp"
            mv "$dir/request.tmp" "$dir/request"
            \(trigger)
            """
    }

    static func resultCommand(context: TerminalShellContext, helper: String?, request: UUID) throws -> String {
        let root: String
        if context.identity.backend == "tmux" {
            guard let session = context.identity.session.split(separator: ":").first else {
                throw TerminalRuntimeError.staleContext
            }
            root = """
                helper=$(tmux show-environment -t \(try RemoteTmuxCommands.quote(String(session))) TERMIND_TMUX_HELPERS) || exit 79
                helper=${helper#TERMIND_TMUX_HELPERS=}
                """
        } else {
            guard let helper else { throw TerminalRuntimeError.staleContext }
            root = "helper=\(try RemoteTmuxCommands.quote(helper))"
        }
        return """
            \(root)
            case "$helper" in /tmp/termind-shell.*) ;; *) exit 79 ;; esac
            suffix=${helper#/tmp/termind-shell.}
            case "$suffix" in ''|*[!a-zA-Z0-9]*) exit 79 ;; esac
            file="$helper/\(context.identity.shellInstance)/journal"
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                if [ -f "$file" ] && grep -F '|draft|' "$file" | grep -q -F '|\(request.uuidString)'; then cat "$file"; exit 0; fi
                sleep 0.1
            done
            exit 79
            """
    }
}
