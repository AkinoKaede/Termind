import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@Suite
struct ArchitectureBoundaryTests {
    @Test
    func aiSettingsUsePortableModelsAndSyncedSkills() throws {
        let root = sourceRoot.deletingLastPathComponent()
        let library = try String(
            contentsOf: root.appending(path: "Frameworks/TermindApplication/FeatureModels/SkillLibraryModel.swift"),
            encoding: .utf8)
        for forbidden in ["import SwiftData", "import AppKit", "import UIKit", "import TermindPersistence"] {
            #expect(!library.contains(forbidden))
        }
        let role = try String(
            contentsOf: root.appending(path: "Frameworks/TermindPresentation/ModelRoleSettings.swift"), encoding: .utf8)
        #expect(role.contains("role.unsetLabel"))
        #expect(!role.contains("AppModel"))
        let mobile = try String(contentsOf: root.appending(path: "TFI/App/MobileAppModel.swift"), encoding: .utf8)
        #expect(mobile.contains("SyncedSkillLibraryPersistence"))
        #expect(mobile.contains("skills.applyRemoteSnapshot"))
        let settings = try String(
            contentsOf: root.appending(path: "TFI/Features/Settings/MobileAISettingsView.swift"), encoding: .utf8)
        #expect(!settings.contains("AgentRuntime("))
    }

    @Test
    func screenshotScenesShareTheProductionWindowHost() throws {
        let source = try String(contentsOf: sourceRoot.appending(path: "App/TermindApp.swift"), encoding: .utf8)
        #expect(source.components(separatedBy: "RootView(").count == 2)
        #expect(!source.contains("ScreenshotDemoWindow"))
        #expect(!source.contains(".suppressed"))
        #expect(source.contains(".restorationBehavior("))
    }

    @Test
    func reviewInvitationsStayLocalAndOutsideTheAgentRuntime() throws {
        let sync = try String(
            contentsOf: sourceRoot.appending(path: "../Frameworks/TermindDomain/Settings/SettingsSyncTypes.swift"),
            encoding: .utf8
        )
        #expect(!sync.contains("reviewFirstUse"))
        #expect(!sync.contains("reviewLastAttempt"))
        let controller = try String(
            contentsOf: sourceRoot.appending(path: "App/AppReviewController.swift"), encoding: .utf8
        )
        for forbidden in ["import StoreKit", "import AppKit", "import SwiftUI", "import AgentKit"] {
            #expect(!controller.contains(forbidden))
        }
    }

