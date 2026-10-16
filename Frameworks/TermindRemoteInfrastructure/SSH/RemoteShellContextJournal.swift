import Foundation
import TermindApplication
import TermindDomain

/// One writer per shell instance; readers see an atomic, bounded snapshot plus event tail.
nonisolated enum RemoteShellContextJournal {
    static let requestReader = #"""
        #!/bin/sh
        dir=$1; expected=$2
        [ -f "$dir/request" ] && [ ! -L "$dir/request" ] || exit 1
        IFS='|' read -r request seq action value deadline original < "$dir/request" || exit 1
        rm -f "$dir/request"
        [ "$action" = "$expected" ] || exit 1
        case "$deadline:$seq" in *[!0-9:]*|:) exit 1 ;; esac
        [ "$(date +%s)" -le "$deadline" ] || exit 1
        IFS='|' read -r tag current ready cwd < "$dir/state" || exit 1
        [ "$seq" = "$current" ] && [ "$ready" = 1 ] || exit 1
        printf '%s|%s|%s\n' "$request" "$value" "$original"
        """#

    static func draftWidget(shell: String, replacing: Bool) -> String {
        let action = replacing ? "replace" : "read"
        if shell == "fish" {
            return """
                set -l response (command sh "$TERMIND_TMUX_HELPERS/request-reader" "$__termind_context_dir" \(action));
                test $status -eq 0; or return;
                set -l fields (string split '|' -- "$response");
                if test "$fields[3]" != '-'; and test (commandline | string collect) != (string unescape --style=url -- "$fields[3]" | string collect); return; end;
                \(replacing ? "commandline -r -- (string unescape --style=url -- \"$fields[2]\");" : "")
                __termind_event draft (string escape --style=url -- (commandline)) "$fields[1]"
                """
        }
        let buffer = shell == "bash" ? "READLINE_LINE" : "BUFFER"
        let cursor = shell == "bash" ? "READLINE_POINT" : "CURSOR"
        return """
            local response request value original;
            response=$(command sh "$TERMIND_TMUX_HELPERS/request-reader" "$__termind_context_dir" \(action)) || return;
            IFS='|' read -r request value original <<< "$response";
            if [ "$original" != '-' ]; then
                original=$(builtin printf '%b.' "$(printf '%s' "$original" | sed 's/%/\\\\x/g')");
                [ "$\(buffer)" = "${original%.}" ] || return;
            fi;
            \(replacing ? "value=$(builtin printf '%b.' \"$(printf '%s' \"$value\" | sed 's/%/\\\\x/g')\"); \(buffer)=${value%.}; \(cursor)=${#\(buffer)};" : "")
            __termind_event draft "$(__termind_encode "$\(buffer)")" "$request"
            """
    }

    static let writer = #"""
        #!/bin/sh
        set -f
        dir=$1; kind=$2; value=${3-}; extra=${4-}
        [ -d "$dir" ] && [ ! -L "$dir" ] || exit 1
        case "$kind" in start|finish|prompt|directory|draft) ;; *) exit 1 ;; esac
        [ "${#value}" -le 8192 ] || value=
        [ "${#extra}" -le 8192 ] || extra=
        seq=0; ready=0; cwd=
        if [ -f "$dir/state" ]; then
            IFS='|' read -r tag seq ready cwd < "$dir/state"
        fi
        seq=$((seq + 1))
        case "$kind" in start) ready=0 ;; prompt) ready=1 ;; directory) cwd=$value ;; esac
        printf 'R1|%s|%s|%s\n' "$seq" "$ready" "$cwd" > "$dir/state.tmp"
        mv "$dir/state.tmp" "$dir/state"
        {
            cat "$dir/meta"
            cat "$dir/state"
            if [ -f "$dir/journal" ]; then sed '1,2d' "$dir/journal" | tail -n 31; fi
            printf 'E1|%s|%s|%s|%s\n' "$seq" "$kind" "$value" "$extra"
        } > "$dir/journal.tmp"
        mv "$dir/journal.tmp" "$dir/journal"
        if [ "${TERMIND_CONTEXT_OSC:-}" = 1 ]; then
            printf '\033]777;TermindContext=%s;' "$TERMIND_CONTEXT_TOKEN"
            cat "$dir/meta"
            cat "$dir/state"
            printf 'E1|%s|%s|%s|%s\n\007' "$seq" "$kind" "$value" "$extra"
        fi
        """#

    static func initialization(shell: String, token: String, backend: String? = nil) -> String {
        let paneVariable = RemoteMultiplexerRegistry.dialect(.init(rawValue: backend ?? "tmux"))?.paneVariable
        let tag = backend == nil ? "M1" : "M2"
        let suffix = backend.map { "|\($0)" } ?? ""
        if shell == "fish" {
            return """
                if set -q __termind_context_dir; return; end
                set -gx TERMIND_CONTEXT_TOKEN '\(token)'
                set -gx __termind_context_dir (command mktemp -d "$TERMIND_TMUX_HELPERS/ctx.XXXXXXXX")
                test -n "$__termind_context_dir"; or return
                \(backend == nil ? "" : """
                command env LC_ALL=C TZ=UTC ps -p "$fish_pid" -o lstart= | string trim > "$__termind_context_dir/process-start"
                """)
                set -l pane shell
                \(paneVariable.map { "if set -q \($0); set pane \"$\($0)\"; end" } ?? "")
                set -l history_name fish
                if set -q fish_history; set history_name "$fish_history"; end
                set -l history_base "$HOME/.local/share"
                if set -q XDG_DATA_HOME; set history_base "$XDG_DATA_HOME"; end
                set -l history_path ''
                if test -n "$history_name"; set history_path "$history_base/fish/$history_name"_history; end
                printf '\(tag)|%s|%s|%s|fish|%s|%s|%s\(suffix)\\n' "$TERMIND_CONTEXT_TOKEN" "$pane" \
                (command basename "$__termind_context_dir") (string escape --style=url -- "$HOME") "$fish_pid" \
                (string escape --style=url -- "$history_path") > "$__termind_context_dir/meta"
                function __termind_event
                    command sh "$TERMIND_TMUX_HELPERS/event" "$__termind_context_dir" $argv
                end
                """
        }
        return """
            [ -z "${__termind_context_dir:-}" ] || return
            export TERMIND_CONTEXT_TOKEN='\(token)'
            __termind_context_dir=$(command mktemp -d "$TERMIND_TMUX_HELPERS/ctx.XXXXXXXX") || return
            export __termind_context_dir
            \(backend == nil ? "" : """
            command env LC_ALL=C TZ=UTC ps -p "$$" -o lstart= | sed 's/^ *//;s/ *$//' > "$__termind_context_dir/process-start"
            """)
            __termind_event() { command sh "$TERMIND_TMUX_HELPERS/event" "$__termind_context_dir" "$@"; }
            __termind_home=$(printf '%s' "$HOME" | od -An -v -tx1 | tr -d ' \\n' | sed 's/../%&/g')
            __termind_history=${HISTFILE:-}
            case "$__termind_history" in ''|/*) ;; *) __termind_history="$PWD/$__termind_history" ;; esac
            __termind_history=$(printf '%s' "$__termind_history" | od -An -v -tx1 | tr -d ' \\n' | sed 's/../%&/g')
            printf '\(tag)|%s|%s|%s|\(shell)|%s|%s|%s\(suffix)\\n' "$TERMIND_CONTEXT_TOKEN" "\(paneVariable.map { "${\($0):-shell}" } ?? "shell")" \
            "${__termind_context_dir##*/}" "$__termind_home" "$$" "$__termind_history" > "$__termind_context_dir/meta"
            """
    }
}

nonisolated struct RemoteShellContextRecord {
    let backend: String
    let token: String
    let pane: String
    let instance: String
    let shell: String
    let process: String
    let home: String?
    let historyPath: String?
    let directory: String?
    let ready: Bool
    let sequence: UInt64
    let entries: [(UInt64, TerminalContextEvent.Payload)]

    init(_ text: String, charset: RemoteCharset = .utf8) throws {
        guard text.utf8.count <= 512 * 1024 else { throw TerminalRuntimeError.invalidResponse }
        // PTYs may expand the record's line separators to CRLF; field data is percent encoded.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { throw TerminalRuntimeError.invalidResponse }
        let meta = lines[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let state = lines[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let legacy = (7...8).contains(meta.count) && meta.first == "M1"
        let modern = meta.count == 9 && meta.first == "M2"
        guard legacy || modern else { throw TerminalRuntimeError.invalidResponse }
        let backend = modern ? meta[8] : (meta[2] == "shell" ? "shell" : "tmux")
        guard UUID(uuidString: meta[1]) != nil, UInt64(meta[6]) != nil,
            Self.validPane(meta[2], backend: backend),
            meta[3].hasPrefix("ctx."),
            meta[3].utf8.allSatisfy({
                $0 == 46 || (48...57).contains($0)
                    || (65...90).contains($0) || (97...122).contains($0)
            }),
            ["bash", "zsh", "fish"].contains(meta[4]),
            state.count == 4, state[0] == "R1", let sequence = UInt64(state[1]),
            ["0", "1"].contains(state[2])
        else { throw TerminalRuntimeError.invalidResponse }
        token = meta[1]
        self.backend = backend
        pane = meta[2]
        instance = meta[3]
        shell = meta[4]
        process = meta[6]
        self.sequence = sequence
        ready = state[2] == "1"
        func decode(_ value: String) throws -> String {
            let bytes = Array(value.utf8)
            var index = 0
            while index < bytes.count {
                if bytes[index] == 37 {
                    guard index + 2 < bytes.count,
                        bytes[(index + 1)...(index + 2)].allSatisfy({
                            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                        })
                    else { throw TerminalRuntimeError.invalidResponse }
                    index += 3
                } else {
                    guard bytes[index] >= 32, bytes[index] < 127 else { throw TerminalRuntimeError.invalidResponse }
                    index += 1
                }
            }
            return RemoteCommandEventFilter.decodePercentEncoded(Data(bytes), charset: charset)
        }
        let home = try decode(meta[5])
        self.home = home.hasPrefix("/") ? home : nil
        let history = try meta.count >= 8 ? decode(meta[7]) : ""
        historyPath =
            (history.isEmpty || history.hasPrefix("/"))
                && !history.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            ? history : nil
        let cwd = try decode(state[3])
        directory = cwd.hasPrefix("/") ? cwd : nil
        var events: [(UInt64, TerminalContextEvent.Payload)] = []
        var last: UInt64?
        for line in lines.dropFirst(2) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, parts[0] == "E1", let seq = UInt64(parts[1]), seq <= sequence,
                seq > 0, last == nil || (last! < UInt64.max && seq == last! + 1)
            else { throw TerminalRuntimeError.invalidResponse }
            last = seq
            let event: TerminalContextEvent.Payload
            switch parts[2] {
            case "start": event = .commandStarted(try decode(parts[3]))
            case "finish":
                guard let status = Int32(parts[3]), (0...255).contains(status),
                    let ms = UInt64(parts[4]), ms <= 31_536_000_000
                else { throw TerminalRuntimeError.invalidResponse }
                event = .commandFinished(status, duration: Double(ms) / 1000)
            case "prompt": event = .promptReady
            case "directory": event = .directory(try decode(parts[3]))
            case "draft":
                guard UUID(uuidString: parts[4]) != nil else { throw TerminalRuntimeError.invalidResponse }
                event = .draft(request: parts[4], value: try decode(parts[3]))
            default: throw TerminalRuntimeError.invalidResponse
            }
            events.append((seq, event))
        }
        guard events.count <= 32, last == sequence else { throw TerminalRuntimeError.invalidResponse }
        entries = events
    }

    static func validPane(_ value: String) -> Bool {
        value.hasPrefix("%") && value.count > 1 && value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    static func validPane(_ value: String, backend: String) -> Bool {
        if backend == "shell" { return value == "shell" }
        return RemoteMultiplexerRegistry.dialect(.init(rawValue: backend))?.validPane(value) ?? false
    }

    func context(server: String, session: String, backend: String) -> TerminalShellContext {
        TerminalShellContext(
            identity: .init(backend: backend, server: server, session: session, pane: pane, shellInstance: instance),
            shell: shell, directory: directory, home: home, promptReady: ready, sequence: sequence,
            capabilities: [.directory, .commandLifecycle], historyPath: historyPath)
    }

    func events(for context: TerminalShellContext) -> [TerminalContextEvent] {
        entries.map { .init(context: context.identity, sequence: $0.0, payload: $0.1) }
    }
}
