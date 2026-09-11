import Foundation
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileNavigationParityTests {
    @Test func vaultReplacesWelcomeAndMetricsRemainsBelowItOnIPad() {
        #expect(MobileTab.allCases == [.vault, .workspaces, .assistant, .settings])
        #expect(MobileDestination.allCases == [.vault, .metrics, .workspaces, .assistant, .settings])
    }

    @Test func aiSettingsUseThreeNativeManagementPages() {
        #expect(MobileAISettingsDestination.allCases == [.models, .skills, .mcp])
    }

    @Test func aiSettingsRowsUseDirectDestinationsInsideTheParentStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileAISettingsView.swift"), encoding: .utf8)
        let index = try #require(source.components(separatedBy: "enum MobileAISettingsDestination").first)
        #expect(index.contains("NavigationLink {"))
        #expect(!index.contains("NavigationLink(value:"))
        #expect(!index.contains("navigationDestination"))
    }

    @Test func metricsUsesAvailableWidthRatherThanDeviceOrientation() {
        #expect(!MobileMetricsDetailPage.showsBothColumns(width: 430))
        #expect(!MobileMetricsDetailPage.showsBothColumns(width: 680))
        #expect(MobileMetricsDetailPage.showsBothColumns(width: 700))
        #expect(MobileMetricsDetailPage.showsBothColumns(width: 1024))
    }

    @Test func connectionFailuresStayInJourneyAndCancellationLeavesTheDetail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileWorkspaceView.swift"), encoding: .utf8)
        #expect(!workspace.contains("\"Connection Error\""))
        #expect(workspace.contains("get: { workspace.operationError != nil }"))
        #expect(workspace.contains("cancel: { closeWorkspace(workspace.id) }"))

        let metrics = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileMetricsView.swift"), encoding: .utf8)
        #expect(metrics.contains("app.metrics.core.setEnabled(false, for: server)"))
        #expect(metrics.contains("dismiss()"))

        let rootView = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileRootView.swift"), encoding: .utf8)
        #expect(rootView.contains("workspace.activateWhenOpened()"))
        let appModel = try String(
            contentsOf: root.appending(path: "TFI/App/MobileAppModel.swift"), encoding: .utf8)
        #expect(appModel.contains("connectsWhenOpened: true"))
        #expect(appModel.contains("workspace.resumeAfterBackground()"))
    }

    @Test func workspaceListOffersLongPressCloseAndKeepsCloseAllInsideMore() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceList = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileRootView.swift"), encoding: .utf8)
        #expect(workspaceList.contains(".contextMenu {"))
        #expect(
            workspaceList.contains(
                "Button(\"Close\", systemImage: \"xmark\", role: .destructive) { closeWorkspace(workspace.id) }"))

        let toolbar = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileConnectionPicker.swift"), encoding: .utf8)
        #expect(toolbar.contains("Menu {"))
        #expect(toolbar.contains("Button(\"Close All Workspaces\""))
        #expect(toolbar.contains("systemImage: \"rectangle.stack.badge.minus\", role: .destructive"))
        #expect(toolbar.contains(".disabled(!hasWorkspaces)"))
        #expect(toolbar.contains("MobileOverflowMenuLabel(\"More\")"))
    }

    @Test func workspaceSupportsCommandGenerationAndBatchUploadEntryPoints() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/MobileWorkspaceView.swift"),
            encoding: .utf8
        )

        #expect(workspace.contains("Button(\"Generate Command\", systemImage: \"sparkles\")"))
        #expect(workspace.contains(".keyboardShortcut(\"i\", modifiers: .command)"))
        #expect(workspace.contains(".dropDestination(for: URL.self)"))
        #expect(workspace.contains("allowedContentTypes: [.data, .folder]"))
        #expect(workspace.contains("allowsMultipleSelection: true"))
    }

    @Test func keyGenerationMatchesDesktopDefaultsAndRequiresMatchingPassphrases() throws {
        let app = try MobileAppModel(inMemory: true)
        let editor = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        #expect(editor.storage == .iCloud)
        #expect(editor.algorithm == .ed25519)
        #expect(editor.curveBits == 256 && editor.rsaBits == 3072)
        #expect(editor.cipher == .aes256 && editor.rounds == 100)
        #expect(editor.resolvedLabel == "Ed25519" && editor.canSave)
        editor.passphrase = "test-only"
        #expect(!editor.canSave)
        editor.confirmation = "test-only"
        #expect(editor.canSave)
        editor.rounds = 0
        #expect(!editor.canSave)
    }

    @Test func certificateFileImportValidatesKeyMatchingAndLeavesDraftUntouchedOnFailure() async throws {
        let app = try MobileAppModel(inMemory: true)
        let first = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let second = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let key = SSHKeyRef(label: "First", publicKey: first.publicKey)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try certificate(publicKey: first.publicKey)
        let file = directory.appending(path: "key-cert.pub")
        try good.write(to: file, atomically: true, encoding: .utf8)
        try await editor.loadCertificateFile(file)
        #expect(editor.certificate == good)
        try certificate(publicKey: second.publicKey).write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: SSHUserCertificateError.keyMismatch) { try await editor.loadCertificateFile(file) }
        #expect(editor.certificate == good)
    }

    private func certificate(publicKey: String) throws -> String {
        let encoded = try #require(publicKey.split(separator: " ").dropFirst().first)
        let blob = try #require(Data(base64Encoded: String(encoded)))
        // Ed25519 authorized keys contain a method string followed by one 32-byte key.
        let key = Data(blob.suffix(32))
        func u32(_ value: UInt32) -> Data {
            var big = value.bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        func u64(_ value: UInt64) -> Data {
            var big = value.bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }
        func field(_ value: Data) -> Data { u32(UInt32(value.count)) + value }
        let method = "ssh-ed25519-cert-v01@openssh.com"
        var certificate = field(Data(method.utf8)) + field(Data("nonce".utf8)) + field(key)
        certificate += u64(42) + u32(1) + field(Data("test".utf8)) + field(Data())
        certificate += u64(0) + u64(UInt64.max)
        for _ in 0..<3 { certificate += field(Data()) }
        certificate += field(Data("ca".utf8)) + field(Data("signature".utf8))
        return "\(method) \(certificate.base64EncodedString())"
    }
}
