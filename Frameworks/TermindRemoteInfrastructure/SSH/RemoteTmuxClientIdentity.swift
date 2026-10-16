import Foundation
import TermindDomain

/// A terminal client, not a pane process or a session ownership credential.
nonisolated struct RemoteTmuxClientIdentity: Equatable, Sendable {
    let terminal: String
    let process: String
    let created: String
    let server: String
    let session: String
    let sessionCreated: String

    init?(update: TerminalRuntimeUpdate, terminal: String) {
        guard update.status == .multiplexer, let context = update.active, context.backend == "tmux",
            Self.validTerminal(terminal)
        else { return nil }
        let client =
            update.clientIdentity?.split(separator: ":", omittingEmptySubsequences: false).map(String.init) ?? []
        let session = context.session.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard client.count == 3, client[0] == terminal, session.count == 2,
            Self.validProcess(client[1]), Self.validProcess(context.server), Int32(client[1]) != Int32(context.server),
            Self.validNumber(client[2]), Self.validNumber(session[1]),
            session[0].hasPrefix("$"), Self.validNumber(String(session[0].dropFirst()))
        else { return nil }
        self.terminal = terminal
        process = client[1]
        created = client[2]
        server = context.server
        self.session = session[0]
        sessionCreated = session[1]
    }

    static func validTerminal(_ terminal: String) -> Bool {
        terminal.hasPrefix("/dev/")
            && terminal.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [47, 46, 95, 45].contains($0)
            }
    }

    private static func validNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value) != nil
    }

    private static func validProcess(_ value: String) -> Bool {
        validNumber(value) && Int32(value).map { $0 > 0 } == true
    }
}
