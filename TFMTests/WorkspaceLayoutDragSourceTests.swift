// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindDomain
import Testing

@testable import Termind

@Suite
@MainActor
struct WorkspaceLayoutDragSourceTests {
    private let sourceFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    private let otherFrame = CGRect(x: 800, y: 100, width: 600, height: 400)
    private let outside = CGPoint(x: 740, y: 260)

    @Test
    func releasingOutsideTheSourceTearsOffAndClearsTheLivePayload() {
        let model = WindowModel()
        let source = source(model: model)
        var received: CGPoint?
        source.onTearOff = {
            received = $0
            #expect(model.dragging == source.payload)
        }

        #expect(source.beginTracking())
        finish(source, at: outside)

        #expect(received == outside)
        #expect(model.dragging == nil)
        finish(source, at: outside)
        #expect(received == outside)
    }

    @Test
    func releasingWithinTheSourceWindowDoesNotTearOff() {
        let model = WindowModel()
        let source = source(model: model)
        source.onTearOff = { _ in Issue.record("A release inside the source window must not create a window") }
        #expect(source.beginTracking())

        finish(source, at: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY))

        #expect(model.dragging == nil)
    }

    @Test
    func anUnhandledReleaseOverAnotherWindowStillTearsOff() {
        let model = WindowModel()
        let source = source(model: model)
        let point = CGPoint(x: otherFrame.midX, y: otherFrame.midY)
        var received: CGPoint?
        source.onTearOff = { received = $0 }
        #expect(source.beginTracking())

        finish(source, at: point)

        #expect(received == point)
        #expect(model.dragging == nil)
    }

    @Test
    func acceptedDropsAndCancelledDragsNeverTearOff() {
        let model = WindowModel()
        let source = source(model: model)
        source.onTearOff = { _ in Issue.record("An accepted or cancelled drag must not create a window") }

        #expect(source.beginTracking())
        finish(source, at: outside, operation: .move)
        #expect(model.dragging == nil)

        #expect(source.beginTracking())
        finish(source, at: outside, primaryButtonPressed: true)
        #expect(model.dragging == nil)

        #expect(source.beginTracking())
        finish(source, at: outside, currentEventIsEscape: true)
        #expect(model.dragging == nil)
    }

    @Test
    func consumedOrReplacedPayloadDoesNotTearOffOrClearAnotherDrag() {
        let model = WindowModel()
        let source = source(model: model)
        source.onTearOff = { _ in Issue.record("A consumed payload cannot be moved again") }

        #expect(source.beginTracking())
        model.dragging = nil
        finish(source, at: outside)
        #expect(model.dragging == nil)

        #expect(source.beginTracking())
        let replacement = DragPayload.pane(UUID())
        model.dragging = replacement
        finish(source, at: outside)
        #expect(model.dragging == replacement)
    }

    @Test
    func sourceStaysTransparentAndRemovesItsRecognizerWhenDetached() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = root
        let model = WindowModel()
        let source = source(model: model)
        source.frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        root.addSubview(source)

        #expect(!window.isVisible)
        #expect(source.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(source.panRecognizer.view === root)
        #expect(!source.panRecognizer.delaysPrimaryMouseButtonEvents)
        #expect(!source.panRecognizer.delaysSecondaryMouseButtonEvents)
        #expect(!source.panRecognizer.delaysKeyEvents)
        #expect(source.beginTracking())

        source.removeFromSuperview()

        #expect(source.panRecognizer.view == nil)
        #expect(root.gestureRecognizers.isEmpty)
        #expect(model.dragging == nil)
    }

    @Test
    func hiddenSourcesAndTrailingControlsCannotStartDrags() {
        let model = WindowModel()
        let source = source(model: model)
        source.frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        source.excludedTrailingWidth = 30

        #expect(source.acceptsDragStart(at: CGPoint(x: 20, y: 16)))
        #expect(!source.acceptsDragStart(at: CGPoint(x: 185, y: 16)))
        #expect(!source.acceptsDragStart(at: CGPoint(x: 20, y: 40)))

        source.isHidden = true

        #expect(!source.acceptsDragStart(at: CGPoint(x: 20, y: 16)))
    }

    @Test
    func parkedPaneSourcesCannotStartDragsOverTheSelectedWorkspaceOrVault() {
        let model = WindowModel()
        let source = source(model: model)
        let workspace = model.workspaces[0]
        source.payload = .pane(workspace.focusedPaneID)
        #expect(source.isEligible)
        model.open(Workspace.sshSession(host: Host(name: "Other", host: "other.example.invalid")))

        #expect(!source.isEligible)
        #expect(!source.beginTracking())

        model.select(workspace.id)
        #expect(source.isEligible)

        model.selectVault()
        #expect(!source.isEligible)
        #expect(!source.beginTracking())
    }

    @Test
    func workspaceSourceRequiresTheVisibleNavigator() {
        let model = WindowModel()
        let source = source(model: model)
        #expect(source.isEligible)

        model.sidebarMode = .assistant
        #expect(!source.isEligible)

        model.sidebarMode = .navigation
        model.sidebar.isPresented = false
        #expect(!source.isEligible)

        model.sidebar.isPresented = true
        #expect(source.isEligible)
        model.closeForWindow()
        #expect(!source.isEligible)
    }

    private func source(model: WindowModel) -> WorkspaceLayoutDragSourceNSView {
        let workspace = model.open(Workspace.sshSession(host: Host(name: "Source", host: "source.example.invalid")))
        let source = WorkspaceLayoutDragSourceNSView()
        source.model = model
        source.payload = .workspace(workspace.id)
        return source
    }

    private func finish(
        _ source: WorkspaceLayoutDragSourceNSView,
        at point: CGPoint,
        operation: NSDragOperation = [],
        primaryButtonPressed: Bool = false,
        currentEventIsEscape: Bool = false
    ) {
        source.finishTracking(
            at: point, operation: operation,
            primaryButtonPressed: primaryButtonPressed, currentEventIsEscape: currentEventIsEscape,
            windowFrames: [sourceFrame]
        )
    }
}
