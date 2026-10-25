// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow) @MainActor
struct MobileCompactNavigationTests {
    @Test(arguments: [false, true], [false, true])
    func vaultPagesRemainResponsiveAfterNavigation(compact: Bool, populated: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        if populated {
            for index in 0..<12 {
                try app.credentials.upsert(
                    SSHKeyRef(label: "Key \(index)", algorithm: .ed25519, credentialRef: "missing.\(UUID())"))
                #expect(app.library.upsert(Identity(name: "Identity \(index)", username: "deploy")))
                app.snippets.upsert(Snippet(title: "Snippet \(index)", body: "pwd"))
            }
        }
        let defaultsName = "MobileCompactNavigationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(compact, forKey: "mobile.compactCards")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let route = CardNavigationRoute()
        let controller = UIHostingController(
            rootView: NavigationStack(path: Binding(get: { route.path }, set: { route.path = $0 })) {
                MobileVaultView(app: app, editingHost: .constant(nil), activateHost: { _ in }, open: { _, _ in })
                    .navigationDestination(for: CardNavigationRoute.Page.self) { page in
                        switch page {
                        case .keychain: MobileCredentialsView(app: app)
                        case .snippets: MobileSnippetsView(app: app, execute: { _, _ in })
                        }
                    }
            }
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "en"))
            .dynamicTypeSize(.large))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await settle(controller)
        for page in [CardNavigationRoute.Page.keychain, .snippets, .keychain, .snippets] {
            route.path = [page]
            try await settle(controller)
            let navigation = try #require(navigation(in: controller))
            #expect(navigation.viewControllers.count == 2)
            let detail = try #require(navigation.topViewController)
            let regions = descendants(detail.view).compactMap { $0 as? MobileCardDragRegion.RegionView }
                .filter { $0.configuration?.target != nil && !$0.bounds.isEmpty }
            #expect(regions.isEmpty == !populated)
            for region in regions {
                #expect(region.bounds.width.isFinite && region.bounds.width > 0)
                #expect(region.bounds.height.isFinite && region.bounds.height > 0)
            }
            let frames = regions.map { $0.convert($0.bounds, to: detail.view) }
            try await settle(controller)
            #expect(regions.map { $0.convert($0.bounds, to: detail.view) } == frames)
            route.path = []
            try await settle(controller)
            #expect(navigation.viewControllers.count == 1)
        }
    }

    private func settle(_ controller: UIViewController) async throws {
        try await Task.sleep(for: .milliseconds(350))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { navigation(in: $0) }.first
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@Observable @MainActor private final class CardNavigationRoute {
    enum Page: Hashable { case keychain, snippets }
    var path: [Page] = []
}
