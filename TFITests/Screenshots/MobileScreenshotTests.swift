import AgentKit
import ObjectiveC
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

/// Opt-in screenshots. Fixtures are entirely in memory and never open a network connection.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_SCREENSHOTS"] == "1"),
    .serialized)
@MainActor
struct MobileScreenshotTests {
    private var captureDevice: String {
        ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_DEVICE"]
            ?? (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
    }

    private var languages: [String] {
        if let language = ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_LOCALE"] {
            return [language]
        }
        return ["en", "zh-Hans", "zh-Hant"]
    }

    @Test func renderScenes() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_SCREENSHOTS"] == "1" else { return }
        let requestedScenes = Set(
            ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_SCENES"]?
                .split(separator: ",").map(String.init) ?? [])
        func includes(_ scene: String) -> Bool { requestedScenes.isEmpty || requestedScenes.contains(scene) }

        for language in languages {
            let app = try makeApp(language: language)
            if includes("vault") {
                try await capture("vault", language: language) {
                    ScreenshotVaultScene(app: app)
                }
            }

            if includes("sftp") {
                try await captureWorkspace(.sftp, language: language)
            }

            if includes("ssh") {
                try await withEnglishKeyboard {
                    try await captureWorkspace(.ssh, language: language)
                }
            }

            if includes("metrics") {
                let metrics = makeMetrics(language: language)
                try await capture("metrics", language: language) {
                    ScreenshotTabShell(selected: .metrics) {
                        NavigationStack {
                            ScreenshotMetricsScene(servers: metrics)
                        }
                    }
                }
            }

            if includes("assistant") {
                let assistant = app.assistant.makeSceneModel()
                let conversation = ConversationModel.demo(language: try #require(AppLanguage(rawValue: language)))
                assistant.library.insertAndSelect(conversation)
                try await capture("assistant", language: language) {
                    ScreenshotTabShell(selected: .assistant) {
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
            connectSFTP: { _, _, _ in ScreenshotFileSystem() },
            writeSSH: { _, _ in }
        )
        let app = try makeApp(language: language, connectionServices: services)
        defer { app.testWorkspaceSession.closeAll() }
        let identity = Identity(name: "Deploy", username: "deploy")
        try app.library.upsert(identity, passwordUpdate: .replace("screenshot-fixture-only"))
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
                .environment(\.scenePhase, .active)
        }
    }

    private func withEnglishKeyboard(_ capture: () async throws -> Void) async throws {
        let mode = try #require(UITextInputMode.activeInputModes.first { $0.primaryLanguage?.hasPrefix("en") == true })
        let selector = #selector(getter: UIResponder.textInputMode)
        let method = try #require(class_getInstanceMethod(MobileTerminalView.self, selector))
        let original = method_getImplementation(method)
        let encoding = try #require(method_getTypeEncoding(method))
        let getter: @convention(block) (AnyObject) -> UITextInputMode = { _ in mode }
        let replacement = imp_implementationWithBlock(getter)
        let typeSelector = #selector(getter: UITextField.keyboardType)
        let typeMethod = try #require(class_getInstanceMethod(MobileTerminalView.self, typeSelector))
        let originalType = method_getImplementation(typeMethod)
        let typeEncoding = try #require(method_getTypeEncoding(typeMethod))
        let typeGetter: @convention(block) (AnyObject) -> Int = { _ in UIKeyboardType.asciiCapable.rawValue }
        let typeReplacement = imp_implementationWithBlock(typeGetter)
        // Scope the public input-mode getter override to this opt-in capture.
        // UIKit still renders its real keyboard, independently of the app locale.
        // ASCII mode also excludes the bilingual keyboard's Pinyin/Zhuyin toggle.
        class_replaceMethod(MobileTerminalView.self, selector, replacement, encoding)
        class_replaceMethod(MobileTerminalView.self, typeSelector, typeReplacement, typeEncoding)
        defer {
            class_replaceMethod(MobileTerminalView.self, selector, original, encoding)
            class_replaceMethod(MobileTerminalView.self, typeSelector, originalType, typeEncoding)
            imp_removeBlock(replacement)
            imp_removeBlock(typeReplacement)
        }
        try await capture()
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
        let isLandscape = isPad || captureDevice == "iphone-duo-inner"
        let targetOrientation: UIInterfaceOrientationMask = isLandscape ? .landscapeLeft : .portrait
        let hasTargetOrientation =
            isLandscape ? scene.interfaceOrientation == .landscapeLeft : scene.interfaceOrientation == .portrait
        if !hasTargetOrientation {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: targetOrientation)) { error in
                print("Unable to rotate the screenshot scene: \(error.localizedDescription)")
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

        if name == "sftp" {
            // SFTP captures must include the real app navigation shell, not an isolated browser.
            _ = try #require(tabController(in: controller))
        }

        if isPad, let tabs = tabController(in: controller) {
            // Keep each scene's navigation presentation independent of restored simulator state.
            tabs.sidebar.isHidden = ["metrics", "ssh", "sftp"].contains(name)
            try await Task.sleep(for: .milliseconds(900))
        }

        if name == "ssh" {
            let terminal = try #require(terminalView(in: controller.view))
            let accessory = try #require(terminal.inputAccessoryView)
            for _ in 0..<100 {
                window.layoutIfNeeded()
                if terminal.isFirstResponder, accessory.window != nil,
                    accessory.convert(accessory.bounds, to: window).maxY
                        < window.bounds.maxY - window.safeAreaInsets.bottom
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(terminal.isFirstResponder)
            try #require(terminal.textInputMode?.primaryLanguage?.hasPrefix("en") == true)
            try #require(accessory.window != nil)
            // An accessory-only hardware keyboard bar ends at the bottom safe area.
            // A software keyboard has its key rows below the accessory instead.
            try #require(
                accessory.convert(accessory.bounds, to: window).maxY
                    < window.bounds.maxY - window.safeAreaInsets.bottom)
            try await Task.sleep(for: .milliseconds(300))
        }

        if ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_SYSTEM_CAPTURE"] == "1" {
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
            .appending(path: "screenshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let device = captureDevice
        let locale = language == "zh-Hans" ? "zh-hans" : language == "zh-Hant" ? "zh-hant" : "en"
        let featureDirectory = outputDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: featureDirectory, withIntermediateDirectories: true)
        let output = featureDirectory.appending(path: "\(device)-\(locale).png")
        try data.write(to: output, options: .atomic)
        print("Screenshot: \(output.path)")
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { tabController(in: $0) }.first
    }

    private func terminalView(in view: UIView) -> MobileTerminalView? {
        if let terminal = view as? MobileTerminalView { return terminal }
        return view.subviews.lazy.compactMap { terminalView(in: $0) }.first
    }

    private func waitForSystemCapture(_ name: String, language: String) async throws {
        let documents = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let control = documents.appending(path: "screenshot-capture-control", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let device = captureDevice
        let locale = language == "zh-Hans" ? "zh-hans" : language == "zh-Hant" ? "zh-hant" : "en"
        let ready = control.appending(path: "ready")
        let ack = control.appending(path: "ack-\(token)")
        let captureID = try #require(ProcessInfo.processInfo.environment["TERMIND_SCREENSHOT_CAPTURE_ID"])
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
        throw ScreenshotCaptureError.systemCaptureTimedOut(name)
    }

    @ToolbarContentBuilder
    private func screenshotBackButton(language: String) -> some ToolbarContent {
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

private enum ScreenshotCaptureError: Error {
    case systemCaptureTimedOut(String)
}

private struct ScreenshotVaultScene: View {
    let app: MobileAppModel

    var body: some View {
        ScreenshotTabShell(selected: .vault) {
            NavigationStack {
                MobileVaultView(
                    app: app, editingHost: .constant(nil), activateHost: { _ in },
                    open: { _, _ in }
                )
            }
        }
    }
}

private struct ScreenshotTabShell<Content: View>: View {
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
                            // Use the same adaptive toolbar layout as the app shell.
                            .mobileToolbarEnvironment()
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

private struct ScreenshotMetricsScene: View {
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

private actor ScreenshotFileSystem: SFTPClientProtocol {
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
