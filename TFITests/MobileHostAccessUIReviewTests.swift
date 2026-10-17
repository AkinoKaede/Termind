import RevenueCat
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS
@testable import TermindInfrastructure

/// Real mobile screens with in-memory hosts; only the published paywall may use the network.
@Suite(
    .requiresKeyWindow,
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_HOST_ACCESS_UI_REVIEW"] == "1"),
    .serialized)
@MainActor
struct MobileHostAccessUIReviewTests {
    @Test(arguments: ["en", "zh-Hans"])
    func hostLocksAndActualSaveStates(language: String) async throws {
        if !Purchases.isConfigured, let configuration = RevenueCatConfiguration.bundled() {
            Purchases.configure(
                with: Configuration.builder(withAPIKey: configuration.apiKey)
                    .with(storeKitVersion: .storeKit2)
                    .with(automaticDeviceIdentifierCollectionEnabled: false)
                    .with(preferredUILocaleOverride: language))
        }
        let service = ReviewPurchaseService()
        let pro = ProAccessController(purchaseService: service, observeUpdates: false)
        await pro.refresh()
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = pro
        let app = try MobileAppModel(dependencies: dependencies)
        defer {
            app.metrics.core.shutdown()
            app.outbox.stop()
        }
        app.library.hostAccess.entitlement = .unrestrictedForTesting
        let names = ["Production", "Staging", "Database", "Backup"]
        for name in names {
            app.library.upsert(TermindDomain.Host(name: name, host: "\(name.lowercased()).example.invalid"))
        }
        app.library.hostAccess.entitlement = .free
        let locked = try #require(app.library.hosts.first(where: { $0.name == "Backup" }))
        #expect(app.library.isLocked(locked))
        #expect(app.metrics.add(locked.id))

        try await withWindow(
            NavigationStack {
                MobileVaultView(app: app, editingHost: .constant(nil), activateHost: { _ in }, open: { _, _ in })
            }, language: language
        ) { window, _ in
            try await scrollToBottom(in: window)
            try capture(window, name: "hosts-\(language)")
        }
        try await withWindow(
            NavigationStack { MobileMetricsView(app: app) }, language: language
        ) { window, _ in
            let server = try #require(app.metrics.servers.first)
            #expect(server.isHostLocked)
            try capture(window, name: "metrics-locked-\(language)")
            app.library.hostAccess.entitlement = .loading
            app.metrics.core.reconcile()
            try await settle()
            #expect(server.hostAccessError == .verifyingEntitlement)
            #expect(server.isConnecting)
            #expect(server.status == String(localized: AppStrings.Pro.verifyingAccess))
            try capture(window, name: "metrics-checking-\(language)")
            app.library.hostAccess.entitlement = .verificationFailed
            app.metrics.core.reconcile()
            try await settle()
            #expect(server.hostAccessError == .entitlementVerificationFailed)
            #expect(!server.isConnecting)
            #expect(server.status == String(localized: AppStrings.Pro.accessVerificationFailed))
            try capture(window, name: "metrics-verification-error-\(language)")
            app.library.hostAccess.entitlement = .free
            app.metrics.core.reconcile()
        }
        if ProcessInfo.processInfo.environment["TERMIND_HOST_ACCESS_UI_REVIEW_METRICS_ONLY"] == "1" { return }
        try await withWindow(
            NavigationStack { MobileAISettingsView(app: app) }, language: language
        ) { window, _ in
            try capture(window, name: "ai-settings-mcp-\(language)")
        }
        try await withWindow(
            NavigationStack { MobileMCPSettings(ai: app.ai) }, language: language
        ) { window, _ in
            try capture(window, name: "mcp-empty-\(language)")
        }
        let scene = MobileSceneModel(app: app, sessionID: "host-access-review-\(language)")
        try await withWindow(MobileRootView(app: app, scene: scene), language: language) { window, controller in
            app.library.hostAccess.entitlement = .verificationFailed
            #expect(scene.workspaceSession.open(hostID: locked.id, kind: .ssh) == nil)
            try await settle()
            let alert = try #require(descendant(of: UIAlertController.self, in: controller))
            #expect(alert.message == String(localized: AppStrings.Pro.accessVerificationFailed))
            try capture(window, name: "connection-verification-error-\(language)")
        }
        app.error = nil
        app.library.hostAccess.entitlement = .free
        #expect(app.deleteHost(locked.id))
        let draft = TermindDomain.Host(name: "Backup", host: "backup.example.invalid")
        let waiting = ReviewAccessWait()
        app.library.hostAccess.entitlement = .loading
        app.library.resolveInitialHostEntitlement = {
            await waiting.wait()
            app.library.hostAccess.entitlement = .verificationFailed
        }
        defer { waiting.finish() }
        let pendingState = ReviewEditorPresentation()
        try await withWindow(
            ReviewHostEditor(app: app, draft: draft, state: pendingState), language: language
        ) { window, controller in
            try capture(window, name: "add-host-\(language)")
            try activateSave(in: controller)
            try await settle()
            #expect(waiting.isWaiting)
            #expect(app.library.host(draft.id) == nil)
            #expect(pendingState.presented)
            // The existing editor places its saving spinner at the end of the form.
            let editor = try #require(descendant(of: UINavigationController.self, in: controller))
            if let scroll = views(in: editor.view).compactMap({ $0 as? UICollectionView }).first {
                if let section = (0..<scroll.numberOfSections).last(where: { scroll.numberOfItems(inSection: $0) > 0 })
                {
                    scroll.scrollToItem(
                        at: IndexPath(item: scroll.numberOfItems(inSection: section) - 1, section: section),
                        at: .bottom, animated: false)
                }
            }
            try await settle()
            try capture(window, name: "save-pending-\(language)")
            waiting.finish()
            try await settle()
            let alert = try #require(descendant(of: UIAlertController.self, in: controller))
            #expect(alert.message == String(localized: AppStrings.Pro.accessVerificationFailed))
            #expect(pendingState.presented)
            #expect(app.library.host(draft.id) == nil)
            try capture(window, name: "save-verification-error-\(language)")
        }

        app.library.hostAccess.entitlement = .free
        let paywallState = ReviewEditorPresentation()
        try await withWindow(
            ReviewHostEditor(app: app, draft: draft, state: paywallState), language: language
        ) { window, controller in
            try activateSave(in: controller)
            try await Task.sleep(for: .seconds(8))
            #expect(paywallState.presented)
            #expect(app.library.host(draft.id) == nil)
            #expect(descendant(of: UIAlertController.self, in: controller) == nil)
            try capture(window, name: "fourth-host-paywall-\(language)")
            print("Mobile paywall capture uses actual RevenueCat PaywallView; inspect product loading before sharing.")
        }
    }

