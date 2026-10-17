import Foundation
import TermindApplication
import TermindDomain

nonisolated struct RemoteMultiplexerDraftTarget {
    let root: String
    let trigger: String
}

public nonisolated struct RemoteMultiplexerRuntimeAdapter: TerminalRuntimeAdapter {
    private let attachment: RemoteSessionReference?
    private let execute: RemoteSessionCommandExecutor
    private let charset: RemoteCharset

    public init(
        attachment: RemoteSessionReference? = nil, execute: @escaping RemoteSessionCommandExecutor,
        charset: RemoteCharset = .utf8
    ) {
        self.attachment = attachment
        self.execute = execute
        self.charset = charset
    }

    private var dialect: any RemoteMultiplexerDialect {
        get throws {
            guard let dialect = RemoteMultiplexerRegistry.dialect(attachment?.backend ?? .tmux) else {
                throw TerminalRuntimeError.unsupported
            }
            return dialect
        }
    }

    public func inspect(terminal: String) async throws -> TerminalRuntimeUpdate {
        // Preserve the native tmux TTY lookup and integrated journal path. Other backends
        // can still provide a read-only directory when no Termind helper was installed.
        if let attachment {
            _ = try dialect
            do {
                let update = try await dialect.runtime(reference: attachment, execute: execute, charset: charset)
                    .inspect(terminal: terminal)
                if update.active != nil { return update }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        } else {
            do {
                let update = try await RemoteTmuxRuntimeDialect(execute: execute, charset: charset)
                    .inspect(terminal: terminal)
                if update.status == .multiplexer || update.backend != nil { return update }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }
        guard let client = try await RemoteTerminalProcessProbe(execute: execute).inspect(terminal: terminal) else {
            return .init(status: .unknown)
        }
        do {
            if let attachment, client.backend == attachment.backend,
                let identity = try? RemoteMultiplexerIdentity.decode(
                    attachment.session.identity, kind: attachment.backend),
                identity.helper != nil,
                client.endpoint
                    == (client.backend == .herdr ? identity.root + "/herdr-client.sock" : identity.socket)
            {
                do {
                    let update = try await RemoteSocketMultiplexerRuntime(
                        reference: attachment, execute: execute, charset: charset, boundClient: client
                    )
                    .inspect(terminal: terminal)
                    if update.active != nil,
                        try await RemoteTerminalProcessProbe(execute: execute).inspect(terminal: terminal) == client
                    {
                        return update
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {}
            }
            return try await RemoteNativeMultiplexerRuntime(client: client, execute: execute).inspect(
                terminal: terminal)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(
                status: .multiplexer, clientIdentity: client.identity, backend: client.backend,
                issue: .inspectionUnavailable)
        }
    }

    static func helper(for attachment: RemoteSessionReference?) throws -> String? {
        guard let attachment else { return nil }
        guard let dialect = RemoteMultiplexerRegistry.dialect(attachment.backend) else {
            throw TerminalRuntimeError.unsupported
        }
        return try dialect.helper(attachment)
    }

    func draftTarget(
        context: TerminalShellContext, terminal: String, replacing: Bool
    ) async throws -> RemoteMultiplexerDraftTarget {
        try await dialect.runtime(reference: attachment, execute: execute, charset: charset)
            .draftTarget(context: context, terminal: terminal, replacing: replacing)
    }

    func refreshSize(of client: RemoteTmuxClientIdentity) async throws {
        try await RemoteTmuxRuntimeDialect(execute: execute, charset: charset).refreshSize(of: client)
    }
}

nonisolated struct RemoteSocketMultiplexerRuntime: RemoteMultiplexerRuntime {
    let reference: RemoteSessionReference
    let execute: RemoteSessionCommandExecutor
    var charset: RemoteCharset = .utf8
    var boundClient: RemoteTerminalProcessProbe.Client? = nil

    func inspect(terminal: String) async throws -> TerminalRuntimeUpdate {
        try await snapshot(terminal: terminal).update
    }

    private struct Snapshot {
        let update: TerminalRuntimeUpdate
        let native: String
        let focus: String
    }

    private var dialect: any RemoteSocketMultiplexerDialect {
        get throws {
            guard let dialect = RemoteMultiplexerRegistry.socketDialect(reference.backend) else {
                throw TerminalRuntimeError.unsupported
            }
            return dialect
        }
    }

    private var identity: RemoteMultiplexerIdentity {
        get throws {
            try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: dialect.id)
        }
    }

    private func nativeCommands() throws -> (String, String) {
        try dialect.runtimeCommands(name: RemoteMultiplexerCommands.quote(reference.session.name))
    }

    private func clientGuard(terminal: String) throws -> String {
        guard RemoteTmuxClientIdentity.validTerminal(terminal), let helper = try identity.helper else {
            throw TerminalRuntimeError.unsupported
        }
        let kind = try identity.kind.rawValue
        if let boundClient {
            return """
                helper=\(try RemoteMultiplexerCommands.quote(helper))
                client='\(boundClient.process)'
                \(try RemoteTerminalProcessProbe.guardClient(boundClient, terminal: terminal))
                """
        }
        return """
            helper=\(try RemoteMultiplexerCommands.quote(helper))
            \(RemoteMultiplexerCommands.stateRoot(try identity.kind, create: false))
            meta="$state/\(reference.session.name)"
            private_state || exit 79
            [ "$(cat "$meta/helper")" = "$helper" ] || exit 79
            [ "$(cat "$meta/identity")" = \(try RemoteMultiplexerCommands.quote(identity.fingerprint)) ] || exit 79
            key=$(printf '%s' \(try RemoteMultiplexerCommands.quote(terminal)) | od -An -v -tx1 | tr -d ' \\n')
            [ ! -L "$helper" ] && [ ! -L "$helper/client-$key" ] || exit 79
            IFS='|' read -r client started < "$helper/client-$key" || exit 79
            case "$client" in ''|*[!0-9]*) exit 79 ;; esac
            [ -n "$started" ] && [ "$(process_start "$client")" = "$started" ] || exit 79
            client_tty=$(ps -p "$client" -o tty= | tr -d ' ')
            [ "/dev/$client_tty" = \(try RemoteMultiplexerCommands.quote(terminal)) ] || exit 79
            # Without a native TTY-to-client API, any other interactive client makes focus ambiguous.
            clients=$(ps -u "$(id -u)" -o pid= -o tty= -o comm= | \
                awk '$2 != "?" && $2 != "??" {n=split($3,a,"/"); if(a[n]=="\(kind)") print $1}')
            [ "$clients" = "$client" ] || exit 79
            """
    }

    private var shellCheck: String {
        get throws {
            """
            shell_check() {
                case "$1" in ''|*[!0-9]*) return 1 ;; esac
                case "$2" in bash|zsh|fish) ;; *) return 1 ;; esac
                [ -d "$3" ] && [ ! -L "$3" ] && [ ! -L "$3/process-start" ] || return 1
                started=$(cat "$3/process-start") || return 1
                [ -n "$started" ] && [ "$(process_start "$1")" = "$started" ] || return 1
                parent=$(ps -p "$1" -o ppid= | tr -d ' ') || return 1
                \(try identity.process.map { "[ \"$1\" = '\($0)' ] && [ \"$parent\" = '\(try identity.daemonProcess!)' ] || return 1" } ?? "")
                parent_name=$(ps -p "$parent" -o comm=)
                [ "${parent_name##*/}" = '\(try identity.kind.rawValue)' ] || return 1
                name=$(ps -p "$1" -o comm=)
                [ "${name##*/}" = "$2" ] || [ "${name##*/}" = "-$2" ] || return 1
            }
            foreground_shell() {
                shell_check "$1" "$2" "$3" || return 1
                groups=$(ps -p "$1" -o pgid= -o tpgid=) || return 1
                set -- $groups
                [ "$#" = 2 ] && [ "$1" = "$2" ]
            }
            """
        }
    }

    private func snapshot(terminal: String) async throws -> Snapshot {
        let (nativeCommand, focusCommand) = try nativeCommands()
        let command = """
            \(try RemoteMultiplexerCommands.guardIdentity(reference))
            \(try clientGuard(terminal: terminal))
            \(try shellCheck)
            native=$(\(nativeCommand)) || exit 79
            focus=$(\(focusCommand)) || exit 79
            printf 'C|%s\\nN|%s\\nA|%s\\n' "$client" "$(hex "$native")" "$(hex "$focus")"
            \(Self.journalCommand(backend: try identity.kind))
            """
        let result = try await execute(command)
        guard result.exitCode == 0, !result.truncated else { throw TerminalRuntimeError.unsupported }
        return try Self.parseSnapshot(
            result.stdout, reference: reference, charset: charset, clientBound: boundClient != nil)
    }

    static func journalCommand(backend: SessionPersistenceBackendID) -> String {
        """
        count=0
        for file in "$helper"/ctx.*/journal; do
            [ -f "$file" ] && [ ! -L "$file" ] || continue
            IFS='|' read -r tag token pane instance shell home pid history backend < "$file" || exit 78
            [ "$tag" = M2 ] && [ "$backend" = '\(backend.rawValue)' ] || continue
            [ "$token" = "$(cat "$helper/event-token")" ] || continue
            dir=${file%/journal}
            [ "${dir##*/}" = "$instance" ] || continue
            shell_check "$pid" "$shell" "$dir" || continue
            count=$((count + 1)); [ "$count" -le 128 ] || exit 78
            foreground=0
            if foreground_shell "$pid" "$shell" "$dir"; then foreground=1; fi
            printf 'BEGIN|%s\\n' "$foreground"
            cat "$file" || exit 78
            printf 'END\\n'
        done
        printf 'DONE\\n'
        """
    }

    static func parse(
        _ text: String, reference: RemoteSessionReference, charset: RemoteCharset = .utf8, clientBound: Bool = false
    ) throws -> TerminalRuntimeUpdate {
        try parseSnapshot(text, reference: reference, charset: charset, clientBound: clientBound).update
    }

    private static func parseSnapshot(
        _ text: String, reference: RemoteSessionReference, charset: RemoteCharset, clientBound: Bool = false
    ) throws -> Snapshot {
        guard text.utf8.count <= 1024 * 1024,
            let dialect = RemoteMultiplexerRegistry.socketDialect(reference.backend)
        else { throw TerminalRuntimeError.invalidResponse }
        let kind = dialect.id
        let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 5, lines[0].hasPrefix("C|"), UInt64(lines[0].dropFirst(2)) != nil,
            lines[1].hasPrefix("N|"), lines[2].hasPrefix("A|"), lines.suffix(2) == ["DONE", ""]
        else { throw TerminalRuntimeError.invalidResponse }
        let native = try RemoteMultiplexerCommands.unhex(String(lines[1].dropFirst(2)), limit: 512 * 1024)
        let focus = try RemoteMultiplexerCommands.unhex(String(lines[2].dropFirst(2)), limit: 512 * 1024)
        let activePane = try dialect.activePane(
            native: native, focus: focus, reference: reference, clientBound: clientBound)
        var contexts: [TerminalShellContext] = []
        var events: [TerminalContextEvent] = []
        var active: TerminalContextIdentity?
        var index = 3
        while index < lines.count - 2 {
            guard lines[index] == "BEGIN|0" || lines[index] == "BEGIN|1" else {
                throw TerminalRuntimeError.invalidResponse
            }
            let foreground = lines[index] == "BEGIN|1"
            index += 1
            let start = index
            while index < lines.count - 2, lines[index] != "END" { index += 1 }
            guard index < lines.count - 2 else { throw TerminalRuntimeError.invalidResponse }
            let record = try RemoteShellContextRecord(lines[start..<index].joined(separator: "\n"), charset: charset)
            index += 1
            guard record.backend == kind.rawValue else { throw TerminalRuntimeError.invalidResponse }
            var context = record.context(
                server: identity.fingerprint, session: reference.session.id, backend: kind.rawValue)
            if !foreground { context.capabilities.remove(.directory) }
            if record.pane == activePane {
                guard active == nil else { throw TerminalRuntimeError.invalidResponse }
                active = context.identity
                if foreground, record.ready, !clientBound {
                    context.capabilities.formUnion([.readDraft, .replaceDraft])
                }
            }
            contexts.append(context)
            events.append(contentsOf: record.events(for: context))
        }
        guard contexts.count <= 128 else { throw TerminalRuntimeError.invalidResponse }
        return Snapshot(
            update: .init(
                status: .multiplexer, clientIdentity: String(lines[0].dropFirst(2)),
                active: active, contexts: contexts, events: events, backend: kind,
                issue: active == nil ? .paneAmbiguous : nil),
            native: native, focus: focus)
    }

    func draftTarget(
        context: TerminalShellContext, terminal: String, replacing: Bool
    ) async throws -> RemoteMultiplexerDraftTarget {
        let snapshot = try await snapshot(terminal: terminal)
        guard snapshot.update.active == context.identity,
            snapshot.update.contexts.first(where: { $0.identity == context.identity }) == context,
            context.capabilities.contains(replacing ? .replaceDraft : .readDraft),
            let helper = try identity.helper
        else { throw TerminalRuntimeError.staleContext }
        let (nativeCommand, focusCommand) = try nativeCommands()
        let guardCommand = """
            \(try RemoteMultiplexerCommands.guardIdentity(reference))
            \(try clientGuard(terminal: terminal))
            [ "$(\(nativeCommand))" = \(try RemoteMultiplexerCommands.quote(snapshot.native)) ] || exit 79
            [ "$(\(focusCommand))" = \(try RemoteMultiplexerCommands.quote(snapshot.focus)) ] || exit 79
            """
        let key = try RemoteMultiplexerCommands.quote(replacing ? "\u{1B}[777;2~" : "\u{1B}[777;1~")
        let name = try RemoteMultiplexerCommands.quote(reference.session.name)
        let pane = try RemoteMultiplexerCommands.quote(context.identity.pane)
        let write = try dialect.writeDraft(name: name, pane: pane, key: key)
        return .init(
            root: guardCommand + "\nhelper=\(try RemoteMultiplexerCommands.quote(helper))",
            trigger: """
                (
                \(guardCommand)
                \(try shellCheck)
                IFS='|' read -r tag token pane instance shell home pid history backend < "$dir/meta" || exit 79
                [ "$backend" = '\(context.identity.backend)' ] && [ "$pane" = \(pane) ] \
                    && [ "$instance" = '\(context.identity.shellInstance)' ] || exit 79
                foreground_shell "$pid" "$shell" "$dir" || exit 79
                IFS='|' read -r tag seq ready cwd < "$dir/state" || exit 79
                [ "$seq" = '\(context.sequence)' ] && [ "$ready" = 1 ] || exit 79
                \(write) >/dev/null || exit 79
                ) || { rm -f "$dir/request"; exit 79; }
                """)
    }
}
