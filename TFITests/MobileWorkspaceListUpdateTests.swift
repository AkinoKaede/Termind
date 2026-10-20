// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow)
@MainActor
struct MobileWorkspaceListUpdateTests {
    @Test func closingAndReopeningWorkspacesKeepsThePresentedListConsistent() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Workspace list", host: "example.invalid")
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "list-updates")
        scene.selectedDestination = .workspaces
        let session = scene.workspaceSession
        defer { session.closeAll() }

        try await withList(app: app, scene: scene) { controller in
            let list = try #require(find(UICollectionView.self, in: controller.view))
            try await expectRows(1, in: list)
            for _ in 0..<4 {
                let descriptors = (0..<3).map {
                    MobileWorkspaceDescriptor(hostID: host.id, title: "Shell \($0)", kind: .ssh)
                }
                session.restoreClosedStates(descriptors.map { .init(descriptor: $0) })
                try await expectRows(3, in: list)
                app.connectionHistory.record(kind: .ssh, for: host.id)
                scene.closeWorkspace(descriptors[1].id)
                try await expectRows(2, in: list)
                scene.closeOtherWorkspaces(than: descriptors[2].id)
                try await expectRows(1, in: list)
                scene.closeAllWorkspaces()
                try await expectRows(1, in: list)
                #expect(session.orderedWorkspaceItems.isEmpty)
                app.connectionHistory.clearAll()
                try await expectRows(1, in: list)
                #expect(find(UICollectionView.self, in: controller.view) === list)
            }
        }
    }

    @Test func coalescedWorkspaceAndHistoryChangesKeepTheLatestRows() async throws {
        let app = try MobileAppModel(inMemory: true)
        let hosts = (0..<3).map { TermindDomain.Host(name: "Host \($0)", host: "example.invalid") }
        for host in hosts {
            app.library.upsert(host)
            app.connectionHistory.record(kind: .ssh, for: host.id)
        }
        let scene = MobileSceneModel(app: app, sessionID: "coalesced-list-updates")
        scene.selectedDestination = .workspaces
        let session = scene.workspaceSession
        defer { session.closeAll() }

        try await withList(app: app, scene: scene) { controller in
            let list = try #require(find(UICollectionView.self, in: controller.view))
            try await expectRows(3, in: list)
            for _ in 0..<4 {
                let descriptor = MobileWorkspaceDescriptor(hostID: hosts[0].id, title: "Shell", kind: .ssh)
                session.restoreClosedStates([.init(descriptor: descriptor)])
                try await expectRows(1, in: list)
                scene.closeWorkspace(descriptor.id)
                app.connectionHistory.clear(for: hosts[0].id)
                try await expectRows(2, in: list)
                session.restoreClosedStates([.init(descriptor: descriptor)])
                scene.closeAllWorkspaces()
                app.connectionHistory.record(kind: .ssh, for: hosts[0].id)
                try await expectRows(3, in: list)
                #expect(find(UICollectionView.self, in: controller.view) === list)
            }
        }
    }

    @Test func closingTheSelectedWorkspaceUpdatesTheListWhilePoppingItsDetail() async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Selected workspace", host: "example.invalid")
        app.library.upsert(host)
        app.connectionHistory.record(kind: .ssh, for: host.id)
        let scene = MobileSceneModel(app: app, sessionID: "popping-list-updates")
        scene.selectedDestination = .workspaces
        let session = scene.workspaceSession
        defer { session.closeAll() }

        try await withList(app: app, scene: scene) { controller in
            let list = try #require(find(UICollectionView.self, in: controller.view))
            for _ in 0..<3 {
                let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Selected shell", kind: .ssh)
                session.restoreClosedStates([.init(descriptor: descriptor)])
                scene.selectWorkspace(descriptor.id)
                try await Task.sleep(for: .milliseconds(400))
                #expect(scene.workspaceID == descriptor.id)
                scene.closeActiveWorkspace()
                try await Task.sleep(for: .milliseconds(400))
                #expect(scene.workspaceID == nil)
                try await expectRows(1, in: list)
                #expect(find(UICollectionView.self, in: controller.view) === list)
            }
        }
    }

    @Test func closingAManagedWorkspaceRemovesItsRowBeforeBackgroundCleanup() async throws {
        let app = try MobileAppModel(inMemory: true)
        let hosts = (0..<2).map { TermindDomain.Host(name: "Host \($0)", host: "example.invalid") }
        for host in hosts {
            app.library.upsert(host)
            app.connectionHistory.record(kind: .ssh, for: host.id)
        }
        let scene = MobileSceneModel(app: app, sessionID: "deferred-list-close")
        scene.selectedDestination = .workspaces
        let session = scene.workspaceSession
        defer { session.closeAll(authorized: true) }
        let descriptor = MobileWorkspaceDescriptor(hostID: hosts[0].id, title: "Managed shell", kind: .ssh)
        session.restoreClosedStates([.init(descriptor: descriptor)])
        let workspace = try #require(session.workspaces.first)
        workspace.restoreRemoteSession(
            .init(
                backend: .tmux, session: .init(id: "$1", name: "shell", identity: Data("identity".utf8)),
                hostID: hosts[0].id, endpoint: "example.invalid:22", username: "user", ownershipToken: UUID()))

        try await withList(app: app, scene: scene) { controller in
            let list = try #require(find(UICollectionView.self, in: controller.view))
            try await expectRows(1, in: list)
            scene.closeWorkspace(descriptor.id)
            // Local removal is synchronous even though remote cleanup has not run yet.
            #expect(session.workspaces.isEmpty)
            #expect(app.persistentSessionCloser.isClosing)
            try await expectRows(2, in: list)
            #expect(session.orderedWorkspaceItems.isEmpty)
            #expect(find(UICollectionView.self, in: controller.view) === list)
        }
    }

    private func expectRows(_ count: Int, in list: UICollectionView) async throws {
        try await Task.sleep(for: .milliseconds(150))
        list.layoutIfNeeded()
        #expect(list.numberOfSections == 2)
        #expect(list.numberOfItems(inSection: 0) == 1)
        #expect(list.numberOfItems(inSection: 1) == count)
    }

    private func withList(
        app: MobileAppModel, scene: MobileSceneModel,
        check: (UIViewController) async throws -> Void
    ) async throws {
        let windowScene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = windowScene.keyWindow
        let window = UIWindow(windowScene: windowScene)
        let controller = UIHostingController(
            rootView: NavigationStack { MobileWorkspaceListView(app: app, scene: scene) })
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(300))
        try await check(controller)
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        return root.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
