import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
        "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"),
    .serialized
)
@MainActor
struct MobileBatchStartupRenderingTests {
    @Test(arguments: [("en", "Batch Startup", "Connect"), ("zh-Hans", "批量启动", "连接"), ("zh-Hant", "批次啟動", "連線")])
    func workspacePresentsLocalizedBatchSheetAndResetsProtocolOnReopen(
        language: String, title: String, connectTitle: String
    ) async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.testWorkspaceSession.closeAll() }
        app.library.upsert(Host(name: "Production Gateway", host: "gateway.example.invalid"))
        app.library.upsert(Host(name: "Staging Server", host: "staging.example.invalid"))
        app.library.upsert(
            Host(name: "Legacy Console", host: "console.example.invalid", sshEnabled: false, telnetEnabled: true))
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectedDestination = .workspaces
        try await withWindow(
            MobileRootView(app: app, scene: scene)
                .environment(\.locale, Locale(identifier: language))
        ) { window, controller in
            scene.openConnectionPicker()
            try await Task.sleep(for: .milliseconds(800))
            let connectSheet = try #require(presented(in: controller))
            let connectFrame = try #require(connectSheet.presentationController?.frameOfPresentedViewInContainerView)
            try capture(window, name: "connect-\(language)")
            scene.workspaceSheet = nil
            try await Task.sleep(for: .milliseconds(700))
            scene.openBatchStartup()
            try await Task.sleep(for: .milliseconds(800))
            let sheet = try #require(presented(in: controller))
            let batchFrame = try #require(sheet.presentationController?.frameOfPresentedViewInContainerView)
            #expect(abs(batchFrame.midX - connectFrame.midX) < 2)
            #expect(abs(batchFrame.midY - connectFrame.midY) < 2)
            if UIDevice.current.userInterfaceIdiom == .pad {
                #expect(abs(batchFrame.midY - window.bounds.midY) < 2)
            }
            let navigation = try #require(descendant(UINavigationController.self, in: sheet))
            #expect(navigation.topViewController?.navigationItem.title == title)
            let connect = try #require(toolbarButton(named: connectTitle, in: navigation))
            #expect(!connect.isEnabled)
            let segmented = try #require(descendants(UISegmentedControl.self, in: sheet.view).first)
            #expect(segmented.numberOfSegments == 2)
            #expect(segmented.selectedSegmentIndex == 0)
            try capture(window, name: "batch-startup-\(language)-ssh")
            segmented.selectedSegmentIndex = 1
            segmented.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(300))
            #expect(segmented.selectedSegmentIndex == 1)
            try capture(window, name: "batch-startup-\(language)-sftp")
            scene.workspaceSheet = nil
            try await Task.sleep(for: .milliseconds(700))
            #expect(app.workspaces.isEmpty)
            scene.openBatchStartup()
            try await Task.sleep(for: .milliseconds(700))
            let reopened = try #require(presented(in: controller))
            #expect(descendants(UISegmentedControl.self, in: reopened.view).first?.selectedSegmentIndex == 0)
            scene.workspaceSheet = nil
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test func protocolChangeUpdatesMountedPickerAndPrunesOnlyIncompatibleSelections() async throws {
        let ssh = Host(name: "Alpha", host: "alpha.invalid")
        let telnet = Host(name: "Bravo", host: "bravo.invalid", sshEnabled: false, telnetEnabled: true)
        let library = HostLibraryModel(hosts: [ssh, telnet])
        let route = BatchPickerRenderingRoute()
        try await withWindow(
            BatchPickerRenderingHost(library: library, selected: [telnet.id], route: route)
                .environment(\.locale, Locale(identifier: "en"))
        ) { _, controller in
            let navigation = try #require(descendant(UINavigationController.self, in: controller))
            #expect(try #require(toolbarButton(named: "Connect", in: navigation)).isEnabled)
            route.connectionProtocol = .sftp
            try await Task.sleep(for: .milliseconds(300))
            #expect(try #require(toolbarButton(named: "Connect", in: navigation)).isEnabled == false)
            route.connectionProtocol = .ssh
            try await Task.sleep(for: .milliseconds(300))
            #expect(try #require(toolbarButton(named: "Connect", in: navigation)).isEnabled == false)
        }
    }

    private func withWindow<Content: View>(
        _ content: Content, check: (UIWindow, UIViewController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        try await check(window, controller)
    }

    private func toolbarButton(named name: String, in navigation: UINavigationController) -> UIBarButtonItem? {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems) + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        return buttons.first {
            $0.accessibilityLabel == name || $0.title == name || $0.customView?.accessibilityLabel == name
        }
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        return controller.children.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func presented(in controller: UIViewController) -> UIViewController? {
        controller.presentedViewController ?? controller.children.lazy.compactMap { presented(in: $0) }.first
    }

    private func capture(_ view: UIView, name: String) throws {
        let data = UIGraphicsImageRenderer(bounds: view.bounds).pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        Attachment.record(data, named: "\(device)-\(name).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-batch-startup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(device)-\(name).png")
        try data.write(to: url)
        print("Batch Startup snapshot: \(url.path)")
    }
}

@Observable @MainActor private final class BatchPickerRenderingRoute {
    var connectionProtocol = MobileConnectionProtocol.ssh
}

private struct BatchPickerRenderingHost: View {
    let library: HostLibraryModel
    let selected: Set<Host.ID>
    @Bindable var route: BatchPickerRenderingRoute

    var body: some View {
        MobileMultiHostPicker(
            library: library, useCase: route.connectionProtocol.useCase, selected: selected,
            title: AppStrings.Vault.batchStartup, actionTitle: AppStrings.Common.connect,
            emptyDescription: AppStrings.Vault.addAHostToConnectToIt, requiresSelection: true,
            save: { _ in }, header: { MobileConnectionProtocolPicker(selection: $route.connectionProtocol) })
    }
}
