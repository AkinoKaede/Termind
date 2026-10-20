// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileStartupViewTests {
    private enum StartupFailure: Error { case unavailableStore }

    @Test func appWindowColdLaunchMountsMainNavigation() async throws {
        // Exercise the real WindowGroup, including its conditional scene-session binding.
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var navigation: UITabBarController?
        for _ in 0..<100 {
            navigation = windowScene.windows.compactMap(\.rootViewController).compactMap { tabs(in: $0) }.first
            if navigation != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try #require(navigation).tabs.count == 5)
    }

    @Test(
        .requiresKeyWindow
    )
    func mountingSceneRootStartsOnceAndPreservesNavigationAcrossUpdates() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let delegate = MobileSceneDelegate()
        let content = MobileBoundSceneRoot(app: app, sessionID: "startup-test", delegate: delegate)
            .modelContainer(app.container)
            .environment(\.scenePhase, .inactive)
        let controller = UIHostingController(rootView: content)
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }

        for _ in 0..<50 {
            controller.view.layoutIfNeeded()
            if app.transferNotificationTarget() != nil, tabs(in: controller) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let mountedScene = app.transferNotificationTarget()
        let scene = try #require(mountedScene)
        let originalTabs = try #require(tabs(in: controller))
        #expect(originalTabs.tabs.count == 5)
        #expect(delegate.app === app)
        #expect(scene.workspaceSession.id == "startup-test")
        scene.selectedDestination = .settings

        // Rebuilding the parent and delivering delegate updates must retain this scene.
        for _ in 0..<3 {
            controller.rootView = content
            delegate.objectWillChange.send()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            #expect(app.transferNotificationTarget() === scene)
            #expect(scene.selectedDestination == .settings)
            #expect(tabs(in: controller) === originalTabs)
        }

        // A notification received during startup is applied only after the mounted root activates.
        app.notifications.onOpen?(.transfers)
        #expect(!scene.showsTransfers)
        controller.rootView = MobileBoundSceneRoot(app: app, sessionID: "startup-test", delegate: delegate)
            .modelContainer(app.container)
            .environment(\.scenePhase, .active)
        for _ in 0..<50 {
            controller.view.layoutIfNeeded()
            if scene.showsTransfers { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(app.transferNotificationTarget() === scene)
        #expect(scene.showsTransfers)
        #expect(scene.selectedDestination == .workspaces)
    }

    private func tabs(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { tabs(in: $0) }.first
    }

    @Test func successfulSceneContentCanBeCreatedOffMainThread() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let makeContent = MobileStartupView.sceneContent(for: .success(app))

        let content = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return makeContent()
        }.value

        #expect(try content.startup.get() === app)
    }

    @Test func failedSceneContentCanBeCreatedOffMainThread() async {
        let makeContent = MobileStartupView.sceneContent(for: .failure(StartupFailure.unavailableStore))

        let content = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return makeContent()
        }.value

        guard case .failure(let error) = content.startup else {
            Issue.record("Failed startup must remain a failure when creating scene content")
            return
        }
        #expect(error as? StartupFailure == .unavailableStore)
    }
}
