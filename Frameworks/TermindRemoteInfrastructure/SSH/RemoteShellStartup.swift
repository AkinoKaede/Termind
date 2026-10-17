import Foundation
import TermindDomain

/// Private, per-session startup files. Nothing is ever typed into an attached terminal.
nonisolated enum RemoteShellStartup {
    static func ordinaryCommand(helper: String) throws -> String {
        "export TERMIND_TMUX_HELPERS=\(try RemoteMultiplexerCommands.quote(helper)); exec /bin/sh \"$TERMIND_TMUX_HELPERS/shell\""
    }

    static func install(
        token: UUID, startupCommand: String?, shellIntegration: Bool, ordinary: Bool = false,
        backend: String? = nil, environment: [HostEnvironmentVariable] = []
    ) throws -> String {
        let eventToken = ordinary ? token : UUID()
        let bootstrap = RemoteShellIntegrationBootstrap(token: eventToken.uuidString)
        let startup = try RemoteMultiplexerCommands.quote(startupCommand ?? "")
        let reportsStartup = shellIntegration && startupCommand?.isEmpty == false
        let posixStartup = """
            if [ "${TERMIND_TMUX_FIRST:-}" = 1 ]; then
                unset TERMIND_TMUX_FIRST
                \(backend == nil ? "" : "mkdir \"$TERMIND_TMUX_HELPERS/startup-decision\" 2>/dev/null || return")
                printf '%s\\n' '\(token.uuidString)' > "$TERMIND_TMUX_HELPERS/started"
                \(reportsStartup ? "__termind_startup_time=$(date +%s); __termind_event start \"$(__termind_encode \(startup))\"" : "")
                eval \(startup)
                \(reportsStartup ? "__termind_startup_status=$?; __termind_event finish \"$__termind_startup_status\" \"$(( ($(date +%s) - __termind_startup_time) * 1000 ))\"" : "")
            fi
            """
        let fishStartup = """
            if test "$TERMIND_TMUX_FIRST" = 1
                set -e TERMIND_TMUX_FIRST
                \(backend == nil ? "" : "command mkdir \"$TERMIND_TMUX_HELPERS/startup-decision\" 2>/dev/null; or return")
                printf '%s\\n' '\(token.uuidString)' > "$TERMIND_TMUX_HELPERS/started"
                \(reportsStartup ? "set -g __termind_startup_time (date +%s); __termind_event start (string escape --style=url -- \(startup))" : "")
                eval \(startup)
                \(reportsStartup ? "set -l command_status $status; set -l elapsed (math (date +%s) - $__termind_startup_time); __termind_event finish $command_status (math $elapsed '*' 1000)" : "")
            end
            """
        let bash =
            (shellIntegration
                ? RemoteShellContextJournal.initialization(
                    shell: "bash", token: eventToken.uuidString, backend: backend)
                    + "\n" + String(decoding: bootstrap.installationCommand(for: "bash", runtime: true)!, as: UTF8.self)
                : "")
            + "\n" + (shellIntegration ? "__termind_command_ready=0\n" : "") + posixStartup
            + (shellIntegration ? "\n__termind_report_prompt\n" : "")
        let zsh =
            (shellIntegration
                ? RemoteShellContextJournal.initialization(shell: "zsh", token: eventToken.uuidString, backend: backend)
                    + "\n" + String(decoding: bootstrap.installationCommand(for: "zsh", runtime: true)!, as: UTF8.self)
                : "")
            + "\n" + posixStartup
        let fish =
            (shellIntegration
                ? RemoteShellContextJournal.initialization(
                    shell: "fish", token: eventToken.uuidString, backend: backend)
                    + "\n" + String(decoding: bootstrap.installationCommand(for: "fish", runtime: true)!, as: UTF8.self)
                : "")
            + "\n" + fishStartup
        let shell = """
            #!/bin/sh
            if [ "${1:-}" = --termind-check-executable ]; then exit 0; fi
            \(backend == nil ? "" : """
            if [ "${TERMIND_SHELL_LOCALE_SET:-}" = x ]; then
                export LC_ALL="$TERMIND_SHELL_LOCALE"
            else
                unset LC_ALL
            fi
            unset TERMIND_SHELL_LOCALE_SET TERMIND_SHELL_LOCALE
            """)
            \(backend.flatMap { RemoteMultiplexerRegistry.socketDialect(.init(rawValue: $0)) }?.restoreShellEnvironment ?? "")
            \(try RemoteMultiplexerCommands.environment(environment))
            SHELL=${TERMIND_TMUX_SHELL:-${SHELL:-/bin/sh}}
            export SHELL
            if [ "$#" -gt 0 ]; then exec "$SHELL" "$@"; fi
            unset __termind_context_dir
            \(backend == nil ? "" : """
            unset TERMIND_TMUX_FIRST
            if mkdir "$TERMIND_TMUX_HELPERS/first-claimed" 2>/dev/null; then
                export TERMIND_TMUX_FIRST=1
            fi
            """)
            export TERMIND_CONTEXT_OSC=\(ordinary ? "1" : "0")
            case "$SHELL" in
                */bash)
                    export PROMPT_COMMAND='. "$TERMIND_TMUX_HELPERS/bashrc"'
                    exec "$SHELL" --noprofile -il ;;
                */zsh) export TERMIND_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"; export ZDOTDIR="$TERMIND_TMUX_HELPERS"; exec "$SHELL" -il ;;
                */fish) exec "$SHELL" -il --init-command "source \\"$TERMIND_TMUX_HELPERS/fish\\"" ;;
                *) exec "${SHELL:-/bin/sh}" -l ;;
            esac
            """
        let bashrc = """
            [ -z "${__termind_context_dir:-}" ] || return
            unset PROMPT_COMMAND
            # Keep login-shell semantics while running the hooks after user configuration.
            # An exec in a login script intentionally bypasses the rest of this wrapper.
            [ ! -r /etc/profile ] || . /etc/profile
            for profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [ -r "$profile" ]; then . "$profile"; break; fi
            done
            \(bash)
            """
        // Run the first command inside the initialized shell, preserving cd/export state.
        // Subsequent ordinary panes use `shell` directly and cannot replay this command.
        let first = "#!/bin/sh\nexport TERMIND_TMUX_FIRST=1\nexec /bin/sh \"$TERMIND_TMUX_HELPERS/shell\"\n"
        var files = [
            "shell": shell, "first": first, "bashrc": bashrc, "fish": fish, "event": RemoteShellContextJournal.writer,
            "request-reader": RemoteShellContextJournal.requestReader, "event-token": eventToken.uuidString,
        ]
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            files[name] = """
                export ZDOTDIR="$TERMIND_USER_ZDOTDIR"
                [[ -r "$TERMIND_USER_ZDOTDIR/\(name)" ]] && source "$TERMIND_USER_ZDOTDIR/\(name)"
                export TERMIND_USER_ZDOTDIR="$ZDOTDIR"
                export ZDOTDIR="$TERMIND_TMUX_HELPERS"
                """
        }
        files[".zlogin", default: ""] += "\nexport ZDOTDIR=\"$TERMIND_USER_ZDOTDIR\"\n\(zsh)\n"
        let writes = try files.keys.sorted().map { name in
            "printf '%s\\n' \(try RemoteMultiplexerCommands.quote(files[name]!)) > \"$helper/\(name)\" || exit 78"
        }.joined(separator: "\n")
        return """
            umask 077
            helper=$(mktemp -d "/tmp/termind-shell.XXXXXXXX") || exit 78
            \(writes)
            chmod 700 "$helper/shell" "$helper/first" || exit 78
            \(ordinary ? "" : """
            "$helper/shell" --termind-check-executable >/dev/null 2>&1 || { rm -rf "$helper"; exit 78; }
            """)
            """
    }
}

/// Only ordinary startup uses the plain-shell fallback, never multiplexer inspection.
nonisolated struct RemoteShellStartupReadiness {
    private let generation: UUID
    private var deadline: UInt64?

    init(generation: UUID, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.generation = generation
        deadline = now + 3_000_000_000
    }

    mutating func receive(_ update: TerminalRuntimeUpdate) {
        if update.status == .ordinary || update.status == .multiplexer || update.backend != nil {
            deadline = nil
        }
    }

    mutating func poll(generation: UUID, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard self.generation == generation else {
            deadline = nil
            return false
        }
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
