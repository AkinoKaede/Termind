import Foundation
import Testing

@Suite
struct ArchitectureBoundaryTests {
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
            contentsOf: sourceRoot.appending(path: "Domain/Settings/SettingsSyncTypes.swift"), encoding: .utf8
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

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Termind", directoryHint: .isDirectory)
    }

    @Test
    func settingsSyncKeepsExecutionHistoryAndLocalPermissionsOutsideItsPayloads() throws {
        let records = try String(
            contentsOf: sourceRoot.appending(path: "Domain/Settings/SettingsSyncTypes.swift"),
            encoding: .utf8)
        for excluded in ["AgentPermissionMode", "AgentRun", "AgentConversation", "mcpServerPort", "mcpServerEnabled"] {
            #expect(!records.contains(excluded))
        }
        let terminal = try String(
            contentsOf: sourceRoot.appending(path: "Infrastructure/Database/PersistentTerminalPreferences.swift"),
            encoding: .utf8)
        #expect(!terminal.contains("dictionaryRepresentation"))
        #expect(!terminal.contains("agentPermissionMode"))
    }

    @Test
    func metricsViewsCannotOwnTransportsAndSecretsAreResolvedOffMainActor() throws {
        try assertNoConcreteImplementations(in: "Features/Metrics")
        let model = try String(
            contentsOf: sourceRoot.appending(path: "Application/Metrics/ServerMetricsModel.swift"), encoding: .utf8)
        #expect(!model.contains("hosts.sshConnectionConfiguration("))
        let preparation = try String(
            contentsOf: sourceRoot.appending(path: "Application/Connections/SSHConnectionPreparation.swift"),
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
            contentsOf: sourceRoot.appending(path: "Application/Agent/GetMetricsTool.swift"), encoding: .utf8)
        #expect(tool.contains("any MetricsSnapshotReading"))
        for forbidden in [
            "SSHMetricsSampler", "AgentConnectionPool", "ServerMetricsModel", "observeDetails(",
            "requestAuthentication(",
        ] {
            #expect(!tool.contains(forbidden))
        }
        for path in ["Application/Metrics/MetricsSnapshot.swift", "Application/Metrics/ServerMetricsModel.swift"] {
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
    func sessionFeaturesDependOnTheConnectionPort() throws {
        for path in ["Features/Terminal/SSHSessionModel.swift", "Features/SFTP/SFTPSessionModel.swift"] {
            let text = try String(
                contentsOf: sourceRoot.appending(path: path), encoding: .utf8
            )
            #expect(!text.contains("HostLibraryModel"), "\(path) bypasses RemoteSessionHostStore")
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
        for file in try swiftFiles(in: "Application/FeatureModels") {
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
            in: "Domain",
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
    }

    @Test
    func featuresDoNotAccessPersistenceOrTransportsDirectly() throws {
        try assertNoImports(
            in: "Features",
            forbidden: ["SwiftData", "Security", "Network", "CSSH2", "OpenSSL"]
        )
        try assertNoConcreteImplementations(in: "Features")
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

    private func swiftFiles(in directory: String) throws -> [URL] {
        let root = sourceRoot.appending(path: directory, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys
            )
        else { return [] }
        return enumerator.compactMap { element in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}
