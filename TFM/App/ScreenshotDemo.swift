import TermindApplication

#if DEBUG
    import Foundation

    /// An explicit, isolated launch configuration used to capture product
    /// images. The scene and language travel as one value so a capture cannot
    /// accidentally combine demo content in one language with UI in another.
    struct ScreenshotDemoConfiguration: Equatable {
        enum Scene: String, CaseIterable {
            case hosts
            case workspace
            case agent
            case command
            case metrics
            case metricsDetail = "metrics-detail"
            case appSettings = "app-settings"
        }

        enum ParseError: Error, Equatable, CustomStringConvertible {
            case duplicateArguments
            case invalidFormat(String)
            case unknownScene(String)
            case unknownLanguage(String)

            var description: String {
                switch self {
                case .duplicateArguments:
                    return "Pass --termind-demo only once."
                case .invalidFormat(let value):
                    return "Invalid Demo argument \(value). Expected "
                        + "--termind-demo=<hosts|workspace|agent|command|metrics|metrics-detail|app-settings>:<en|ja|zh-Hans|zh-Hant>."
                case .unknownScene(let value):
                    return
                        "Unknown Demo scene \(value). Expected hosts, workspace, agent, command, metrics, metrics-detail, or app-settings."
                case .unknownLanguage(let value):
                    return "Unknown Demo language \(value). Expected en, ja, zh-Hans, or zh-Hant."
                }
            }
        }

        private static let option = "--termind-demo"

        let scene: Scene
        let language: AppLanguage

        static var active: Self? {
            do {
                return try parse(arguments: ProcessInfo.processInfo.arguments)
            } catch {
                fatalError("Unable to launch Termind Demo: \(error)")
            }
        }

        static func parse(arguments: [String]) throws -> Self? {
            let candidates = arguments.filter {
                $0 == option || $0.hasPrefix("\(option)=")
            }
            guard candidates.count <= 1 else { throw ParseError.duplicateArguments }
            guard let argument = candidates.first else { return nil }

            let prefix = "\(option)="
            guard argument.hasPrefix(prefix) else {
                throw ParseError.invalidFormat(argument)
            }
            let value = String(argument.dropFirst(prefix.count))
            let components = value.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw ParseError.invalidFormat(argument)
            }

            let sceneValue = String(components[0])
            guard let scene = Scene(rawValue: sceneValue) else {
                throw ParseError.unknownScene(sceneValue)
            }

            let languageValue = String(components[1])
            let language: AppLanguage
            switch languageValue {
            case "en": language = .english
            case "ja": language = .japanese
            case "ko": language = .korean
            case "de": language = .german
            case "fr": language = .french
            case "zh-Hans": language = .simplifiedChinese
            case "zh-Hant": language = .traditionalChinese
            default: throw ParseError.unknownLanguage(languageValue)
            }
            return Self(scene: scene, language: language)
        }

        var windowSize: CGSize {
            CGSize(width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
        }

        func makeHostLibrary() -> HostLibraryModel {
            let hosts = HostLibraryModel.demo(language: language, includesConnectionActivity: scene != .hosts)
            if scene == .hosts {
                // Seed once at app launch, matching the two workspaces below. Window construction
                // runs inside SwiftUI rendering and must not mutate the observed host library.
                for host in hosts.hosts.prefix(2) {
                    hosts.setStatus(.connected, for: host.id)
                }
            }
            return hosts
        }

        func makeWindow(hosts: HostLibraryModel) -> WindowModel {
            switch scene {
            case .workspace:
                return workspaceWindow(hosts: hosts, showsCommandResult: false)
            case .command:
                return workspaceWindow(hosts: hosts, showsCommandResult: true)
            case .agent:
                return agentWindow(hosts: hosts)
            case .hosts:
                return hostsWindow(hosts: hosts)
            case .appSettings:
                let window = WindowModel()
                window.selectedDestination = .settings
                window.settingsRoute = .category(.app)
                return window
            case .metrics, .metricsDetail:
                let window = WindowModel()
                window.selectedDestination = .metrics
                window.showsSidebar = scene == .metrics
                window.sidebarMode = .navigation
                window.metricsHostID = scene == .metricsDetail ? hosts.hosts.first?.id : nil
                return window
            }
        }

        private func hostsWindow(hosts: HostLibraryModel) -> WindowModel {
            let workspaces = hosts.hosts.prefix(2).map { host in
                let session = SSHSessionModel.demo(host: host)
                let workspace = Workspace(pane: Pane(.sshSession(session)))
                workspace.customTitle = host.name
                return workspace
            }
            let window = WindowModel(workspaces: workspaces, vaultDestination: .hosts)
            window.selectedDestination = .vault
            window.showsSidebar = true
            window.sidebarMode = .navigation
            return window
        }

        private func agentWindow(hosts: HostLibraryModel) -> WindowModel {
            guard let host = hosts.hosts.first else {
                preconditionFailure("Screenshot demo requires its bundled host")
            }

            let session = SSHSessionModel.demo(host: host)
            let pane = Pane(.sshSession(session))
            pane.customTitle = text(en: "nginx diagnostics", zhHans: "Nginx 诊断", zhHant: "Nginx 診斷", ja: "nginxの診断")
            let workspace = Workspace(pane: pane)
            workspace.customTitle = text(
                en: "Production diagnostics", zhHans: "生产环境诊断", zhHant: "正式環境診斷", ja: "本番環境の診断")
            workspace.focusedPaneID = pane.id

            let conversation = ConversationModel.demo(language: language)
            let library = AssistantLibraryModel()
            library.insertAndSelect(conversation)

            let window = WindowModel(workspaces: [workspace], assistantLibrary: library)
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
            first.customTitle =
                showsCommandResult
                ? text(en: "nginx logs", zhHans: "Nginx 日志", zhHant: "Nginx 日誌", ja: "nginxのログ")
                : "api-01"
            let sftpChannel = SFTPChannelModel.demo(hostID: saved[0].id)
            sftpChannel.selection = ["/etc/nginx/nginx.conf"]
            let sftp = Pane(.sftpChannel(sftpChannel))
            sftp.customTitle = text(en: "nginx config", zhHans: "Nginx 配置", zhHant: "Nginx 設定", ja: "nginxの設定")
            let secondSession =
                showsCommandResult
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
                        first: .split(
                            .init(
                                axis: .vertical,
                                fraction: 0.5,
                                first: .leaf(first),
                                second: .leaf(second)
                            )
                        ),
                        second: .leaf(sftp)
                    )
                )
            }
            workspace.focusedPaneID = first.id
            workspace.customTitle =
                showsCommandResult
                ? text(en: "Log investigation", zhHans: "日志调查", zhHant: "日誌調查", ja: "ログの調査")
                : text(en: "Production diagnostics", zhHans: "生产环境诊断", zhHant: "正式環境診斷", ja: "本番環境の診断")
            workspace.broadcastsInput = !showsCommandResult
            if showsCommandResult {
                workspace.commandGeneratorState = .inserted(targetCount: 1)
            }

            let window = WindowModel(workspaces: [workspace])
            window.showsSidebar = true
            window.sidebarMode = .navigation
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
            return
                ([
                    "\u{001B}]7;file://\(host)/var/log/nginx\u{0007}",
                    "\u{001B}[2mLast login: Thu Aug 27 16:42:18 from 10.0.0.12\u{001B}[0m",
                ] + history + [
                    prompt + " tail -f /var/log/nginx/access.log"
                ]).joined(separator: "\r\n")
        }

        private func text(en: String, zhHans: String, zhHant: String, ja: String) -> String {
            switch language {
            case .simplifiedChinese: zhHans
            case .traditionalChinese: zhHant
            case .japanese: ja
            case .system, .english, .german, .french, .korean: en
            }
        }
    }
#endif
