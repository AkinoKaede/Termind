// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct WorkspaceLayoutDropTests {
    private let size = CGSize(width: 400, height: 240)
    private let trailingPoint = CGPoint(x: 390, y: 120)

    private func workspace(_ name: String) -> Workspace {
        Workspace.sshSession(host: Host(name: name, host: "\(name.lowercased()).example.invalid"))
    }

    private func receiver(window: WindowModel, workspace: Workspace, pane: Pane) -> WorkspaceLayoutDropNSView {
        let controller = PaneLayoutDropController(window: window, workspace: workspace, pane: pane)
        let receiver = WorkspaceLayoutDropNSView(frame: CGRect(origin: .zero, size: size))
        receiver.draggedID = { controller.draggedID }
        receiver.preview = { point, size in controller.preview(at: point, in: size) }
        receiver.perform = { point, size in controller.perform(at: point, in: size) }
        return receiver
    }

    private func pasteboard(for id: UUID) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString(id.uuidString, forType: .string)
        return pasteboard
    }

    /// Configure the native destinations before pickup, then enter AppKit's
    /// callbacks without another SwiftUI render or representable update.
    @Test(arguments: ["leading", "trailing", "top", "bottom"])
    func selectedWorkspaceDragImmediatelyPreviewsAndMergesIntoItsNeighbour(edge: String) {
        let source = workspace("Source")
        let target = workspace("Target")
        let hidden = workspace("Hidden")
        let sourcePane = source.focusedPane
        let targetPane = target.focusedPane
        let window = WindowModel(workspaces: [source, target, hidden])
        window.select(source.id)
        let sourceReceiver = receiver(window: window, workspace: source, pane: sourcePane)
        let targetReceiver = receiver(window: window, workspace: target, pane: targetPane)
        let hiddenReceiver = receiver(window: window, workspace: hidden, pane: hidden.focusedPane)
        let pasteboard = pasteboard(for: source.id)
        defer { pasteboard.releaseGlobally() }

        let point: CGPoint
        let expectedPreview: CGRect
        let expectedAxis: SplitAxis
        let expectedPanes: [UUID]
        switch edge {
        case "leading":
            point = CGPoint(x: 10, y: 120)
            expectedPreview = CGRect(x: 0, y: 0, width: 200, height: 240)
            expectedAxis = .horizontal
            expectedPanes = [sourcePane.id, targetPane.id]
        case "trailing":
            point = trailingPoint
            expectedPreview = CGRect(x: 200, y: 0, width: 200, height: 240)
            expectedAxis = .horizontal
            expectedPanes = [targetPane.id, sourcePane.id]
        case "top":
            point = CGPoint(x: 200, y: 10)
            expectedPreview = CGRect(x: 0, y: 0, width: 400, height: 120)
            expectedAxis = .vertical
            expectedPanes = [sourcePane.id, targetPane.id]
        default:
            point = CGPoint(x: 200, y: 230)
            expectedPreview = CGRect(x: 0, y: 120, width: 400, height: 120)
            expectedAxis = .vertical
            expectedPanes = [targetPane.id, sourcePane.id]
        }

        #expect(window.dragging == nil)
        #expect(targetReceiver.registeredDraggedTypes.contains(.string))
        #expect(targetReceiver.update(at: point, pasteboard: pasteboard).isEmpty)
        window.dragging = .workspace(source.id)

        #expect(window.displayedWorkspace === target)
        for inactive in [sourceReceiver, hiddenReceiver] {
            #expect(inactive.update(at: point, pasteboard: pasteboard).isEmpty)
            #expect(inactive.previewRect == nil)
            #expect(!inactive.receive(at: point, pasteboard: pasteboard))
            #expect(window.dragging == .workspace(source.id))
        }
        #expect(
            targetReceiver.participates(at: point, currentEventType: .leftMouseDragged, pasteboard: pasteboard))
        #expect(targetReceiver.update(at: point, pasteboard: pasteboard) == .move)
        #expect(targetReceiver.previewRect == expectedPreview)
        #expect(targetReceiver.receive(at: point, pasteboard: pasteboard))

        #expect(window.workspaces.map(\.id) == [target.id, hidden.id])
        #expect(target.panes.map(\.id) == expectedPanes)
        #expect(target.layout.pane(sourcePane.id) === sourcePane)
        #expect(target.layout.pane(targetPane.id) === targetPane)
        guard case .split(let branch) = target.layout else {
            Issue.record("A workspace dropped on an edge must create a split")
            return
        }
        #expect(branch.axis == expectedAxis)
        #expect(branch.fraction == 0.5)
        #expect(window.selectedWorkspace === target)
        #expect(window.dragging == nil)
        #expect(targetReceiver.previewRect == nil)
    }

    @Test
    func destinationHiddenAfterHoverRejectsTheDropWithoutAReceiverUpdate() {
        let source = workspace("Source")
        let target = workspace("Target")
        let window = WindowModel(workspaces: [target, source])
        window.select(target.id)
        let receiver = receiver(window: window, workspace: target, pane: target.focusedPane)
        let pasteboard = pasteboard(for: source.id)
        defer { pasteboard.releaseGlobally() }
        window.dragging = .workspace(source.id)
        #expect(receiver.update(at: trailingPoint, pasteboard: pasteboard) == .move)
        #expect(receiver.previewRect != nil)

        // AppKit may already have chosen this destination when another
        // surface takes the foreground. Release must recheck its live owner.
        window.selectVault()

        #expect(!receiver.receive(at: trailingPoint, pasteboard: pasteboard))
        #expect(receiver.previewRect == nil)
        #expect(window.workspaces.map(\.id) == [target.id, source.id])
        #expect(target.panes.count == 1)
        #expect(window.dragging == .workspace(source.id))
    }

    @Test
    func paneDragRearrangesTheLiveLayoutWithoutReconfiguringTheReceiver() {
        let workspace = workspace("First")
        let sourcePane = workspace.focusedPane
        workspace.splitFocusedPane(
            axis: .vertical, with: .sshSession(host: Host(name: "Second", host: "second.example.invalid")))
        let targetPane = workspace.focusedPane
        let window = WindowModel(workspaces: [workspace])
        window.select(workspace.id)
        let sourceReceiver = receiver(window: window, workspace: workspace, pane: sourcePane)
        let targetReceiver = receiver(window: window, workspace: workspace, pane: targetPane)
        let pasteboard = pasteboard(for: sourcePane.id)
        defer { pasteboard.releaseGlobally() }

        #expect(window.dragging == nil)
        window.dragging = .pane(sourcePane.id)

        #expect(!sourceReceiver.receive(at: trailingPoint, pasteboard: pasteboard))
        #expect(window.dragging == .pane(sourcePane.id))
        #expect(targetReceiver.update(at: trailingPoint, pasteboard: pasteboard) == .move)
        #expect(targetReceiver.previewRect == CGRect(x: 200, y: 0, width: 200, height: 240))
        #expect(targetReceiver.receive(at: trailingPoint, pasteboard: pasteboard))

        #expect(window.workspaces.map(\.id) == [workspace.id])
        #expect(workspace.panes.map(\.id) == [targetPane.id, sourcePane.id])
        #expect(workspace.focusedPane === sourcePane)
        guard case .split(let branch) = workspace.layout else {
            Issue.record("Rearranging the two panes must preserve a split")
            return
        }
        #expect(branch.axis == .horizontal)
        #expect(window.dragging == nil)
        #expect(targetReceiver.previewRect == nil)
    }

    @Test(arguments: [true, false])
    func emptySlotReplacesItsWholeAreaForWorkspaceAndPaneDrags(dragWorkspace: Bool) {
        let source = workspace("Source")
        let sourcePane = source.focusedPane
        let target = dragWorkspace ? workspace("Target") : source
        let retainedPane = target.focusedPane
        target.splitFocusedPane(axis: .horizontal, with: Pane(.empty))
        let slot = target.focusedPane
        let window = WindowModel(workspaces: dragWorkspace ? [target, source] : [target])
        window.select(target.id)
        let receiver = receiver(window: window, workspace: target, pane: slot)
        let draggedID = dragWorkspace ? source.id : sourcePane.id
        let pasteboard = pasteboard(for: draggedID)
        defer { pasteboard.releaseGlobally() }

        #expect(window.dragging == nil)
        window.dragging = dragWorkspace ? .workspace(source.id) : .pane(sourcePane.id)

        #expect(receiver.update(at: trailingPoint, pasteboard: pasteboard) == .move)
        #expect(receiver.previewRect == CGRect(origin: .zero, size: size))
        #expect(receiver.receive(at: trailingPoint, pasteboard: pasteboard))

        #expect(window.workspaces.map(\.id) == [target.id])
        #expect(target.panes.map(\.id) == (dragWorkspace ? [retainedPane.id, sourcePane.id] : [sourcePane.id]))
        #expect(target.layout.pane(slot.id) == nil)
        #expect(target.layout.pane(sourcePane.id) === sourcePane)
        #expect(window.dragging == nil)
        #expect(receiver.previewRect == nil)
    }

    @Test(arguments: ["text", "unrelatedUUID", "file"])
    func cancelledDragStateDoesNotMakeAnExternalPayloadRearrangeWorkspaces(payload: String) {
        let source = workspace("Source")
        let target = workspace("Target")
        let window = WindowModel(workspaces: [target, source])
        window.select(target.id)
        let receiver = receiver(window: window, workspace: target, pane: target.focusedPane)
        let pasteboard = pasteboard(for: source.id)
        defer { pasteboard.releaseGlobally() }
        window.dragging = .workspace(source.id)
        #expect(receiver.update(at: trailingPoint, pasteboard: pasteboard) == .move)
        #expect(receiver.previewRect != nil)

        // A release outside the window can leave this model payload behind.
        // The next external drag must still be checked against its own data.
        pasteboard.clearContents()
        switch payload {
        case "text": pasteboard.setString("Text from another application", forType: .string)
        case "unrelatedUUID": pasteboard.setString(UUID().uuidString, forType: .string)
        default: pasteboard.setString("file:///tmp/workspace-drop-test.txt", forType: .fileURL)
        }

        #expect(
            !receiver.participates(
                at: trailingPoint, currentEventType: .leftMouseDragged, pasteboard: pasteboard))
        #expect(receiver.update(at: trailingPoint, pasteboard: pasteboard).isEmpty)
        #expect(receiver.previewRect == nil)
        #expect(!receiver.receive(at: trailingPoint, pasteboard: pasteboard))
        #expect(window.workspaces.map(\.id) == [target.id, source.id])
        #expect(target.panes.count == 1)
        #expect(window.dragging == .workspace(source.id))
    }

    @Test
    func endingTheSourceSessionClearsPreviewWithoutAnotherDragEvent() {
        let source = workspace("Source")
        let target = workspace("Target")
        let window = WindowModel(workspaces: [target, source])
        window.select(target.id)
        let receiver = receiver(window: window, workspace: target, pane: target.focusedPane)
        let pasteboard = pasteboard(for: source.id)
        defer { pasteboard.releaseGlobally() }
        window.dragging = .workspace(source.id)
        #expect(receiver.update(at: trailingPoint, pasteboard: pasteboard) == .move)
        #expect(receiver.previewRect != nil)

        window.dragging = nil
        receiver.clearPreviewIfInactive()

        #expect(receiver.previewRect == nil)
        #expect(window.workspaces.map(\.id) == [target.id, source.id])
    }

    @Test
    func assistantConversationUUIDNeverBecomesAWorkspaceLayoutDrop() {
        let workspace = workspace("Target")
        let window = WindowModel(workspaces: [workspace])
        window.select(workspace.id)
        let receiver = receiver(window: window, workspace: workspace, pane: workspace.focusedPane)
        let conversationID = UUID()
        let pasteboard = pasteboard(for: conversationID)
        defer { pasteboard.releaseGlobally() }
        window.dragging = .assistantConversation(conversationID)

        #expect(
            !receiver.participates(
                at: trailingPoint, currentEventType: .leftMouseDragged, pasteboard: pasteboard))
        #expect(receiver.update(at: trailingPoint, pasteboard: pasteboard).isEmpty)
        #expect(!receiver.receive(at: trailingPoint, pasteboard: pasteboard))
        #expect(receiver.previewRect == nil)
        #expect(window.dragging == .assistantConversation(conversationID))
        #expect(workspace.panes.count == 1)
    }

    @Test(arguments: [
        NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .mouseMoved, .cursorUpdate, .scrollWheel,
    ])
    func matchingStaleUUIDDoesNotInterceptOrdinaryPointerEvents(event: NSEvent.EventType) {
        let source = workspace("Source")
        let target = workspace("Target")
        let window = WindowModel(workspaces: [target, source])
        window.select(target.id)
        let receiver = receiver(window: window, workspace: target, pane: target.focusedPane)
        let pasteboard = pasteboard(for: source.id)
        defer { pasteboard.releaseGlobally() }
        window.dragging = .workspace(source.id)

        #expect(!receiver.participates(at: trailingPoint, currentEventType: event, pasteboard: pasteboard))
        #expect(
            !receiver.participates(
                at: CGPoint(x: 500, y: 120), currentEventType: .leftMouseDragged, pasteboard: pasteboard))
        #expect(receiver.previewRect == nil)
        #expect(window.workspaces.map(\.id) == [target.id, source.id])
    }
}
