import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

/// Opt-in coverage of every non-host mobile card consumer, using only in-memory records.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_CARD_LAYOUT_REVIEW"] == "1"),
    .serialized)
@MainActor
struct MobileCardPageLayoutReviewTests {
    @Test(arguments: ["en", "zh-Hans"], [352.0, 800.0])
    func allMobileCardPages(language: String, width: CGFloat) async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Production gateway", host: "gateway.production.example.invalid")
        app.library.upsert(host)
        let key = SSHKeyRef(label: "Deployment", algorithm: .ed25519, credentialRef: "review-key")
        try app.credentials.upsert(key, credential: .software(SSHPrivateKeySecret(privateKey: "rendering-fixture")))
        try app.credentials.upsert(
            SSHKeyRef(
                label: "Long production private key", algorithm: .rsa, credentialRef: "review-missing",
                storage: .iCloud, keySize: 4096, hasPassphrase: true))
        app.library.upsert(Identity(name: "Deployment", username: "deploy", keyID: key.id))
        app.library.upsert(Identity(name: "Missing key", username: "missing", keyID: UUID()))
        app.library.upsert(Identity(name: "No secret", username: "unfinished"))
        #expect(
            app.knownHosts.save(
                KnownHostEntry(
                    hostname: host.host, algorithm: .ed25519, fingerprint: "SHA256:fixture",
                    addedAt: .now.addingTimeInterval(-86_400))))
        #expect(
            app.knownHosts.save(
                KnownHostEntry(
                    hostname: "long-address.internal.production.example.invalid", algorithm: .rsa,
                    fingerprint: "SHA256:fixture-rsa", addedAt: .now.addingTimeInterval(-604_800))))
        let package = SnippetPackage(name: "Operations / Production / Database")
        app.snippets.upsert(package)
        app.snippets.upsert(Snippet(title: "Inspect disk usage", body: "df -h"))
        app.snippets.upsert(
            Snippet(
                title: "Restart production database", body: "sudo systemctl restart postgresql", packageID: package.id))
        app.snippets.upsert(
            Snippet(title: "Remove old database files", body: "rm -rf /var/lib/old-data", packageID: package.id))
        for kind in PortForwardingRule.Kind.allCases {
            try app.forwardingLibrary.save(
                PortForwardingRule(
                    hostID: host.id, kind: kind, targetHost: "database.production.example.invalid", targetPort: 5432))
        }
        for state in [SFTPTransfer.State.running, .completed, .failed("Connection interrupted")] {
            app.library.enqueueSFTPTransfer(
                SFTPTransfer(
                    hostID: host.id, localPath: "/tmp/production-database-backup.tar.gz",
                    remotePath: "/srv/backups/production-database-backup.tar.gz", byteCount: 100_000,
                    transferredBytes: 42_000, state: state))
        }
        _ = app.metrics.add(host.id, pro: true)
        let server = try #require(app.metrics.servers.first)
        app.metrics.core.setEnabled(false, for: server)
        server.isConnecting = false
        server.status = ""
        server.point = MetricsPoint(
            date: .now, cpu: 42, memory: 67, diskRead: 125_000, diskWrite: 8_000,
            networkReceive: 400_000, networkSend: 9_000)
        defer { app.metrics.pause() }

        for scheme in [ColorScheme.light, .dark] {
            let pages: [(String, AnyView)] = [
                ("known-hosts", AnyView(MobileKnownHostsView(app: app))),
                ("keys-identities", AnyView(MobileCredentialsView(app: app))),
                ("port-forwarding", AnyView(MobileForwardingView(app: app))),
                ("snippets", AnyView(MobileSnippetsView(app: app))),
                ("metrics", AnyView(MobileMetricsView(app: app))),
                ("themes", AnyView(MobileTerminalThemeView(model: app.terminalSettings, isDark: scheme == .dark))),
                ("transfers", AnyView(MobileTransfersView(transfers: app.transfers, hosts: app.library))),
            ]
            for (name, page) in pages {
                let image = try await MobileCardLayoutTests().render(
                    page
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, scheme)
                        .preferredColorScheme(scheme)
                        .frame(width: width, height: 900),
                    width: width)
                let png = try #require(UIImage(cgImage: image, scale: 2, orientation: .up).pngData())
                Attachment.record(png, named: "cards-ios-\(name)-\(language)-\(Int(width))-\(scheme).png")
            }
        }
    }
}
