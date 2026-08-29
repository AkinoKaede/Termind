#if DEBUG
    import Testing

    @testable import Termind

    @MainActor
    struct ScreenshotDemoTests {
        @Test
        func hostsIsTheFirstDemoScene() {
            #expect(ScreenshotDemoConfiguration.Scene.allCases.first == .hosts)
        }

        @Test
        func parsesEverySceneAndLanguageCombination() throws {
            let languages: [(argument: String, language: AppLanguage)] = [
                ("en", .english),
                ("zh", .simplifiedChineseChina),
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
            #expect(throws: ScreenshotDemoConfiguration.ParseError.invalidFormat(
                "--termind-demo"
            )) {
                try ScreenshotDemoConfiguration.parse(arguments: [
                    "Termind", "--termind-demo",
                ])
            }
            #expect(throws: ScreenshotDemoConfiguration.ParseError.invalidFormat(
                "--termind-demo=hosts"
            )) {
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
        func generatedDemoContentFollowsExplicitLanguage() throws {
            let englishHosts = HostLibraryModel.demo(language: .english)
            let chineseHosts = HostLibraryModel.demo(language: .simplifiedChineseChina)
            #expect(englishHosts.rootGroups.first?.name == "Production")
            #expect(chineseHosts.rootGroups.first?.name == "生产环境")

            let englishConversation = ConversationModel.demo(language: .english)
            let chineseConversation = ConversationModel.demo(
                language: .simplifiedChineseChina
            )
            #expect(englishConversation.customTitle == "Diagnose 502 responses")
            #expect(chineseConversation.customTitle == "诊断 502 响应")
            #expect(try #require(englishConversation.messages.first).text.hasPrefix("Find"))
            #expect(try #require(chineseConversation.messages.first).text.hasPrefix("查明"))
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
