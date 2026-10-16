import Foundation
import TermindApplication
import TermindDomain

nonisolated enum RemoteHerdrCommands {
    private struct Listing: Decodable {
        let sessions: [Session]
        struct Session: Decodable {
            let name: String
            let running: Bool
            let socketPath: String
            let sessionDir: String
            let connectionError: String?

            enum CodingKeys: String, CodingKey {
                case name, running
                case socketPath = "socket_path"
                case sessionDir = "session_dir"
                case connectionError = "connection_error"
            }
        }
    }

    static var list: String {
        RemoteMultiplexerCommands.discovery(.herdr) + "\n\"$exe\" session list --json"
    }

    static func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate] {
        let value: Listing
        do { value = try JSONDecoder().decode(Listing.self, from: Data(text.utf8)) } catch {
            throw RemoteSessionFailure.invalidResponse
        }
        return try value.sessions.compactMap { session in
            guard session.connectionError == nil else { throw RemoteSessionFailure.invalidResponse }
            guard RemoteMultiplexerCommands.validName(session.name),
                RemoteMultiplexerCommands.validPath(session.sessionDir),
                session.socketPath == session.sessionDir + "/herdr.sock"
            else { throw RemoteSessionFailure.invalidResponse }
            guard session.running else { return nil }
            return .init(name: session.name, root: session.sessionDir, socket: session.socketPath)
        }
    }

    static func create(name: String) -> String {
        """
        root="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/sessions"
        mkdir -p "$root" || exit 78
        [ ! -L "$root" ] || exit 79
        mkdir "$root/\(name)" || exit 79
        chmod 700 "$root/\(name)" || exit 78
        socket="$root/\(name)/herdr.sock"
        # Only the new named server inherits the wrapper; the user's config remains untouched.
        native_started=1
        SHELL="$helper/shell" HERDR_STARTUP_CWD="$PWD" nohup "$exe" --session '\(name)' server \
            </dev/null >"$meta/create-error" 2>&1 &
        attempt=0
        while [ ! -S "$socket" ]; do
            attempt=$((attempt + 1)); [ "$attempt" -lt 50 ] || exit 78
            sleep 0.1
        done
        """
    }
}

nonisolated struct RemoteHerdrDialect: RemoteSocketMultiplexerDialect {
    let id = SessionPersistenceBackendID.herdr
    let paneVariable: String? = "HERDR_PANE_ID"
    var list: String { RemoteHerdrCommands.list }

    func validateVersion(_ output: String) throws {
        let version = try RemoteMultiplexerVersion(output, backend: id)
        // Preserve both supported release lines; 0.8.0 and 0.8.1 lack the lifecycle fixes.
        guard
            version.major > 0 || version.minor > 8 || (version.minor == 8 && version.patch >= 2)
                || (version.minor == 7 && version.patch >= 5)
        else { throw RemoteSessionFailure.unsupported }
    }
    func validPane(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 58, 95].contains($0)
            }
    }
    func parseList(_ text: String) throws -> [RemoteMultiplexerCandidate] { try RemoteHerdrCommands.parseList(text) }
    func create(name: String, token: UUID) -> String { RemoteHerdrCommands.create(name: name) }
    func attach(name: String) -> String { "\"$exe\" --session \(name) client" }
    func stop(name: String) -> String { "\"$exe\" session stop \(name) --json" }
    func validRoute(_ identity: RemoteMultiplexerIdentity, name: String) -> Bool {
        identity.socket == identity.root + "/herdr.sock"
            && (name == "default"
                ? identity.root.hasSuffix("/herdr") : identity.root.hasSuffix("/herdr/sessions/" + name))
    }
    func routing(_ identity: RemoteMultiplexerIdentity) throws -> String {
        let root = identity.root
        let config: String
        if root.hasSuffix("/herdr") {
            config = String(root.dropLast("/herdr".count))
        } else if let range = root.range(of: "/herdr/sessions/", options: .backwards),
            RemoteMultiplexerCommands.validName(String(root[range.upperBound...]))
        {
            config = String(root[..<range.lowerBound])
        } else {
            throw RemoteSessionFailure.invalidResponse
        }
        guard RemoteMultiplexerCommands.validPath(config) else { throw RemoteSessionFailure.invalidResponse }
        return "export XDG_CONFIG_HOME=\(try RemoteMultiplexerCommands.quote(config))"
    }
    func metadataFields(_ candidate: RemoteMultiplexerCandidate) throws -> String {
        "directory=$(directory_fingerprint \(try RemoteMultiplexerCommands.quote(candidate.root))) || exit 79"
    }
    func validateTermination(_ reference: RemoteSessionReference, identity: RemoteMultiplexerIdentity) throws {
        guard reference.session.name != "default", identity.directoryFingerprint != nil else {
            throw RemoteSessionFailure.ownershipMismatch
        }
    }
    func terminationCleanup(_ reference: RemoteSessionReference, identity: RemoteMultiplexerIdentity) throws -> String {
        """
        private_state || exit 79
        [ "$(cat "$meta/owner")" = '\(reference.ownershipToken!.uuidString)' ] || exit 79
        [ "$(cat "$meta/identity")" = \(try RemoteMultiplexerCommands.quote(identity.fingerprint)) ] || exit 79
        [ "$(directory_fingerprint \(try RemoteMultiplexerCommands.quote(identity.root)))" = '\(identity.directoryFingerprint!)' ] || exit 79
        [ ! -e \(try RemoteMultiplexerCommands.quote(identity.socket)) ] || exit 79
        "$exe" session delete \(try RemoteMultiplexerCommands.quote(reference.session.name)) --json >/dev/null || exit 78
        [ ! -e \(try RemoteMultiplexerCommands.quote(identity.root)) ] || exit 79
        """
    }
    func runtimeCommands(name: String) -> (String, String) {
        ("\"$exe\" session list --json", "\"$exe\" --session \(name) pane list")
    }
    func activePane(
        native: String, focus: String, reference: RemoteSessionReference, clientBound: Bool = false
    ) throws -> String? {
        let sessions = try RemoteHerdrCommands.parseList(native)
        guard clientBound || sessions.count == 1, sessions.contains(where: { $0.name == reference.session.name }) else {
            return nil
        }
        struct Response: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable {
                    let paneID: String
                    enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
                }
                let panes: [Pane]
            }
            let result: Result
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(focus.utf8))
        // Herdr's pane-current is global, not a per-client focus API.
        guard response.result.panes.count == 1, let pane = response.result.panes.first?.paneID, validPane(pane) else {
            return nil
        }
        // A verified endpoint with exactly one pane has no per-client pane ambiguity.
        // Without that endpoint evidence, even a singleton might belong to a switched-away session.
        return clientBound ? pane : nil
    }
    func writeDraft(name: String, pane: String, key: String) -> String {
        "\"$exe\" --session \(name) pane send-text \(pane) \(key)"
    }
}
