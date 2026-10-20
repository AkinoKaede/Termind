// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWorkspaceStoreTests {
    @Test(arguments: [Data("broken".utf8), Data("[]".utf8), Data("{\"version\":2,\"sessions\":{}}".utf8)])
    func retirementDeletesLegacySnapshotsWithoutTouchingOtherSettings(data: Data) throws {
        let name = "WorkspaceRetirement.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(data, forKey: MobileWorkspaceStore.key)
        defaults.set(data, forKey: MobileWorkspaceStore.recentlyClosedKey)
        defaults.set(data, forKey: "connection-history")
        MobileWorkspaceStore.retire(in: defaults)
        MobileWorkspaceStore.retire(in: defaults)
        #expect(defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(defaults.object(forKey: MobileWorkspaceStore.recentlyClosedKey) == nil)
        #expect(defaults.data(forKey: "connection-history") == data)
    }

    @Test func activityLinksExcludeReferenceAndRejectExtraParameters() throws {
        let id = UUID()
        let reference = Data("private-ownership-marker".utf8)
        let session = WorkspaceActivityAttributes.Session(
            id: id, title: "Saved", kind: "ssh", connected: false,
            recovery: .init(sourceWorkspaceID: id, hostID: UUID(), kind: "ssh", remoteSession: reference))
        #expect(!session.destinationURL.absoluteString.contains("private"))
        #expect(session.destinationURL.query == nil)
        #expect(WorkspaceActivityAttributes.recovery(from: session.destinationURL)?.remoteSession == nil)
        #expect(WorkspaceActivityAttributes.workspaceID(from: session.destinationURL) == id)
        let legacy = "termind://workspace/\(id)?v=1&host=\(UUID())&kind=ssh"
        #expect(WorkspaceActivityAttributes.workspaceID(from: try #require(URL(string: legacy))) == id)
        let injected = try #require(URL(string: legacy + "&command=whoami"))
        #expect(WorkspaceActivityAttributes.workspaceID(from: injected) == nil)
    }

    @Test func payloadBudgetDropsWholeEntriesAndKeepsFocusedReference() throws {
        let sessions = (0..<6).map { index in
            let id = UUID()
            return WorkspaceActivityAttributes.Session(
                id: id, title: "Session \(index)", kind: "ssh", connected: false,
                recovery: .init(
                    sourceWorkspaceID: id, hostID: UUID(), kind: "ssh", remoteSession: Data(repeating: 42, count: 900)))
        }
        let state = WorkspaceActivityAttributes.ContentState.snapshot(sessions, focusedID: sessions[4].id)
        #expect(try JSONEncoder().encode(state).count <= 3500)
        #expect(state.sessions.count < sessions.count)
        #expect(state.sessions.first?.recovery == sessions[4].recovery)
        for session in state.sessions {
            #expect(session.recovery?.remoteSession?.count == 900)
        }
    }
}
