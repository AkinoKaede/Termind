// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct TerminalSidebarInsertionTests {
    @Test(arguments: [WindowSidebarState.Mode.snippets, .history], [false, true])
    func clicksAndMenusInsertOnlyIntoTheFocusedDraft(
        mode: WindowSidebarState.Mode, usesMenu: Bool
    ) async throws {
        let fixture = TerminalSidebarInsertionFixture(mode: mode)
        defer { fixture.close() }
        try await fixture.prepare()
        fixture.source.terminalInputArea.draft = "echo old tail"
        fixture.source.terminalInputArea.mode = .commandGenerator
        await fixture.layout()
        let editor = try fixture.focusEditor()
        editor.setSelectedRange(NSRange(location: 5, length: 3))

        try fixture.insert(usesMenu: usesMenu)
        await fixture.settleClick()

        #expect(fixture.source.terminalInputArea.draft == "echo hostname tail")
        #expect(fixture.source.terminalInputArea.mode == .commandGenerator)
        #expect(!fixture.source.terminalInputArea.isGenerating)
        #expect(editor.selectedRange() == NSRange(location: 13, length: 0))
        #expect(fixture.window.firstResponder === editor)
        #expect(fixture.other.terminalInputArea.draft.isEmpty)
        #expect(fixture.sourceWrites.isEmpty && fixture.otherWrites.isEmpty)

        fixture.source.terminalInputArea.mode = .input
        #expect(
            fixture.source.terminalInputArea.submit {
                try fixture.workspace.submitInputArea($0, from: fixture.source)
            })
        #expect(fixture.sourceWrites == [Data("echo hostname tail\r".utf8)])
        #expect(fixture.otherWrites == fixture.sourceWrites)
    }

    @Test(arguments: [WindowSidebarState.Mode.snippets, .history], [false, true])
    func terminalFocusedInsertionKeepsTheExistingBroadcastPath(
        mode: WindowSidebarState.Mode, usesMenu: Bool
    ) async throws {
        let fixture = TerminalSidebarInsertionFixture(mode: mode)
        defer { fixture.close() }
        try await fixture.prepare()
        fixture.source.terminalInputArea.draft = "keep my draft"
        fixture.source.sshSession?.requestTerminalFocus()
        await fixture.layout()
        #expect(fixture.source.sshSession?.terminalViewOwner.hasKeyboardFocusForTesting == true)

        try fixture.insert(usesMenu: usesMenu)
        await fixture.settleClick()

        #expect(fixture.sourceWrites == [Data("hostname".utf8)])
        #expect(fixture.otherWrites == fixture.sourceWrites)
        #expect(fixture.source.terminalInputArea.draft == "keep my draft")
    }

    @Test(arguments: [WindowSidebarState.Mode.snippets, .history])
    func doubleClickStillExecutesWithoutEditingTheFocusedDraft(mode: WindowSidebarState.Mode) async throws {
        let fixture = TerminalSidebarInsertionFixture(mode: mode)
        defer { fixture.close() }
        try await fixture.prepare()
        fixture.source.terminalInputArea.draft = "keep my draft"
        await fixture.layout()
        _ = try fixture.focusEditor()

        try fixture.doubleClickRow()
        await fixture.settleClick()

        #expect(fixture.sourceWrites == [Data("hostname\r".utf8)])
        #expect(fixture.otherWrites == fixture.sourceWrites)
        #expect(fixture.source.terminalInputArea.draft == "keep my draft")
    }

    @Test
    func stalePaneAndEditorFocusCannotRedirectAnotherPanesInsertion() async throws {
        let fixture = TerminalSidebarInsertionFixture()
        defer { fixture.close() }
        try await fixture.prepare()
        let editor = try fixture.focusEditor()
        fixture.workspace.broadcastsInput = false
        fixture.workspace.focus(fixture.other.id)
        fixture.workspace.insertSidebarText("other pane", in: fixture.window)
        #expect(fixture.source.terminalInputArea.draft.isEmpty)
        #expect(fixture.sourceWrites.isEmpty)
        #expect(fixture.otherWrites == [Data("other pane".utf8)])

        fixture.workspace.focus(fixture.source.id)
        editor.acceptsSubmission = false
        #expect(
            !TerminalInputTextView.insertInFocusedEditor(
                "inactive", for: fixture.source.terminalInputArea, in: fixture.window))
        editor.acceptsSubmission = true
        fixture.source.terminalInputArea.dismissEditorFocus()
        #expect(
            !TerminalInputTextView.insertInFocusedEditor(
                "hidden", for: fixture.source.terminalInputArea, in: fixture.window))
        #expect(fixture.source.terminalInputArea.draft.isEmpty)
    }

    @Test
    func insertionCannotUseAnotherWindowsEditorOrAnInactiveWindow() async throws {
        let first = TerminalSidebarInsertionFixture()
        let second = TerminalSidebarInsertionFixture()
        defer {
            second.close()
            first.close()
        }
        try await first.prepare()
        _ = try first.focusEditor()
        try await second.prepare()
        _ = try second.focusEditor()

        #expect(
            !TerminalInputTextView.insertInFocusedEditor(
                "inactive window", for: first.source.terminalInputArea, in: first.window))
        #expect(
            !TerminalInputTextView.insertInFocusedEditor(
                "foreign editor", for: first.source.terminalInputArea, in: second.window))
        second.workspace.insertSidebarText("current window", in: second.window)
        #expect(first.source.terminalInputArea.draft.isEmpty)
        #expect(second.source.terminalInputArea.draft == "current window")
        #expect(first.sourceWrites.isEmpty && second.sourceWrites.isEmpty)
    }

    @Test(arguments: [SplitAxis.horizontal, .vertical], [false, true])
    func visibilityChangesCleanUpFocusBeforeTheTransitionFinishes(
        axis: SplitAxis, disablesAnimations: Bool
    ) async throws {
        let fixture = TerminalSidebarInsertionFixture(axis: axis, disablesAnimations: disablesAnimations)
        defer { fixture.close() }
        try await fixture.prepare()
        let input = fixture.source.terminalInputArea
        input.draft = "keep this request"
        input.mode = .commandGenerator
        await fixture.layout()
        _ = try fixture.focusEditor()
        let terminals = fixture.terminalIdentities
        let heights = fixture.terminalHeights
        let preferredHeight = input.preferredHeight
        input.generate(
            context: .init(draft: input.draft, shell: "", cwd: ""),
            using: SidebarWaitingGenerator(), isCurrent: { true })
        #expect(input.isGenerating)

        fixture.setInputAreaVisible(false)
        await fixture.layout()
        #expect(!input.isGenerating && !input.isEditorFocused)
        #expect(
            !TerminalInputTextView.insertInFocusedEditor("hidden", for: input, in: fixture.window))
        await fixture.settleAnimation()
        #expect(fixture.editors.isEmpty)
        #expect(fixture.terminalIdentities == terminals)
        #expect(zip(fixture.terminalHeights, heights).allSatisfy { $0 > $1 })

        for visible in [true, false, true, false, true] {
            fixture.setInputAreaVisible(visible)
            try await Task.sleep(for: .milliseconds(30))
        }
        await fixture.settleAnimation()
        #expect(fixture.editors.count == 2)
        #expect(fixture.terminalIdentities == terminals)
        #expect(fixture.terminalHeights == heights)
        #expect(input.draft == "keep this request")
        #expect(input.mode == .commandGenerator && input.preferredHeight == preferredHeight)
        #expect(fixture.sourceWrites.isEmpty && fixture.otherWrites.isEmpty)
    }
}

