import Foundation
import Testing

@testable import Termind

@Suite
struct ShellIntegrationBootstrapTests {
    @Test
    func bashBootstrapIsHiddenAndEmitsStandardOSC7() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "ABC123")
        let probe = String(decoding: bootstrap.startCommand, as: UTF8.self)
        let probeOutput = Data(
            ("Welcome\r\nuser@host$ " + probe.dropLast()
                + "\r\n__TRMD_ABC123_SHELL__/bin/bash__\r\nuser@host$ ").utf8
        )

        let probeUpdate = bootstrap.receive(probeOutput)
        let command = try #require(probeUpdate.command)
        let commandText = String(decoding: command, as: UTF8.self)
        #expect(commandText.contains("file://localhost%s"))
        #expect(!commandText.contains("$HOSTNAME"))
        #expect(!commandText.contains("kitty-shell-cwd"))
        #expect(probeUpdate.visibleOutput == nil)

        let integrationOutput = Data(
            (commandText.dropLast() + "\r\n__TRMD_ABC123_DONE__\r\n"
                + "\u{1B}]7;file://localhost/home/user\u{7}user@host$ ").utf8
        )
        let completed = bootstrap.receive(integrationOutput)
        let visible = try #require(completed.visibleOutput)
        let visibleText = String(decoding: visible, as: UTF8.self)

        #expect(completed.isComplete)
        #expect(
            visibleText
                == "Welcome\r\n\u{1B}]7;file://localhost/home/user\u{7}user@host$ "
        )
        #expect(!visibleText.contains("__TRMD_"))
        #expect(!visibleText.contains("__termind_report_cwd"))
    }

    @Test(arguments: ["zsh", "fish"])
    func supportedShellsUseStandardFileURI(shell: String) throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "SHELL")
        let update = bootstrap.receive(
            Data("__TRMD_SHELL_SHELL__/usr/bin/\(shell)__\r\n".utf8)
        )
        let command = try #require(update.command)
        let text = String(decoding: command, as: UTF8.self)

        #expect(text.contains("file://localhost"))
        #expect(!text.contains("$HOST"))
        #expect(!text.contains("hostname"))
        #expect(!text.contains("kitty-shell-cwd"))
    }

    @Test
    func unsupportedShellSkipsInjection() {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "OTHER")
        let update = bootstrap.receive(
            Data("__TRMD_OTHER_SHELL__/bin/tcsh__\r\nprompt> ".utf8)
        )

        #expect(update.command == nil)
        #expect(update.isComplete)
        #expect(update.visibleOutput == Data("prompt> ".utf8))
    }

    @Test
    func timeoutHidesProbeAndRestoresLatestPrompt() {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "TIMEOUT", now: 0)
        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        _ = bootstrap.receive(
            Data(("Welcome\r\nodd> " + probe + "\r\nsyntax error\r\nodd> ").utf8),
            now: 100_000_000
        )

        let update = bootstrap.poll(now: 3_000_000_000)
        let visible = String(decoding: update.visibleOutput ?? Data(), as: UTF8.self)

        #expect(visible == "Welcome\r\nodd> ")
        #expect(!update.isComplete)
        #expect(!visible.contains("TIMEOUT"))
        #expect(!visible.contains("syntax error"))
    }

    @Test
    func lateSupportedProbeStillInstallsAndHidesChunkedBootstrap() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "LATE", now: 0)
        _ = bootstrap.receive(Data("Welcome\r\nuser@host$ ".utf8), now: 100_000_000)

        let timeout = bootstrap.poll(now: 3_000_000_000)
        #expect(timeout.visibleOutput == Data("Welcome\r\nuser@host$ ".utf8))
        #expect(!timeout.isComplete)

        let probeEcho = bootstrap.startCommand.dropLast()
        let split = probeEcho.index(probeEcho.startIndex, offsetBy: probeEcho.count / 2)
        let first = bootstrap.receive(Data(probeEcho[..<split]), now: 3_100_000_000)
        #expect(first.visibleOutput == nil)
        #expect(first.command == nil)

        let second = bootstrap.receive(
            Data(probeEcho[split...]) + Data("\r\n__TRMD_LATE_SHELL__/bin/ba".utf8),
            now: 3_200_000_000
        )
        #expect(second.visibleOutput == nil)
        #expect(second.command == nil)

        let detected = bootstrap.receive(
            Data("sh__\r\nuser@host$ ".utf8), now: 3_300_000_000
        )
        let command = try #require(detected.command)
        #expect(detected.visibleOutput == nil)

        let commandText = String(decoding: command.dropLast(), as: UTF8.self)
        _ = bootstrap.receive(
            Data((commandText + "\r\n__TRMD_LATE_DO").utf8), now: 3_400_000_000
        )
        let completed = bootstrap.receive(
            Data(
                ("NE__\r\n\u{1B}]7;file://localhost/home/user\u{7}user@host$ ").utf8
            ),
            now: 3_500_000_000
        )
        let visible = String(decoding: try #require(completed.visibleOutput), as: UTF8.self)

        #expect(completed.isComplete)
        #expect(visible == "\u{1B}]7;file://localhost/home/user\u{7}user@host$ ")
        #expect(!visible.contains("__TRMD_"))
        #expect(!visible.contains("__termind_"))
    }

    @Test
    func lateUnsupportedProbeIsHiddenAndSkipsInstallation() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "OTHER", now: 0)
        _ = bootstrap.receive(Data("router# ".utf8), now: 0)
        _ = bootstrap.poll(now: 3_000_000_000)

        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        let completed = bootstrap.receive(
            Data((probe + "\r\n__TRMD_OTHER_SHELL__/bin/tcsh__\r\nrouter# ").utf8),
            now: 3_100_000_000
        )
        let visible = String(decoding: try #require(completed.visibleOutput), as: UTF8.self)

        #expect(completed.command == nil)
        #expect(completed.isComplete)
        #expect(visible == "router# ")
        #expect(!visible.contains("printf"))
        #expect(!visible.contains("__TRMD_"))
    }

    @Test
    func lateProbeErrorIsHiddenAfterQuietPeriod() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "ERROR", now: 0)
        _ = bootstrap.receive(Data("odd> ".utf8), now: 0)
        _ = bootstrap.poll(now: 3_000_000_000)

        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        let response = bootstrap.receive(
            Data((probe + "\r\nprintf: command not found\r\nodd> ").utf8),
            now: 3_100_000_000
        )
        #expect(response.visibleOutput == nil)

        let completed = bootstrap.poll(now: 3_600_000_000)
        let visible = String(decoding: try #require(completed.visibleOutput), as: UTF8.self)
        #expect(completed.isComplete)
        #expect(visible == "odd> ")
        #expect(!visible.contains("printf"))
        #expect(!visible.contains("command not found"))
    }

    @Test
    func lateInstallationTimeoutHidesCommandAndError() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "INSTALL", now: 0)
        _ = bootstrap.receive(Data("user@host$ ".utf8), now: 0)
        _ = bootstrap.poll(now: 3_000_000_000)

        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        let detected = bootstrap.receive(
            Data((probe + "\r\n__TRMD_INSTALL_SHELL__/bin/bash__\r\n").utf8),
            now: 3_100_000_000
        )
        let command = try #require(detected.command)
        let commandText = String(decoding: command.dropLast(), as: UTF8.self)
        _ = bootstrap.receive(
            Data((commandText + "\r\nsyntax error\r\nuser@host$ ").utf8),
            now: 3_200_000_000
        )

        let completed = bootstrap.poll(now: 6_100_000_000)
        let visible = String(decoding: try #require(completed.visibleOutput), as: UTF8.self)
        #expect(completed.isComplete)
        #expect(visible == "user@host$ ")
        #expect(!visible.contains("__termind_"))
        #expect(!visible.contains("syntax error"))
    }

    @Test
    func lateScannerPassesOrdinaryOutputThrough() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "SCAN", now: 0)
        _ = bootstrap.poll(now: 3_000_000_000)

        let update = bootstrap.receive(
            Data("background notice\r\n".utf8), now: 3_100_000_000
        )

        #expect(try #require(update.visibleOutput) == Data("background notice\r\n".utf8))
        #expect(update.command == nil)
        #expect(!update.isComplete)
    }

    @Test
    func userInputPreventsLateInstallationWithoutLeakingProbe() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "INPUT", now: 0)
        _ = bootstrap.receive(Data("user@host$ ".utf8), now: 0)
        _ = bootstrap.poll(now: 3_000_000_000)
        bootstrap.noteUserInput()

        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        let completed = bootstrap.receive(
            Data((probe + "\r\n__TRMD_INPUT_SHELL__/bin/zsh__\r\nuser@host$ ls -").utf8),
            now: 3_100_000_000
        )
        let visible = String(decoding: try #require(completed.visibleOutput), as: UTF8.self)

        #expect(completed.command == nil)
        #expect(completed.isComplete)
        #expect(visible == "user@host$ ls -")
        #expect(!visible.contains("__TRMD_"))
        #expect(!visible.contains("printf"))
    }
}
