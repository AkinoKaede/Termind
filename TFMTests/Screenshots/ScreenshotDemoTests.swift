import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation

#if DEBUG
    import Testing

    @testable import Termind

    @Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_MAC_SCREENSHOTS"] == "1"))
    @MainActor
    struct ScreenshotDemoTests {
        @Test
        func parsesEverySceneAndLanguageCombination() throws {
            let languages: [(argument: String, language: AppLanguage)] = [
                ("en", .english),
                ("zh-Hans", .simplifiedChinese),
                ("zh-Hant", .traditionalChinese),
            ]

            for scene in ScreenshotDemoConfiguration.Scene.allCases {
                for language in languages {
                    let parsed = try ScreenshotDemoConfiguration.parse(arguments: [
                        "Termind", "--termind-demo=\(scene.rawValue):\(language.argument)",
                    ])
                    let configuration = try #require(parsed)
                    #expect(configuration.scene == scene)
                    #expect(configuration.language == language.language)
                }
            }
        }

        @Test
        func noDemoArgumentUsesOrdinaryLaunch() throws {
            #expect(
                try ScreenshotDemoConfiguration.parse(arguments: ["Termind"]) == nil
            )
        }

        @Test
        func rejectsIncompleteAndUnknownArguments() {
            #expect(
                throws: ScreenshotDemoConfiguration.ParseError.invalidFormat(
                    "--termind-demo"
                )
            ) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo",
                ])
            }
            #expect(
                throws: ScreenshotDemoConfiguration.ParseError.invalidFormat(
                    "--termind-demo=hosts"
                )
            ) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo=hosts",
                ])
            }
            #expect(throws: ScreenshotDemoConfiguration.ParseError.unknownScene("vault")) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo=vault:en",
                ])
            }
            #expect(throws: ScreenshotDemoConfiguration.ParseError.unknownLanguage("fr")) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo=hosts:fr",
                ])
            }
            #expect(throws: ScreenshotDemoConfiguration.ParseError.unknownLanguage("zh")) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo=hosts:zh",
                ])
            }
            #expect(throws: ScreenshotDemoConfiguration.ParseError.duplicateArguments) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo=hosts:en", "--termind-demo=hosts:zh-Hans",
                ])
            }
        }

        @Test
        func hostsSceneOpensHostsWithNavigationVisible() {
            let configuration = ScreenshotDemoConfiguration(
                scene: .hosts, language: .english
            )
            let window = configuration.makeWindow(hosts: configuration.makeHostLibrary())

            #expect(window.selectedDestination == .vault)
            #expect(window.vaultDestination == .hosts)
            #expect(window.showsSidebar)
            #expect(window.sidebarMode == .navigation)
        }

        @Test
        func vaultCaptureStatusesMatchItsTwoWorkspacesInEveryLanguage() throws {
            for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
                let configuration = ScreenshotDemoConfiguration(scene: .hosts, language: language)
                let hosts = configuration.makeHostLibrary()
                let window = configuration.makeWindow(hosts: hosts)

                #expect(window.workspaces.count == 2)
                #expect(hosts.sftpTransfers.isEmpty)
                #expect(!hosts.hosts.isEmpty)
                var connectedHostIDs: Set<UUID> = []
                for workspace in window.workspaces {
                    #expect(workspace.panes.count == 1)
                    let session = try #require(workspace.panes.first?.sshSession)
                    #expect(session.status == .connected)
                    connectedHostIDs.insert(session.hostID)
                }
                #expect(connectedHostIDs.count == 2)
                for host in hosts.hosts {
                    let expectedStatus: ConnectionStatus =
                        connectedHostIDs.contains(host.id) ? .connected : .disconnected
                    #expect(hosts.status(of: host.id) == expectedStatus)
                }
            }
        }

        @Test
        func otherCaptureScenesKeepTheirConnectionActivity() {
            for scene in ScreenshotDemoConfiguration.Scene.allCases where scene != .hosts {
                let hosts = ScreenshotDemoConfiguration(scene: scene, language: .english).makeHostLibrary()
                #expect(!hosts.sftpTransfers.isEmpty)
                #expect(hosts.hosts.contains { hosts.status(of: $0.id) == .connected })
                #expect(hosts.hosts.contains { hosts.status(of: $0.id) == .connecting })
            }
        }

        @Test
        func appSettingsSceneUsesTheProductionSettingsRouteInEveryLanguage() {
            for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
                let configuration = ScreenshotDemoConfiguration(scene: .appSettings, language: language)
                let window = configuration.makeWindow(hosts: .demo())
                #expect(window.selectedDestination == .settings)
                #expect(window.settingsRoute == .category(.app))
            }
        }

        @Test
        func workspaceScenesBuildExpectedWindowState() throws {
            let hosts = HostLibraryModel.demo()
            let workspace = ScreenshotDemoConfiguration(
                scene: .workspace, language: .english
            ).makeWindow(hosts: hosts)
            let command = ScreenshotDemoConfiguration(
                scene: .command, language: .english
            ).makeWindow(hosts: hosts)
            let agent = ScreenshotDemoConfiguration(
                scene: .agent, language: .english
            ).makeWindow(hosts: hosts)

            #expect(workspace.selectedWorkspace != nil)
            #expect(workspace.showsSidebar)
            #expect(workspace.sidebarMode == .navigation)
            #expect(command.selectedWorkspace != nil)
            #expect(command.showsSidebar)
            #expect(command.sidebarMode == .navigation)
            #expect(agent.selectedWorkspace != nil)
            #expect(agent.showsSidebar)
            #expect(agent.sidebarMode == .assistant)

            let workspaceModel = try #require(workspace.selectedWorkspace)
            #expect(workspaceModel.focusedPane === workspaceModel.panes[0])
            #expect(workspaceModel.panes.map(\.kind) == [.sshSession, .sshSession, .sftpChannel])

            guard case .split(let root) = workspaceModel.layout else {
                Issue.record("Workspace screenshot demo should use a horizontal root split")
                return
            }
            #expect(root.axis == .horizontal)
            #expect(root.fraction == 0.5)
            guard case .split(let terminals) = root.first else {
                Issue.record("Workspace screenshot demo should stack two terminals on the left")
                return
            }
            #expect(terminals.axis == .vertical)
            #expect(terminals.fraction == 0.5)
            #expect(terminals.first.panes.first?.kind == .sshSession)
            #expect(terminals.second.panes.first?.kind == .sshSession)
            #expect(root.second.panes.first?.kind == .sftpChannel)

            let sftp = try #require(root.second.panes.first?.sftpChannel)
            #expect(sftp.files.count == 11)
            #expect(
                Set(sftp.files.map(\.name)) == [
                    "conf.d", "modules-enabled", "sites-available", "sites-enabled", "snippets",
                    "fastcgi.conf", "fastcgi_params", "mime.types", "nginx.conf", "proxy_params",
                    "uwsgi_params",
                ])
            #expect(sftp.selection == ["/etc/nginx/nginx.conf"])
        }

        @Test
        func metricsScenesUseFrozenRowsAndCorrectNavigation() throws {
            for scene in [ScreenshotDemoConfiguration.Scene.metrics, .metricsDetail] {
                let configuration = ScreenshotDemoConfiguration(scene: scene, language: .english)
                let hosts = HostLibraryModel.demo()
                let model = configuration.makeMetricsModel(hosts: hosts)
                let window = configuration.makeWindow(hosts: hosts)
                #expect(window.selectedDestination == .metrics)
                #expect(window.showsSidebar == (scene == .metrics))
                #expect(window.metricsHostID == (scene == .metricsDetail ? hosts.hosts.first?.id : nil))
                #expect(model.servers.count == 6)
                let first = try #require(model.servers.first)
                let point = try #require(first.point)
                #expect(first.processes.count == 20)
                #expect(first.filesystems.count == 1)
                #expect(point.cpu == 32.8)
                let liveSample = LinuxMetricsParser.parse(
                    "__TERMIND_ADDRESSES__\n2: eth0 inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0"
                )
                #expect(point.networkDevices.first?.addresses == liveSample.interfaceAddresses["eth0"])
                model.start()
                #expect(model.servers.first === first)
                #expect(model.servers.allSatisfy { !$0.isConnecting && $0.selection.enabled && $0.point != nil })
                if scene == .metrics {
                    let rates = model.servers.flatMap {
                        [$0.point?.diskRead, $0.point?.diskWrite, $0.point?.networkReceive, $0.point?.networkSend]
                            .compactMap { $0 }
                    }
                    #expect(rates.contains { $0 >= 1_024 && $0 < 1_048_576 })
                    #expect(rates.contains { $0 >= 1_048_576 })
                    #expect(model.servers[0].point?.diskWrite == 0)
                    #expect(model.servers[4].point?.networkSend == 0)
                    #expect(model.servers[5].point?.diskRead == 0)
                    #expect(model.servers[5].point?.diskWrite == 0)
                    #expect(model.servers[2].point?.cpu == 96.4)
                    #expect(model.servers[2].point?.memory == 82.6)
                    #expect(model.servers[1].point?.diskWrite == 0)
                    #expect(model.servers[3].point?.networkReceive == 0)
                    #expect(model.servers[3].point?.networkSend == 0)
                    #expect(
                        model.servers.allSatisfy {
                            $0.point?.diskRead != nil && $0.point?.diskWrite != nil
                                && $0.point?.networkReceive != nil && $0.point?.networkSend != nil
                        })
                    #expect(model.servers[5].point?.memory == 93.1)
                    #expect(model.servers.compactMap { $0.point?.memoryFree }.allSatisfy { $0 >= 0 })
                }
                model.shutdown()
            }
        }

        @Test
        func otherScreenshotScenesDoNotLoadSavedMonitors() {
            let configuration = ScreenshotDemoConfiguration(scene: .hosts, language: .english)
            let model = configuration.makeMetricsModel(hosts: .demo())
            model.start()
            #expect(model.servers.isEmpty)
            model.shutdown()
        }

        @Test
        func demoHostsUseEightDistinctBundledDistributionIcons() throws {
            let hosts = HostLibraryModel.demo().hosts
            let distributions = try hosts.map {
                try #require($0.detectedDistribution)
            }
            #expect(Set(distributions.map(\.id)).count == 8)
            for distribution in distributions {
                #expect(LinuxDistributionIconCatalog.entry(for: distribution) != nil)
            }
        }
    }
#endif
