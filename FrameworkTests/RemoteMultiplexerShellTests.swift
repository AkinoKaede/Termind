// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

#if os(macOS)
    import Foundation
    import TermindApplication
    import TermindDomain
    import Testing

    @testable import TermindRemoteInfrastructure

    @Suite
    nonisolated struct RemoteMultiplexerShellTests {
        private static let shells = ["/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }

        @Test(arguments: [
            ("100 100 100 pts/4 /bin/sh\n", true),
            ("100 100 100 pts/4 -ksh\n", true),
            ("100 100 100 pts/4 tmux\n", false),
            ("100 100 200 pts/4 bash\n200 200 200 pts/4 tmux\n", false),
            ("100 100 100 pts/4 bash\n200 100 100 pts/4 vim\n", false),
            ("100 100 100 pts/4 bash\n200 100 100 pts/4 zsh\n", false),
            ("100 100 100 pts/5 sh\n", false),
            ("100 100 100 pts/4 unknown\n", false),
            ("malformed\n", false),
            ("", false),
        ])
        func fallbackRequiresOneVerifiedForegroundShell(value: (String, Bool)) async throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            let probe = RemoteTerminalProcessProbe { command in
                try Self.run(
                    "ps() { printf '%s' \(try RemoteMultiplexerCommands.quote(value.0)); }\n" + command,
                    home: fixture.home.path)
            }
            #expect(try await probe.isOrdinaryShell(terminal: "/dev/pts/4") == value.1)
        }

        @Test(arguments: [false, true])
        func tmuxCreationPreservesTheInteractiveLocale(explicitLocale: Bool) throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            let result = try fixture.run(
                """
                export STUB_EMPTY=1 LANG=en_US.UTF-8
                \(explicitLocale ? "export LC_ALL=C" : "unset LC_ALL")
                \(try RemoteTmuxCommands.create(token: fixture.owner, startupCommand: nil, shellIntegration: true))
                code=$?
                rm -rf "$helper"
                exit "$code"
                """)
            #expect(result.exitCode == 0, "\(result.stdout)")
            let locale = try String(contentsOf: fixture.home.appendingPathComponent("locale"), encoding: .utf8)
            #expect(locale == (explicitLocale ? "x|C|en_US.UTF-8" : "||en_US.UTF-8"))
            #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("created").path))
        }

        @Test func ordinaryStartupRunsReadableNonExecutableHelpersWithAnUnsupportedShell() throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            let install = try RemoteShellStartup.install(
                token: UUID(), startupCommand: nil, shellIntegration: true, ordinary: true
            )
            .replacingOccurrences(of: "/tmp/termind-shell.XXXXXXXX", with: fixture.home.path + "/helper.XXXXXXXX")
            let installation = try Self.run(install + "\nprintf '%s' \"$helper\"", home: fixture.home.path)
            #expect(installation.exitCode == 0)
            let helper = installation.stdout
            for name in ["shell", "first"] {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper + "/" + name)
            }
            let input = "printf usable > \"$HOME/usable\"; exit\n"
            for launch in [
                try RemoteShellStartup.ordinaryCommand(helper: helper),
                "export TERMIND_TMUX_HELPERS=\(try RemoteMultiplexerCommands.quote(helper)); exec /bin/sh \"$TERMIND_TMUX_HELPERS/first\"",
            ] {
                let result = try Self.run(
                    """
                    export TERMIND_TMUX_SHELL=/bin/sh
                    printf '%s' \(try RemoteMultiplexerCommands.quote(input)) | /bin/sh -c \(try RemoteMultiplexerCommands.quote(launch))
                    """, home: fixture.home.path)
                #expect(result.exitCode == 0, "\(result.stdout)")
                #expect(
                    try String(contentsOf: fixture.home.appendingPathComponent("usable"), encoding: .utf8) == "usable")
                try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("usable"))
            }
        }

        @Test func managedHelperExecutionFailurePrecedesNativeCreation() throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            let create = try RemoteTmuxCommands.create(
                token: fixture.owner, startupCommand: nil, shellIntegration: true
            )
            .replacingOccurrences(
                of: "chmod 700 \"$helper/shell\" \"$helper/first\"",
                with: "chmod 600 \"$helper/shell\" \"$helper/first\"")
            let result = try fixture.run("export STUB_EMPTY=1\n" + create)
            #expect(result.exitCode == 78)
            #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("created").path))
        }

        @Test func everyTmuxOperationResolvesTheExecutableOutsidePATH() throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            try fixture.journals(stale: 0, live: 1, backend: "tmux")
            let probe = try fixture.run(RemoteMultiplexerCommands.discovery(.tmux) + "\n\"$exe\" -V")
            #expect(probe.stdout == "tmux 3.4\n")
            let listing = try fixture.run(RemoteTmuxCommands.list)
            let session = try #require(try RemoteTmuxCommands.parseSessions(listing.stdout).first)
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "test:22", username: "user",
                ownershipToken: fixture.owner)
            let create = try fixture.run(
                RemoteTmuxCommands.create(token: fixture.owner, startupCommand: nil, shellIntegration: true))
            #expect(try RemoteTmuxCommands.parseSessions(create.stdout).first?.id == session.id)
            #expect(try fixture.run(RemoteTmuxCommands.attach(reference)).stdout == "TERMIND_ATTACHED\n")
            #expect(try fixture.run(RemoteTmuxCommands.terminate(reference)).stdout == "TERMIND_ENDED\n")

            let runtime = try fixture.run(RemoteTmuxRuntimeDialect.command(terminal: "/dev/pts/4"))
            let update = try RemoteTmuxRuntimeDialect.parse(runtime.stdout, terminal: "/dev/pts/4")
            let context = try #require(update.contexts.first)
            #expect(context.capabilities.contains(.replaceDraft))
            let client = try #require(RemoteTmuxClientIdentity(update: update, terminal: "/dev/pts/4"))
            let resize = try fixture.run(
                "kill() { [ \"$1:$2\" = '-WINCH:300' ]; }\n" + RemoteTmuxRuntimeDialect.resizeCommand(client: client))
            #expect(resize.stdout == "TERMIND_RESIZED\n")
            let request = UUID()
            let draft = try fixture.run(
                RemoteTerminalDraft.command(
                    context: context, terminal: "/dev/pts/4", helper: nil, clientIdentity: update.clientIdentity,
                    request: request, replacement: "echo draft"))
            #expect(draft.exitCode == 0)
            let requested = try String(
                contentsOf: fixture.helper.appendingPathComponent("ctx.live0/request"), encoding: .utf8)
            #expect(requested.hasPrefix(request.uuidString + "|1|replace|"))
            let journal = fixture.helper.appendingPathComponent("ctx.live0/journal")
            let updatedJournal = try String(contentsOf: journal, encoding: .utf8)
                .replacingOccurrences(of: "R1|1|1|", with: "R1|2|1|")
            try (updatedJournal + "E1|2|draft|%64%72%61%66%74|\(request)\n")
                .write(to: journal, atomically: true, encoding: .utf8)
            let result = try fixture.run(
                RemoteTerminalDraft.resultCommand(context: context, helper: nil, request: request))
            let record = try RemoteShellContextRecord(result.stdout)
            #expect(record.entries.last?.1 == .draft(request: request.uuidString, value: "draft"))
        }

        @Test(arguments: [1, 129])
        func tmuxJournalLimitCountsOnlyLivePaneProcesses(live: Int) throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            try fixture.journals(stale: 129, live: live, backend: "tmux")
            let result = try fixture.run(
                "export STUB_PANES=\(live)\n" + RemoteTmuxRuntimeDialect.command(terminal: "/dev/pts/4"))
            if live > 128 {
                #expect(result.exitCode == 78)
            } else {
                #expect(result.exitCode == 0, "\(result.stdout)")
                let update = try RemoteTmuxRuntimeDialect.parse(result.stdout, terminal: "/dev/pts/4")
                #expect(update.contexts.count == 1)
                #expect(update.contexts.first?.capabilities.contains(.replaceDraft) == true)
                #expect(update.active?.shellInstance == "ctx.live0")
            }
        }

        @Test(arguments: [1, 129])
        func socketJournalLimitCountsOnlyValidatedProcesses(live: Int) throws {
            let fixture = try TmuxFixture()
            defer { fixture.cleanUp() }
            try fixture.journals(stale: 129, live: live, backend: "zmx")
            let result = try fixture.run(
                """
                helper="$STUB_HELPER"
                shell_check() { [ "$1" -ge 500 ]; }
                foreground_shell() { shell_check "$@"; }
                \(RemoteSocketMultiplexerRuntime.journalCommand(backend: .zmx))
                """)
            if live > 128 {
                #expect(result.exitCode == 78)
            } else {
                #expect(result.exitCode == 0)
                let lines = result.stdout.components(separatedBy: "\n")
                #expect(lines.first == "BEGIN|1")
                #expect(lines.filter { $0 == "BEGIN|1" }.count == 1)
                let record = try RemoteShellContextRecord(lines[1...3].joined(separator: "\n"))
                #expect(record.instance == "ctx.live0")
                #expect(record.ready)
            }
        }

        @Test(arguments: ["shell", "tmux", "zellij", "zmx", "herdr"], shells)
        func shellHooksKeepCwdInTheJournalDuringCommands(backend: String, shell: String) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("termind-cwd-test-\(UUID())")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("next"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let install = try RemoteShellStartup.install(
                token: UUID(), startupCommand: "cd \"$HOME\"", shellIntegration: true,
                backend: ["shell", "tmux"].contains(backend) ? nil : backend
            ).replacingOccurrences(
                of: "/tmp/termind-shell.XXXXXXXX",
                with: root.appendingPathComponent("termind-shell.XXXXXXXX").path
            )
            let input = """
                cat "$__termind_context_dir/journal" > "$HOME/during"
                cd "$HOME/next"
                cat "$__termind_context_dir/journal" > "$HOME/after"
                exit
                """
            let result = try Self.run(
                """
                \(install)
                export TERMIND_TMUX_HELPERS="$helper" TERMIND_TMUX_SHELL=\(try RemoteMultiplexerCommands.quote(shell))
                unset TMUX_PANE ZELLIJ_PANE_ID HERDR_PANE_ID
                \(backend == "tmux" ? "export TMUX_PANE=%1" : "")
                export ZELLIJ_PANE_ID=1 HERDR_PANE_ID=1
                printf '%s\\n' \(try RemoteMultiplexerCommands.quote(input)) | /bin/sh "$helper/first"
                """, home: root.path)
            #expect(result.exitCode == 0, "\(result.stdout)")
            let during = try RemoteShellContextRecord(
                String(contentsOf: root.appendingPathComponent("during"), encoding: .utf8))
            let after = try RemoteShellContextRecord(
                String(contentsOf: root.appendingPathComponent("after"), encoding: .utf8))
            #expect(during.backend == backend)
            #expect(!during.ready)
            #expect(!after.ready)
            #expect(during.directory == root.resolvingSymlinksInPath().path)
            #expect(after.directory == root.appendingPathComponent("next").resolvingSymlinksInPath().path)
            #expect(after.sequence > during.sequence)
        }

        @Test(arguments: SessionPersistenceBackendID.supported, shells)
        func startupSnippetRunsOnlyInFirstShellAndPreservesUserConfiguration(
            backend: SessionPersistenceBackendID, shell: String
        ) throws {
            for integration in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("termind-shell-test-\(UUID())")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let name = URL(fileURLWithPath: shell).lastPathComponent
                let userConfig = name == "zsh" ? ".zshrc" : ".bash_profile"
                try "export USER_CONFIGURATION=preserved\n".write(
                    to: root.appendingPathComponent(userConfig), atomically: true, encoding: .utf8)
                if name == "fish" {
                    let config = root.appendingPathComponent(".config/fish")
                    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
                    try "set -gx USER_CONFIGURATION preserved\n".write(
                        to: config.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
                }
                let startup =
                    name == "fish"
                    ? "cd \"$HOME\"; set -gx FROM_SNIPPET yes; printf once >> \"$HOME/once\""
                    : "cd \"$HOME\"; export FROM_SNIPPET=yes; printf once >> \"$HOME/once\""
                let install = try RemoteShellStartup.install(
                    token: UUID(), startupCommand: startup, shellIntegration: integration,
                    backend: backend == .tmux ? nil : backend.rawValue,
                    environment: [.init(variable: "SESSION_ONLY", value: "host-value")]
                )
                .replacingOccurrences(
                    of: "/tmp/termind-shell.XXXXXXXX",
                    with: root.appendingPathComponent("termind-shell.XXXXXXXX").path
                )

                let firstInput = """
                    printf '%s|%s|%s|%s\\n' "$PWD" "$FROM_SNIPPET" "$USER_CONFIGURATION" "$SESSION_ONLY" > "$HOME/first-result"
                    exit
                    """
                let secondInput = """
                    printf '%s\\n' "$USER_CONFIGURATION" > "$HOME/second-result"
                    exit
                    """
                let script = """
                    \(install)
                    trap 'rm -rf "$helper"' EXIT
                    [ -z "${SESSION_ONLY:-}" ] || exit 83
                    export TERMIND_TMUX_HELPERS="$helper" TERMIND_TMUX_SHELL=\(try RemoteMultiplexerCommands.quote(shell))
                    export TMUX_PANE=%1 ZELLIJ_PANE_ID=1 HERDR_PANE_ID=1
                    printf '%s\\n' \(try RemoteMultiplexerCommands.quote(firstInput)) | /bin/sh "$helper/first"
                    printf '%s\\n' \(try RemoteMultiplexerCommands.quote(secondInput)) | /bin/sh "$helper/shell"
                    """
                let result = try Self.run(script, home: root.path)
                #expect(result.exitCode == 0, "\(result.stderr)\n\(result.stdout)")
                #expect(try String(contentsOf: root.appendingPathComponent("once"), encoding: .utf8) == "once")
                let first = try String(contentsOf: root.appendingPathComponent("first-result"), encoding: .utf8)
                #expect(first.hasSuffix("|yes|preserved|host-value\n"), "\(first)")
                #expect(
                    try String(contentsOf: root.appendingPathComponent("second-result"), encoding: .utf8)
                        == "preserved\n")
                #expect(
                    try String(contentsOf: root.appendingPathComponent(userConfig), encoding: .utf8)
                        == "export USER_CONFIGURATION=preserved\n")
            }
        }

        @Test(arguments: shells)
        func cancelledStartupCannotRunLaterWhenUserConfigurationFinishes(shell: String) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("termind-cancel-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let install = try RemoteShellStartup.install(
                token: UUID(), startupCommand: "printf late > \"$HOME/late\"", shellIntegration: true, backend: "zmx"
            ).replacingOccurrences(
                of: "/tmp/termind-shell.XXXXXXXX", with: root.appendingPathComponent("termind-shell.XXXXXXXX").path)
            let result = try Self.run(
                """
                \(install)
                export TERMIND_TMUX_HELPERS="$helper" TERMIND_TMUX_SHELL=\(try RemoteMultiplexerCommands.quote(shell))
                mkdir "$helper/startup-decision"
                printf 'printf ready > "$HOME/ready"\\nexit\\n' | /bin/sh "$helper/shell" || exit $?
                [ ! -e "$helper/started" ]
                """, home: root.path)
            #expect(result.exitCode == 0, "\(result.stdout)")
            #expect(try String(contentsOf: root.appendingPathComponent("ready"), encoding: .utf8) == "ready")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("late").path))
        }

        @Test func expiredAndMismatchedDraftRequestsAreConsumedWithoutReturningPayload() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("termind-draft-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let state = root.appendingPathComponent("state")
            let request = root.appendingPathComponent("request")
            let reader = root.appendingPathComponent("reader")
            try "R1|10|1|%2Ftmp\n".write(to: state, atomically: true, encoding: .utf8)
            try RemoteShellContextJournal.requestReader.write(to: reader, atomically: true, encoding: .utf8)
            for (sequence, deadline) in [("10", "1"), ("9", String(Int(Date().timeIntervalSince1970) + 60))] {
                try "\(UUID())|\(sequence)|replace|%65%63%68%6F|\(deadline)|-\n".write(
                    to: request, atomically: true, encoding: .utf8)
                let result = try Self.run(
                    "sh \(RemoteMultiplexerCommands.quote(reader.path)) \(RemoteMultiplexerCommands.quote(root.path)) replace",
                    home: root.path)
                #expect(result.exitCode != 0)
                #expect(result.stdout.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: request.path))
            }
        }

        private struct TmuxFixture {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("termind-tmux-test-\(UUID())")
            let helper = URL(
                fileURLWithPath: "/tmp/termind-shell." + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            let owner = UUID()
            let token = UUID()

            init() throws {
                let bin = home.appendingPathComponent(".local/bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
                try token.uuidString.write(
                    to: helper.appendingPathComponent("event-token"), atomically: true, encoding: .utf8)
                let executable = bin.appendingPathComponent("tmux")
                try Self.stub.write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }

            func cleanUp() {
                try? FileManager.default.removeItem(at: home)
                try? FileManager.default.removeItem(at: helper)
            }

            func run(_ command: String) throws -> RemoteSessionCommandResult {
                // Do not allow fixture execution to discover a real multiplexer installed on the test host.
                let command = command.replacingOccurrences(
                    of: "/opt/homebrew/bin /usr/local/bin /usr/bin /snap/bin \"$HOME/.local/bin\" \"$HOME/.cargo/bin\"",
                    with: "\"$HOME/.local/bin\"")
                return try RemoteMultiplexerShellTests.run(
                    """
                    export PATH=/usr/bin:/bin
                    export STUB_HELPER=\(try RemoteMultiplexerCommands.quote(helper.path)) STUB_OWNER='\(owner)'
                    \(command)
                    """, home: home.path)
            }

            func journals(stale: Int, live: Int, backend: String) throws {
                for (prefix, count, firstPID) in [("stale", stale, 10), ("live", live, 500)] {
                    for index in 0..<count {
                        let name = "ctx.\(prefix)\(index)"
                        let directory = helper.appendingPathComponent(name)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let pane = backend == "tmux" ? "%\(index + 1)" : "shell"
                        let metadata =
                            backend == "tmux"
                            ? "M1|\(token)|\(pane)|\(name)|bash|%2Fhome|\(firstPID + index)|"
                            : "M2|\(token)|\(pane)|\(name)|bash|%2Fhome|\(firstPID + index)||\(backend)"
                        try "\(metadata)\nR1|1|1|%2Fwork\nE1|1|prompt||\n".write(
                            to: directory.appendingPathComponent("journal"), atomically: true, encoding: .utf8)
                        try "R1|1|1|%2Fwork\n".write(
                            to: directory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
                    }
                }
            }

            private static let stub = #"""
                #!/bin/sh
                printf '%s\n' "$*" >> "$HOME/calls"
                for argument do format=$argument; done
                case "$1" in
                    -V) printf 'tmux 3.4\n' ;;
                    list-sessions) [ "${STUB_EMPTY:-}" = 1 ] || printf '$1\n' ;;
                    new-session)
                        : > "$HOME/created"
                        printf '%s|%s|%s' "${LC_ALL+x}" "${LC_ALL-}" "${LANG-}" > "$HOME/locale"
                        printf '$1\n' ;;
                    set-option) ;;
                    show-environment)
                        case "$4" in
                            TERMIND_TMUX_OWNER) printf 'TERMIND_TMUX_OWNER=%s\n' "$STUB_OWNER" ;;
                            TERMIND_TMUX_HELPERS) printf 'TERMIND_TMUX_HELPERS=%s\n' "$STUB_HELPER" ;;
                            TERMIND_TMUX_SHELL) printf 'TERMIND_TMUX_SHELL=/bin/bash\n' ;;
                            *) exit 90 ;;
                        esac ;;
                    display-message)
                        case "$format" in
                            '#{session_name}') printf 'build\n' ;;
                            '#{pid}:#{session_created}') printf '200:100\n' ;;
                            '#{pane_current_path}') printf '/work\n' ;;
                            '#{pane_current_command}') printf 'bash\n' ;;
                            *session_id*) printf '$1 100 200 1 1\n' ;;
                            *) printf '1\n' ;;
                        esac ;;
                    list-clients)
                        case "$format" in
                            C*) printf 'C|/dev/pts/4|300|400|200|$1|100|%%1||root\n' ;;
                            *client_key_table*) printf '/dev/pts/4|300|400|%%1||root|$1|100\n' ;;
                            *) printf '/dev/pts/4|300|400|200|$1|100|\n' ;;
                        esac ;;
                    list-panes)
                        i=0
                        while [ "$i" -lt "${STUB_PANES:-1}" ]; do
                            printf 'P|%%%s|%s|0|0|bash\n' "$((i + 1))" "$((i + 500))"
                            i=$((i + 1))
                        done ;;
                    if-shell)
                        case "$*" in
                            *kill-session*) printf 'TERMIND_ENDED\n' ;;
                            *attach-session*) printf 'TERMIND_ATTACHED\n' ;;
                        esac ;;
                    *) exit 91 ;;
                esac
                """#
        }

        static func run(_ command: String, home: String) throws -> RemoteSessionCommandResult {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HOME": home, "XDG_CONFIG_HOME": home + "/.config", "XDG_DATA_HOME": home + "/.local/share",
                "ZDOTDIR": home, "LC_ALL": "C",
            ]) { _, new in new }
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return .init(stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: process.terminationStatus)
        }
    }
#endif
