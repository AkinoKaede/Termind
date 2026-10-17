import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileLocalDiscoveryRenderingTests {
    @Test(arguments: [HostTerminalProtocol.ssh, .telnet, .mosh, .eternalTerminal], [false, true])
    func connectionActionsRespectProtocolAndManagedHosts(
        connectionProtocol: HostTerminalProtocol, managed: Bool
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        var host = TermindDomain.Host(name: "Example", host: "192.168.1.24")
        if managed { host.tailscale = .init(groupID: UUID(), stableNodeID: "preview") }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(
            rootView: NavigationStack {
                Form {
                    HostConnectionFields(host: .constant(host), protocol: connectionProtocol, discover: {})
                    HostWakeOnLANSection(
                        preferences: .constant(.init()), fetchMAC: {})
                }
                .navigationTitle(AppStrings.Vault.addHost.swiftUIKey)
            }
            .environment(\.locale, Locale(identifier: "en")))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))
        let labels = accessibilityLabels(in: window)
        let discovery = AppLocalization.resolve(AppStrings.LocalNetwork.discovery, locale: Locale(identifier: "en"))
        let fetchMAC = AppLocalization.resolve(AppStrings.LocalNetwork.fetchMAC, locale: Locale(identifier: "en"))
        let supportsDiscovery = !managed && [.ssh, .telnet].contains(connectionProtocol)
        #expect(labels.contains { $0.contains(discovery) } == supportsDiscovery)
        #expect(labels.contains { $0.contains(fetchMAC) })
        if !managed, connectionProtocol == .ssh {
            let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(data, named: "iphone-connection-actions.png")
        }
    }

    @Test(arguments: ["en", "zh-Hans"])
    func discoveredHostsUseTheNativeSheet(language: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let service = PreviewDiscovery()
        let model = LocalDiscoveryModel(service: service)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(
            rootView: DiscoverySheetPreview(model: model)
                .environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            model.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for _ in 0..<100 {
            if model.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.phase == .finished)
        #expect(model.hosts.contains { $0.source == .bonjour })
        #expect(model.hosts.contains { $0.source == .probe })
        #expect(service.scanCount == 1)
        try #require(controller.presentedViewController != nil)
        model.scan()
        for _ in 0..<100 {
            if model.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.phase == .finished)
        #expect(service.scanCount == 2)
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        let labels = accessibilityLabels(in: window)
        for text in ["Mac mini", "mac-mini.local:22", "192.168.1.24:22", "Raspberry Pi", "raspberrypi.local:22"] {
            #expect(labels.contains { $0.contains(text) })
        }
        for resource in [
            AppStrings.LocalNetwork.discovery, AppStrings.LocalNetwork.rescan, AppStrings.Common.cancel,
        ] {
            let title = AppLocalization.resolve(resource, locale: Locale(identifier: language))
            #expect(labels.contains { $0.contains(title) })
        }
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let name = "iphone-\(language)-discovery.png"
        Attachment.record(data, named: name)
        let directory = FileManager.default.temporaryDirectory.appending(path: "local-discovery-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: name)
        try data.write(to: output)
        print("Local discovery screenshot: \(output.path)")
    }

    @Test(arguments: ["en", "zh-Hans"])
    func macLookupUsesCompactDismissalWithoutDescription(language: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let library = HostLibraryModel()
        let model = HostMACAddressModel(
            host: .init(name: "Example", host: "preview.invalid"), library: library, resolver: PreviewMACResolver())
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: MACLookupSheetPreview(model: model, library: library)
                .environment(\.locale, Locale(identifier: language)))
        window.makeKeyAndVisible()
        defer {
            model.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for _ in 0..<100 {
            if model.authenticationPrompt != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.authenticationPrompt != nil)
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        let labels = accessibilityLabels(in: window)
        let locale = Locale(identifier: language)
        let title = AppLocalization.resolve(AppStrings.LocalNetwork.fetchMAC, locale: locale)
        let cancel = AppLocalization.resolve(AppStrings.Common.cancel, locale: locale)
        #expect(labels.contains { $0.contains(title) })
        #expect(labels.contains { $0.contains(cancel) })
        for description in [
            "Authentication and host-key approval are used only for this lookup. The host draft is not saved.",
            "身份验证和主机密钥确认仅用于此次查询，不会保存主机草稿。",
        ] {
            #expect(!labels.contains { $0.contains(description) })
        }
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(data, named: "iphone-\(language)-mac-lookup.png")
    }

    private struct MACLookupSheetPreview: View {
        let model: HostMACAddressModel
        let library: HostLibraryModel
        @State private var presented = false

        var body: some View {
            Color(uiColor: .systemGroupedBackground)
                .sheet(isPresented: $presented) {
                    MobileHostMACAddressView(model: model, library: library, select: { _ in })
                }
                .onAppear { presented = true }
        }
    }

    private struct DiscoverySheetPreview: View {
        let model: LocalDiscoveryModel
        @State private var presented = false

        var body: some View {
            Color(uiColor: .systemGroupedBackground)
                .sheet(isPresented: $presented) {
                    MobileLocalDiscoveryView(model: model, select: { _ in })
                }
                .onAppear { presented = true }
        }
    }

    private func accessibilityLabels(in root: NSObject) -> [String] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject) -> [String] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            var children: [NSObject] = (element as? UIView)?.subviews ?? []
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children += (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
            }
            return [element.accessibilityLabel].compactMap { $0 } + children.flatMap(visit)
        }
        return visit(root)
    }
}

private struct PreviewMACResolver: HostMACAddressResolving {
    func resolve(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws
        -> [HostMACAddressCandidate]
    {
        []
    }
}

@MainActor
private final class PreviewDiscovery: LocalHostDiscovering {
    let connectionProtocol = LocalDiscoveryProtocol.ssh
    private(set) var scanCount = 0

    func discover() async throws -> [DiscoveredLocalHost] {
        scanCount += 1
        return [
            .init(name: "Mac mini", address: "mac-mini.local", port: 22, source: .bonjour),
            .init(name: "192.168.1.24", address: "192.168.1.24", port: 22, source: .probe),
            .init(name: "Raspberry Pi", address: "raspberrypi.local", port: 22, source: .bonjour),
        ]
    }
}
