// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWorkspacePersistenceTests {
    @Test(arguments: [false, true])
    func everyProtocolSurvivesColdLaunchWithoutOpeningAConnection(persistenceEnabled: Bool) throws {
        let name = "AllWorkspaceProtocols.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = try MobileAppModel(dependencies: .testing(defaults: defaults))
        defer { for workspace in original.workspaces { workspace.disconnect() } }
        var host = Host(name: "Server", host: "example.invalid", telnetEnabled: true)
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.sessionPersistence.enabled = persistenceEnabled
        original.library.upsert(host)
        let session = original.workspaceSession(for: "window")
        let kinds: [ConnectionHistoryEntry.Kind] = [.ssh, .sftp, .telnet, .mosh, .eternalTerminal]
        let ids = try kinds.map { kind in
            try #require(session.open(hostID: host.id, kind: kind))
        }
        #expect(session.renameWorkspace(ids[0], to: "Build"))
        let expected = session.restorableDescriptors
        #expect(try MobileWorkspaceStore(defaults: defaults).load().sessions["window"] == expected)

        var connections = 0
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = original.container
        dependencies.workspaceConnections.connectSSH = { _, _, _, _, _, _ in connections += 1 }
        let restored = try MobileAppModel(dependencies: dependencies)
        let saved = restored.workspaceSession(for: "window")
        #expect(saved.savedWorkspaceDescriptors == expected)
        #expect(saved.orderedWorkspaceItems.map(\.id) == ids)
        #expect(saved.orderedWorkspaceItems.map(\.descriptor.kind) == kinds)
        #expect(saved.orderedWorkspaceItems.first?.descriptor.title == "Build")
        #expect(restored.workspaces.isEmpty)
        #expect(connections == 0)
        #expect(restored.connectionHistory.entries().count == original.connectionHistory.entries().count)

        saved.closeOtherWorkspaces(than: ids[0])
        #expect(try MobileWorkspaceStore(defaults: defaults).load().sessions["window"]?.map(\.id) == [ids[0]])
        saved.closeAll()
        #expect(try MobileWorkspaceStore(defaults: defaults).load().sessions["window"]?.isEmpty == true)
        #expect(restored.workspaces.isEmpty)
    }

    @Test(arguments: [ConnectionHistoryEntry.Kind.ssh, .sftp, .telnet, .mosh, .eternalTerminal])
    func disabledProtocolKeepsItsRecordUntilExplicitlyClosed(kind: ConnectionHistoryEntry.Kind) throws {
        let name = "DisabledWorkspaceProtocol.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = try MobileAppModel(dependencies: .testing(defaults: defaults))
        defer { for workspace in original.workspaces { workspace.disconnect() } }
        var host = Host(name: "Server", host: "example.invalid", telnetEnabled: true)
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        original.library.upsert(host)
        let id = try #require(original.testWorkspaceSession.open(hostID: host.id, kind: kind))
        switch kind {
        case .ssh, .sftp: host.sshEnabled = false
        case .telnet: host.telnetEnabled = false
        case .mosh: host.terminalTransports.moshEnabled = false
        case .eternalTerminal: host.terminalTransports.eternalTerminalEnabled = false
        }
        #expect(original.library.saveHost(host))
        original.persistWorkspaceDescriptors()

        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = original.container
        let restored = try MobileAppModel(dependencies: dependencies)
        #expect(restored.testWorkspaceSession.savedWorkspaceDescriptors.map(\.id) == [id])
        #expect(restored.testWorkspaceSession.openWorkspace(id) == nil)
        restored.persistWorkspaceDescriptors()
        #expect(try MobileWorkspaceStore(defaults: defaults).load().sessions["test"]?.map(\.id) == [id])
        restored.testWorkspaceSession.close(id)
        #expect(try MobileWorkspaceStore(defaults: defaults).load().sessions["test"]?.isEmpty == true)
    }

    @Test func plainSSHAndExternalTemporaryConnectionKeepDifferentPersistencePolicies() throws {
        let name = "PlainWorkspaceRestoration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = try MobileAppModel(dependencies: .testing(defaults: defaults))
        defer { for workspace in original.workspaces { workspace.disconnect() } }
        let host = Host(name: "Server", host: "example.invalid")
        original.library.upsert(host)
        let id = try #require(original.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let temporary = try RemoteConnectionURLParser.parse(
            #require(URL(string: "ssh://temporary.example.invalid")))
        let temporaryID = try #require(original.testWorkspaceSession.openExternalConnection(temporary))
        #expect(original.containsWorkspace(temporaryID))

        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = original.container
        let restored = try MobileAppModel(dependencies: dependencies)
        defer { for workspace in restored.workspaces { workspace.disconnect() } }
        let scene = MobileSceneModel(app: restored, sessionID: "test")
        #expect(scene.workspaceSession.savedWorkspaceDescriptors.map(\.id) == [id])
        scene.open(WorkspaceActivityAttributes.destinationURL(for: id))
        scene.open(WorkspaceActivityAttributes.destinationURL(for: id))
        let workspace = try #require(scene.activeWorkspace)
        #expect(workspace.id == id)
        #expect(!scene.isWorkspaceUnavailable)
        #expect(!workspace.sessionPersistence.requiresSelection)
        #expect(workspace.sessionPersistence.prompt == nil)
        #expect(restored.workspaces.count == 1)
        scene.workspaceSession.close(id)
        #expect(scene.workspaceSession.reopenLastClosed() == id)
        let reopened = try #require(restored.workspaces.first)
        #expect(!reopened.sessionPersistence.requiresSelection)
        #expect(reopened.pendingInitialCommand == nil)
    }

    @Test func attachmentChangesAreSavedWithoutRequiringTheHostPersistenceSwitch() throws {
        let name = "WorkspaceReferenceUpdates.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let app = try MobileAppModel(dependencies: .testing(defaults: defaults))
        defer { for workspace in app.workspaces { workspace.disconnect() } }
        let host = Host(name: "Server", host: "example.invalid")
        app.library.upsert(host)
        let id = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let workspace = try #require(app.workspaces.first)
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "$1", name: "build", identity: Data("identity".utf8)),
            hostID: host.id, endpoint: "example.invalid:22", username: "user", ownershipToken: nil)
        workspace.restoreRemoteSession(reference)
        let store = MobileWorkspaceStore(defaults: defaults)
        #expect(try store.load().sessions["test"]?.first?.remoteSession == reference)
        workspace.restoreRemoteSession(nil)
        #expect(try store.load().sessions["test"]?.first?.remoteSession == nil)
        #expect(try store.load().sessions["test"]?.map(\.id) == [id])
    }

    @Test(arguments: [false, true])
    func undiscoveredHostKeepsAClosableRecordAndCanOpenAfterDiscovery(rediscover: Bool) throws {
        let name = "UndiscoveredWorkspaceHost.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let host = Host(name: "Server", host: "example.invalid")
        let record = MobileWorkspaceDescriptor(hostID: host.id, title: "Saved shell", kind: .ssh)
        let store = MobileWorkspaceStore(defaults: defaults)
        try store.save(.init(sessions: ["test": [record]]))
        let app = try MobileAppModel(dependencies: .testing(defaults: defaults))
        let session = app.testWorkspaceSession
        #expect(session.openWorkspace(record.id) == nil)
        #expect(session.orderedWorkspaceItems.map(\.id) == [record.id])
        app.persistWorkspaceDescriptors()
        #expect(try store.load().sessions["test"] == [record])
        if rediscover {
            app.library.upsert(host)
            let opened = try #require(session.openWorkspace(record.id))
            #expect(opened.id == record.id)
            #expect(!opened.sessionPersistence.requiresSelection)
        }
        session.close(record.id)
        #expect(try store.load().sessions["test"]?.isEmpty == true)
    }

    @Test func coldLaunchDoesNotPersistOrReplayOneShotCommands() throws {
        let name = "OneShotWorkspaceRestoration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = try MobileAppModel(dependencies: .testing(defaults: defaults))
        defer { for workspace in original.workspaces { workspace.disconnect() } }
        let host = Host(name: "Server", host: "example.invalid")
        original.library.upsert(host)
        let command = "echo one-shot-marker"
        let id = try #require(
            original.testWorkspaceSession.execute(Snippet(title: "One shot", body: command), on: [host.id]).first)
        #expect(original.workspaces.first?.pendingInitialCommand == command)
        let data = try #require(defaults.data(forKey: MobileWorkspaceStore.restorationKey))
        #expect(!String(decoding: data, as: UTF8.self).contains(command))
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = original.container
        let restored = try MobileAppModel(dependencies: dependencies)
        defer { for workspace in restored.workspaces { workspace.disconnect() } }
        let opened = try #require(restored.testWorkspaceSession.openWorkspace(id))
        #expect(opened.pendingInitialCommand == nil)
        #expect(opened.id == id)
    }
}
