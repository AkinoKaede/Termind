// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

private nonisolated let terminalMouseHasDisplay: Bool = {
    var count: UInt32 = 0
    return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
}()

@Suite(
    .requiresVisibleWindow, .serialized, .disabled(if: !terminalMouseHasDisplay, "Ghostty requires an active display"))
@MainActor
struct TerminalMouseInteractionTests {
    @Test func uploadMenuPresentsFilePickerOnThePersistentTerminalWindow() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        // The custom mount bypasses Ghostty's SwiftUI representable.
        #expect(fixture.state.attachedPlatformView == nil)
        let uploadBindingID = fixture.owner.bindUpload(
            action: { fixture.owner.chooseUploadFiles { _ in Issue.record("Cancelled picker must not upload") } },
            isAvailable: { true })
        defer { fixture.owner.unbindUpload(uploadBindingID) }
        let title = String(localized: AppStrings.Terminal.uploadFile)
        let item = try #require(fixture.view.selectionContextMenu().item(withTitle: title))
        #expect(!title.contains("…"))
        _ = fixture.view.perform(item.action, with: item)
        for _ in 0..<100 where fixture.window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try #require(fixture.window.attachedSheet as? NSOpenPanel)
        #expect(panel.canChooseFiles)
        #expect(panel.canChooseDirectories)
        #expect(panel.allowsMultipleSelection)
        panel.cancel(nil)
    }

    @Test func statusBarPathReachesTerminalThroughWorkspaceOverlays() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        let path = "/home/user/中文/my files"
        let hosts = fixture.workspace.panes.compactMap { pane -> Host? in
            guard let session = pane.sshSession else { return nil }
            session.status = .connected
            session.workingDirectory = path
            session.receiveShellIntegrationEvent(.available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/user"))
            return Host(id: session.hostID, name: "Drag test", host: "test.invalid")
        }
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts))
        defer { app.shutdownForTermination() }
        let model = WindowModel(workspaces: [fixture.workspace])
        let first = try #require(fixture.workspace.panes.first { $0.sshSession === fixture.session })
        fixture.workspace.focus(first.id)
        let domain = "TerminalPathDrag.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: DesktopSettingsKey.statusBarExpanded)
        defer { defaults.removePersistentDomain(forName: domain) }
        let hosting = NSHostingView(
            rootView: WorkspaceContentView(workspace: fixture.workspace, isActive: true)
                .overlay(alignment: .bottomTrailing) { StatusBarView().padding(12) }
                .environment(app).environment(model).defaultAppStorage(defaults)
                .frame(width: 800, height: 500))
        fixture.window.title = "Path drag verification"
        fixture.window.contentView = hosting
        fixture.window.setContentSize(NSSize(width: 800, height: 500))
        fixture.window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        fixture.feed("\u{1B}[?2004h")
        fixture.firstWrites.removeAll()

        func targets(in view: NSView) -> [FileURLDropNSView] {
            (view as? FileURLDropNSView).map { [$0] } ?? view.subviews.flatMap { targets(in: $0) }
        }
        let point = fixture.view.convert(NSPoint(x: 50, y: 50), to: hosting)
        let target = try #require(
            targets(in: hosting).first {
                $0.acceptedKinds.contains(.terminalPath) && $0.bounds.contains($0.convert(point, from: hosting))
            })
        let text = RemoteShellCommand.escapeArgument(path)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(text, forType: TerminalPathDrag.pasteboardType)
        let drag = DraggingInfoStub(pasteboard: pasteboard)
        #expect(target.draggingEntered(drag) == .copy)
        #expect(target.draggingUpdated(drag) == .copy)
        #expect(target.performDragOperation(drag))
        try await fixture.flushWrites()
        #expect(fixture.firstWrites.reduce(Data(), +) == Data("\u{1B}[200~\(text)\u{1B}[201~".utf8))
        fixture.window.contentView = nil
    }

    @Test func pathDropProposesCopyAndPastesExactlyOnceWithoutSubmittingOrEscapingAgain() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.workspace.broadcastsInput = true
        fixture.feed("\u{1B}[?2004h")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = RemoteShellCommand.escapeArgument("/home/user/中文/my files/it's live")
        pasteboard.setString(text, forType: TerminalPathDrag.pasteboardType)
        let drag = DraggingInfoStub(pasteboard: pasteboard)
        fixture.setClipboard("unchanged")

        #expect(fixture.view.registeredDraggedTypes.contains(TerminalPathDrag.pasteboardType))
        #expect(fixture.view.draggingEntered(drag) == .copy)
        #expect(fixture.view.draggingUpdated(drag) == .copy)
        #expect(fixture.view.prepareForDragOperation(drag))
        #expect(fixture.view.pathDropOperation(from: pasteboard, sourceOperations: [.copy, .move]) == .copy)
        #expect(fixture.view.pathDropOperation(from: pasteboard, sourceOperations: .move).isEmpty)
        #expect(fixture.firstWrites.isEmpty)
        #expect(fixture.view.performDragOperation(drag))
        try await fixture.flushWrites()

        let expected = Data("\u{1B}[200~\(text)\u{1B}[201~".utf8)
        #expect(fixture.firstWrites.reduce(Data(), +) == expected)
        #expect(fixture.secondWrites.reduce(Data(), +) == expected)
        #expect(NSPasteboard.general.string(forType: .string) == "unchanged")
    }

    @Test func hidingOrUnmountingTheTerminalRejectsAnAlreadyTrackedPathDrop() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("/srv/path", forType: TerminalPathDrag.pasteboardType)
        #expect(fixture.view.pathDropOperation(from: pasteboard, sourceOperations: .copy) == .copy)

        fixture.owner.mount(in: fixture.mount, state: fixture.state, isVisible: false, requestsFocus: false)
        #expect(!fixture.view.registeredDraggedTypes.contains(TerminalPathDrag.pasteboardType))
        #expect(fixture.view.pathDropOperation(from: pasteboard, sourceOperations: .copy).isEmpty)
        #expect(!fixture.view.receivePathDrop(from: pasteboard, sourceOperations: .copy))

        fixture.owner.mount(in: fixture.mount, state: fixture.state, isVisible: true, requestsFocus: false)
        #expect(fixture.view.pathDropOperation(from: pasteboard, sourceOperations: .copy) == .copy)
        fixture.owner.unmount(from: fixture.mount)
        #expect(!fixture.view.registeredDraggedTypes.contains(TerminalPathDrag.pasteboardType))
        #expect(!fixture.view.receivePathDrop(from: pasteboard, sourceOperations: .copy))
        try await fixture.flushWrites()
        #expect(fixture.firstWrites.isEmpty)
    }

    @Test func dragCopiesChineseAndMultipleLinesOnlyAfterRelease() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.view.copyOnSelect = true
        fixture.feed("hello 中文\r\nsecond line")
        fixture.setClipboard("unchanged")
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, column: 0, row: 0))
        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, column: 11, row: 1))
        #expect(NSPasteboard.general.string(forType: .string) == "unchanged")
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, column: 11, row: 1))
        #expect(NSPasteboard.general.string(forType: .string) == "hello 中文\nsecond line")
        #expect(fixture.firstWrites.isEmpty)
        #expect(fixture.secondWrites.isEmpty)
    }

    @Test(arguments: [2, 3])
    func repeatedClicksCopyWordOrLine(_ count: Int) async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.view.copyOnSelect = true
        fixture.feed("hello world")
        fixture.setClipboard("unchanged")
        for _ in 0..<count {
            fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, column: 1, row: 0))
            fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, column: 1, row: 0))
        }
        let copied = try #require(NSPasteboard.general.string(forType: .string))
        #expect(copied.trimmingCharacters(in: .whitespacesAndNewlines) == (count == 2 ? "hello" : "hello world"))
    }

    @Test func disabledCopyEmptySelectionAndKeyboardSelectionLeaveClipboardAlone() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.feed("hello world")
        fixture.setClipboard("unchanged")
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, column: 0, row: 0))
        fixture.view.mouseDragged(with: try fixture.event(.leftMouseDragged, column: 5, row: 0))
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, column: 5, row: 0))
        #expect(fixture.state.surface?.hasSelection() == true)
        #expect(NSPasteboard.general.string(forType: .string) == "unchanged")

        fixture.view.copyOnSelect = true
        _ = fixture.view.performBindingAction("select_all")
        #expect(NSPasteboard.general.string(forType: .string) == "unchanged")
        // An unmatched release must not copy an earlier keyboard selection.
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp))
        #expect(NSPasteboard.general.string(forType: .string) == "unchanged")
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown, column: 20, row: 5))
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp, column: 20, row: 5))
        #expect(NSPasteboard.general.string(forType: .string) == "unchanged")
    }

    @Test func rightClickPastesBracketedTextOnceAndBroadcastsOnceWithASelection() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.view.pasteOnRightClick = true
        fixture.workspace.broadcastsInput = true
        fixture.feed("selected text\u{1B}[?2004h")
        _ = fixture.view.performBindingAction("select_all")
        fixture.setClipboard("echo 中文\necho second")
        fixture.view.rightMouseDown(with: try fixture.event(.rightMouseDown))
        #expect(fixture.view.menu(for: try fixture.event(.rightMouseDown)) == nil)
        #expect(fixture.firstWrites.isEmpty)
        // Preference and modifier changes during a click do not change its route.
        fixture.view.pasteOnRightClick = false
        fixture.view.rightMouseDragged(with: try fixture.event(.rightMouseDragged))
        fixture.view.rightMouseUp(with: try fixture.event(.rightMouseUp, modifiers: .option))
        fixture.view.rightMouseUp(with: try fixture.event(.rightMouseUp))
        try await fixture.flushWrites()
        let expected = Data("\u{1B}[200~echo 中文\necho second\u{1B}[201~".utf8)
        #expect(fixture.firstWrites.reduce(Data(), +) == expected)
        #expect(fixture.secondWrites.reduce(Data(), +) == expected)
    }

    @Test func emptyClipboardAndOptionRightClickDoNotPaste() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.view.pasteOnRightClick = true
        NSPasteboard.general.clearContents()
        try fixture.rightClick()
        try await fixture.flushWrites()
        #expect(fixture.firstWrites.isEmpty)
        fixture.setClipboard("do not paste")
        fixture.view.rightMouseDown(with: try fixture.event(.rightMouseDown, modifiers: .option))
        // Inspect the Option menu without entering AppKit's modal tracking loop.
        #expect(fixture.view.menu(for: try fixture.event(.rightMouseDown, modifiers: .option)) != nil)
        try await fixture.flushWrites()
        #expect(fixture.firstWrites.isEmpty)
        fixture.feed("selection")
        _ = fixture.view.performBindingAction("select_all")
        #expect(fixture.view.menu(for: try fixture.event(.rightMouseDown, modifiers: .option)) != nil)
    }

    @Test func capturedMouseKeepsBothReportsAndNeverBroadcastsOrCopies() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.view.copyOnSelect = true
        fixture.view.pasteOnRightClick = true
        fixture.workspace.broadcastsInput = true
        fixture.setClipboard("do not paste")
        fixture.feed("\u{1B}[?1000h\u{1B}[?1006h")
        #expect(fixture.view.isMouseCaptured)
        fixture.view.rightMouseDown(with: try fixture.event(.rightMouseDown))
        fixture.view.pasteOnRightClick = false
        fixture.view.rightMouseUp(with: try fixture.event(.rightMouseUp))
        fixture.view.mouseDown(with: try fixture.event(.leftMouseDown))
        fixture.view.mouseUp(with: try fixture.event(.leftMouseUp))
        try await fixture.flushWrites()
        let reports = String(decoding: fixture.firstWrites.reduce(Data(), +), as: UTF8.self)
        #expect(reports.contains("\u{1B}[<2;"))
        #expect(reports.contains("M"))
        #expect(reports.contains("m"))
        #expect(!reports.contains("do not paste"))
        #expect(fixture.secondWrites.isEmpty)
        #expect(NSPasteboard.general.string(forType: .string) == "do not paste")
    }

    @Test func emptyPasteDoesNotMarkTheNextMouseReportAsInteractiveInput() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.view.pasteOnRightClick = true
        fixture.workspace.broadcastsInput = true
        NSPasteboard.general.clearContents()
        try fixture.rightClick()
        fixture.feed("\u{1B}[?1000h\u{1B}[?1006h")
        try fixture.rightClick()
        try await fixture.flushWrites()
        #expect(!fixture.firstWrites.isEmpty)
        #expect(fixture.secondWrites.isEmpty)
    }

    @Test func enablingPasteDuringAClickAppliesToTheNextClick() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.setClipboard("paste once")
        fixture.view.rightMouseDown(with: try fixture.event(.rightMouseDown))
        fixture.view.pasteOnRightClick = true
        // The click already chose the menu route; avoid presenting it in this test.
        #expect(fixture.view.menu(for: try fixture.event(.rightMouseDown)) != nil)
        try await fixture.flushWrites()
        #expect(fixture.firstWrites.isEmpty)
        try fixture.rightClick()
        try await fixture.flushWrites()
        #expect(fixture.firstWrites.reduce(Data(), +) == Data("paste once".utf8))
    }

    @Test func mirroredSettingsUpdateTheMountedSwiftUIViewWithoutReplacingItsSurface() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        let domain = "TerminalMouseLiveSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let hosting = NSHostingView(
            rootView: PersistentTerminalSurfaceView(
                state: fixture.state, owner: fixture.owner, isVisible: true, requestsFocus: false
            ).defaultAppStorage(defaults))
        hosting.frame = fixture.mount.bounds
        fixture.mount.addSubview(hosting)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let surface = try #require(fixture.state.surface)
        #expect(!fixture.view.copyOnSelect)
        #expect(!fixture.view.pasteOnRightClick)
        let settings = TerminalExperienceSettingsModel(defaults: defaults)
        settings.set(true, for: \.copyOnSelect)
        settings.set(true, for: \.pasteOnRightClick)
        for _ in 0..<100 where !fixture.view.copyOnSelect || !fixture.view.pasteOnRightClick {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.view.copyOnSelect)
        #expect(fixture.view.pasteOnRightClick)
        #expect(fixture.state.surface === surface)
    }

    @Test func movingBetweenNativeWindowsIgnoresStaleUnmountsAndKeepsTerminalContents() async throws {
        let fixture = try await TerminalMouseFixture.make()
        let targetMount = TerminalMountView(frame: fixture.mount.frame)
        let target = NSWindow(contentRect: targetMount.frame, styleMask: [.titled], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        target.animationBehavior = .none
        target.contentView = targetMount
        target.makeKeyAndOrderFront(nil)
        defer {
            fixture.owner.unmount(from: targetMount)
            target.close()
            fixture.close()
        }
        fixture.feed("preserved across windows")
        let surface = try #require(fixture.state.surface)
        fixture.owner.mount(in: targetMount, state: fixture.state, isVisible: true, requestsFocus: true)
        targetMount.layoutSubtreeIfNeeded()
        fixture.owner.unmount(from: fixture.mount)
        // SwiftUI may still update the old representable after the new one mounted.
        fixture.owner.mount(in: fixture.mount, state: fixture.state, isVisible: false, requestsFocus: false)
        #expect(fixture.view.window === target)
        #expect(fixture.state.surface === surface)
        #expect(fixture.state.isSurfaceVisible)
        #expect(fixture.backend.readViewportText()?.contains("preserved across windows") == true)
        #expect(fixture.owner.hasKeyboardFocusForTesting)
        fixture.window.close()
        #expect(fixture.view.window === target)
        #expect(fixture.state.surface === surface)
    }

    @Test func preferenceUpdatesAndReparentingPreserveSurfaceAndScrollback() async throws {
        let fixture = try await TerminalMouseFixture.make()
        defer { fixture.close() }
        fixture.feed("retained history")
        let surface = try #require(fixture.state.surface)
        fixture.owner.mount(
            in: fixture.mount, state: fixture.state, isVisible: true, requestsFocus: false,
            copyOnSelect: true, pasteOnRightClick: true)
        #expect(fixture.view.copyOnSelect)
        #expect(fixture.view.pasteOnRightClick)
        #expect(fixture.state.surface === surface)
        let newMount = TerminalMountView(frame: fixture.mount.frame)
        fixture.window.contentView?.addSubview(newMount)
        fixture.owner.mount(
            in: newMount, state: fixture.state, isVisible: true, requestsFocus: false,
            copyOnSelect: false, pasteOnRightClick: true)
        newMount.layoutSubtreeIfNeeded()
        #expect(newMount.subviews.first === fixture.view)
        #expect(fixture.state.surface === surface)
        #expect(fixture.backend.readViewportText()?.contains("retained history") == true)
        #expect(!fixture.view.copyOnSelect)
        #expect(fixture.view.pasteOnRightClick)
        fixture.owner.unmount(from: newMount)
    }
}

