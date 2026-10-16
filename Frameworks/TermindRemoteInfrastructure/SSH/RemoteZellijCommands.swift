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
        \(RemoteMultiplexerCommands.discovery(.zellij))
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

nonisolated struct RemoteZellijDialect: RemoteSocketMultiplexerDialect {
    let id = SessionPersistenceBackendID.zellij
    let paneVariable: String? = "ZELLIJ_PANE_ID"
    var list: String { RemoteZellijCommands.list }

    func validateVersion(_ output: String) throws {
        let version = try RemoteMultiplexerVersion(output, backend: id)
        guard version.major > 0 || version.minor > 44 || (version.minor == 44 && version.patch >= 3) else {
            throw RemoteSessionFailure.unsupported
        }
    }
    func validPane(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate] {
        try RemoteZellijCommands.parseList(text)
    }
    func create(name: String, token: UUID) -> String { RemoteZellijCommands.create(name: name) }
    func attach(name: String) -> String { "\"$exe\" attach \(name)" }
    func stop(name: String) -> String { "\"$exe\" kill-session \(name)" }
    func validateIdentity(_ identity: RemoteMultiplexerIdentity) throws {}
    func validRoute(_ identity: RemoteMultiplexerIdentity, name: String) -> Bool {
        identity.socket.hasSuffix("/" + name)
    }
    func routing(_ identity: RemoteMultiplexerIdentity) throws -> String {
        """
        export ZELLIJ_SOCKET_DIR=\(try RemoteMultiplexerCommands.quote(identity.root))
        \(identity.isolated ? "export XDG_CACHE_HOME=\(try RemoteMultiplexerCommands.quote(identity.root + "/cache"))" : "")
        """
    }
    func prepareAttachment() -> String {
        """
        # An attach command can otherwise resurrect a cached session after a disconnect race.
        cache="/tmp/termind-zellij-attach-cache-$(id -u)"
        private_dir "$cache" || exit 79
        export XDG_CACHE_HOME="$cache"
        """
    }
    var restoreShellEnvironment: String {
        """
        if [ "${TERMIND_SHELL_CACHE_HOME_SET:-}" = x ]; then
            export XDG_CACHE_HOME="$TERMIND_SHELL_CACHE_HOME"
        else
            unset XDG_CACHE_HOME
        fi
        unset TERMIND_SHELL_CACHE_HOME_SET TERMIND_SHELL_CACHE_HOME
        """
    }
    func runtimeCommands(name: String) -> (String, String) {
        ("\"$exe\" list-sessions --short --no-formatting", "\"$exe\" --session \(name) action list-clients")
    }
    func activePane(native: String, focus: String, reference: RemoteSessionReference) throws -> String? {
        // A switched client cannot be bound using its original argv. Require a unique live session too.
        guard native == reference.session.name else { return nil }
        let clients = focus.split(separator: "\n")
        guard clients.first == "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND", clients.count == 2 else { return nil }
        let fields = clients[1].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 3, UInt64(fields[0]) != nil, fields[1].hasPrefix("terminal_") else { return nil }
        let pane = String(fields[1].dropFirst("terminal_".count))
        return validPane(pane) ? pane : nil
    }
    func writeDraft(name: String, pane: String, key: String) -> String {
        "\"$exe\" --session \(name) action write-chars --pane-id \(pane) \(key)"
    }
}
