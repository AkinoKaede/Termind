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
        RemoteMultiplexerKind.herdr.discovery + "\n\"$exe\" session list --json"
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
