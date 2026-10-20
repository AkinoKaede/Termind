// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileWorkspaceWindowIntegrationTests {
    @Test func nativeWindowsRouteActivityLinksAndKeepRestorableSessionOwnership() async throws {
        #expect(UIApplication.shared.supportsMultipleScenes)
        let first = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let firstDelegate = try #require(delegate(for: first))
        try await waitUntil { firstDelegate.app != nil }
        let app = try #require(firstDelegate.app)
        let host = Host(name: "Window Routing", host: "routing.invalid")
        app.library.upsert(host)
        defer { _ = app.deleteHost(host.id) }
        let firstModel = app.workspaceSession(for: first.session.persistentIdentifier)
        let firstID = try #require(firstModel.open(hostID: host.id, kind: .ssh))
        #expect(firstModel.renameWorkspace(firstID, to: "Window A"))
        firstDelegate.receiveWorkspaceActivity(MobileWorkspaceSceneRouting.activity(for: firstID))
        try await waitUntil { self.navigationTitles(in: first).contains("Window A") }

        let initialIDs = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        var activationError: String?
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil) {
            activationError = $0.localizedDescription
        }
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { !initialIDs.contains($0.session.persistentIdentifier) }
                || activationError != nil
        }
        #expect(activationError == nil)
        let second = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { !initialIDs.contains($0.session.persistentIdentifier) })
        defer {
            if UIApplication.shared.openSessions.contains(second.session) {
                UIApplication.shared.requestSceneSessionDestruction(second.session, options: nil, errorHandler: nil)
            }
        }
        let secondDelegate = try #require(delegate(for: second))
        try await waitUntil { secondDelegate.app != nil }
        #expect(secondDelegate.app === app)
        let secondModel = app.workspaceSession(for: second.session.persistentIdentifier)
        #expect(secondModel.orderedWorkspaceItems.isEmpty)
        let secondID = try #require(secondModel.open(hostID: host.id, kind: .ssh))
        #expect(secondModel.renameWorkspace(secondID, to: "Window B"))
        secondDelegate.receiveWorkspaceActivity(MobileWorkspaceSceneRouting.activity(for: secondID))
        try await waitUntil { self.navigationTitles(in: second).contains("Window B") }

        // The system delivers an Activity link to B although the requested workspace belongs to A.
        secondDelegate.receiveWorkspaceActivity(MobileWorkspaceSceneRouting.activity(for: firstID))
        try await waitUntil {
            first.activationState == .foregroundActive && self.navigationTitles(in: first).contains("Window A")
                && firstDelegate.pendingWorkspaceID == nil && secondDelegate.pendingWorkspaceID == nil
        }
        #expect(firstModel.workspaces.map(\.id) == [firstID])
        #expect(secondModel.workspaces.map(\.id) == [secondID])
        #expect(navigationTitles(in: second).contains("Window B"))

        // Exercise the reclaim callback without discarding the persistent native session.
        secondDelegate.sceneDidDisconnect(second)
        firstDelegate.sceneDidBecomeActive(first)
        #expect(app.workspaceOwner(secondID) == second.session.persistentIdentifier)
        #expect(secondModel.workspaces.map(\.id) == [secondID])
        MobileWorkspaceSceneRouting.activate(
            sessionID: second.session.persistentIdentifier, workspaceID: secondID,
            unavailable: { Issue.record("Restorable window could not be activated") })
        try await waitUntil {
            second.activationState == .foregroundActive && self.navigationTitles(in: second).contains("Window B")
        }

        UIApplication.shared.requestSceneSessionDestruction(second.session, options: nil) {
            Issue.record("Could not close native test window: \($0.localizedDescription)")
        }
        try await waitUntil { !UIApplication.shared.openSessions.contains(second.session) }
        try await waitUntil { app.workspaceOwner(secondID) == nil }
        #expect(firstModel.workspaces.map(\.id) == [firstID])
    }

    private func delegate(for scene: UIWindowScene) -> MobileSceneDelegate? {
        if let delegate = scene.delegate as? MobileSceneDelegate { return delegate }
        // SwiftUI wraps the configured UIKit delegate; use its public Objective-C forwarding hook.
        return (scene.delegate as? NSObject)?.forwardingTarget(
            for: #selector(MobileSceneDelegate.sceneDidDisconnect(_:))) as? MobileSceneDelegate
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(condition())
    }

    private func navigationTitles(in scene: UIWindowScene) -> [String] {
        func titles(_ controller: UIViewController) -> [String] {
            let own =
                (controller as? UINavigationController)?.viewControllers.compactMap { $0.navigationItem.title } ?? []
            return own + controller.children.flatMap(titles)
        }
        return scene.windows.compactMap(\.rootViewController).flatMap(titles)
    }
}