@MainActor
private final class TerminalMouseFixture {
    let workspace: Workspace
    let session: SSHSessionModel
    let mount: TerminalMountView
    let window: NSWindow
    let view: TermindTerminalView
    let backend: InMemoryTerminalSession
    var firstWrites: [Data] = []
    var secondWrites: [Data] = []
    private let savedClipboard: [[NSPasteboard.PasteboardType: Data]]

    var state: TerminalViewState { session.terminalState }
    var owner: PersistentTerminalViewOwner { session.terminalViewOwner }

    private init() throws {
        savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        workspace = Workspace.sshSession(host: Host(name: "first", host: "first.example"))
        session = try #require(workspace.focusedPane.sshSession)
        let peer = Pane.sshSession(host: Host(name: "second", host: "second.example"))
        workspace.splitFocusedPane(axis: .horizontal, with: peer)
        guard case .inMemory(let memory) = session.terminalState.configuration.backend else {
            throw CocoaError(.coderInvalidValue)
        }
        backend = memory
        session.terminalState.setTerminalConfiguration(
            TerminalConfiguration { builder in
                builder.withWindowPaddingX(0)
                builder.withWindowPaddingY(0)
            })
        mount = TerminalMountView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window = NSWindow(contentRect: mount.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = mount
        window.orderFront(nil)
        session.terminalViewOwner.mount(in: mount, state: session.terminalState, isVisible: true, requestsFocus: false)
        mount.layoutSubtreeIfNeeded()
        view = try #require(mount.subviews.first as? TermindTerminalView)
        session.inputSink = { [weak self] in self?.firstWrites.append($0) }
        peer.sshSession?.inputSink = { [weak self] in self?.secondWrites.append($0) }
    }

    static func make() async throws -> TerminalMouseFixture {
        let fixture = try TerminalMouseFixture()
        for _ in 0..<100 where fixture.state.surface == nil || fixture.state.surfaceSize == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(fixture.state.surface)
        _ = try #require(fixture.state.surfaceSize)
        return fixture
    }

    func feed(_ text: String) {
        backend.receive(Data(text.utf8))
        backend.waitForPendingOutput()
    }

    func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func event(
        _ type: NSEvent.EventType, column: Double = 1, row: Double = 1, modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let metrics = try #require(state.surfaceSize)
        let scale = window.backingScaleFactor
        let point = NSPoint(
            x: (column + 0.5) * Double(metrics.cellWidthPixels) / scale,
            y: view.bounds.height - (row + 0.5) * Double(metrics.cellHeightPixels) / scale)
        return try #require(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func rightClick() throws {
        view.rightMouseDown(with: try event(.rightMouseDown))
        view.rightMouseUp(with: try event(.rightMouseUp))
    }

    func flushWrites() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    func close() {
        owner.unmount(from: mount)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        let items = savedClipboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }
}
