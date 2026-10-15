import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

/// Opt-in native screenshots use only in-memory records and never open a connection.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_CARD_SCREENSHOTS"] != nil),
    .serialized)
@MainActor
struct MobileCardRenderingTests {
    @Test func renderCardsAndTouchPalette() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_CARD_SCREENSHOTS"] != nil else { return }
        let app = try MobileAppModel(inMemory: true)
        let group = HostGroup(name: "Production / 生产环境")
        app.library.upsert(group)
        for (index, color) in [TagColor.teal, .orange, .purple, .none].enumerated() {
            let tags =
                switch index {
                case 0: [String]()
                case 1: ["production"]
                default: ["production", "ap-east", "long-tag-that-must-stay-on-one-line"]
                }
            let host = TermindDomain.Host(
                name: index == 0 ? "Production Gateway — Shanghai / 生产网关" : "Worker \(index)",
                host: "gateway-\(index).production.example.invalid", groupID: group.id,
                tags: tags, colorTag: color,
                detectedDistribution: index == 3 ? DetectedDistribution(id: "alpine") : nil)
            app.library.upsert(host)
            if index == 3 {
                app.connectionHistory.record(
                    kind: .ssh, for: host.id,
                    at: Date.now.addingTimeInterval(-3_600))
            }
            if index == 3 {
                _ = app.knownHosts.save(
                    KnownHostEntry(
                        hostname: host.host, fingerprint: "SHA256:0123456789abcdefghijklmnopqrstuvwxyzABCDE"))
            }
        }
        let editableKnownHost = KnownHostEntry(
            hostname: "known-host.production.example.invalid", algorithm: .rsa,
            fingerprint: "SHA256:editable0123456789abcdefghijklmnopqrstuvwxyz",
            addedAt: .now.addingTimeInterval(-86_400))
        let hashedAddress =
            "|1|" + Data(repeating: 7, count: 20).base64EncodedString()
            + "|" + Data(repeating: 9, count: 20).base64EncodedString()
        let hashedKnownHost = KnownHostEntry(
            hostname: hashedAddress, algorithm: .ecdsa384,
            fingerprint: "SHA256:hashed0123456789abcdefghijklmnopqrstuvwxyz",
            addedAt: .now.addingTimeInterval(-604_800))
        try app.library.commitSSHImport(SSHImportBatch(knownHosts: [editableKnownHost, hashedKnownHost]))
        let key = SSHKeyRef(
            label: "Production Key / 生产密钥", algorithm: .rsa,
            fingerprint: "SHA256:0123456789abcdefghijklmnopqrstuvwxyzABCDE",
            credentialRef: "termind.key.\(UUID())", storage: .thisDevice, keySize: 4096,
            hasPassphrase: true, colorTag: .teal)
        try app.credentials.upsert(
            key, credential: .software(SSHPrivateKeySecret(privateKey: "rendering-fixture")))
        try app.library.upsert(
            Identity(
                name: "Deployment / 部署", username: "deploy", keyID: key.id,
                colorTag: .purple),
            passwordUpdate: .replace("rendering-fixture"))
        _ = app.library.upsert(
            Identity(name: "Missing Key / 密钥缺失", username: "missing", keyID: UUID(), colorTag: .orange))
        _ = app.library.upsert(
            Identity(name: "No Secret / 无凭据", username: "unfinished"))
        try app.credentials.upsert(
            SSHKeyRef(
                label: "Missing Private Key / 私钥缺失", algorithm: .ecdsa384,
                fingerprint: "SHA256:missing", credentialRef: "termind.key.\(UUID())", storage: .iCloud))
        let snippetPackage = SnippetPackage(name: "Operations / 运维")
        app.snippets.upsert(snippetPackage)
        app.snippets.upsert(
            Snippet(
                title: "Inspect disk usage / 检查磁盘", body: "df -h\ndu -sh /var/log",
                packageID: snippetPackage.id))
        app.snippets.upsert(
            Snippet(title: "Remove cache / 清理缓存", body: "rm -rf /tmp/cache", packageID: snippetPackage.id))
        let forwardingHost = try #require(app.library.hosts.first)
        for (index, kind) in [PortForwardingRule.Kind.local, .remote, .dynamic].enumerated() {
            _ = try app.forwardingLibrary.save(
                PortForwardingRule(
                    hostID: forwardingHost.id, kind: kind, bindPort: 8080 + index,
                    label: index == 0 ? "Database / 数据库" : "", colorTag: .teal))
        }
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Production Gateway")
        server.isConnecting = false
        server.status = ""
        server.point = MetricsPoint(
            date: .now, cpu: 42, memory: 67, diskRead: 125_000, diskWrite: 8_000, networkReceive: 400_000,
            networkSend: 9_000,
            networkDevices: [
                MetricsDevicePoint(
                    id: "en0", read: 400_000, write: 9_000, readTotal: 8_000_000, writeTotal: 1_200_000,
                    kind: .hardware, addresses: ["192.0.2.10"]),
                MetricsDevicePoint(
                    id: "utun4", read: 12_000, write: 4_000, readTotal: 900_000, writeTotal: 300_000,
                    kind: .virtual, addresses: ["10.0.0.2"]),
            ])

