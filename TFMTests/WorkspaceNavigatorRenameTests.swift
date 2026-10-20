// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct WorkspaceNavigatorRenameTests {
    @Test func contextMenuRenameStartsWithTheCompleteWorkspaceTitle() async throws {
        let fixture = WorkspaceNavigatorRenameFixture()
        defer { fixture.close() }
        try await fixture.prepare()

        let (_, menu) = try fixture.workspaceMenu()
        let renameIndex = try #require(menu.items.firstIndex { $0.title == "Rename" })
        menu.performActionForItem(at: renameIndex)

        try await fixture.expectCompleteTitle()
    }

    @Test func doubleClickRenameStartsWithTheCompleteWorkspaceTitle() async throws {
        let fixture = WorkspaceNavigatorRenameFixture()
        defer { fixture.close() }
        try await fixture.prepare()

        let (menuView, _) = try fixture.workspaceMenu()
        fixture.doubleClick(menuView)

        try await fixture.expectCompleteTitle()
    }
}

@MainActor
private final class WorkspaceNavigatorRenameFixture {
    private let title = "Production Workspace"
    private let app: AppModel
    private let controller: NSHostingController<AnyView>
    private let window: NSWindow

    init() {
        let host = TermindDomain.Host(name: title, host: "workspace.invalid")
        app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let navigation = WindowModel(workspaces: [.sshSession(host: host)])
        controller = NSHostingController(
            rootView: AnyView(
                WorkspaceNavigatorView()
                    .environment(app)
                    .environment(navigation)
                    .environment(\.locale, Locale(identifier: "en"))
                    .frame(width: 280, height: 640)
            ))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? .zero
    }

    func prepare() async throws {
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()
    }

    func workspaceMenu() throws -> (NativeRowContextMenu.RowMenuView, NSMenu) {
        for menuView in descendants(of: controller.view).compactMap({ $0 as? NativeRowContextMenu.RowMenuView }) {
            guard let menu = menuView.makeMenu() else { continue }
            let titles = Set(menu.items.map(\.title))
            if titles.contains("Save Workspace Template"), titles.contains("Rename") {
                return (menuView, menu)
            }
        }
        Issue.record("Workspace row context menu was not found")
        throw WorkspaceNavigatorRenameFixtureError.missingWorkspaceMenu
    }

    func doubleClick(_ view: NSView) {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        sendMouseEvent(.leftMouseDown, at: location, clickCount: 1, timestamp: 1)
        sendMouseEvent(.leftMouseUp, at: location, clickCount: 1, timestamp: 1.05)
        sendMouseEvent(.leftMouseDown, at: location, clickCount: 2, timestamp: 1.1)
        sendMouseEvent(.leftMouseUp, at: location, clickCount: 2, timestamp: 1.15)
    }

    func expectCompleteTitle() async throws {
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
        // SidebarInlineRenameField selects its initial value when it receives focus. The
        // Workspace regression was constructing that field before this full title arrived.
        _ = try #require(
            descendants(of: controller.view).compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.stringValue == title })
    }

    func close() {
        app.shutdownForTermination()
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    private func sendMouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        clickCount: Int,
        timestamp: TimeInterval
    ) {
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
        else {
            Issue.record("Could not create a synthetic mouse event")
            return
        }
        window.sendEvent(event)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private enum WorkspaceNavigatorRenameFixtureError: Error {
    case missingWorkspaceMenu
}
