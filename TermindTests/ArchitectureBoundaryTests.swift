import Foundation
import Testing

@Suite
struct ArchitectureBoundaryTests {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Termind", directoryHint: .isDirectory)
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
                let isStandardDialogAction = line.contains(".defaultAction")
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
                "SwiftUI", "AppKit", "UIKit", "SwiftData", "Security", "Network",
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

    private func swiftFiles(in directory: String) throws -> [URL] {
        let root = sourceRoot.appending(path: directory, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys
        ) else { return [] }
        return enumerator.compactMap { element in
            guard let url = element as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}