    private func withWindow(
        _ content: some View, language: String,
        check: (UIWindow, UIViewController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await settle()
        try await check(window, controller)
    }

    private func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let filename = "iphone-host-access-\(name).png"
        Attachment.record(data, named: filename)
        let directory = FileManager.default.temporaryDirectory.appending(path: "host-access-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: filename)
        try data.write(to: path)
        print("TERMIND_MOBILE_HOST_ACCESS_REVIEW|\(path.path)")
    }

    private func activateSave(in controller: UIViewController) throws {
        let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
        let item = try #require(navigation.topViewController?.navigationItem)
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        let save = try #require(
            buttons.first {
                ["Save", "保存", "儲存"].contains($0.accessibilityLabel ?? $0.title ?? "")
            })
        #expect(save.isEnabled)
        let action = try #require(save.action)
        #expect(UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil))
    }

    private func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func scrollToBottom(in view: UIView) async throws {
        for _ in 0..<3 {
            view.layoutIfNeeded()
            if let scroll = views(in: view).compactMap({ $0 as? UIScrollView }).max(by: {
                $0.contentSize.height - $0.bounds.height < $1.contentSize.height - $1.bounds.height
            }) {
                scroll.setContentOffset(
                    CGPoint(
                        x: 0,
                        y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    ),
                    animated: false)
            }
            try await settle()
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(800)) }
}

@MainActor
private final class ReviewPurchaseService: ProPurchaseService {
    var updates: AsyncStream<EntitlementStatus> { AsyncStream { $0.finish() } }
    func currentStatus() async throws -> EntitlementStatus { .free }
}

@MainActor
private final class ReviewAccessWait {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@Observable @MainActor
private final class ReviewEditorPresentation {
    var presented = true
}

private struct ReviewHostEditor: View {
    let app: MobileAppModel
    let draft: TermindDomain.Host
    @Bindable var state: ReviewEditorPresentation

    var body: some View {
        NavigationStack {
            MobileVaultView(app: app, editingHost: .constant(nil), activateHost: { _ in }, open: { _, _ in })
        }
        .sheet(isPresented: $state.presented) { MobileHostEditor(app: app, host: draft) }
    }
}
