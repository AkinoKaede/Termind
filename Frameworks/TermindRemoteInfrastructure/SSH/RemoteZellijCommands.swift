import Foundation
import TermindApplication
import TermindDomain

nonisolated enum RemoteZellijCommands {
    static let userRoot = #"""
        if [ -n "${ZELLIJ_SOCKET_DIR:-}" ]; then root=$ZELLIJ_SOCKET_DIR
        elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then root="$XDG_RUNTIME_DIR/zellij"
        else root="${TMPDIR:-/tmp}/zellij-$(id -u)"; fi
        """#

    static var list: String {
        """
        \(RemoteMultiplexerKind.zellij.discovery)
        \(RemoteMultiplexerCommands.utilities)
        \(userRoot)
        user_root=$root
        for scope in user managed; do
            if [ "$scope" = user ]; then root=$user_root; else root="/tmp/termind-zellij-$(id -u)"; fi
            printf 'ROOT|%s|%s\\n' "$scope" "$(hex "$root")"
            if [ -d "$root" ]; then
                export ZELLIJ_SOCKET_DIR=$root
                listing=$("$exe" list-sessions --short --no-formatting 2>&1)
                code=$?
                if [ "$code" = 0 ]; then
                    printf '%s\\n' "$listing" | while IFS= read -r name; do
                        case "$name" in ''|*[!a-zA-Z0-9_.-]*|.|..) exit 78 ;; esac
                        # list-sessions also includes serialized, exited sessions. Never offer those as live.
                        socket=$(find "$root" -type s -name "$name" -print 2>/dev/null) || exit 78
                        [ -S "$socket" ] && [ ! -L "$socket" ] || continue
                        "$exe" --session "$name" action list-panes --json >/dev/null 2>&1 || continue
                        printf '%s\\n' "$name"
                    done || exit 78
                elif [ "$listing" != 'No active zellij sessions found.' ]; then printf '%s\\n' "$listing" >&2; exit 78; fi
            fi
            printf 'END\\n'
        done
        """
    }

    static func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate] {
        guard text.hasSuffix("\n") else { throw RemoteSessionFailure.invalidResponse }
        var result: [RemoteMultiplexerCandidate] = []
        var root: String?
        var isolated = false
        var scopes: Set<String> = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("ROOT|") {
                let fields = line.components(separatedBy: "|")
                guard root == nil, fields.count == 3, ["user", "managed"].contains(fields[1]),
                    scopes.insert(fields[1]).inserted
                else { throw RemoteSessionFailure.invalidResponse }
                root = try RemoteMultiplexerCommands.unhex(fields[2])
                isolated = fields[1] == "managed"
            } else if line == "END" {
                guard root != nil else { throw RemoteSessionFailure.invalidResponse }
                root = nil
            } else {
                guard let root, RemoteMultiplexerCommands.validName(line) else {
                    throw RemoteSessionFailure.invalidResponse
                }
                result.append(.init(name: line, root: root, socket: nil, isolated: isolated))
            }
        }
        guard root == nil, scopes == ["user", "managed"] else { throw RemoteSessionFailure.invalidResponse }
        return result
    }

    static func create(name: String) -> String {
        """
        root="/tmp/termind-zellij-$(id -u)"
        private_dir "$root" || exit 78
        export ZELLIJ_SOCKET_DIR=$root
        export TERMIND_SHELL_CACHE_HOME_SET="${XDG_CACHE_HOME+x}" TERMIND_SHELL_CACHE_HOME="${XDG_CACHE_HOME-}"
        private_dir "$root/cache" || exit 78
        export XDG_CACHE_HOME="$root/cache"
        existing=$(find "$root" -type s -name '\(name)' -print) || exit 78
        [ -z "$existing" ] || exit 79
        native_started=1
        "$exe" --layout-string 'layout { pane; }' attach --create-background '\(name)' options --default-shell "$helper/shell" \
            --session-serialization false >/dev/null || exit 78
        socket=$(find "$root" -type s -name '\(name)' -print) || exit 78
        """
    }
}
