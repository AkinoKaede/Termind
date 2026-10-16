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
        \(RemoteMultiplexerCommands.discovery(.zmx))
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
            for (index, column) in line.split(separator: "\t").enumerated() {
                // Recent releases indent the name column even outside a zmx session.
                let part = index == 0 ? column.drop(while: { $0 == " " }) : column
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
        { sub(/^ +/, "", $1); name=""; pid=""; created=""; count=0
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

nonisolated struct RemoteZmxDialect: RemoteSocketMultiplexerDialect {
    let id = SessionPersistenceBackendID.zmx
    let paneVariable: String? = nil
    let versionArgument = "version"
    let capabilities = RemoteSessionCapabilities(clientCount: true, shellIntegration: true)
    var list: String { RemoteZmxCommands.list }

    func validateVersion(_ output: String) throws {
        let version = try RemoteMultiplexerVersion(output, backend: id)
        guard version.major > 0 || version.minor >= 7 else { throw RemoteSessionFailure.unsupported }
    }
    func validPane(_ value: String) -> Bool { value == "shell" }
    func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate] { try RemoteZmxCommands.parseList(text) }
    func create(name: String, token: UUID) -> String { RemoteZmxCommands.create(name: name, token: token) }
    func attach(name: String) -> String {
        // attach is an upsert. A daemon lost after validation must not become an unrelated shell.
        "\"$exe\" attach \(name) /bin/sh -c 'exit 79'"
    }
    func stop(name: String) -> String { "\"$exe\" kill \(name) --force" }
    func validRoute(_ identity: RemoteMultiplexerIdentity, name: String) -> Bool {
        identity.socket == identity.root + "/" + name
    }
    func routing(_ identity: RemoteMultiplexerIdentity) throws -> String {
        "export ZMX_DIR=\(try RemoteMultiplexerCommands.quote(identity.root))"
    }
    func validateIdentity(_ identity: RemoteMultiplexerIdentity) throws {
        guard !identity.isolated, identity.process != nil, identity.created != nil,
            identity.daemonProcess.flatMap(UInt64.init).map({ $0 > 1 }) == true,
            identity.daemonStarted?.isEmpty == false,
            identity.daemonStarted!.utf8.allSatisfy({ (32...126).contains($0) })
        else { throw RemoteSessionFailure.invalidResponse }
    }
    func identityGuard(_ identity: RemoteMultiplexerIdentity, name: String) throws -> String {
        """
        [ "$(\(RemoteZmxCommands.nativeIdentity(name: name)))" = '\(identity.process!):\(identity.created!)' ] || exit 79
        [ "$(ps -p '\(identity.process!)' -o ppid= | tr -d ' ')" = '\(identity.daemonProcess!)' ] || exit 79
        [ "$(process_start '\(identity.daemonProcess!)')" = \(try RemoteMultiplexerCommands.quote(identity.daemonStarted!)) ] || exit 79
        """
    }
    func ownershipGuard(_ identity: RemoteMultiplexerIdentity, name: String, token: UUID) throws -> String {
        """
        [ "$("$exe" get \(try RemoteMultiplexerCommands.quote(name)) termind_owner)" = '\(token.uuidString)' ] || exit 79
        [ "$(cat "$meta/native" 2>/dev/null)" = '\(identity.process!):\(identity.created!)' ] || exit 79
        """
    }
    func metadataOwnershipGuard(_ candidate: RemoteMultiplexerCandidate) throws -> String {
        """
        export ZMX_DIR=\(try RemoteMultiplexerCommands.quote(candidate.root))
        if [ "$("$exe" get '\(candidate.name)' termind_owner)" != "$owner" ] \
            || [ "$(cat "$meta/native" 2>/dev/null)" != '\(candidate.process!):\(candidate.created!)' ]; then
            owner=-; helper=-
        fi
        """
    }
    func metadataFields(_ candidate: RemoteMultiplexerCandidate) throws -> String {
        """
        # zmx's list PID is the PTY child, not the daemon. Bind its parent separately.
        daemon=$(ps -p '\(candidate.process!)' -o ppid= | tr -d ' ') || exit 79
        comm=$(ps -p "$daemon" -o comm=)
        [ "${comm##*/}" = zmx ] || exit 79
        born=$(process_start "$daemon")
        [ -n "$born" ] || exit 79
        born=$(hex "$born")
        """
    }
    func runtimeCommands(name: String) -> (String, String) { ("\"$exe\" list", "printf 'shell'") }
    func activePane(
        native: String, focus: String, reference: RemoteSessionReference, clientBound: Bool = false
    ) throws -> String? {
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: id)
        let root = identity.root.utf8.map { String(format: "%02x", $0) }.joined()
        let sessions = try RemoteZmxCommands.parseList("ROOT|\(root)\n" + native + "\nEND\n")
        guard clientBound || sessions.count == 1,
            let session = sessions.first(where: { $0.name == reference.session.name }),
            session.name == reference.session.name, session.process == identity.process,
            session.created == identity.created, session.clients == 1
        else { return nil }
        return "shell"
    }
    func writeDraft(name: String, pane: String, key: String) -> String { "\"$exe\" send \(name) \(key)" }
}
