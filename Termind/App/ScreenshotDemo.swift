import Foundation

/// Explicit, isolated launch scenes used to capture product images for the
/// website. Nothing here is reachable in an ordinary launch.
enum ScreenshotDemoMode: String {
    case workspace
    case agent
    case command

    static var active: ScreenshotDemoMode? {
        ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_DEMO"]
            .flatMap(ScreenshotDemoMode.init(rawValue:))
    }

    static var language: AppLanguage? {
        switch ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_LANGUAGE"] {
        case "en": .english
        case "zh": .simplifiedChineseChina
        default: nil
        }
    }

    func makeWindow(hosts: HostLibraryModel) -> WindowModel {
        switch self {
        case .workspace:
            return workspaceWindow(hosts: hosts, showsCommandResult: false)
        case .command:
            return workspaceWindow(hosts: hosts, showsCommandResult: true)
        case .agent:
            return agentWindow(hosts: hosts)
        }
    }

    private func agentWindow(hosts: HostLibraryModel) -> WindowModel {
        guard let host = hosts.hosts.first else {
            preconditionFailure("Screenshot demo requires its bundled host")
        }

        let session = SSHSessionModel.demo(host: host)
        let pane = Pane(.sshSession(session))
        pane.customTitle = "nginx diagnostics"
        let workspace = Workspace(pane: pane)
        workspace.customTitle = "Production diagnostics"
        workspace.focusedPaneID = pane.id

        let conversation = ConversationModel.demo()
        let library = AssistantLibraryModel()
        library.insertAndSelect(conversation)

        let window = WindowModel(tabs: [workspace], assistantLibrary: library)
        window.showsSidebar = true
        window.sidebarMode = .assistant
        window.openAssistantInSidebar(conversation.id)
        return window
    }

    private func workspaceWindow(
        hosts: HostLibraryModel, showsCommandResult: Bool
    ) -> WindowModel {
        let saved = hosts.hosts
        precondition(saved.count >= 2, "Screenshot demo requires its bundled hosts")

        let firstSession: SSHSessionModel
        if showsCommandResult {
            firstSession = SSHSessionModel.demo(
                host: saved[0],
                transcript: [
                    "\u{001B}]7;file://web-01/var/log/nginx\u{0007}",
                    "\u{001B}[2mLast login: Thu Aug 27 16:42:18 from 10.0.0.12\u{001B}[0m",
                    "\u{001B}[36mdeploy@web-01\u{001B}[0m "
                        + "\u{001B}[34m/var/log/nginx\u{001B}[0m % "
                        + "find . -type f -newermt today -printf '%s %p\\n' | sort -nr | head -10 ",
                ].joined(separator: "\r\n")
            )
        } else {
            firstSession = .demo(
                host: saved[0],
                transcript: broadcastTranscript(for: saved[0].name, variant: .primary)
            )
        }

        let first = Pane(.sshSession(firstSession))
        first.customTitle = showsCommandResult ? "nginx logs" : "api-01"
        let sftpSession = SFTPSessionModel.demo(hostID: saved[0].id)
        sftpSession.selection = ["/etc/nginx/nginx.conf"]
        let sftp = Pane(.sftpSession(sftpSession))
        sftp.customTitle = "nginx config"
        let secondSession = showsCommandResult
            ? SSHSessionModel.demo(host: saved[1])
            : SSHSessionModel.demo(
                host: saved[1],
                transcript: broadcastTranscript(for: saved[1].name, variant: .secondary)
            )
        let second = Pane(.sshSession(secondSession))
        second.customTitle = "worker-02"

        let workspace = Workspace(pane: first)
        if showsCommandResult {
            workspace.layout = .leaf(first)
        } else {
            workspace.layout = .split(
                .init(
                    axis: .horizontal,
                    fraction: 0.5,
                    first: .leaf(first),
                    second: .split(
                        .init(
                            axis: .vertical,
                            fraction: 0.5,
                            first: .leaf(sftp),
                            second: .leaf(second)
                        )
                    )
                )
            )
        }
        workspace.focusedPaneID = first.id
        workspace.customTitle = showsCommandResult ? "Log investigation" : "Production diagnostics"
        workspace.broadcastsInput = !showsCommandResult
        if showsCommandResult {
            workspace.commandGeneratorState = .inserted(targetCount: 1)
        }

        let window = WindowModel(tabs: [workspace])
        window.showsSidebar = false
        return window
    }

    private enum BroadcastTranscriptVariant { case primary, secondary }

    private func broadcastTranscript(
        for host: String, variant: BroadcastTranscriptVariant
    ) -> String {
        let prompt =
            "\u{001B}[36mdeploy@\(host)\u{001B}[0m "
            + "\u{001B}[34m/var/log/nginx\u{001B}[0m %"
        let history: [String]
        switch variant {
        case .primary:
            history = [
                prompt + " systemctl status nginx --no-pager",
                "● nginx.service - A high performance web server",
                "     Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)",
                "     Active: \u{001B}[32mactive (running)\u{001B}[0m since Thu 2026-08-27 09:14:03 UTC",
            ]
        case .secondary:
            history = [
                prompt + " journalctl -u nginx -n 2 --no-pager",
                "Aug 27 09:13:58 web-02 nginx[1842]: configuration test is successful",
                "Aug 27 09:14:03 web-02 systemd[1]: Started nginx.service",
            ]
        }
        return ([
            "\u{001B}]7;file://\(host)/var/log/nginx\u{0007}",
            "\u{001B}[2mLast login: Thu Aug 27 16:42:18 from 10.0.0.12\u{001B}[0m",
        ] + history + [
            prompt + " tail -f /var/log/nginx/access.log",
        ]).joined(separator: "\r\n")
    }
}
