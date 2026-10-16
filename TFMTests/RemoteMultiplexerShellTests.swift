import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
nonisolated struct RemoteMultiplexerShellTests {
    private static let shells = ["/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

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
        ).replacingOccurrences(
            of: "exec \"$TERMIND_TMUX_HELPERS/shell\"",
            with: "exec /bin/sh \"$TERMIND_TMUX_HELPERS/shell\"")
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
            .replacingOccurrences(
                of: "exec \"$TERMIND_TMUX_HELPERS/shell\"",
                with: "exec /bin/sh \"$TERMIND_TMUX_HELPERS/shell\"")
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
                try String(contentsOf: root.appendingPathComponent("second-result"), encoding: .utf8) == "preserved\n")
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
