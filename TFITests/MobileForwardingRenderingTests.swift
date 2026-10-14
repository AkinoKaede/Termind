import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileForwardingRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func forwardingUsesVaultCardsAndInPageAuthenticationWithoutASheet(_ language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Production", host: "server.example.invalid")
        app.library.upsert(host)
        let rule = PortForwardingRule(hostID: host.id, label: "Database", colorTag: .teal)
        let unnamed = PortForwardingRule(hostID: host.id, bindPort: 15432)
        for candidate in [
            rule,
            PortForwardingRule(hostID: host.id, kind: .remote, bindPort: 9090, label: "Preview", colorTag: .orange),
            PortForwardingRule(hostID: host.id, kind: .dynamic, bindPort: 1080, label: "SOCKS5"),
            unnamed,
        ] {
            try app.forwardingLibrary.save(candidate)
        }
        let route = ForwardingRenderRoute()
        var features = MobileFeatureRegistry()
        features.register(
            MobileFeatureRegistration(id: .vault, title: "Vault", symbol: "server.rack") { app, scene in
                AnyView(
                    MobileForwardingView(app: app)
                        .navigationDestination(
                            isPresented: Binding(get: { route.details }, set: { route.details = $0 })
                        ) {
                            MobileForwardingDetailView(app: app, ruleID: route.unnamed ? unnamed.id : rule.id)
                        }
                        .sheet(isPresented: Binding(get: { route.editing }, set: { route.editing = $0 })) {
                            MobileForwardingEditor(app: app, rule: rule, isNew: false)
                        })
            })
        let scene = MobileSceneModel(app: app, sessionID: "test")
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        let container = UIViewController()
        let controller = UIHostingController(
            rootView: MobileRootView(app: app, scene: scene, features: features)
                .environment(\.locale, Locale(identifier: language)).environment(\.scenePhase, .active))
        container.addChild(controller)
        container.view.addSubview(controller.view)
        controller.didMove(toParent: container)
        window.rootViewController = container
        window.windowLevel = .alert + 3
        window.makeKeyAndVisible()
        defer {
            app.forwardings.stopAll()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        resize(controller, width: 430, height: 900)
        try await Task.sleep(for: .milliseconds(300))
        try capture(controller.view, name: "cards-\(language)")
        route.editing = true
        try await Task.sleep(for: .milliseconds(650))
        try capture(try #require(presented(in: controller)?.view), name: "editor-\(language)")
        route.editing = false
        try await Task.sleep(for: .milliseconds(650))
        route.details = true
        try await Task.sleep(for: .milliseconds(650))
        try capture(controller.view, name: "detail-stopped-\(language)")
        route.unnamed = true
        try await Task.sleep(for: .milliseconds(400))
        try capture(controller.view, name: "detail-unnamed-\(language)")
        route.details = false
        try await Task.sleep(for: .milliseconds(650))
        route.unnamed = false
        app.forwardings.start(rule.id)
        for _ in 0..<400 where app.forwardings.connection(for: rule.id)?.authenticationPrompt == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let context = try #require(app.forwardings.connection(for: rule.id))
        let prompt = try #require(context.authenticationPrompt)
        #expect(!route.details)
        #expect(presented(in: controller) == nil)
        route.details = true
        for size in [
            CGSize(width: 430, height: 900), CGSize(width: 900, height: 430), CGSize(width: 1024, height: 900),
        ] {
            resize(controller, width: size.width, height: size.height)
            try await Task.sleep(for: .milliseconds(650))
            #expect(context.authenticationPrompt?.id == prompt.id)
            #expect(presented(in: controller) == nil)
            try capture(controller.view, name: "journey-\(language)-\(Int(size.width))")
        }
        route.details = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(context.authenticationPrompt?.id == prompt.id)
        route.details = true
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        resize(controller, width: 430, height: 900)
        try await Task.sleep(for: .milliseconds(300))
        try capture(controller.view, name: "journey-\(language)-large-type")
        app.forwardings.stop(rule.id)
        #expect(context.authenticationPrompt == nil)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
    }

    private func resize(_ controller: UIViewController, width: CGFloat, height: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.window?.frame = frame
        controller.parent?.view.frame = frame
        controller.traitOverrides.horizontalSizeClass = width >= 600 ? .regular : .compact
        controller.view.frame = frame
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
    private func presented(in controller: UIViewController) -> UIViewController? {
        controller.presentedViewController ?? controller.children.lazy.compactMap { presented(in: $0) }.first
    }
    private func capture(_ view: UIView, name: String) throws {
        let data = UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        Attachment.record(data, named: "mobile-forwarding-\(name).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-forwarding-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "mobile-forwarding-\(name).png"))
    }
}

@Observable @MainActor private final class ForwardingRenderRoute {
    var details = false
    var unnamed = false
    var editing = false
}
