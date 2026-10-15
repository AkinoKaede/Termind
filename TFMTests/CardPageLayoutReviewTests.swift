import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

/// Actual card consumers, not copies of their layouts. Never opens a connection.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_CARD_LAYOUT_REVIEW"] == "1"),
    .serialized)
@MainActor
struct CardPageLayoutReviewTests {
    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans"], [320.0, 800.0])
    func allManagedCardPages(language: String, width: CGFloat) async throws {
        NSApp.unhideWithoutActivation()
        let host = TermindDomain.Host(name: "Production gateway", host: "gateway.production.example.invalid")
        let key = SSHKeyRef(label: "Deployment", algorithm: .ed25519, credentialRef: "review-key")
        let locked = SSHKeyRef(
            label: "Long production private key", algorithm: .rsa, credentialRef: "review-missing",
            storage: .iCloud, keySize: 4096, hasPassphrase: true)
        let package = SnippetPackage(name: "Operations / Production / Database")
        let library = HostLibraryModel(
            hosts: [host], keys: [key, locked],
            identities: [
                Identity(name: "Deployment", username: "deploy", keyID: key.id),
                Identity(name: "Missing key", username: "missing", keyID: UUID()),
                Identity(name: "No secret", username: "unfinished"),
            ],
            snippets: [
                Snippet(title: "Inspect disk usage", body: "df -h"),
                Snippet(
                    title: "Restart production database", body: "sudo systemctl restart postgresql",
                    packageID: package.id),
                Snippet(title: "Remove old database files", body: "rm -rf /var/lib/old-data", packageID: package.id),
            ],
            snippetPackages: [package],
            portForwardings: PortForwardingRule.Kind.allCases.map {
                PortForwardingRule(
                    hostID: host.id, kind: $0, targetHost: "database.production.example.invalid", targetPort: 5432)
            },
            knownHosts: [
                KnownHostEntry(hostname: host.host, algorithm: .ed25519, addedAt: .now.addingTimeInterval(-86_400)),
                KnownHostEntry(
                    hostname: "long-address.internal.production.example.invalid", algorithm: .rsa,
                    addedAt: .now.addingTimeInterval(-604_800)),
            ])
        try library.upsert(key, credential: .software(SSHPrivateKeySecret(privateKey: "rendering-fixture")))
        let app = AppModel(hosts: library)
        defer { app.shutdownForTermination() }
        let navigation = WindowModel()
        navigation.terminalThemeQueries[.light] = "Solarized"
        navigation.terminalThemeQueries[.dark] = "Solarized"
        let server = ServerMetric(selection: MetricsSelection(id: host.id), name: host.name)
        server.isConnecting = false
        server.status = ""
        server.point = MetricsPoint(
            date: .now, cpu: 42, memory: 67, diskRead: 125_000, diskWrite: 8_000,
            networkReceive: 400_000, networkSend: 9_000)

        for scheme in [ColorScheme.light, .dark] {
            let pages: [(String, AnyView)] = [
                (
                    "hosts",
                    AnyView(
                        CardPage {
                            CardGrid {
                                ForEach(0...2, id: \.self) { count in
                                    hostCard(host, tagCount: count)
                                }
                            }
                        })
                ),
                ("known-hosts", AnyView(KnownHostsPageView(state: KnownHostsPageState()))),
                ("keys-identities", AnyView(KeychainPageView())),
                ("port-forwarding", AnyView(PortForwardingPageView(state: PortForwardingPageState()))),
                ("snippets", AnyView(SnippetsPageView())),
                ("metrics", AnyView(CardPage { ServerMetricsCard(server: server, model: app.serverMetrics) })),
                (
                    "themes",
                    AnyView(TerminalThemePage(scheme: scheme == .dark ? .dark : .light, editConfiguration: {}))
                ),
            ]
            for (name, page) in pages {
                let content = page.environment(app).environment(navigation).environment(VaultWorkEditingSession())
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, scheme)
                    .frame(width: width, height: 760)
                let controller = NSHostingController(rootView: content)
                controller.sizingOptions = []
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: width, height: 760),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentViewController = controller
                window.setContentSize(NSSize(width: width, height: 760))
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 760)
                // Native glass needs an unoccluded window, but not keyboard focus.
                window.orderFrontRegardless()
                defer {
                    window.orderOut(nil)
                    window.contentViewController = nil
                    window.close()
                }
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                controller.view.layoutSubtreeIfNeeded()
                #expect(window.contentView?.bounds.size == CGSize(width: width, height: 760))
                window.title = "Termind Card Review | cards-macos-\(name)-\(language)-\(Int(width))-\(scheme)"
                // cacheDisplay omits native glass compositing. A screenshot runner
                // captures this window number with screencapture -l instead.
                print(
                    "TERMIND_CARD_LAYOUT_WINDOW|\(window.windowNumber)|cards-macos-\(name)-\(language)-\(Int(width))-\(scheme)"
                )
                fflush(nil)
                try await Task.sleep(for: .seconds(1))
                #expect(!window.isKeyWindow)
            }
        }
    }

    private func hostCard(_ host: TermindDomain.Host, tagCount: Int) -> some View {
        var host = host
        host.tags = Array(["router", "home"].prefix(tagCount))
        return HostCard(
            host: host, isSelected: false, select: {}, extendSelection: {},
            actionHosts: [host], requestDelete: {})
    }
}
