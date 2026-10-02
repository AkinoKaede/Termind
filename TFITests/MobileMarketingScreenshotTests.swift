import AgentKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

/// Opt-in marketing captures. Fixtures are entirely in memory and never open a network connection.
@Suite(.serialized) @MainActor
struct MobileMarketingScreenshotTests {
    private var languages: [String] {
        if let language = ProcessInfo.processInfo.environment["TERMIND_MARKETING_LOCALE"] {
            return [language]
        }
        return ["en", "zh-Hans", "zh-Hant"]
    }

    @Test func renderMarketingScenes() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_MARKETING_SCREENSHOTS"] == "1" else { return }
        let requestedScenes = Set(
            ProcessInfo.processInfo.environment["TERMIND_MARKETING_SCENES"]?
                .split(separator: ",").map(String.init) ?? [])
        func includes(_ scene: String) -> Bool { requestedScenes.isEmpty || requestedScenes.contains(scene) }

        for language in languages {
            let app = try makeApp(language: language)
            if includes("vault") {
                try await capture("vault", language: language) {
                    MarketingVaultScene(app: app)
                }
            }

            if includes("sftp"), UIDevice.current.userInterfaceIdiom == .pad {
                try await captureWorkspace(.sftp, language: language)
            } else if includes("sftp") {
                let sftp = MobileSFTPChannelModel()
                try await sftp.attach(
                    fileSystem: MarketingFileSystem(), path: "/srv/termind/releases/2026.09",
                    connectionGeneration: UUID(), handlesConnectionError: { _ in false }, didChangePath: {})
                try await capture("sftp", language: language) {
                    NavigationStack {
                        MobileSFTPBrowser(
                            channel: sftp, connected: true, open: { _ in }, openWith: { _ in },
                            canImportEditedCopy: { _ in false }, importEditedCopy: { _ in },
                            download: { _ in }, copy: { _ in },
                            paste: {}, rename: { _ in }, editPermissions: { _ in }, delete: { _ in }
                        )
                        .navigationTitle(text(language, "Production files", "生产文件", "正式環境檔案"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            marketingBackButton(language: language)
                            ToolbarItem(placement: .primaryAction) {
                                Menu {
                                    Button("Refresh", systemImage: "arrow.clockwise") {}
                                } label: {
                                    MobileOverflowMenuLabel("Files")
                                }
                            }
                        }
                    }
                }
            }

            if includes("ssh"), UIDevice.current.userInterfaceIdiom == .pad {
                try await captureWorkspace(.ssh, language: language)
            } else if includes("ssh") {
                let terminal = makeTerminal()
                try await capture("ssh", language: language) {
                    NavigationStack { MarketingTerminalScene(terminal: terminal, language: language) }
                }
            }

            if includes("metrics") {
                let metrics = makeMetrics(language: language)
                try await capture("metrics", language: language) {
                    MarketingTabShell(selected: .metrics) {
                        NavigationStack {
                            MarketingMetricsScene(servers: metrics)
                        }
                    }
                }
            }

            if includes("assistant") {
                let assistant = app.assistant.makeSceneModel()
                let conversation = ConversationModel.demo(language: try #require(AppLanguage(rawValue: language)))
                assistant.library.insertAndSelect(conversation)
                try await capture("assistant", language: language) {
                    MarketingTabShell(selected: .assistant) {
                        NavigationStack {
                            MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                        }
                    }
                }
            }
        }
    }

    private func makeApp(
        language: String, connectionServices: MobileWorkspaceConnectionServices = .live
    ) throws -> MobileAppModel {
        let app = try MobileAppModel(inMemory: true, workspaceConnectionServices: connectionServices)
        let production = HostGroup(name: text(language, "Production", "生产环境", "正式環境"))
        let edge = HostGroup(name: text(language, "Edge", "边缘节点", "邊緣節點"))
        app.library.upsert(production)
        app.library.upsert(edge)
        let hosts = [
            Host(
                name: "web-01", host: "web-01.example.invalid", groupID: production.id, tags: ["nginx", "prod"],
                colorTag: .red),
            Host(
                name: "worker-02", host: "worker-02.example.invalid", groupID: production.id, tags: ["jobs"],
                colorTag: .blue),
            Host(
                name: "db-primary", host: "db-primary.example.invalid", groupID: production.id, tags: ["postgres"],
                colorTag: .purple),
            Host(
                name: "cdn-edge-tokyo", host: "cdn-edge-tokyo.example.invalid", groupID: edge.id, tags: ["edge"],
                colorTag: .orange),
            Host(name: "nas", host: "nas.example.invalid", tags: ["zfs"], colorTag: .teal),
            Host(name: "pi-hole", host: "pi-hole.example.invalid", tags: ["dns"], colorTag: .green),
        ]
        for host in hosts { app.library.upsert(host) }
        return app
    }

    private func captureWorkspace(_ kind: ConnectionHistoryEntry.Kind, language: String) async throws {
        let output = terminalOutput
        let services = MobileWorkspaceConnectionServices(
            makePTYChannel: { receive, exit, shellIntegration in
                receive(output)
                return SSHPTYChannel(output: receive, exit: exit, shellIntegration: shellIntegration)
            },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { _, _, _ in MarketingFileSystem() },
            writeSSH: { _, _ in }
        )
        let app = try makeApp(language: language, connectionServices: services)
        defer { app.testWorkspaceSession.closeAll() }
        let identity = Identity(name: "Deploy", username: "deploy")
        try app.library.upsert(identity, passwordUpdate: .replace("marketing-fixture-only"))
        var host = try #require(app.library.hosts.first(where: { $0.name == "web-01" }))
        host.identityID = identity.id
        app.library.upsert(host)
        let id = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: kind))
        let workspace = try #require(app.workspaces.first(where: { $0.id == id }))
        for _ in 0..<200 where !workspace.connected {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(workspace.connected)
        if kind == .sftp {
            #expect(
                app.testWorkspaceSession.renameWorkspace(id, to: text(language, "Production files", "生产文件", "正式環境檔案")))
            try #require(workspace.sftpChannel.files.count == 6)
        }
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectWorkspace(id)
        try await capture(kind == .ssh ? "ssh" : "sftp", language: language) {
            MobileRootView(app: app, scene: scene)
        }
    }

    private func makeTerminal() -> TerminalViewState {
        let backend = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = TerminalViewState(configSource: .none)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(backend), resizeThrottleMilliseconds: 0)
        let surface = MobileTerminalSurface()
        terminal.makePlatformView = { surface.view }
        backend.receive(terminalOutput)
        return terminal
    }

    private var terminalOutput: Data {
        let prompt = "\u{001B}[36mdeploy@web-01\u{001B}[0m \u{001B}[34m/var/log/nginx\u{001B}[0m %"
        let lines = [
            "Last login: Sun Sep 13 14:20:06 from 10.0.0.12",
            "\(prompt) systemctl status nginx --no-pager",
            "● nginx.service — active (running)",
            "   Loaded: loaded (/usr/lib/systemd/system/nginx.service; enabled)",
            "   Active: \u{001B}[32mactive (running)\u{001B}[0m since 13:42:18 UTC",
            "\(prompt) tail -n 4 access.log",
            "10.0.4.18  GET /api/status  200  18ms",
            "10.0.4.24  GET /health      200   3ms",
            "10.0.4.31  GET /assets/app  304   2ms",
            prompt,
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func makeMetrics(language: String) -> [ServerMetric] {
        let names = ["web-01", "worker-02", "db-primary", "cdn-edge-tokyo"]
        let values: [(Double, Double, Double, Double)] = [
            (33, 46, 182_000, 768_000), (18, 32, 24_000, 128_000),
            (86, 78, 2_300_000, 86_000), (13, 22, 16_000, 0),
        ]
        return zip(names, values).map { name, value in
            let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: name)
            server.isConnecting = false
            server.collectionState = .live
            server.status = ""
            server.point = MetricsPoint(
                date: Date(timeIntervalSince1970: 1_789_000_000), cpu: value.0, memory: value.1,
                diskRead: value.2, diskWrite: value.2 / 3, networkReceive: value.3, networkSend: value.3 / 8,
                uptime: 1_576_800, coreCount: 16, load: [3.28, 2.98, 2.73])
            return server
        }
    }

    private func capture<V: View>(
        _ name: String, language: String, @ViewBuilder view: () -> V
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let targetOrientation: UIInterfaceOrientationMask = isPad ? .landscapeLeft : .portrait
        let hasTargetOrientation =
            isPad ? scene.interfaceOrientation == .landscapeLeft : scene.interfaceOrientation == .portrait
        if !hasTargetOrientation {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: targetOrientation)) { error in
                print("Unable to rotate the marketing scene: \(error.localizedDescription)")
            }
            try await Task.sleep(for: .milliseconds(800))
        }
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: view()
                .environment(\.locale, Locale(identifier: language))
                .environment(
                    \.mobileLayout,
                    MobileLayout(sizeClass: scene.traitCollection.horizontalSizeClass == .regular ? .regular : .compact)
                )
                .preferredColorScheme(.light))
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.windowLevel = .normal
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(900))

        if isPad, let tabs = tabController(in: controller) {
            // Keep each scene's navigation presentation independent of restored simulator state.
            tabs.sidebar.isHidden = ["metrics", "ssh", "sftp"].contains(name)
            try await Task.sleep(for: .milliseconds(900))
        }

        if ProcessInfo.processInfo.environment["TERMIND_MARKETING_SYSTEM_CAPTURE"] == "1" {
            try await waitForSystemCapture(name, language: language)
            return
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scene.screen.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())

        let outputDirectory = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appending(path: "marketing-screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let locale = language == "zh-Hans" ? "zh-hans" : language == "zh-Hant" ? "zh-hant" : "en"
        let featureDirectory = outputDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: featureDirectory, withIntermediateDirectories: true)
        let output = featureDirectory.appending(path: "\(device)-\(locale).png")
        try data.write(to: output, options: .atomic)
        print("Marketing snapshot: \(output.path)")
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { tabController(in: $0) }.first
    }

    private func waitForSystemCapture(_ name: String, language: String) async throws {
        let documents = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let control = documents.appending(path: "marketing-capture-control", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let locale = language == "zh-Hans" ? "zh-hans" : language == "zh-Hant" ? "zh-hant" : "en"
        let ready = control.appending(path: "ready")
        let ack = control.appending(path: "ack-\(token)")
        let captureID = try #require(ProcessInfo.processInfo.environment["TERMIND_MARKETING_CAPTURE_ID"])
        try "\(name)\t\(device)\t\(locale)\t\(token)\t\(captureID)\n".write(
            to: ready, atomically: true, encoding: .utf8)

        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: ack.path) {
                try? FileManager.default.removeItem(at: ready)
                try? FileManager.default.removeItem(at: ack)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MarketingCaptureError.systemCaptureTimedOut(name)
    }

    @ToolbarContentBuilder
    private func marketingBackButton(language: String) -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {}) {
                Label(text(language, "Workspaces", "工作区", "工作區"), systemImage: "chevron.left")
            }
        }
    }

    private func text(_ language: String, _ english: String, _ simplified: String, _ traditional: String) -> String {
        switch language {
        case "zh-Hans": simplified
        case "zh-Hant": traditional
        default: english
        }
    }
}

