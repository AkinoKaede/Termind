import Foundation

/// Private, per-session startup files. Nothing is ever typed into an attached terminal.
nonisolated enum RemoteTmuxShellStartup {
    static func install(
        token: UUID, startupCommand: String?, shellIntegration: Bool, ordinary: Bool = false
    ) throws -> String {
        let eventToken = ordinary ? token : UUID()
        let bootstrap = RemoteShellIntegrationBootstrap(token: eventToken.uuidString)
        let startup = try RemoteTmuxCommands.quote(startupCommand ?? "")
        let reportsStartup = shellIntegration && startupCommand?.isEmpty == false
        let posixStartup = """
            if [ "${TERMIND_TMUX_FIRST:-}" = 1 ]; then
                unset TERMIND_TMUX_FIRST
                \(reportsStartup ? "__termind_startup_time=$(date +%s); __termind_event start \"$(__termind_encode \(startup))\"" : "")
                eval \(startup)
                \(reportsStartup ? "__termind_startup_status=$?; __termind_event finish \"$__termind_startup_status\" \"$(( ($(date +%s) - __termind_startup_time) * 1000 ))\"" : "")
            fi
            """
        let fishStartup = """
            if test "$TERMIND_TMUX_FIRST" = 1
                set -e TERMIND_TMUX_FIRST
                \(reportsStartup ? "set -g __termind_startup_time (date +%s); __termind_event start (string escape --style=url -- \(startup))" : "")
                eval \(startup)
                \(reportsStartup ? "set -l command_status $status; set -l elapsed (math (date +%s) - $__termind_startup_time); __termind_event finish $command_status (math $elapsed '*' 1000)" : "")
            end
            """
        let bash =
            (shellIntegration
                ? RemoteShellContextJournal.initialization(shell: "bash", token: eventToken.uuidString)
                    + "\n" + String(decoding: bootstrap.installationCommand(for: "bash", runtime: true)!, as: UTF8.self)
                : "")
            + "\n" + (shellIntegration ? "__termind_command_ready=0\n" : "") + posixStartup
            + (shellIntegration ? "\n__termind_report_prompt\n" : "")
        let zsh =
            (shellIntegration
                ? RemoteShellContextJournal.initialization(shell: "zsh", token: eventToken.uuidString)
                    + "\n" + String(decoding: bootstrap.installationCommand(for: "zsh", runtime: true)!, as: UTF8.self)
                : "")
            + "\n" + posixStartup
        let fish =
            (shellIntegration
                ? RemoteShellContextJournal.initialization(shell: "fish", token: eventToken.uuidString)
                    + "\n" + String(decoding: bootstrap.installationCommand(for: "fish", runtime: true)!, as: UTF8.self)
                : "")
            + "\n" + fishStartup
        let shell = """
            #!/bin/sh
            SHELL=${TERMIND_TMUX_SHELL:-${SHELL:-/bin/sh}}
            export SHELL
            if [ "$#" -gt 0 ]; then exec "$SHELL" "$@"; fi
            unset __termind_context_dir
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
        let first = "#!/bin/sh\nexport TERMIND_TMUX_FIRST=1\nexec \"$TERMIND_TMUX_HELPERS/shell\"\n"
        var files = [
            "shell": shell, "first": first, "bashrc": bashrc, "fish": fish, "event": RemoteShellContextJournal.writer,
            "request-reader": RemoteShellContextJournal.requestReader,
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
            "printf '%s\\n' \(try RemoteTmuxCommands.quote(files[name]!)) > \"$helper/\(name)\" || exit 78"
        }.joined(separator: "\n")
        return """
            umask 077
            helper=$(mktemp -d "/tmp/termind-shell.XXXXXXXX") || exit 78
            \(writes)
            chmod 700 "$helper/shell" "$helper/first" || exit 78
            """
    }
}
