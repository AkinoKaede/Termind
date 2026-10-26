// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct WorkspaceWindowMoveTests {
    @Test
    func splitPaneWaitsForDestinationAndPreservesConnectionsAndHistory() throws {
        let host = Host(name: "Server", host: "server.example")
        let history = ConnectionHistoryModel()
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]), connectionHistory: history)
        let source = WindowModel()
        let target = WindowModel()
        let sourceNative = nativeWindow()
        let targetNative = nativeWindow()
        defer {
            sourceNative.close()
            targetNative.close()
        }
        app.mainWindows.register(sourceNative, model: source, requestID: nil)
        let sftp = SFTPChannelModel.demo(hostID: host.id, path: "/srv")
        let workspace = Workspace(pane: Pane(.sftpChannel(sftp)))
        let remaining = workspace.focusedPane
        let moved = Pane.sshSession(host: host)
        moved.customTitle = "Build"
        let input = moved.terminalInputArea
        input.draft = "unsubmitted request"
        input.mode = .commandGenerator
        workspace.splitFocusedPane(axis: .horizontal, with: moved)
        source.open(workspace)
        let ssh = try #require(moved.sshSession)
        ssh.status = .connected
        let historyIDs = Set(history.entries().map(\.id))
        #expect(historyIDs.count == 2)
        var created: [UUID] = []
        app.mainWindows.createScene = { created.append($0) }

        let request = try #require(app.mainWindows.movePane(moved.id, from: source))
        #expect(app.mainWindows.movePane(moved.id, from: source) == request)
        #expect(created == [request])
        #expect(workspace.panes.count == 2)
        #expect(workspace.focusedPane === moved)
        #expect(source.sidebar.sessionContext.workingDirectory == nil)
        #expect(target.workspaces.isEmpty)

        app.mainWindows.register(targetNative, model: target, requestID: request)
        let received = try #require(target.selectedWorkspace)
        #expect(received !== workspace)
        #expect(received.focusedPane === moved)
        #expect(received.focusedPane.terminalInputArea === input)
        #expect(input.draft == "unsubmitted request" && input.mode == .commandGenerator)
        #expect(received.lifecycleRouter === target)
        #expect(moved.customTitle == "Build")
        #expect(source.selectedWorkspace === workspace)
        #expect(workspace.focusedPane === remaining)
        #expect(workspace.lifecycleRouter === source)
        #expect(source.sidebar.sessionContext.workingDirectory == "/srv")
        #expect(target.sidebar.sessionContext.workingDirectory == nil)
        #expect(app.closedWorkspaceRecords.isEmpty)
        #expect(ssh.status == .connected && sftp.status == .connected)
        #expect(sftp.path == "/srv")
        #expect(Set(history.entries().map(\.id)) == historyIDs)
        #expect(history.entries().allSatisfy { $0.endedAt == nil })

        app.mainWindows.register(targetNative, model: target, requestID: request)
        #expect(target.workspaces.count == 1)
        sourceNative.close()
        #expect(ssh.status == .connected)
        #expect(sftp.status == .disconnected)
        #expect(history.entries().first { $0.kind == .ssh }?.endedAt == nil)
        #expect(history.entries().first { $0.kind == .sftp }?.endedAt != nil)
        targetNative.close()
        #expect(ssh.status == .disconnected)
        #expect(history.entries().allSatisfy { $0.endedAt != nil })
    }

    @Test
    func lonePaneCarriesItsOriginalWorkspaceAndName() throws {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        workspace.automaticTitle = "Production 2"
        workspace.focusedPane.customTitle = "Build"
        workspace.sourceTemplateID = UUID()
        let source = WindowModel(workspaces: [workspace])
        let target = WindowModel()
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let native = nativeWindow()
        defer {
            source.closeForWindow()
            native.close()
        }

        let request = try #require(app.mainWindows.movePane(workspace.focusedPaneID, from: source))
        #expect(source.selectedWorkspace === workspace)
        app.mainWindows.register(native, model: target, requestID: request)

        #expect(target.selectedWorkspace === workspace)
        #expect(workspace.automaticTitle == "Production 2")
        #expect(workspace.focusedPane.customTitle == "Build")
        #expect(workspace.sourceTemplateID != nil)
        #expect(source.workspaces.isEmpty)
        #expect(source.selectedDestination == .vault)
        #expect(source.vaultDestination == .welcome)
        #expect(app.closedWorkspaceRecords.isEmpty)
    }

    @Test(arguments: [false, true])
    func aClosedPaneOrWindowCannotBeResurrectedByLateRegistration(closesWindow: Bool) throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let moved = Pane.sshSession(host: host)
        workspace.splitFocusedPane(axis: .horizontal, with: moved)
        let session = try #require(moved.sshSession)
        session.status = .connected
        let source = WindowModel(workspaces: [workspace])
        let target = WindowModel()
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let sourceNative = nativeWindow()
        let targetNative = nativeWindow()
        defer {
            sourceNative.close()
            targetNative.close()
        }
        app.mainWindows.register(sourceNative, model: source, requestID: nil)
        let request = try #require(app.mainWindows.movePane(moved.id, from: source))

        if closesWindow {
            sourceNative.close()
        } else {
            source.closeSelected()
        }
        app.mainWindows.register(targetNative, model: target, requestID: request)

        #expect(session.status == .disconnected)
        #expect(target.workspaces.isEmpty)
        #expect(source.pane(moved.id) == nil)
        #expect(app.closedWorkspaceRecords.first?.isWindow == closesWindow)
        #expect(app.mainWindows.movePane(moved.id, from: source) == nil)
        if !closesWindow {
            app.reopenClosedRecord(try #require(app.closedWorkspaceRecords.first?.id), in: source)
            #expect(source.selectedWorkspace?.focusedPane.id == moved.id)
            #expect(source.selectedWorkspace?.focusedPane.sshSession !== session)
            #expect(target.workspaces.isEmpty)
        }
    }

    @Test
    func missingFactoryAndInvalidPanesNeverChangeTheSource() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let empty = Pane(.empty)
        workspace.splitFocusedPane(axis: .horizontal, with: empty)
        let source = WindowModel(workspaces: [workspace])
        defer { source.closeForWindow() }
        let app = AppModel(hosts: HostLibraryModel())
        let pane = workspace.layout.firstPane

        #expect(app.mainWindows.movePane(pane.id, from: source) == nil)
        var created: [UUID] = []
        app.mainWindows.createScene = { created.append($0) }
        #expect(app.mainWindows.movePane(UUID(), from: source) == nil)
        #expect(app.mainWindows.movePane(empty.id, from: source) == nil)
        #expect(created.isEmpty)
        #expect(workspace.panes.count == 2)
        #expect(workspace.layout.firstPane === pane)
        #expect(source.selectedWorkspace === workspace)
    }

    @Test
    func concurrentPaneMovesCanArriveInReverseRequestOrder() throws {
        let host = Host(name: "Server", host: "server.example")
        let workspace = Workspace.sshSession(host: host)
        let firstPane = workspace.focusedPane
        let secondPane = Pane.sshSession(host: host)
        workspace.splitFocusedPane(axis: .horizontal, with: secondPane)
        let source = WindowModel(workspaces: [workspace])
        let first = WindowModel()
        let second = WindowModel()
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let firstNative = nativeWindow()
        let secondNative = nativeWindow()
        defer {
            source.closeForWindow()
            firstNative.close()
            secondNative.close()
        }

        let firstRequest = try #require(app.mainWindows.movePane(firstPane.id, from: source))
        let secondRequest = try #require(app.mainWindows.movePane(secondPane.id, from: source))
        #expect(firstRequest != secondRequest)
        app.mainWindows.register(secondNative, model: second, requestID: secondRequest)
        #expect(source.selectedWorkspace === workspace)
        #expect(workspace.focusedPane === firstPane)
        app.mainWindows.register(firstNative, model: first, requestID: firstRequest)

        #expect(first.selectedWorkspace === workspace)
        #expect(first.selectedWorkspace?.focusedPane === firstPane)
        #expect(second.selectedWorkspace?.focusedPane === secondPane)
        #expect(source.workspaces.isEmpty)
        #expect(app.closedWorkspaceRecords.isEmpty)
    }

    @Test(arguments: [false, true])
    func releasedWindowUsesTheDropScreenAndSourcesOrdinarySize(movesPane: Bool) throws {
        let screen = try #require(NSScreen.screens.last)
        let normalSize = CGSize(width: 900, height: 600)
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let source = WindowModel(workspaces: [workspace])
        source.sidebar.preferredWidth = 472
        source.showsSidebar = false
        let target = WindowModel()
        let sourceNative = nativeWindow(size: normalSize)
        let targetNative = nativeWindow()
        defer {
            sourceNative.close()
            targetNative.close()
        }
        app.mainWindows.register(sourceNative, model: source, requestID: nil)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: sourceNative)
        sourceNative.setContentSize(CGSize(width: 1300, height: 800))
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: sourceNative)
        let point = CGPoint(x: screen.visibleFrame.maxX - 4, y: screen.visibleFrame.maxY - 4)
        let request = try #require(
            movesPane
                ? app.mainWindows.movePane(workspace.focusedPaneID, from: source, at: point)
                : app.mainWindows.moveWorkspace(workspace.id, from: source, at: point))
        let layout = try #require(app.mainWindows.requestedLayout(for: request))
        #expect(layout.isFullScreen)
        #expect(layout.size == normalSize)
        #expect(layout.sidebarWidth == 472)
        #expect(!layout.showsSidebar)

        app.mainWindows.register(targetNative, model: target, requestID: request)

        #expect(target.selectedWorkspace === workspace)
        #expect(target.sidebar.preferredWidth == 472)
        #expect(!target.showsSidebar)
        #expect(targetNative.frame.size.width == min(normalSize.width, screen.visibleFrame.width))
        #expect(targetNative.frame.size.height == min(normalSize.height, screen.visibleFrame.height))
        #expect(targetNative.frame.maxX == screen.visibleFrame.maxX)
        #expect(targetNative.frame.maxY == max(point.y, screen.visibleFrame.minY + targetNative.frame.height))
        #expect(screen.visibleFrame.contains(targetNative.frame))
    }

    private func nativeWindow(size: CGSize = CGSize(width: 800, height: 600)) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 150, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }
}
