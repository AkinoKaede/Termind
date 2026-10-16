import Foundation
import TermindApplication
import TermindDomain

nonisolated enum RemoteZmxCommands {
    static let root = #"""
        if [ -n "${ZMX_DIR:-}" ]; then root=$ZMX_DIR
        elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then root="$XDG_RUNTIME_DIR/zmx"
        else root="${TMPDIR:-/tmp}/zmx-$(id -u)"; fi
        """#

    static var list: String {
        """
        \(RemoteMultiplexerKind.zmx.discovery)
        \(RemoteMultiplexerCommands.utilities)
        \(root)
        printf 'ROOT|%s\\n' "$(hex "$root")"
        "$exe" list || exit 78
        printf 'END\\n'
        """
    }

    static func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate] {
        var lines = text.split(separator: "\n").map(String.init)
        guard text.hasSuffix("\n"), lines.count >= 2, lines[0].hasPrefix("ROOT|"), lines.last == "END" else {
            throw RemoteSessionFailure.invalidResponse
        }
        lines.removeLast()
        let root = try RemoteMultiplexerCommands.unhex(String(lines.removeFirst().dropFirst(5)))
        guard RemoteMultiplexerCommands.validPath(root) else { throw RemoteSessionFailure.invalidResponse }
        return try lines.map { line in
            var fields: [String: String] = [:]
            for part in line.split(separator: "\t") {
                guard let separator = part.firstIndex(of: "=") else { throw RemoteSessionFailure.invalidResponse }
                let key = String(part[..<separator])
                guard fields[key] == nil else { throw RemoteSessionFailure.invalidResponse }
                fields[key] = String(part[part.index(after: separator)...])
            }
            guard let name = fields["name"], RemoteMultiplexerCommands.validName(name),
                let pid = fields["pid"], UInt64(pid).map({ $0 > 1 }) == true,
                let created = fields["created"], UInt64(created) != nil,
                let clients = fields["clients"].flatMap(Int.init), clients >= 0, fields["err"] == nil
            else { throw RemoteSessionFailure.invalidResponse }
            return .init(
                name: name, root: root, socket: root + "/" + name, process: pid, created: created, clients: clients)
        }
    }

    static func create(name: String, token: UUID) -> String {
        """
        \(root)
        export ZMX_DIR=$root
        socket="$root/\(name)"
        [ ! -e "$socket" ] && [ ! -L "$socket" ] || exit 79
        native_started=1
        "$exe" attach '\(name)' "$helper/shell" </dev/null >/dev/null 2>"$meta/create-error" || exit 78
        "$exe" set '\(name)' 'termind_owner=\(token.uuidString)' >/dev/null || exit 78
        native=$(\(nativeIdentity(name: name))) || exit 79
        [ -n "$native" ] || exit 79
        printf '%s\\n' "$native" > "$meta/native"
        """
    }

    // The listed PID is the PTY child. Labels or commands containing "pid=" are not identity fields.
    static func nativeIdentity(name: String) -> String {
        """
        "$exe" list | awk -F '\\t' -v target='\(name)' '
        { name=""; pid=""; created=""; count=0
          for(i=1;i<=NF;i++) {
            if ($i ~ /^name=/) {name=substr($i,6); count++}
            if ($i ~ /^pid=[0-9]+$/) {pid=substr($i,5); count++}
            if ($i ~ /^created=[0-9]+$/) {created=substr($i,9); count++}
          }
          if(name==target && count==3 && pid!="" && created!="") print pid ":" created
        }'
        """
    }
}
