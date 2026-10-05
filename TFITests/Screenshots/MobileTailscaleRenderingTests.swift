import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS
@testable import TermindPresentation

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileTailscaleRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func editAndAddressRowsRenderWithoutDuplicateLabels(language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        var group = HostGroup(name: "Production")
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net"))
        app.library.upsert(group)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let rows = NavigationStack {
            Form {
                Section(AppStrings.Tailscale.addresses.swiftUIKey) {
                    TailscaleCopyField(
                        label: AppStrings.Tailscale.magicDNS,
                        value: "production-server-with-a-long-hostname.example.ts.net", copy: { _ in })
                    TailscaleCopyField(
                        label: AppStrings.Tailscale.ipv6,
                        value: "fd7a:115c:a1e0:ab12:1234:5678:abcd:ef01", copy: { _ in })
                }
                TailscalePingSection(
                    pinging: .constant(true), result: .init(milliseconds: 12.4, route: .direct("100.64.0.2:41641")),
                    error: nil, history: [9, 14, 12.4], isAvailable: true)
                Section(AppStrings.Tailscale.details.swiftUIKey) {
                    TailscaleFormRow(label: AppStrings.Tailscale.keyExpiry, symbol: "key") {
                        Text(AppStrings.Settings.disabled)
                    }
                    TailscaleFormRow(label: AppStrings.Tailscale.operatingSystem, symbol: "desktopcomputer") {
                        Text(verbatim: "Linux")
                    }
                }
            }.navigationTitle(AppStrings.Tailscale.title.swiftUIKey)
        }
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        try store.save(
            TailscaleLocalState(
                groupID: group.id, profileID: UUID(),
                peers: [
                    TailscalePeer(
                        stableID: "server", name: "Production", dnsName: "production-server.example.ts.net",
                        online: false, sshHostKeys: ["fixture"],
                        details: TailscalePeerDetails(
                            addresses: ["100.64.0.2", "fd7a:115c:a1e0::1234"], operatingSystem: "Linux"))
                ]))
        let model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in throw TailscaleConfigurationError.unavailable },
            profileStorage: .disabled, hostname: { "iPhone" }, hasAccess: { false })
        model.start()
        let host = try #require(library.hosts.first)
        let peer = TailscalePeerView(model: model, host: host, copy: { _ in })
        let surfaces: [(String, AnyView)] = [
            ("edit", AnyView(MobileHostGroupEditor(app: app, group: group, parentID: nil))),
            ("rows", AnyView(rows)),
            ("peer", AnyView(peer)),
        ]
        for (name, view) in surfaces {
            for largeText in [false, true] {
                let controller = UIHostingController(
                    rootView:
                        view.environment(\.locale, Locale(identifier: language))
                        .dynamicTypeSize(largeText ? .accessibility2 : .large))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                for style in [UIUserInterfaceStyle.light, .dark] {
                    window.overrideUserInterfaceStyle = style
                    controller.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(300))
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let data = try #require(image.pngData())
                    let filename = "tailscale-mobile-\(name)-\(language)-\(style.rawValue)-\(largeText).png"
                    Attachment.record(data, named: filename)
                    try data.write(to: FileManager.default.temporaryDirectory.appending(path: filename))
                }
            }
        }
        await model.shutdown()
    }
}