    @Test
    func assistantCompositionIsSharedAndMobileInputRemainsSwiftUI() throws {
        let mobile = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Application/Agent/MobileAssistantModel.swift"),
            encoding: .utf8)
        let desktop = try String(contentsOf: sourceRoot.appending(path: "App/AppModel.swift"), encoding: .utf8)
        for source in [mobile, desktop] {
            #expect(source.contains("AssistantExecutionController("))
            #expect(!source.contains("AgentRuntime("))
        }
        let composer = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/AI/MobileAssistantComposer.swift"), encoding: .utf8)
        #expect(composer.contains("axis: .vertical"))
        #expect(!composer.contains("UITextView"))
        #expect(!composer.contains("UIViewRepresentable"))
        try assertNoImports(
            in: "../Frameworks/TermindApplication/Agent",
            forbidden: ["TermindInfrastructure", "TermindRemoteInfrastructure", "UIKit", "AppKit", "PDFKit", "Speech"])
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TFM", directoryHint: .isDirectory)
    }

    @Test
    func settingsSyncKeepsExecutionHistoryAndLocalPermissionsOutsideItsPayloads() throws {
        let records = try String(
            contentsOf: sourceRoot.appending(path: "../Frameworks/TermindDomain/Settings/SettingsSyncTypes.swift"),
            encoding: .utf8)
        for excluded in ["AgentPermissionMode", "AgentRun", "AgentConversation", "mcpServerPort", "mcpServerEnabled"] {
            #expect(!records.contains(excluded))
        }
        let terminal = try String(
            contentsOf: sourceRoot.appending(
                path: "../Frameworks/TermindPersistence/TerminalPreferences+Defaults.swift"),
            encoding: .utf8)
        #expect(!terminal.contains("dictionaryRepresentation"))
        #expect(!terminal.contains("agentPermissionMode"))
    }

    @Test
    func metricsViewsCannotOwnTransportsAndSecretsAreResolvedOffMainActor() throws {
        try assertNoConcreteImplementations(in: "Features/Metrics")
        let model = try String(
            contentsOf: sourceRoot.appending(path: "../Frameworks/TermindApplication/Metrics/ServerMetricsModel.swift"),
            encoding: .utf8)
        #expect(!model.contains("hosts.sshConnectionConfiguration("))
        let preparation = try String(
            contentsOf: sourceRoot.appending(
                path: "../Frameworks/TermindApplication/Connections/SSHConnectionPreparation.swift"),
            encoding: .utf8)
        #expect(preparation.contains("Task.detached"))
        let view = try String(
            contentsOf: sourceRoot.appending(path: "Features/Metrics/MetricsView.swift"), encoding: .utf8)
        #expect(!view.contains("SSHExecSession"))
        #expect(!view.contains("KeychainSecretStore"))
    }

    @Test
    func metricsToolDependsOnSnapshotsAndMonitoringDoesNotImportAgentKit() throws {
        let tool = try String(
            contentsOf: sourceRoot.appending(
                path: "../Frameworks/TermindRemoteInfrastructure/Agent/GetMetricsTool.swift"), encoding: .utf8)
        #expect(tool.contains("any MetricsSnapshotReading"))
        for forbidden in [
            "SSHMetricsSampler", "AgentConnectionPool", "ServerMetricsModel", "observeDetails(",
            "requestAuthentication(",
        ] {
            #expect(!tool.contains(forbidden))
        }
        for path in [
            "../Frameworks/TermindApplication/Metrics/MetricsSnapshot.swift",
            "../Frameworks/TermindApplication/Metrics/ServerMetricsModel.swift",
        ] {
            let source = try String(contentsOf: sourceRoot.appending(path: path), encoding: .utf8)
            #expect(!source.contains("import AgentKit"))
        }
    }

    @Test
    func coreDirectoryIsGone() {
        let core = sourceRoot.appending(path: "Core", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: core.path))
    }

    @Test
    func retiredFeatureDirectoriesAreGone() {
        for directory in ["Tabs", "ContextPanel"] {
            let url = sourceRoot.appending(path: "Features/\(directory)", directoryHint: .isDirectory)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func appTargetsDoNotReintroduceFrameworkForwardingAliases() throws {
        let forwarding = try Regex(
            #"(?m)^typealias\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:Termind|Shared)[A-Za-z0-9_.]*"#
        )
        for directory in ["", "../TFI"] {
            for file in try swiftFiles(in: directory) {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(
                    source.firstMatch(of: forwarding) == nil,
                    "\(file.path) forwards a framework type instead of importing its owner"
                )
            }
        }

        for file in try swiftFiles(in: "../Frameworks/TermindPersistence") {
            #expect(!file.lastPathComponent.hasPrefix("Shared"))
        }

        let sharedDeclaration = try Regex(
            #"(?m)^public\s+(?:nonisolated\s+)?(?:final\s+)?(?:struct|class|enum|actor|protocol|typealias)\s+Shared[A-Z]"#
        )
        for module in [
            "TermindDomain", "TermindApplication", "TermindInfrastructure",
            "TermindRemoteInfrastructure", "TermindPresentation", "TermindPersistence",
        ] {
            for file in try swiftFiles(in: "../Frameworks/\(module)") {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(
                    source.firstMatch(of: sharedDeclaration) == nil,
                    "\(file.path) uses Shared as a framework namespace"
                )
            }
        }
    }

    @Test
    func mobileTargetUsesTheDesktopLayerVocabulary() throws {
        let mobile = sourceRoot.appending(path: "../TFI", directoryHint: .isDirectory)
        for name in [
            "App", "Application", "Design", "DesignSystem", "Features", "Infrastructure", "Platform", "UI",
        ] {
            let directory = mobile.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            #expect(!(try swiftFiles(in: "../TFI/\(name)")).isEmpty)
        }

        try assertNoImports(
            in: "../TFI/Application",
            forbidden: ["SwiftUI", "UIKit", "SwiftData", "TermindPersistence"])
        try assertNoImports(
            in: "../TFI/UI",
            forbidden: ["SwiftData", "TermindPersistence", "TermindRemoteInfrastructure"])
        try assertNoConcreteImplementations(in: "../TFI/Features")
    }

    @Test
    func sessionFeaturesDependOnTheConnectionPort() throws {
        for path in ["Features/Terminal/SSHSessionModel.swift", "Features/SFTP/SFTPSessionModel.swift"] {
            let text = try String(
                contentsOf: sourceRoot.appending(path: path), encoding: .utf8
            )
            #expect(!text.contains("HostLibraryModel"), "\(path) bypasses RemoteSessionHostStore")
        }
    }

    @Test
    func remoteDirectoryStateDependsOnTheApplicationPort() throws {
        let value = try String(
            contentsOf: sourceRoot.appending(path: "../Frameworks/TermindDomain/Transfers/RemoteFile.swift"),
            encoding: .utf8
        )
        #expect(value.contains("struct RemoteFile"))
        #expect(!value.contains("symbol:"))
        #expect(!value.contains("sftpKindDescription"))

        let transport = try String(
            contentsOf: sourceRoot.appending(
                path: "../Frameworks/TermindRemoteInfrastructure/SSH/SFTPClient.swift"),
            encoding: .utf8
        )
        #expect(transport.contains("SFTPClientProtocol: RemoteFileSystem"))
        #expect(!transport.contains("struct RemoteFile"))

        let mobile = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Application/Transfers/MobileSFTPSessionModel.swift"),
            encoding: .utf8
        )
        #expect(mobile.contains("any RemoteFileSystem"))
        #expect(!mobile.contains("TermindRemoteInfrastructure"))

        let workspace = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Workspaces/MobileWorkspace.swift"),
            encoding: .utf8
        )
        #expect(!workspace.contains("private(set) var files: [RemoteFile]"))
        #expect(!workspace.contains("var path = \"/\""))
    }

    @Test
    func terminalPresentationPolicyIsSharedAcrossApps() throws {
        let presentation = try String(
            contentsOf: sourceRoot.appending(
                path: "../Frameworks/TermindPresentation/Terminal/TerminalAppearance.swift"),
            encoding: .utf8
        )
        #expect(presentation.contains("enum TermindTerminalThemeCatalog"))
        #expect(presentation.contains("func applyPreferences"))
        #expect(
            !FileManager.default.fileExists(
                atPath: sourceRoot.appending(path: "../TFI/Platform/MobileTerminalAppearance.swift").path
            )
        )

        let desktopTheme = try String(
            contentsOf: sourceRoot.appending(path: "Design/TerminalTheme.swift"), encoding: .utf8)
        #expect(!desktopTheme.contains("enum TermindTerminalThemeCatalog"))
        #expect(!desktopTheme.contains("func applyAppearance"))

        for path in [
            "Features/Terminal/SSHSessionModel.swift",
            "Features/Terminal/SerialSessionModel.swift",
            "../TFI/Features/Workspaces/MobileWorkspace.swift",
        ] {
            let source = try String(contentsOf: sourceRoot.appending(path: path), encoding: .utf8)
            #expect(source.contains("TerminalFindController("), "\(path) does not use shared Find state")
            #expect(!source.contains("var findQuery ="), "\(path) owns a second Find query")
        }

        for path in [
            "UI/Components/ConnectionJourneyView.swift",
            "../TFI/UI/Components/MobileConnectionJourneyView.swift",
        ] {
            let source = try String(contentsOf: sourceRoot.appending(path: path), encoding: .utf8)
            #expect(source.contains("ConnectionJourneyHeader("))
            #expect(source.contains("ConnectionJourneyReconnectStatus("))
            #expect(!source.contains("private var headerSymbol"))
        }
    }

    @Test
    func retiredContextPanelTypesAreGone() throws {
        for file in try swiftFiles(in: "Features") {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("ContextPanel"), "\(file.path) retains retired ContextPanel naming")
        }
    }

    @Test
    func customKeyboardShortcutsUseTheApplicationRegistry() throws {
        for file in try swiftFiles(in: "")
        where file.lastPathComponent != "AppShortcut.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() where line.contains(".keyboardShortcut(") {
                let isStandardDialogAction =
                    line.contains(".defaultAction")
                    || line.contains(".cancelAction")
                #expect(
                    isStandardDialogAction,
                    "\(file.path):\(offset + 1) bypasses AppShortcut"
                )
            }
        }
    }

    @Test
    func featureFacadesDoNotExposeTheirBackingLibrary() throws {
        for file in try swiftFiles(in: "../Frameworks/TermindApplication/FeatureModels") {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !text.contains("\n    let library: HostLibraryModel"),
                "\(file.path) exposes the backing aggregate"
            )
        }
    }

    @Test
    func domainImportsOnlyPlatformIndependentFrameworks() throws {
        try assertNoImports(
            in: "../Frameworks/TermindDomain",
            forbidden: [
                "SwiftUI", "AppKit", "UIKit", "SwiftData", "Security", "Network", "StoreKit", "CloudKit",
                "CSSH2", "OpenSSL", "GhosttyTerminal", "GhosttyTheme",
            ]
        )
    }

    @Test
    func applicationDoesNotImportImplementationFrameworks() throws {
        try assertNoImports(
            in: "Application",
            forbidden: [
                "SwiftUI", "AppKit", "UIKit", "SwiftData", "Security", "Network",
                "CSSH2", "OpenSSL", "GhosttyTerminal", "GhosttyTheme",
            ]
        )
        try assertNoConcreteImplementations(in: "Application")
        try assertNoConcreteImplementations(in: "../Frameworks/TermindApplication")
    }

    @Test
    func featuresDoNotAccessPersistenceOrTransportsDirectly() throws {
        try assertNoImports(
            in: "Features",
            forbidden: ["SwiftData", "Security", "Network", "CSSH2", "OpenSSL"]
        )
        try assertNoConcreteImplementations(in: "Features")
    }

    @Test
    func listViewKitIsLimitedToNativeListWorkloads() throws {
        let allowed: Set<String> = [
            "TFI/UI/Components/MobileNativeList.swift",
            "TFM/Features/AI/TranscriptListView.swift",
            "TFM/Features/AI/TranscriptNativeRows.swift",
            "TFM/Features/Assistant/AssistantView.swift",
            "TFM/Features/SFTP/SFTPBrowserView.swift",
            "TFM/Features/Sidebar/WindowSidebarView.swift",
            "TFM/UI/Components/HostingListRow.swift",
        ]
        let repositoryRoot = sourceRoot.deletingLastPathComponent().standardizedFileURL
        let productionFiles = try ["", "../TFI", "../Frameworks", "../TermindMCPBridge"].flatMap {
            try swiftFiles(in: $0)
        }
        let importers = try Set(
            productionFiles.compactMap { file -> String? in
                let text = try String(contentsOf: file, encoding: .utf8)
                guard text.split(separator: "\n").contains("import ListViewKit") else {
                    return nil
                }
                return file.standardizedFileURL.path.replacingOccurrences(
                    of: repositoryRoot.path + "/", with: "")
            }
        )

        #expect(importers == allowed)

        let mobileConsumers = try Set(
            swiftFiles(in: "../TFI").compactMap { file -> String? in
                let text = try String(contentsOf: file, encoding: .utf8)
                guard text.contains("MobileNativeList(") else { return nil }
                return file.standardizedFileURL.path.replacingOccurrences(
                    of: repositoryRoot.path + "/", with: "")
            }
        )
        #expect(
            mobileConsumers == [
                "TFI/Features/Terminal/MobileCommandHistoryView.swift",
                "TFI/Features/Terminal/MobileTerminalSnippetsView.swift",
            ])
    }

    private func assertNoImports(in directory: String, forbidden: Set<String>) throws {
        for file in try swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for framework in forbidden {
                #expect(
                    !text.split(separator: "\n").contains("import \(framework)"),
                    "\(file.path) imports forbidden framework \(framework)"
                )
            }
        }
    }

    private func assertNoConcreteImplementations(in directory: String) throws {
        let forbidden = [
            "ModelContext", "FetchDescriptor", "KeychainSecretStore",
            "SFTPClient()", "SSHExecSession()", "URLSession(",
        ]
        for file in try swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for symbol in forbidden {
                #expect(
                    !containsToken(symbol, in: text),
                    "\(file.path) constructs or accesses infrastructure symbol \(symbol)"
                )
            }
        }
    }

    private func containsToken(_ token: String, in text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let code = line.split(separator: "//", maxSplits: 1).first ?? line[...]
            if token.allSatisfy({ $0.isLetter }) {
                return code.range(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: token))\\b",
                    options: .regularExpression
                ) != nil
            }
            return code.contains(token)
        }
    }

    /// The agent runtime lives in AgentKit and must keep living there.
    ///
    /// A redefinition here would compile: Swift resolves the app's own type
    /// ahead of an imported one, so the app would silently fork the runtime and
    /// nothing would fail until a card drawn by one was replayed by the other.
    /// Checked by definition rather than by import, because the app is expected
    /// to import AgentKit everywhere.
    @Test
    func typesOwnedByTheAgentPackageAreNotRedefinedHere() throws {
        let owned = [
            "AgentRuntime", "AgentToolExecutor", "AgentToolScheduler", "AgentTurnDriver",
            "AgentToolCatalog", "AgentToolRegistry", "AgentEventChannel", "AgentContextPipeline",
            "AgentSecretLifecycle", "AgentApprovalBroker", "SecretBroker", "AgentProviderClient",
            "MCPClient", "MCPServer", "ModelProvider", "AIModel", "AgentSkill",
        ]
        let declaration = try Regex(
            #"(?m)^\s*(?:public |internal |private |fileprivate |nonisolated |final |indirect )*"#
                + #"(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        )
        for file in try swiftFiles(in: "") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: declaration) {
                let name = String(match.output[1].substring ?? "")
                #expect(
                    !owned.contains(name),
                    "\(file.path) redefines \(name), which AgentKit owns"
                )
            }
        }
    }

    @Test
    func mobileNavigationAndMetricsShareTheDesktopDesign() throws {
        let root = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/App/MobileRootView.swift"), encoding: .utf8)
        #expect(!root.contains("Welcome"))
        #expect(root.contains("Label(\"Transfers\", systemImage: \"arrow.up.arrow.down\")"))
        let vault = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Vault/MobileVaultView.swift"), encoding: .utf8)
        let navigation = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Shell/MobileNavigation.swift"), encoding: .utf8)
        #expect(navigation.contains("case vault, metrics, workspaces, assistant, settings"))
        #expect(!vault.contains("Label(\"Port Forwarding\", systemImage:"))
        #expect(vault.contains("open(host.id, .ssh)"))
        let cards = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/UI/Managed/MobileCards.swift"), encoding: .utf8)
        #expect(vault.contains("MobileActionCard {"))
        #expect(cards.contains(".contextMenu {"))
        #expect(cards.contains("actions"))
        #expect(!vault.contains("Import SSH Files"))
        let keys = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Keychain/MobileCredentialsView.swift"),
            encoding: .utf8)
        #expect(!keys.contains("draft.notes"))
        let settings = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Settings/MobileSettingsView.swift"), encoding: .utf8
        )
        #expect(settings.contains("Label(\"App\", systemImage: \"app.badge\")"))
        #expect(settings.contains("Label(\"Sync\", systemImage: \"icloud\")"))
        #expect(!settings.contains("Live Activities"))
        let mobile = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Application/Metrics/MobileMetricsModel.swift"),
            encoding: .utf8)
        #expect(mobile.contains("ServerMetricsModel("))
        #expect(!mobile.contains("while !Task.isCancelled"))
        let workspace = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Workspaces/MobileWorkspaceView.swift"),
            encoding: .utf8)
        #expect(workspace.contains(".toolbarTitleMenu"))
        #expect(!workspace.contains("connectionMenuAction"))
        #expect(workspace.contains("let closeWorkspace: (UUID) -> Void"))
        #expect(workspace.contains("closeWorkspace(workspace.id)"))
        #expect(workspace.contains("MobileOverflowMenuLabel(\"More\")"))
        #expect(workspace.contains("Button(\"Generate Command\", systemImage: \"sparkles\")"))
        let snippets = try #require(workspace.range(of: "Button(\"Snippets\", systemImage: \"curlybraces\")"))
        let history = try #require(workspace.range(of: "Button(\"History\", systemImage: \"clock\")"))
        let historyDivider = try #require(workspace[history.upperBound...].range(of: "Divider()"))
        let nextMatch = try #require(workspace.range(of: "Button(\"Next Match\", systemImage: \"chevron.down\")"))
        #expect(snippets.lowerBound < history.lowerBound)
        #expect(history.lowerBound < historyDivider.lowerBound)
        #expect(historyDivider.lowerBound < nextMatch.lowerBound)
        #expect(workspace.contains(".dropDestination(for: URL.self)"))
        #expect(workspace.contains(".toolbar(.hidden, for: .tabBar)"))
        #expect(workspace.contains("guard let text = UIPasteboard.general.string else { return }"))
        #expect(workspace.contains("workspace.insertTerminalText(text)"))
        #expect(root.contains("private func closeWorkspace(_ id: UUID)"))
        #expect(!workspace.contains("Circle().fill(workspace.connected"))
        let keyboard = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Terminal/MobileTerminalKeyboard.swift"),
            encoding: .utf8)
        #expect(keyboard.contains("ScrollView(.horizontal"))
        let pasteButton = try #require(keyboard.range(of: "pasteButton"))
        let keyboardToggle = try #require(keyboard.range(of: "keyboardToggle"))
        #expect(pasteButton.lowerBound < keyboardToggle.lowerBound)
        #expect(keyboard.contains("Button(action: paste)"))
        #expect(keyboard.contains("Label(\"Paste\", systemImage: \"doc.on.clipboard\")"))
        #expect(keyboard.contains(".padding(.horizontal, 8)"))
        #expect(keyboard.contains("static let barHeight: CGFloat = 44"))
        #expect(keyboard.contains(".buttonStyle(.plain)"))
        #expect(!keyboard.contains(".buttonStyle(.bordered)"))
        #expect(keyboard.contains(".frame(width: 44, height: 44)"))
        #expect(keyboard.contains(".frame(height: Self.barHeight)"))
    }

    @Test
    func mobilePortUsesSharedStoresAndSeparateSigningFiles() throws {
        let mobile = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/App/MobileAppModel.swift"), encoding: .utf8)
        #expect(mobile.contains("SyncedAIConfigurationPersistence(settingsPersistence)"))
        #expect(mobile.contains("settingsSync?.didApplyRemote"))
        #expect(mobile.contains("vaultSync?.didApplyRemote"))
        let project = try String(
            contentsOf: sourceRoot.appending(path: "../Termind.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(project.contains("TFI/TFI.entitlements"))
        #expect(project.contains("TFM/TFM.entitlements"))
        #expect(!project.contains("Termind.entitlements"))
        let terminal = try String(
            contentsOf: sourceRoot.appending(path: "../TFI/Features/Settings/MobileTerminalSettingsView.swift"),
            encoding: .utf8)
        #expect(!terminal.contains("remoteWindowTitleInMenuBar"))
        let cloud = try swiftFiles(in: "../Frameworks/TermindInfrastructure/Cloud")
        #expect(cloud.count == 2)
    }

    @Test
    func sharedFrameworksCannotImportPlatformAppsOrUI() throws {
        for module in [
            "TermindDomain", "TermindApplication", "TermindInfrastructure", "TermindRemoteInfrastructure",
            "TermindPersistence",
        ] {
            try assertNoImports(
                in: "../Frameworks/\(module)",
                forbidden: ["Termind", "TermindIOS", "AppKit", "UIKit", "IOKit", "ServiceManagement"])
        }
        try assertNoImports(
            in: "../Frameworks/TermindApplication",
            forbidden: ["TermindInfrastructure", "TermindPersistence", "SwiftData"])
        try assertNoImports(
            in: "../Frameworks/TermindPersistence",
            forbidden: ["TermindInfrastructure", "TermindRemoteInfrastructure"])
    }

    @Test
    func sharedPresentationHasNoPlatformOrStorageDependency() throws {
        try assertNoImports(
            in: "../Frameworks/TermindPresentation",
            forbidden: [
                "Termind", "TermindIOS", "UIKit", "AppKit", "SwiftData", "TermindPersistence",
                "TermindRemoteInfrastructure",
            ])
    }

    @Test
    func swiftDataModelsHaveOneSharedOwner() throws {
        for directory in [
            "", "../TFI", "../Frameworks/TermindDomain", "../Frameworks/TermindApplication",
            "../Frameworks/TermindInfrastructure",
        ] {
            for file in try swiftFiles(in: directory) {
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(
                    source.range(of: #"(?m)^\s*@Model\b"#, options: .regularExpression) == nil,
                    "\(file.path) declares a model outside TermindPersistence")
            }
        }
        let models = try swiftFiles(in: "../Frameworks/TermindPersistence")
        #expect(!models.isEmpty)
    }

    private func swiftFiles(in directory: String) throws -> [URL] {
        let root = sourceRoot.appending(path: directory, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys
            )
        else { throw CocoaError(.fileReadNoSuchFile) }
        let files = enumerator.compactMap { element -> URL? in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
        guard !files.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        return files
    }
}