@MainActor
private final class SidebarWaitingGenerator: CommandGenerating {
    func generate(_ context: CommandGeneratorContext) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "unused"
    }
}

@MainActor
private final class TerminalSidebarInsertionFixture {
    let source: Pane
    let other: Pane
    let workspace: Workspace
    let window: NSWindow
    private let app: AppModel
    private let controller: NSHostingController<AnyView>
    private let defaults: UserDefaults
    private let suite = "TerminalSidebarInsertionTests.\(UUID())"
    private let writes = Writes()
    var sourceWrites: [Data] { writes.source }
    var otherWrites: [Data] { writes.other }

    private final class Writes {
        var source: [Data] = []
        var other: [Data] = []
    }

    init(
        mode: WindowSidebarState.Mode = .snippets, axis: SplitAxis = .horizontal,
        disablesAnimations: Bool = true
    ) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: DesktopSettingsKey.showTerminalInputArea)
        let firstHost = TermindDomain.Host(name: "Source", host: "source.invalid")
        let secondHost = TermindDomain.Host(name: "Other", host: "other.invalid")
        source = Pane.sshSession(host: firstHost)
        other = Pane.sshSession(host: secondHost)
        workspace = Workspace(pane: source)
        workspace.splitFocusedPane(axis: axis, with: other)
        workspace.focus(source.id)
        workspace.broadcastsInput = true
        for session in workspace.broadcastTargets {
            session.status = .connected
            session.connectionJourney.hide()
        }
        let writes = writes
        source.sshSession?.inputSink = { writes.source.append($0) }
        other.sshSession?.inputSink = { writes.other.append($0) }
        source.sshSession?.commandHistory.record("hostname")
        app = AppModel(
            hosts: HostLibraryModel(
                hosts: [firstHost, secondHost],
                snippets: [Snippet(title: "Hostname", body: "hostname")],
                localDefaults: defaults))
        let navigation = WindowModel(workspaces: [workspace])
        navigation.sidebarMode = mode
        let workspace = workspace
        controller = NSHostingController(
            rootView: AnyView(
                HStack(spacing: 0) {
                    WindowSidebarView().frame(width: 280)
                    WorkspaceContentView(workspace: workspace, isActive: true)
                }
                .environment(app)
                .environment(navigation)
                .environment(\.locale, Locale(identifier: "en"))
                .transaction { $0.disablesAnimations = disablesAnimations }
                .defaultAppStorage(defaults)))
        controller.sizingOptions = []
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 540),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 1_000, height: 540))
    }

    func prepare() async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await layout()
        // A key window in an inactive app still consumes its first click as activation.
        for _ in 0..<100 where !NSApp.isActive || !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
            try await Task.sleep(for: .milliseconds(20))
        }
        if !NSApp.isActive || !window.isKeyWindow {
            Attachment.record(
                Data(
                    """
                    appActive=\(NSApp.isActive), activationPolicy=\(NSApp.activationPolicy().rawValue)
                    visible=\(window.isVisible), canBecomeKey=\(window.canBecomeKey)
                    keyWindow=\(String(describing: NSApp.keyWindow)), modalWindow=\(String(describing: NSApp.modalWindow))
                    frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none")
                    """.utf8),
                named: "sidebar-insertion-window.txt")
        }
        try #require(NSApp.isActive)
        try #require(window.isKeyWindow)
    }

    var editors: [TerminalInputTextView] {
        descendants(controller.view).compactMap { $0 as? TerminalInputTextView }
    }

    var terminalIdentities: [ObjectIdentifier] {
        descendants(controller.view).compactMap { $0 as? AppTerminalView }.map(ObjectIdentifier.init)
    }

    var terminalHeights: [CGFloat] {
        descendants(controller.view).compactMap { $0 as? AppTerminalView }.map(\.bounds.height)
    }

    func focusEditor() throws -> TerminalInputTextView {
        let editor = try #require(editors.first { $0.inputArea === source.terminalInputArea })
        try #require(window.makeFirstResponder(editor))
        return editor
    }

    func insert(usesMenu: Bool) throws {
        let (row, menu) = try sidebarRow()
        if usesMenu {
            let index = try #require(menu.items.firstIndex { $0.title == "Insert" })
            menu.performActionForItem(at: index)
        } else {
            click(row, count: 1, timestamp: ProcessInfo.processInfo.systemUptime)
        }
    }

    func doubleClickRow() throws {
        let (row, _) = try sidebarRow()
        let timestamp = ProcessInfo.processInfo.systemUptime
        click(row, count: 1, timestamp: timestamp)
        click(row, count: 2, timestamp: timestamp + 0.1)
    }

    private func sidebarRow() throws -> (NativeRowContextMenu.RowMenuView, NSMenu) {
        for row in descendants(controller.view).compactMap({ $0 as? NativeRowContextMenu.RowMenuView }) {
            if let menu = row.makeMenu(), menu.items.contains(where: { $0.title == "Insert" }) {
                return (row, menu)
            }
        }
        Issue.record("Sidebar insert menu was not found")
        throw FixtureError.missingRow
    }

    private func click(_ view: NSView, count: Int, timestamp: TimeInterval) {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: timestamp + Double(index) * 0.05,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                    pressure: type == .leftMouseDown ? 1 : 0)
            else {
                Issue.record("Could not create a sidebar mouse event")
                return
            }
            window.sendEvent(event)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func settleClick() async {
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        await layout()
    }

    func setInputAreaVisible(_ visible: Bool) {
        defaults.set(visible, forKey: DesktopSettingsKey.showTerminalInputArea)
    }

    func settleAnimation() async {
        await layout()
        try? await Task.sleep(for: .milliseconds(350))
        await layout()
    }

    func layout() async {
        controller.view.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
    }

    func close() {
        source.disconnectConnection()
        other.disconnectConnection()
        app.shutdownForTermination()
        window.contentViewController = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }

    private enum FixtureError: Error { case missingRow }
}
