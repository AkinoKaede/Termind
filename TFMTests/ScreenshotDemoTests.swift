import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure

#if DEBUG
    import Testing

    @testable import Termind

    @MainActor
    struct ScreenshotDemoTests {
        @Test
        func parsesEverySceneAndLanguageCombination() throws {
            let languages: [(argument: String, language: AppLanguage)] = [
                ("en", .english),
                ("zh", .simplifiedChinese),
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
            #expect(throws: ScreenshotDemoConfiguration.ParseError.duplicateArguments) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo=hosts:en", "--termind-demo=hosts:zh",
                ])
            }
        }

        @Test
        func hostsSceneOpensHostsWithNavigationVisible() {
            let configuration = ScreenshotDemoConfiguration(
                scene: .hosts, language: .english
            )
            let window = configuration.makeWindow(hosts: .demo())

            #expect(window.selectedDestination == .vault)
            #expect(window.vaultDestination == .hosts)
            #expect(window.showsSidebar)
            #expect(window.sidebarMode == .navigation)
        }

        @Test
        func appSettingsSceneUsesTheProductionSettingsRouteInBothLanguages() {
            for language in [AppLanguage.english, .simplifiedChinese] {
                let configuration = ScreenshotDemoConfiguration(scene: .appSettings, language: language)
                let window = configuration.makeWindow(hosts: .demo())
                #expect(window.selectedDestination == .settings)
                #expect(window.settingsRoute == .category(.app))
            }
        }

        @Test
        func workspaceScenesBuildExpectedWindowState() {
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
            #expect(!workspace.showsSidebar)
            #expect(command.selectedWorkspace != nil)
            #expect(command.showsSidebar)
            #expect(command.sidebarMode == .navigation)
            #expect(agent.selectedWorkspace != nil)
            #expect(agent.showsSidebar)
            #expect(agent.sidebarMode == .assistant)
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
