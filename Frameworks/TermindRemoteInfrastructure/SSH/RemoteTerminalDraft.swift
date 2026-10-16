import Foundation
import TermindApplication
import TermindDomain

nonisolated enum RemoteTerminalDraft {
    static func command(
        context: TerminalShellContext, terminal: String, helper: String?,
        clientIdentity: String?, request: UUID, replacement: String?, original: String? = nil,
        charset: RemoteCharset = .utf8, target: RemoteMultiplexerDraftTarget? = nil
    ) throws -> String {
        let identity = context.identity
        guard context.promptReady, ["bash", "zsh", "fish"].contains(context.shell),
            identity.shellInstance.hasPrefix("ctx."),
            identity.shellInstance.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
            }), replacement?.utf8.count ?? 0 <= 4096, replacement?.contains("\0") != true,
            original?.utf8.count ?? 0 <= 4096, original?.contains("\0") != true
        else { throw TerminalRuntimeError.staleContext }
        let root: String
        let trigger: String
        if let target {
            guard RemoteMultiplexerKind(rawValue: identity.backend) != nil else {
                throw TerminalRuntimeError.staleContext
            }
            root = target.root
            trigger = target.trigger
        } else if identity.backend == "tmux" {
            let target = try RemoteTmuxRuntimeDialect.draftTarget(
                context: context, terminal: terminal, clientIdentity: clientIdentity, replacing: replacement != nil)
            root = target.root
            trigger = target.trigger
        } else {
            guard identity.backend == "shell", let helper else { throw TerminalRuntimeError.staleContext }
            root = "helper=\(try RemoteMultiplexerCommands.quote(helper))"
            // The worker sends the negotiated widget key after this request is installed.
            trigger = "printf 'READY\\n'"
        }
        let bytes = try RemoteCharsetStreamConverter.encode(replacement ?? "", charset: charset)
        guard bytes.count <= 4096 else { throw TerminalRuntimeError.staleContext }
        let encoded = bytes.map { String(format: "%%%02X", $0) }.joined()
        let baselineBytes = try original.map { try RemoteCharsetStreamConverter.encode($0, charset: charset) }
        guard baselineBytes?.count ?? 0 <= 4096 else { throw TerminalRuntimeError.staleContext }
        let baseline = baselineBytes?.map { String(format: "%%%02X", $0) }.joined() ?? "-"
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
                helper=$(tmux show-environment -t \(try RemoteMultiplexerCommands.quote(String(session))) TERMIND_TMUX_HELPERS) || exit 79
                helper=${helper#TERMIND_TMUX_HELPERS=}
                """
        } else {
            guard let helper else { throw TerminalRuntimeError.staleContext }
            root = "helper=\(try RemoteMultiplexerCommands.quote(helper))"
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
