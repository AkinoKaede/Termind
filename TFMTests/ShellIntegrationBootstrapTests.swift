import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

@Suite
struct ShellIntegrationBootstrapTests {
    @Test
    func bashBootstrapIsHiddenAndEmitsStandardOSC7() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "ABC123")
        let probe = String(decoding: bootstrap.startCommand, as: UTF8.self)
        let probeOutput = Data(
            ("Welcome\r\nuser@host$ " + probe.dropLast()
                + "\r\n__TRMD_ABC123_SYSTEM__\"ubuntu\"|\"24.04\"|Linux|6.8.0-40-generic|x86_64__\r\n"
                + "__TRMD_ABC123_SHELL__/bin/bash__\r\nuser@host$ ").utf8
        )

        let probeUpdate = bootstrap.receive(probeOutput)
        let command = try #require(probeUpdate.command)
        let commandText = String(decoding: command, as: UTF8.self)
        #expect(commandText.contains("file://localhost%s"))
        #expect(commandText.contains("TermindCommand=ABC123"))
        #expect(commandText.contains("TermindCommandFinished=ABC123"))
        #expect(commandText.contains("TermindPrompt=ABC123"))
        #expect(commandText.contains("TermindDraft=ABC123"))
        #expect(commandText.contains("PROMPT_COMMAND"))
        #expect(commandText.contains("bash_preexec_imported"))
        #expect(commandText.contains("__termind_get_trap"))
        #expect(commandText.contains("__termind_integration_token"))
        #expect(commandText.contains("__termind_compose_clear"))
        #expect(commandText.contains("emacs-standard vi-insertion vi-command"))
        #expect(commandText.contains("\\e[777;1~"))
        #expect(commandText.contains("\\e[777;2~"))
        #expect(!commandText.contains("$HOSTNAME"))
        #expect(!commandText.contains("kitty-shell-cwd"))
        #expect(probeUpdate.visibleOutput == nil)
        #expect(probe.contains("/etc/os-release"))
        #expect(probe.contains("/usr/lib/os-release"))
        #expect(!probe.contains(". /etc/os-release"))

        let integrationOutput = Data(
            (String(commandText.dropLast())
                + "\r\n__TRMD_ABC123_HOME__%2Fhome%2Fuser\r\n"
                + "__TRMD_ABC123_DONE__\r\n"
                + "\u{1B}]7;file://localhost/home/user\u{7}user@host$ ").utf8
        )
        let completed = bootstrap.receive(integrationOutput)
        let visible = try #require(completed.visibleOutput)
        let visibleText = String(decoding: visible, as: UTF8.self)

        #expect(completed.isComplete)
        #expect(completed.homeDirectory == "/home/user")
        #expect(
            completed.diagnostic
                == .installed(late: false, homeResolved: true, systemInfoAvailable: true)
        )
        #expect(
            completed.systemInfo
                == RemoteSystemInfo(
                    distributionID: "ubuntu", distributionVersion: "24.04",
                    kernelName: "Linux", kernelRelease: "6.8.0-40-generic",
                    architecture: "x86_64"
                ))
        #expect(
            visibleText
                == "Welcome\r\n\u{1B}]7;file://localhost/home/user\u{7}user@host$ "
        )
        #expect(!visibleText.contains("__TRMD_"))
        #expect(!visibleText.contains("__termind_report_cwd"))
    }

    @Test(arguments: ["zsh", "fish"])
    func redrawnProbeEchoIsHidden(shell: String) throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "REDRAW")
        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        let redrawnProbe = probe.replacingOccurrences(
            of: "command sh", with: "\u{1B}[32mcommand\u{1B}[0m sh"
        )
        let probeOutput = Data(
            ("Welcome\r\nuser@host$ " + redrawnProbe
                + "\r\n__TRMD_REDRAW_SYSTEM__ubuntu||24.04|Linux|6.8.0|x86_64__\r\n"
                + "__TRMD_REDRAW_SHELL__/bin/\(shell)__\r\nuser@host$ ").utf8
        )

        let probeUpdate = bootstrap.receive(probeOutput)
        _ = try #require(probeUpdate.command)
        #expect(probeUpdate.visibleOutput == nil)

        let completed = bootstrap.receive(
            Data(
                ("__TRMD_REDRAW_HOME__%2Fhome%2Fuser\r\n"
                    + "__TRMD_REDRAW_DONE__\r\nuser@host$ ").utf8
            )
        )
        let visible = String(
            decoding: try #require(completed.visibleOutput), as: UTF8.self
        )

        #expect(visible == "Welcome\r\nuser@host$ ")
        #expect(!visible.contains("command sh"))
        #expect(!visible.contains("__TRMD_"))
    }

    @Test(arguments: ["zsh", "fish"])
    func timeoutDoesNotRevealRedrawnProbeEcho(shell: String) throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "SLOW", now: 0)
        let probe = String(decoding: bootstrap.startCommand.dropLast(), as: UTF8.self)
        let redrawnProbe = probe.replacingOccurrences(
            of: "command sh", with: "\u{1B}[35mcommand\u{1B}[0m sh"
        )
        _ = bootstrap.receive(
            Data(("Welcome\r\n\(shell)> " + redrawnProbe).utf8), now: 100_000_000
        )

        let update = bootstrap.poll(now: 3_000_000_000)
        let visible = String(decoding: update.visibleOutput ?? Data(), as: UTF8.self)

        #expect(visible == "Welcome\r\n")
        #expect(!visible.contains("command sh"))
        #expect(!visible.contains("__TRMD_"))

        let detected = bootstrap.receive(
            Data(
                ("\r\n__TRMD_SLOW_SYSTEM__ubuntu||24.04|Linux|6.8.0|x86_64__\r\n"
                    + "__TRMD_SLOW_SHELL__/bin/\(shell)__\r\n\(shell)> ").utf8
            ),
            now: 3_100_000_000
        )
        _ = try #require(detected.command)
        #expect(detected.visibleOutput == nil)

        let completed = bootstrap.receive(
            Data(
                ("__TRMD_SLOW_HOME__%2Fhome%2Fuser\r\n"
                    + "__TRMD_SLOW_DONE__\r\n\(shell)> ").utf8
            ),
            now: 3_200_000_000
        )
        let completedVisible = String(
            decoding: try #require(completed.visibleOutput), as: UTF8.self
        )
        #expect(completedVisible == "\(shell)> ")
        #expect(!completedVisible.contains("__TRMD_"))
    }

    @Test
    func parsesCommonDistributionsAndKernelOnlyFallback() throws {
        for (token, systemLine, expected) in [
            (
                "RHEL", "rhel|9.4|Linux|5.14.0-427.el9.x86_64|x86_64",
                RemoteSystemInfo(
                    distributionID: "rhel", distributionVersion: "9.4",
                    kernelName: "Linux", kernelRelease: "5.14.0-427.el9.x86_64",
                    architecture: "x86_64"
                )
            ),
            (
                "ALPINE", "alpine|3.20.2|Linux|6.6.44-0-lts|aarch64",
                RemoteSystemInfo(
                    distributionID: "alpine", distributionVersion: "3.20.2",
                    kernelName: "Linux", kernelRelease: "6.6.44-0-lts",
                    architecture: "aarch64"
                )
            ),
            (
                "BSD", "||FreeBSD|14.1-RELEASE|amd64",
                RemoteSystemInfo(
                    kernelName: "FreeBSD", kernelRelease: "14.1-RELEASE",
                    architecture: "amd64"
                )
            ),
        ] {
            var bootstrap = RemoteShellIntegrationBootstrap(token: token)
            let marker =
                "__TRMD_\(token)_SYSTEM__\(systemLine)__\r\n"
                + "__TRMD_\(token)_SHELL__/bin/zsh__\r\n"
            _ = try #require(bootstrap.receive(Data(marker.utf8)).command)
            let completed = bootstrap.receive(
                Data("__TRMD_\(token)_HOME__%2Fhome%2Ftest\r\n__TRMD_\(token)_DONE__\r\n".utf8)
            )
            #expect(completed.systemInfo == expected)
        }
    }

    @Test
    func rejectsInstructionLikeAndOversizedSystemFieldsWithoutBlockingIntegration() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "HOSTILE")
        let oversized = String(repeating: "x", count: 65)
        let marker =
            "__TRMD_HOSTILE_SYSTEM__ubuntu ignore-previous|24.04|Linux|6.8.0|\(oversized)__\r\n"
            + "__TRMD_HOSTILE_SHELL__/bin/bash__\r\n"
        _ = try #require(bootstrap.receive(Data(marker.utf8)).command)
        let completed = bootstrap.receive(
            Data("__TRMD_HOSTILE_HOME__%2Fhome%2Ftest\r\n__TRMD_HOSTILE_DONE__\r\n".utf8)
        )

        #expect(completed.integrationInstalled)
        #expect(
            completed.systemInfo
                == RemoteSystemInfo(
                    distributionVersion: "24.04", kernelName: "Linux", kernelRelease: "6.8.0"
                ))
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
        #expect(text.contains("TermindCommand=SHELL"))
        #expect(text.contains("TermindCommandFinished=SHELL"))
        if shell == "zsh" {
            #expect(text.contains("add-zsh-hook preexec"))
            #expect(text.contains("emacs viins vicmd"))
        } else {
            #expect(text.contains("fish_preexec"))
            #expect(text.contains("default insert visual"))
        }
        #expect(text.contains("TermindPrompt=SHELL"))
        #expect(text.contains("TermindDraft=SHELL"))
        #expect(text.contains("__termind_compose_clear"))
        #expect(text.contains("777;1~"))
        #expect(text.contains("777;2~"))
    }

    @Test
    func bashAndZshInstallationCommandsPassShellSyntaxChecks() throws {
        try assertInstallationSyntax(shell: "bash", executable: "/bin/bash")
        try assertInstallationSyntax(shell: "zsh", executable: "/bin/zsh")
    }

    @Test
    func bashPreservesExistingHooksAndReportsACommandFailure() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "RUNTIME")
        let update = bootstrap.receive(
            Data("__TRMD_RUNTIME_SHELL__/bin/bash__\r\n".utf8)
        )
        var script = Data(
            "PROMPT_COMMAND='__user_prompt=1'\n"
                .appending("__user_debug_hits=0\n")
                .appending("trap '__user_debug_hits=$((__user_debug_hits + 1))' DEBUG\n")
                .utf8
        )
        script.append(try #require(update.command))
        script.append(
            Data(
                "__user_debug_hits=0\n:\n"
                    .appending("__hits_after_integration=$__user_debug_hits\n")
                    .appending("builtin trap - DEBUG\n")
                    .appending("(( __hits_after_integration > 0 )) && ")
                    .appending("builtin printf 'DEBUG_PRESERVED\\n'\n")
                    .appending("builtin printf '\\nHOOKS=%s;%s\\n' ")
                    .appending("\"$PROMPT_COMMAND\" \"$__hits_after_integration\"\n")
                    .appending("__termind_report_prompt\n")
                    .appending("__termind_report_command 'false'\n")
                    .appending("false\n__termind_report_prompt\nexit 0\n")
                    .utf8
            ))

        let result = try runShell(executable: "/bin/bash", arguments: [], input: script)

        #expect(result.status == 0, Comment(rawValue: result.errors))
        #expect(result.output.contains("DEBUG_PRESERVED"))
        #expect(
            result.output.contains(
                "HOOKS=__termind_prompt_begin\n__user_prompt=1\n__termind_prompt_end;"
            ))
        #expect(result.output.contains("TermindCommand=RUNTIME;false\u{7}"))
        #expect(result.output.contains("TermindCommandFinished=RUNTIME;1;0\u{7}"))
    }

    @Test
    func bashWrapsIndexedPromptCommandWithoutReorderingExistingHooks() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "ARRAY")
        let update = bootstrap.receive(
            Data("__TRMD_ARRAY_SHELL__/bin/bash__\r\n".utf8)
        )
        var script = Data(
            "PROMPT_COMMAND=('__user_prompt_one' '__user_prompt_two')\n".utf8
        )
        script.append(try #require(update.command))
        script.append(
            Data(
                "builtin trap - DEBUG\n"
                    .appending("builtin printf 'ARRAY=%s|%s|%s|%s\\n' ")
                    .appending(
                        "\"${PROMPT_COMMAND[0]}\" \"${PROMPT_COMMAND[1]}\" "
                    )
                    .appending(
                        "\"${PROMPT_COMMAND[2]}\" \"${PROMPT_COMMAND[3]}\"\n"
                    )
                    .utf8
            ))

        let result = try runShell(executable: "/bin/bash", arguments: [], input: script)

        #expect(result.status == 0, Comment(rawValue: result.errors))
        #expect(
            result.output.contains(
                "ARRAY=__termind_prompt_begin|__user_prompt_one|__user_prompt_two|__termind_prompt_end\n"
            ))
    }

    @Test
    func bashDoesNotRecordAlmaLinuxTitlePromptCommand() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "ALMA")
        let update = bootstrap.receive(
            Data("__TRMD_ALMA_SHELL__/bin/bash__\r\n".utf8)
        )
        var script = Data(
            #"""
            PS1=; PS2=
            PROMPT_COMMAND='printf "\033]0;%s@%s:%s\007" "${USER}" "${HOSTNAME%%.*}" "${PWD/#$HOME/\~}"'

            """#.utf8
        )
        script.append(try #require(update.command))
        script.append(Data("false\necho USER_VISIBLE\nexit 0\n".utf8))

        let result = try runShell(
            executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-i"], input: script
        )
        #expect(result.status == 0, Comment(rawValue: result.errors))

        var filter = RemoteCommandEventFilter(token: "ALMA")
        var visible = Data()
        var events: [RemoteCommandEventFilter.Event] = []
        for byte in result.output.utf8 {
            let filtered = filter.receive(Data([byte]))
            visible.append(filtered.visibleOutput)
            events.append(contentsOf: filtered.events)
        }

        let visibleText = String(decoding: visible, as: UTF8.self)
        let commands = events.compactMap { event -> String? in
            guard case .commandStarted(let command) = event else { return nil }
            return command
        }
        let statuses = events.compactMap { event -> Int32? in
            guard case .commandFinished(let status, _) = event else { return nil }
            return status
        }
        let promptCount = events.count(where: { $0 == .promptReady })

        #expect(visibleText.contains("\u{1B}]0;"))
        #expect(visibleText.contains("USER_VISIBLE"))
        #expect(commands.contains("false"))
        #expect(commands.contains("echo USER_VISIBLE"))
        #expect(!commands.contains(where: { $0.contains("]0;%s@%s:%s") }))
        #expect(statuses.contains(1))
        #expect(statuses.contains(0))
        #expect(promptCount >= 3)
    }

    @Test
    func bashIgnoresItsDraftBindingWithoutLeavingThePrompt() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "DRAFT")
        let update = bootstrap.receive(
            Data("__TRMD_DRAFT_SHELL__/bin/bash__\r\n".utf8)
        )
        var script = Data(
            """
            __termind_test_internal() {
                __termind_report_command '__termind_compose_draft'
                builtin printf '\nREADY_AFTER_INTERNAL=%s\n' "$__termind_command_ready"
            }

            """.utf8
        )
        script.append(try #require(update.command))
        script.append(
            Data(
                "__termind_test_internal\n"
                    .appending("false\n__termind_report_prompt\nexit 0\n")
                    .utf8
            ))

        let result = try runShell(executable: "/bin/bash", arguments: [], input: script)

        #expect(result.status == 0, Comment(rawValue: result.errors))
        #expect(result.output.contains("READY_AFTER_INTERNAL=1\n"))
        #expect(!result.output.contains("TermindCommand=DRAFT;__termind_"))
        #expect(result.output.contains("TermindCommand=DRAFT;false\u{7}"))
        #expect(result.output.contains("TermindCommandFinished=DRAFT;1;0\u{7}"))
    }

    @Test(arguments: [0, 1, 42], [false, true])
    func zshRunsPromptHooksAndPreservesCommandOutput(exitStatus: Int, capturesStartupOutput: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("LS_OUTPUT_VISIBLE"))

        var bootstrap = RemoteShellIntegrationBootstrap(token: "ZSHRUNTIME")
        let update = bootstrap.receive(
            Data("__TRMD_ZSHRUNTIME_SHELL__/bin/zsh__\r\n".utf8)
        )
        var script = Data(
            """
            PS1=; PS2=; RPS1=; unsetopt promptcr promptsp
            function user_prompt {
                builtin local prompt_status=$?
                if [[ -n ${saved_stdout:-} ]]; then
                    exec 1>&$saved_stdout
                    exec {saved_stdout}>&-
                    unset saved_stdout
                fi
                builtin printf 'USER_PROMPT_STATUS=%s\\n' "$prompt_status"
            }
            function user_preexec { builtin printf 'USER_PREEXEC\\n'; }
            precmd_functions=(user_prompt); preexec_functions=(user_preexec)

            """.utf8
        )
        if capturesStartupOutput {
            // Model a prompt plugin that captures startup output and restores
            // stdout from precmd. Aborting our hook must not strand that capture,
            // which would make subsequent commands, including ls, invisible.
            script.append(Data("exec {saved_stdout}>&1; exec >/dev/null; ".utf8))
        }
        script.append(try #require(update.command))
        script.append(
            Data(
                """
                ls
                builtin printf 'STDOUT_VISIBLE\\n'; builtin printf 'STDERR_VISIBLE\\n' >&2; (exit \(exitStatus))
                builtin printf 'NEXT_STATUS=%s\\n' "$?"
                exit 0

                """.utf8
            ))

        // Interactive mode executes zsh's real preexec/precmd chain. A syntax
        // check cannot detect assignments to special read-only parameters.
        let result = try runShell(
            executable: "/bin/zsh", arguments: ["-d", "-f", "-i"], input: script,
            directory: directory
        )
        #expect(result.status == 0, Comment(rawValue: result.errors))
        #expect(!result.errors.contains("read-only variable"), Comment(rawValue: result.errors))
        #expect(result.errors.contains("STDERR_VISIBLE\n"))

        var filter = RemoteCommandEventFilter(token: "ZSHRUNTIME")
        var visible = Data()
        var events: [RemoteCommandEventFilter.Event] = []
        // SSH may split an OSC frame at any byte; ordinary output must survive.
        for byte in result.output.utf8 {
            let filtered = filter.receive(Data([byte]))
            visible.append(filtered.visibleOutput)
            events.append(contentsOf: filtered.events)
        }
        let text = String(decoding: visible, as: UTF8.self)
        #expect(text.contains("LS_OUTPUT_VISIBLE\n"))
        #expect(text.contains("STDOUT_VISIBLE\n"))
        #expect(text.contains("NEXT_STATUS=\(exitStatus)\n"))
        #expect(text.contains("USER_PROMPT_STATUS=\(exitStatus)\n"))
        #expect(text.contains("USER_PREEXEC\n"))
        #expect(text.contains("\u{1B}]7;file://localhost"))
        #expect(events.contains(.promptReady))
        #expect(events.contains(.commandStarted("ls")))
        #expect(
            events.contains { event in
                if case .commandStarted(let command) = event {
                    return command.contains("STDOUT_VISIBLE")
                }
                return false
            })
        #expect(
            events.contains { event in
                if case .commandFinished(let status, let duration) = event {
                    return status == Int32(exitStatus) && duration != nil
                }
                return false
            })
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
        #expect(update.homeResolutionUnavailable || update.isComplete)
        #expect(update.diagnostic == .skipped(.unsupportedShell))
    }

    @Test
    func homeMarkerDecodesSpecialCharacters() throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "HOME")
        let install = bootstrap.receive(
            Data("__TRMD_HOME_SHELL__/bin/bash__\r\n".utf8)
        )
        _ = try #require(install.command)

        let completed = bootstrap.receive(
            Data("__TRMD_HOME_HOME__%2Fhome%2FJane%20Doe\r\n__TRMD_HOME_DONE__\r\n".utf8)
        )

        #expect(completed.homeDirectory == "/home/Jane Doe")
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
        #expect(update.diagnostic == .probeDelayed)
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
            Data((commandText + "\r\n__TRMD_LATE_HO").utf8), now: 3_400_000_000
        )
        let completed = bootstrap.receive(
            Data(
                ("ME__%2Fhome%2Fuser\r\n__TRMD_LATE_DONE__\r\n"
                    + "\u{1B}]7;file://localhost/home/user\u{7}user@host$ ").utf8
            ),
            now: 3_500_000_000
        )
        let visible = String(decoding: try #require(completed.visibleOutput), as: UTF8.self)

        #expect(completed.isComplete)
        #expect(completed.homeDirectory == "/home/user")
        #expect(
            completed.diagnostic
                == .installed(late: true, homeResolved: true, systemInfoAvailable: false)
        )
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
        #expect(completed.diagnostic == .skipped(.unsupportedShell))
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
        #expect(completed.diagnostic == .timedOut(stage: .lateProbe, late: true))
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
        #expect(completed.diagnostic == .timedOut(stage: .installation, late: true))
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
        #expect(completed.diagnostic == .skipped(.userInput))
        #expect(visible == "user@host$ ls -")
        #expect(!visible.contains("__TRMD_"))
        #expect(!visible.contains("printf"))
    }

    private func assertInstallationSyntax(shell: String, executable: String) throws {
        var bootstrap = RemoteShellIntegrationBootstrap(token: "SYNTAX")
        let update = bootstrap.receive(
            Data("__TRMD_SYNTAX_SHELL__/bin/\(shell)__\r\n".utf8)
        )
        let command = try #require(update.command)
        let result = try runShell(executable: executable, arguments: ["-n"], input: command)
        #expect(result.status == 0, "\(shell): \(result.errors)")
    }

    private func runShell(
        executable: String, arguments: [String], input: Data, directory: URL? = nil
    ) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        standardInput.fileHandleForWriting.write(input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}
