import Foundation
import Testing

@Suite
struct ArchitectureBoundaryTests {
    @Test
    func forwardingAndMobileAuthenticationRemainFeatureOwned() throws {
        let controller = try String(
            contentsOf: sourceRoot.appending(
                path: "../Frameworks/TermindRemoteInfrastructure/SSH/PortForwardingController.swift"),
            encoding: .utf8)
        for symbol in ["UserDefaults", "SettingsKey", "SessionReconnectController", "ExternalAuthentication"] {
            #expect(!containsToken(symbol, in: controller))
        }
        for path in ["../TFI/App/MobileAppModel.swift", "../TFI/App/MobileRootView.swift"] {
            let source = try String(contentsOf: sourceRoot.appending(path: path), encoding: .utf8)
            #expect(!containsToken("SSHKeyboardInteractiveQueue", in: source))
            #expect(!containsToken("keyboardAuthentication", in: source))
        }
        for path in ["Features/HostEditor/HostEditorView.swift", "../TFI/Features/HostEditor/MobileHostEditor.swift"] {
            let source = try String(contentsOf: sourceRoot.appending(path: path), encoding: .utf8)
            #expect(!containsToken("PortForwardingRule", in: source))
        }
    }

    @Test
    func mobileLayersKeepUIAndInfrastructureSeparate() throws {
        try assertNoImports(
            in: "../TFI/Application",
            forbidden: ["SwiftUI", "UIKit", "SwiftData", "GRDB", "TermindPersistence"])
        try assertNoImports(
            in: "../TFI/UI",
            forbidden: ["SwiftData", "GRDB", "TermindPersistence", "TermindRemoteInfrastructure"])
        try assertNoConcreteImplementations(in: "../TFI/Features")
    }

    @Test
    func domainImportsOnlyPlatformIndependentFrameworks() throws {
        try assertNoImports(
            in: "../Frameworks/TermindDomain",
            forbidden: [
                "SwiftUI", "AppKit", "UIKit", "SwiftData", "GRDB", "Security", "Network", "StoreKit", "CloudKit",
                "CSSH2", "OpenSSL", "GhosttyTerminal", "GhosttyTheme",
            ]
        )
    }

    @Test
    func applicationDoesNotImportImplementationFrameworks() throws {
        try assertNoImports(
            in: "Application",
            forbidden: [
                "SwiftUI", "AppKit", "UIKit", "SwiftData", "GRDB", "Security", "Network",
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
            forbidden: ["SwiftData", "GRDB", "Security", "Network", "CSSH2", "OpenSSL"]
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

        #expect(importers.isSubset(of: allowed))
    }

    /// App-local types shadow imports, so redefining these would silently fork AgentKit.
    @Test
    func typesOwnedByTheAgentPackageAreNotRedefinedHere() throws {
        let owned = [
            "AgentRuntime", "AgentToolExecutor", "AgentToolScheduler", "AgentTurnDriver",
            "AgentToolCatalog", "AgentToolRegistry", "AgentEventChannel", "AgentContextPipeline",
            "AgentSecretLifecycle", "AgentApprovalBroker", "SecretBroker", "AgentProviderClient",
            "AgentModelRetryPolicy", "AgentModelRetryProgress",
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
                "Termind", "TermindIOS", "UIKit", "AppKit", "SwiftData", "GRDB", "TermindPersistence",
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

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TFM", directoryHint: .isDirectory)
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