private enum MarketingCaptureError: Error {
    case systemCaptureTimedOut(String)
}

private struct MarketingVaultScene: View {
    let app: MobileAppModel

    var body: some View {
        MarketingTabShell(selected: .vault) {
            NavigationStack {
                MobileVaultView(
                    app: app, editingHost: .constant(nil), activateHost: { _ in },
                    open: { _, _ in }
                )
            }
        }
    }
}

private struct MarketingTabShell<Content: View>: View {
    let selected: MobileDestination
    let content: Content
    private let features = MobileFeatureRegistry.standard()

    init(selected: MobileDestination, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.content = content()
    }

    var body: some View {
        TabView(selection: .constant(selected)) {
            ForEach(features.registrations) { feature in
                Tab(feature.title.swiftUIKey, systemImage: feature.symbol, value: feature.id) {
                    if feature.id == selected {
                        content
                    } else {
                        NavigationStack { Color.clear }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .toolbar(.visible, for: .tabBar)
    }
}

private struct MarketingTerminalScene: View {
    @ObservedObject var terminal: TerminalViewState
    let language: String

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurfaceView(context: terminal)
        }
        .navigationTitle("web-01")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {}) {
                    Label(
                        language == "zh-Hans" ? "工作区" : language == "zh-Hant" ? "工作區" : "Workspaces",
                        systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Generate Command", systemImage: "sparkles") {}
                } label: {
                    MobileOverflowMenuLabel("Terminal")
                }
            }
        }
    }
}