        for language in ["en", "zh-Hans", "zh-Hant"] {
            for scheme in [ColorScheme.light, .dark] {
                try await capture("vault", language: language, scheme: scheme) {
                    NavigationStack {
                        MobileVaultView(
                            app: app, editingHost: .constant(nil), activateHost: { _ in },
                            open: { _, _ in })
                    }
                }
                try await capture("history", language: language, scheme: scheme) {
                    NavigationStack {
                        MobileConnectionHistoryView(app: app, open: { _, _ in })
                    }
                }
                try await capture("workspaces-recents", language: language, scheme: scheme) {
                    NavigationStack {
                        MobileWorkspaceListView(app: app, scene: MobileSceneModel(app: app, sessionID: "test"))
                    }
                }
                try await capture("snippets", language: language, scheme: scheme) {
                    NavigationStack { MobileSnippetsView(app: app) }
                }
                try await capture("snippets-search", language: language, scheme: scheme) {
                    NavigationStack { MobileSnippetsView(app: app, initialQuery: "Inspect") }
                }
                try await capture("keychain", language: language, scheme: scheme) {
                    NavigationStack { MobileCredentialsView(app: app) }
                }
                try await capture("settings", language: language, scheme: scheme) {
                    NavigationStack { MobileSettingsView(app: app) }
                }
                try await capture("palette", language: language, scheme: scheme) {
                    NavigationStack {
                        Form {
                            Section("Color") { ColorTagPicker(selection: .constant(.teal), layout: .touch) }
                            Section("Color") { ColorTagPicker(selection: .constant(.none), layout: .touch) }
                        }.navigationTitle("Host")
                    }
                }
                try await capture("metrics", language: language, scheme: scheme) {
                    NavigationStack {
                        MobileCardPage {
                            MobileActionCard(action: {}) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(server.name).font(.subheadline.bold()).lineLimit(1)
                                    MetricsInstrumentBody(server: server, sleeping: false)
                                }
                            } actions: {
                                Button("Pause") {}
                            }
                        }.navigationTitle("Metrics")
                    }
                }
                try await capture("metrics-details", language: language, scheme: scheme) {
                    NavigationStack {
                        ScrollView { MetricsSystemPanels(server: server).padding() }
                            .background(Color(uiColor: .systemGroupedBackground))
                            .navigationTitle(server.name)
                    }
                }
                try await capture("known-hosts", language: language, scheme: scheme) {
                    NavigationStack { MobileKnownHostsView(app: app) }
                }
                try await capture("known-host-editor", language: language, scheme: scheme) {
                    MobileKnownHostEditor(app: app, entry: editableKnownHost)
                }
                try await capture("known-host-editor-hashed", language: language, scheme: scheme) {
                    MobileKnownHostEditor(app: app, entry: hashedKnownHost)
                }
                try await capture("vault-compact", language: language, scheme: scheme, compact: true) {
                    NavigationStack {
                        MobileVaultView(
                            app: app, editingHost: .constant(nil), activateHost: { _ in }, open: { _, _ in })
                    }
                }
                try await capture("keychain-compact", language: language, scheme: scheme, compact: true) {
                    NavigationStack { MobileCredentialsView(app: app) }
                }
                try await capture("snippets-compact", language: language, scheme: scheme, compact: true) {
                    NavigationStack { MobileSnippetsView(app: app) }
                }
                try await capture("forwarding-compact", language: language, scheme: scheme, compact: true) {
                    NavigationStack { MobileForwardingView(app: app) }
                }
                try await capture("known-hosts-compact", language: language, scheme: scheme, compact: true) {
                    NavigationStack { MobileKnownHostsView(app: app) }
                }
                try await capture("app-settings-compact", language: language, scheme: scheme, compact: true) {
                    NavigationStack { MobileAppSettingsView(workspaceSettings: app.workspaceSettings) }
                }
            }
            try await capture("large-type", language: language, scheme: .light) {
                NavigationStack {
                    MobileVaultView(
                        app: app, editingHost: .constant(nil), activateHost: { _ in },
                        open: { _, _ in })
                }
                .environment(\.dynamicTypeSize, .accessibility3)
            }
            try await capture("compact-large-type", language: language, scheme: .light, compact: true) {
                NavigationStack { MobileCredentialsView(app: app) }
                    .environment(\.dynamicTypeSize, .accessibility3)
            }
            try await capture("metrics-large-type", language: language, scheme: .light) {
                MobileCardPage {
                    MobileCard { MetricsInstrumentBody(server: server, sleeping: false, layout: .adaptive) }
                }.environment(\.dynamicTypeSize, .accessibility3)
            }
            try await capture("key-editor", language: language, scheme: .light) {
                MobileKeyEditor(
                    model: MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: app.credentials.keys[0])
                )
            }
            try await capture("empty", language: language, scheme: .light) {
                NavigationStack {
                    MobileVaultView(
                        app: try! MobileAppModel(inMemory: true), editingHost: .constant(nil),
                        activateHost: { _ in },
                        open: { _, _ in })
                }
            }
            try await capture("known-hosts-large-type", language: language, scheme: .light) {
                NavigationStack { MobileKnownHostsView(app: app) }
                    .environment(\.dynamicTypeSize, .accessibility3)
            }
        }
    }

    private func capture<V: View>(
        _ name: String, language: String, scheme: ColorScheme, compact: Bool = false, @ViewBuilder view: () -> V
    ) async throws {
        let suiteName = "MobileCardRenderingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(compact, forKey: "mobile.compactCards")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: view().defaultAppStorage(defaults)
                .environment(\.locale, Locale(identifier: language)).preferredColorScheme(scheme))
        window.rootViewController = controller
        if name == "opaque" { controller.traitOverrides.accessibilityContrast = .high }
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let directory = FileManager.default.temporaryDirectory.appending(path: "card-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let appearance = scheme == .dark ? "dark" : "light"
        let output = directory.appending(path: "\(device)-\(language)-\(name)-\(appearance).png")
        try data.write(to: output)
        print("Card snapshot: \(output.path)")
    }
}
