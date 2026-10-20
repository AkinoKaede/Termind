// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileBatchStartupTests {
    @Test func connectionProtocolsResolveTheSameTargetsAsConnect() {
        let ssh = Host(name: "SSH", host: "ssh.invalid")
        let telnet = Host(name: "Telnet", host: "telnet.invalid", sshEnabled: false, telnetEnabled: true)
        let both = Host(name: "Both", host: "both.invalid", telnetEnabled: true)
        var disabled = ssh
        disabled.sshEnabled = false
        var selections: [ConnectionHistoryEntry.Kind] = []
        let connect = MobileConnectionPickerModel { _, kind in selections.append(kind) }

        #expect(connect.kind == .ssh)
        for host in [ssh, telnet, both, disabled] { connect.select(host) }
        #expect(selections == [.ssh, .telnet, .ssh])
        #expect(MobileConnectionProtocol.ssh.kind(for: disabled) == nil)
        selections = []
        connect.kind = .sftp
        for host in [ssh, telnet, both, disabled] { connect.select(host) }
        #expect(selections == [.sftp, .sftp])
    }

    @Test(arguments: HostTerminalProtocol.allCases)
    func pickerRecentsAndBatchUseTheSameDefaultTransport(transport: HostTerminalProtocol) throws {
        let app = try MobileAppModel(inMemory: true)
        defer {
            app.testWorkspaceSession.closeAll()
            app.outbox.stop()
        }
        var host = Host(name: "Default", host: "server.invalid", telnetEnabled: true)
        host.sshEnabled = transport != .telnet
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        if transport != .telnet { host.terminalTransports.defaultTransport = transport }
        #expect(app.library.saveHost(host))
        var selections: [ConnectionHistoryEntry.Kind] = []
        let picker = MobileConnectionPickerModel { _, kind in selections.append(kind) }

        picker.select(host)
        #expect(selections == [.terminal(transport)])
        #expect(MobileConnectionHistory.preferredKind(for: host) == .terminal(transport))
        let ids = app.testWorkspaceSession.batchStartup(hostIDs: [host.id], connectionProtocol: .ssh)
        #expect(ids.count == 1)
        #expect(app.workspaces.last?.descriptor.kind == .terminal(transport))
        #expect(app.connectionHistory.entries(for: host.id).map(\.kind) == [.terminal(transport)])
        if host.sshEnabled {
            _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
            #expect(app.workspaces.last?.descriptor.kind == .ssh)
        }
    }

    @Test func switchingProtocolsRetainsSearchAndOnlyCompatibleSelections() {
        let ssh = Host(name: "Alpha", host: "ssh.invalid")
        let telnet = Host(
            name: "Bravo", host: "telnet.invalid", sshEnabled: false, telnetEnabled: true, telnetPort: 2323)
        let library = HostLibraryModel(hosts: [ssh, telnet])
        let picker = MobileMultiHostPickerModel(library: library, useCase: .preferredTerminal, selected: [])

        picker.toggleAllResults()
        #expect(picker.orderedSelection == [ssh.id, telnet.id])
        #expect(picker.loginAddress(for: telnet) == library.loginAddress(for: telnet, protocol: .telnet))
        picker.query = "Bravo"
        picker.updateUseCase(.sftp)
        #expect(picker.query == "Bravo")
        #expect(picker.hosts.isEmpty)
        #expect(picker.orderedSelection == [ssh.id])
        picker.updateUseCase(.preferredTerminal)
        #expect(picker.hosts.map(\.id) == [telnet.id])
        #expect(picker.orderedSelection == [ssh.id])
        picker.toggleAllResults()
        #expect(picker.orderedSelection == [ssh.id, telnet.id])
        picker.toggleAllResults()
        #expect(picker.orderedSelection == [ssh.id])
    }

    @Test func batchCreatesIndependentOrderedWorkspacesWithHistoryAndRestoration() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.testWorkspaceSession.closeAll() }
        let alpha = Host(name: "Alpha", host: "alpha.invalid")
        let bravo = Host(name: "Bravo", host: "bravo.invalid", sshEnabled: false, telnetEnabled: true)
        let charlie = Host(name: "Charlie", host: "charlie.invalid")
        for host in [charlie, alpha, bravo] { app.library.upsert(host) }
        let existing = try #require(app.testWorkspaceSession.open(hostID: alpha.id, kind: .ssh))

        let ids = app.testWorkspaceSession.batchStartup(
            hostIDs: [charlie.id, bravo.id, alpha.id, alpha.id, UUID()], connectionProtocol: .ssh)
        let added = ids.compactMap { id in app.workspaces.first { $0.id == id } }

        #expect(added.map(\.descriptor.hostID) == [alpha.id, bravo.id, charlie.id])
        #expect(added.map(\.descriptor.kind) == [.ssh, .telnet, .ssh])
        #expect(ids.count == 3)
        #expect(!ids.contains(existing))
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.map(\.id) == [existing] + ids)
        #expect(app.testWorkspaceSession.savedWorkspaceDescriptors.map(\.id) == [existing] + ids)
        #expect(app.connectionHistory.entries(for: alpha.id).count == 2)
        #expect(app.connectionHistory.entries(for: bravo.id).map(\.kind) == [.telnet])
        #expect(added.allSatisfy { $0.busy || $0.authenticationRequired })
    }

    @Test func confirmationRechecksProtocolAvailabilityAndAllocatesDistinctNames() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.testWorkspaceSession.closeAll() }
        #expect(app.workspaceSettings.setAutomaticRenaming(true))
        let first = Host(name: "Server", host: "first.invalid")
        let second = Host(name: "Server", host: "second.invalid")
        var changed = Host(name: "Changed", host: "changed.invalid")
        for host in [first, second, changed] { app.library.upsert(host) }
        changed.sshEnabled = false
        changed.telnetEnabled = true
        app.library.upsert(changed)

        let ids = app.testWorkspaceSession.batchStartup(
            hostIDs: [first.id, changed.id, second.id, UUID()], connectionProtocol: .sftp)
        #expect(ids.count == 2)
        #expect(app.workspaces.map(\.descriptor.title) == ["Server", "Server (1)"])
        #expect(app.workspaces.allSatisfy { $0.descriptor.kind == .sftp })
        #expect(app.testWorkspaceSession.batchStartup(hostIDs: [], connectionProtocol: .ssh).isEmpty)
    }

    @Test func sceneDefersStartupUntilDismissalAndKeepsOtherScenesUnchanged() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.testWorkspaceSession.closeAll() }
        let host = Host(name: "Host", host: "host.invalid")
        app.library.upsert(host)
        let first = MobileSceneModel(app: app, sessionID: "test")
        let second = MobileSceneModel(app: app, sessionID: "other")
        defer { second.closeAllWorkspaces() }
        second.open(hostID: host.id, kind: .ssh)
        let otherWorkspace = second.workspaceID

        first.openBatchStartup()
        #expect(first.isBatchStartupPresented)
        #expect(!second.isBatchStartupPresented)
        first.prepareBatchStartup(hostIDs: [host.id], connectionProtocol: .sftp)
        first.prepareBatchStartup(hostIDs: [host.id], connectionProtocol: .ssh)
        #expect(app.workspaces.count == 1)
        first.completeBatchStartup()
        first.completeBatchStartup()
        #expect(app.workspaces.count == 2)
        #expect(first.workspaceSession.workspaces.first?.descriptor.kind == .sftp)
        #expect(first.workspaceSession.workspaces.count == 1)
        #expect(second.workspaceSession.workspaces.count == 1)
        #expect(!first.isBatchStartupPresented)
        #expect(first.selectedDestination == .workspaces)
        #expect(first.workspaceID == nil)
        #expect(second.workspaceID == otherWorkspace)

        first.openBatchStartup()
        first.workspaceSheet = nil
        first.completeBatchStartup()
        #expect(app.workspaces.count == 2)
    }

    @Test func openingTransfersDiscardsAnUnfinishedBatchRequest() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.testWorkspaceSession.closeAll() }
        let host = Host(name: "Host", host: "host.invalid")
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.openBatchStartup()
        scene.prepareBatchStartup(hostIDs: [host.id], connectionProtocol: .ssh)
        scene.openTransfers()
        scene.completeBatchStartup()
        #expect(scene.showsTransfers)
        #expect(scene.workspaceSheet == nil)
        #expect(app.workspaces.isEmpty)

        scene.open(hostID: host.id, kind: .ssh)
        #expect(scene.workspaceID != nil)
        #expect(!scene.showsTransfers)
        scene.openTransfers()
        scene.closeAllWorkspaces()
        #expect(scene.showsTransfers)
        scene.openConnectionPicker()
        #expect(scene.workspaceDestination == nil)
        #expect(scene.workspaceSheet == .connectionPicker)
    }

    @Test func aPreviousSheetDismissalDoesNotCloseTheNewBatchPicker() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.openConnectionPicker()
        scene.openBatchStartup()
        scene.completeBatchStartup()
        #expect(scene.workspaceSheet == .batchStartup)
        #expect(app.workspaces.isEmpty)
    }

    @Test func openingConnectDiscardsAnUnfinishedBatchRequest() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.testWorkspaceSession.closeAll() }
        let host = Host(name: "Host", host: "host.invalid")
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.openBatchStartup()
        scene.prepareBatchStartup(hostIDs: [host.id], connectionProtocol: .ssh)
        scene.openConnectionPicker()
        scene.completeBatchStartup()
        #expect(scene.isConnectionPickerPresented)
        #expect(!scene.isBatchStartupPresented)
        #expect(app.workspaces.isEmpty)
    }
}
