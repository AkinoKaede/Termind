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

    @Test func iPadSidebarOmitsBrandTitle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootSource = try String(
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
        #expect(!rootSource.contains(".navigationTitle(\"Termind\")"))
    }

    @Test func vaultOnlyShowsMetricsWhenTheSidebarDoesNotProvideIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootSource = try String(
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
        let vaultSource = try String(
            contentsOf: root.appending(path: "TFI/Features/Vault/MobileVaultView.swift"), encoding: .utf8)

        #expect(rootSource.contains("NavigationStack { vault }"))
        #expect(rootSource.contains("case .vault: sidebarVault"))
        #expect(rootSource.contains("app: app, open: open, showsMetrics: false"))
        #expect(vaultSource.contains("guard showsMetrics else { return [] }"))
        #expect(vaultSource.contains("if showsMetrics {"))
    }

    @Test func aiSettingsRowsUseDirectDestinationsInsideTheParentStack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Settings/MobileAISettingsView.swift"), encoding: .utf8)
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

    @Test func metricsProcessListRemovesItsAutomaticTopMargin() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/Metrics/MobileMetricsView.swift"), encoding: .utf8)
        let processes = try #require(source.components(separatedBy: "struct MobileMetricsProcessesView").last)

        #expect(processes.contains(".contentMargins(.top, 0, for: .scrollContent)"))
    }

    @Test func connectionFailuresStayInJourneyAndCancellationLeavesTheDetail() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"), encoding: .utf8)
        #expect(!workspace.contains("\"Connection Error\""))
        #expect(workspace.contains("get: { workspace.operationError != nil }"))
        #expect(workspace.contains("cancel: { closeWorkspace(workspace.id) }"))

        let metrics = try String(
            contentsOf: root.appending(path: "TFI/Features/Metrics/MobileMetricsView.swift"), encoding: .utf8)
        #expect(metrics.contains("app.metrics.core.setEnabled(false, for: server)"))
        #expect(metrics.contains("dismiss()"))

        let rootView = try String(
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
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
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
        #expect(workspaceList.contains(".contextMenu {"))
        #expect(
            workspaceList.contains(
                "Button(\"Close\", systemImage: \"xmark\", role: .destructive) { closeWorkspace(workspace.id) }"))

        let toolbar = try String(
            contentsOf: root.appending(path: "TFI/Features/HostChooser/MobileConnectionPicker.swift"), encoding: .utf8)
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
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"),
            encoding: .utf8
        )

        #expect(workspace.contains("Button(\"Generate Command\", systemImage: \"sparkles\")"))
        #expect(workspace.contains(".keyboardShortcut(\"i\", modifiers: .command)"))
        #expect(workspace.contains(".dropDestination(for: URL.self)"))
        #expect(workspace.contains("allowedContentTypes: [.data, .folder]"))
        #expect(workspace.contains("allowsMultipleSelection: true"))
    }

    @Test func knownHostsExposeAlignedCardActionsAndEditing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "TFI/Features/KnownHosts/MobileKnownHostsView.swift"), encoding: .utf8)

        #expect(source.contains("MobileActionCard"))
        #expect(source.contains("symbol: \"touchid\""))
        #expect(source.contains("Button(\"Edit\", systemImage: \"pencil\")"))
        #expect(source.contains("Button(\"Copy Fingerprint\", systemImage: \"doc.on.doc\")"))
        #expect(source.contains("Button(\"Delete\", systemImage: \"trash\", role: .destructive)"))
        #expect(source.contains("MobileKnownHostEditor(app: app, entry: $0)"))
        #expect(source.contains(".relative(presentation: .numeric).locale(locale)"))
        #expect(!source.contains("Fingerprint Mismatch"))
        #expect(!source.contains("title: \"Host key changed\""))
    }

    @Test func mobileListsCardsAndPaywallKeepTheRefinedPresentation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let metrics = try String(
            contentsOf: root.appending(path: "TFI/Features/Metrics/MobileMetricsView.swift"), encoding: .utf8)
        #expect(metrics.contains(".scrollContentBackground(.hidden)"))
        #expect(metrics.contains(".background(Color(uiColor: .systemBackground))"))

        let cards = try String(
            contentsOf: root.appending(path: "TFI/UI/Managed/MobileCards.swift"), encoding: .utf8)
        let actionCard = try #require(cards.components(separatedBy: "struct MobileActionCard").last)
        #expect(actionCard.contains(".mobileCardSurface()"))
        #expect(actionCard.contains(".contextMenu {"))
        #expect(cards.contains(".contentShape([.interaction, .contextMenuPreview], shape)"))
        #expect(cards.contains(".containerShape("))
        #expect(!cards.contains(".contentShape(.rect)"))
        #expect(cards.contains("} preview: {\n                    cardSurface"))
        #expect(!cards.contains("sourceSize"))
        #expect(!cards.contains(".frame(width: 320"))

        let vault = try String(
            contentsOf: root.appending(path: "TFI/Features/Vault/MobileVaultView.swift"), encoding: .utf8)
        #expect(vault.contains("MobileCardPage {"))
        #expect(!vault.contains("List {"))
        #expect(vault.contains("app.library.setExpanded(!section.isExpanded, for: id)"))
        #expect(vault.contains("app.library.setUngroupedExpanded(!section.isExpanded)"))

        let rootView = try String(
            contentsOf: root.appending(path: "TFI/App/MobileRootView.swift"), encoding: .utf8)
        #expect(rootView.contains("ContentUnavailableView(\n                \"No Workspaces\""))
        #expect(rootView.contains(".buttonStyle(.plain)"))

        let pro = try String(
            contentsOf: root.appending(path: "TFI/Features/Commerce/MobileProView.swift"), encoding: .utf8)
        #expect(!pro.contains("Arrange multiple panes and broadcast input"))
        #expect(!pro.contains(".safeAreaInset(edge: .bottom)"))
        #expect(pro.contains("featureList\n                    purchaseActions"))
    }

    @Test func workspaceCloseActionsStayAtTheBottomOfBothMenus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = try String(
            contentsOf: root.appending(path: "TFI/Features/Workspaces/MobileWorkspaceView.swift"), encoding: .utf8)
        let segments = workspace.components(
            separatedBy: "Button(\"Close\", systemImage: \"xmark\", role: .destructive)")

        #expect(segments.count == 3)
        #expect(segments[0].contains("Button(\"Previous Match\", systemImage: \"chevron.up\")"))
        #expect(segments[1].contains("Button(\"New Folder\", systemImage: \"folder.badge.plus\")"))
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
