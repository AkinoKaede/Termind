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
                        preferences: .constant(.init()), requestAccess: { true }, fetchMAC: {})
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
        #expect(labels.contains { $0.contains("192.168.1.24:22") })
        for resource in [
            AppStrings.LocalNetwork.bonjour, AppStrings.LocalNetwork.advertisedSSH,
            AppStrings.LocalNetwork.verifiedSSH, AppStrings.LocalNetwork.telnetPortOpen,
        ] {
            let unwanted = AppLocalization.resolve(resource, locale: Locale(identifier: language))
            #expect(!labels.contains { $0.contains(unwanted) })
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