private struct MarketingMetricsScene: View {
    let servers: [ServerMetric]

    var body: some View {
        MobileCardPage {
            MobileCardGrid {
                ForEach(servers) { server in
                    MobileActionCard(action: {}) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(server.name).font(.subheadline.bold()).lineLimit(1)
                            MetricsInstrumentBody(server: server, sleeping: false, layout: .horizontal)
                        }
                    } actions: {
                        Button("Pause", systemImage: "pause") {}
                    }
                }
            }
        }
        .navigationTitle("Metrics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(AppStrings.Common.addHosts, systemImage: "plus") {}.labelStyle(.iconOnly)
            }
        }
    }
}

private actor MarketingFileSystem: SFTPClientProtocol {
    private let files: [RemoteFile] = [
        RemoteFile(
            path: "/srv/termind/releases/2026.09/bin", name: "bin", kind: .directory, size: 0,
            modifiedAt: Date(timeIntervalSince1970: 1_788_900_000), permissions: 0o755, ownerUID: 501, ownerGID: 20),
        RemoteFile(
            path: "/srv/termind/releases/2026.09/config", name: "config", kind: .directory, size: 0,
            modifiedAt: Date(timeIntervalSince1970: 1_788_920_000), permissions: 0o755, ownerUID: 501, ownerGID: 20),
        RemoteFile(
            path: "/srv/termind/releases/2026.09/Termind.app.tar.zst", name: "Termind.app.tar.zst", kind: .file,
            size: 48_392_192, modifiedAt: Date(timeIntervalSince1970: 1_788_940_000), permissions: 0o644, ownerUID: 501,
            ownerGID: 20),
        RemoteFile(
            path: "/srv/termind/releases/2026.09/checksums.txt", name: "checksums.txt", kind: .file, size: 2_048,
            modifiedAt: Date(timeIntervalSince1970: 1_788_940_400), permissions: 0o644, ownerUID: 501, ownerGID: 20),
        RemoteFile(
            path: "/srv/termind/releases/2026.09/release-notes.md", name: "release-notes.md", kind: .file, size: 18_420,
            modifiedAt: Date(timeIntervalSince1970: 1_788_941_000), permissions: 0o644, ownerUID: 501, ownerGID: 20),
        RemoteFile(
            path: "/srv/termind/releases/2026.09/deploy.sh", name: "deploy.sh", kind: .file, size: 6_144,
            modifiedAt: Date(timeIntervalSince1970: 1_788_942_000), permissions: 0o755, ownerUID: 501, ownerGID: 20),
    ]

    func connect(using _: SSHConnectionConfiguration, progress _: SSHRouteProgressHandler?) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/srv/termind/releases/2026.09" }
    func listDirectory(at _: String) async throws -> [RemoteFile] { files }
    func attributes(at _: String) async throws -> RemoteFile? { nil }
    func readFile(at _: String, maximumBytes _: Int) async throws -> Data { Data() }
    func writeFile(_: Data, at _: String, overwrite _: Bool) async throws {}
    func setPermissions(at _: String, to _: UInt32) async throws {}
    func createDirectory(at _: String) async throws {}
    func rename(from _: String, to _: String, overwrite _: Bool) async throws {}
    func removeFile(at _: String) async throws {}
    func removeDirectory(at _: String) async throws {}
    func uploadFile(
        from _: URL, to _: String, overwrite _: Bool, cancellation _: TransferCancellationToken,
        progress _: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
    func downloadFile(
        from _: String, to _: URL, overwrite _: Bool, cancellation _: TransferCancellationToken,
        progress _: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}
