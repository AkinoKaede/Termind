import AppKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct ClosedWorkspaceRestoreTests {
    @Test func restartKeepsClosedSplitsInOneRecentList() throws {
        let name = "ClosedWorkspace.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let host = Host(name: "Server", host: "server.example")
        let hosts = HostLibraryModel(hosts: [host])
        let dependencies = AppDependencies(
            hostRepository: AppDependencies.inMemory(hosts: [host], groups: []).hostRepository, outboxRunner: nil,
            settingsDefaults: defaults)
        let firstApp = AppModel(hosts: hosts, dependencies: dependencies)
        let workspace = Workspace.sshSession(host: host)
        workspace.focusedPane.customTitle = "Shell"
        workspace.splitFocusedPane(axis: .vertical, with: .sftpChannel(host: host))
        workspace.focusedPane.customTitle = "Files"
        workspace.customTitle = "Operations"
        let original = WindowModel(workspaces: [workspace])
        firstApp.registerWindow(original)
        original.close(workspace.id)
        original.closeForWindow()

        let nextApp = AppModel(hosts: hosts, dependencies: dependencies)
        let window = WindowModel()
        nextApp.registerWindow(window)
        #expect(window.recentlyClosedWorkspaces.isEmpty)
        #expect(window.closedHistory().flatMap(\.items).map(\.title) == ["Operations"])
        #expect(window.canReopen)
        let current = Workspace.sshSession(host: host)
        window.open(current)
        window.close(current.id)
        #expect(window.closedHistory().count == 2)
        window.reopenLastClosed()
        #expect(window.selectedWorkspace === current)
        window.reopenLastClosed()
        let restored = try #require(window.selectedWorkspace)
        #expect(restored !== workspace)
        #expect(restored.panes.map(\.kind) == [.sshSession, .sftpChannel])
        #expect(restored.panes.map(\.customTitle) == ["Shell", "Files"])
        #expect(restored.customTitle == "Operations")
        #expect(restored.focusedPane.kind == .sftpChannel)
        #expect(!window.canReopen)
        let thirdApp = AppModel(hosts: hosts, dependencies: dependencies)
        let thirdWindow = WindowModel()
        thirdApp.registerWindow(thirdWindow)
        #expect(!thirdWindow.canReopen)
    }

    @Test func closingAWindowCreatesOneGroupAndReopenWaitsForANewWindow() throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let first = Workspace.sshSession(host: host)
        first.splitFocusedPane(axis: .vertical, with: .sftpChannel(host: host))
        let second = Workspace(pane: .sftpChannel(host: host))
        let source = WindowModel(workspaces: [first, second])
        source.select(first.id)
        app.registerWindow(source)
        source.closeForWindow()
        let record = try #require(app.closedWorkspaceRecords.first)
        #expect(record.isWindow)
        #expect(record.items.map(\.id) == [first.id, second.id])
        #expect(app.closedWorkspaceRecords.count == 1)
        let current = WindowModel()
        app.registerWindow(current)
        #expect(current.reopensWindow)
        var requests: [UUID] = []
        app.mainWindows.createScene = { requests.append($0) }
        current.reopenLastClosed()
        current.reopenLastClosed()
        #expect(requests.count == 1)
        #expect(current.workspaces.isEmpty)
        #expect(app.closedWorkspaceRecords.count == 1)
        let destination = WindowModel()
        let native = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        native.isReleasedWhenClosed = false
        defer { native.close() }
        let requestID = try #require(requests.first)
        app.mainWindows.register(native, model: destination, requestID: requestID)
        #expect(destination.workspaces.map(\.id) == [first.id, second.id])
        #expect(destination.selectedWorkspace === first)
        #expect(first.panes.count == 2)
        #expect(app.closedWorkspaceRecords.isEmpty)
    }

    @Test func selectingAWindowChildRestoresOnlyThatWorkspaceAndKeepsTheRest() throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let first = Workspace.sshSession(host: host)
        let second = Workspace(pane: .sftpChannel(host: host))
        let source = WindowModel(workspaces: [first, second])
        app.registerWindow(source)
        source.closeForWindow()
        let id = try #require(app.closedWorkspaceRecords.first?.id)
        let destination = WindowModel()
        app.registerWindow(destination)
        app.restoreClosedRecord(id, into: destination, itemID: first.id)
        #expect(destination.selectedWorkspace === first)
        #expect(app.closedWorkspaceRecords.first?.items.map(\.id) == [second.id])
        #expect(destination.reopensWindow)
    }

    @Test func missingHostsAreNotOfferedAfterRestart() throws {
        let host = Host(name: "Server", host: "server.example")
        let record = ClosedWorkspaceRecord(.sshSession(host: host), hosts: HostLibraryModel(hosts: [host]))
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        app.registerWindow(window)
        app.recentlyClosedStore.record(RecentlyClosedRecord(items: [record]))
        #expect(!window.canReopen)
        window.reopenClosedWorkspace(record.id)
        #expect(window.workspaces.isEmpty)
    }
}
