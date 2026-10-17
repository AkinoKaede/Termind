import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct ChooserInteractionTests {
    @Test(arguments: ["light", "dark", "empty", "reduced-transparency"])
    func quickOpenIntegratedGlassRendersAcrossAppearances(_ variant: String) async throws {
        let fixture = ChooserFixture()
        defer { fixture.close() }
        fixture.model.openPage(.hosts)
        fixture.mount(
            QuickOpenHarness(
                workspace: nil,
                reduceTransparency: variant == "reduced-transparency"
            )
        )
        try await fixture.settle()
        fixture.window.appearance = NSAppearance(
            named: variant == "dark" ? .darkAqua : .aqua
        )
        fixture.window.makeKey()
        fixture.model.isQuickOpenPresented = true
        let field = try await fixture.quickOpenEditableField()
        if variant == "empty" {
            field.stringValue = "no matching command exists"
            field.delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field)
            )
            try await fixture.settle()
        }

        let image = try fixture.capture()
        Attachment.record(image, named: "quick-open-integrated-glass-\(variant).png")
    }

    @Test(arguments: ["toolbar", "ssh", "serial"])
    func quickOpenTakesFocusAndHandlesTypingNavigationAndReopening(_ source: String) async throws {
        let fixture = ChooserFixture()
        defer { fixture.close() }
        var workspace: Workspace?
        if source == "ssh" {
            let session = SSHSessionModel(host: fixture.hosts[0])
            session.status = .connected
            workspace = fixture.model.open(Workspace(pane: Pane(.sshSession(session))))
        } else if source == "serial" {
            let session = SerialSessionModel(
                configuration: SerialConnectionConfiguration(devicePath: "/dev/termind-test"),
                service: fixture.app.serialPorts)
            session.status = .connected
            workspace = fixture.model.open(Workspace(pane: Pane(.serialSession(session))))
        } else {
            fixture.model.openPage(.hosts)
        }
        fixture.mount(QuickOpenHarness(workspace: workspace))
        try await fixture.settle()
        if source == "toolbar" {
            fixture.model.focusToolbarFind()
            try await fixture.settle()
            #expect(fixture.model.isToolbarFindFocused)
        }

        fixture.window.makeKey()
        fixture.model.isQuickOpenPresented = true
        let field = try await fixture.quickOpenField()
        #expect(!fixture.model.isToolbarFindFocused)
        try fixture.type("New ", into: field)
        try await fixture.settle()
        #expect(field.stringValue == "New ")
        #expect(fixture.window.firstResponder === field.currentEditor())
        // New Window → New Chat → New Window → New Chat, then execute.
        try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try fixture.key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try fixture.key("\r", code: 36)
        try await fixture.settle()
        #expect(!fixture.model.isQuickOpenPresented)
        #expect(fixture.model.selectedDestination == .assistant)
        try await fixture.waitUntilQuickOpenCloses()

        fixture.window.makeKey()
        fixture.model.isQuickOpenPresented = true
        let reopened = try await fixture.quickOpenField()
        #expect(reopened.stringValue.isEmpty)
        try fixture.key("\u{1B}", code: 53)
        try await fixture.settle()
        #expect(!fixture.model.isQuickOpenPresented)
    }

    @Test
    func closingBeforeFocusDeliveryAndOpeningInAnotherWindowDoNotStealTheCaret() async throws {
        let first = ChooserFixture()
        let second = ChooserFixture()
        defer {
            second.close()
            first.close()
        }
        first.model.openPage(.hosts)
        first.mount(QuickOpenHarness(workspace: nil))
        try await first.settle()
        first.model.isQuickOpenPresented = true
        first.window.contentView?.layoutSubtreeIfNeeded()
        first.model.isQuickOpenPresented = false
        try await first.settle()
        first.model.focusToolbarFind()
        try await first.settle()
        let original = try #require(first.window.firstResponder)
        try await first.settle()
        #expect(first.window.firstResponder === original)

        second.model.openPage(.hosts)
        second.mount(QuickOpenHarness(workspace: nil))
        try await second.settle()
        second.model.focusToolbarFind()
        try await second.settle()
        let responder = try #require(second.window.firstResponder)
        first.model.isQuickOpenPresented = true
        try await second.settle()
        #expect(second.window.isKeyWindow)
        #expect(second.window.firstResponder === responder)
        #expect(!second.model.isQuickOpenPresented)
    }

    @Test
    func connectUsesImmediateRowsWhileSerialAddsAnExplicitTopAction() async throws {
        let connect = ChooserFixture()
        defer { connect.close() }
        connect.mount(HostChooserView(purpose: .connect))
        try await connect.settle()

        let connectActions = connect.elements.filter {
            $0.accessibilityIdentifier?() == "host-chooser.confirm"
        }
        #expect(connectActions.isEmpty)
        let picker = try #require(connect.views.compactMap { $0 as? NSSegmentedControl }.first)
        #expect(picker.segmentCount == 3)

        _ = try await connect.quickOpenField()
        try connect.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try connect.key("\r", code: 36)
        try await connect.settle()
        #expect(connect.model.workspaces.count == 1)

        let serial = ChooserFixture()
        defer { serial.close() }
        serial.mount(HostChooserView(purpose: .connect))
        try await serial.settle()
        let serialPicker = try #require(serial.views.compactMap { $0 as? NSSegmentedControl }.first)
        serialPicker.selectedSegment = 2
        #expect(serialPicker.sendAction(serialPicker.action, to: serialPicker.target))
        try await serial.settle()
        #expect(serial.model.workspaces.isEmpty)
    }

    @Test(arguments: [HostOpenTarget.sshSession, .sftpChannel], [1, 3])
    func batchConnectAndReturnCreateExactlyOneWorkspace(target: HostOpenTarget, count: Int) async throws {
        let fixture = ChooserFixture()
        defer { fixture.close() }
        fixture.mount(HostChooserView(purpose: .batchStartup))
        try await fixture.settle()
        #expect(fixture.model.workspaces.isEmpty)
        let protocolPicker = try #require(fixture.views.compactMap { $0 as? NSSegmentedControl }.first)
        #expect(protocolPicker.segmentCount == 2)
        if target == .sftpChannel {
            protocolPicker.selectedSegment = 1
            #expect(protocolPicker.sendAction(protocolPicker.action, to: protocolPicker.target))
        }

        _ = try await fixture.quickOpenField()
        for _ in 0..<count {
            try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
            try fixture.key(" ", code: 49)
        }
        #expect(fixture.model.workspaces.isEmpty)
        try fixture.key("\r", code: 36)
        try await fixture.settle()
        #expect(fixture.model.workspaces.count == 1)
        let workspace = try #require(fixture.model.selectedWorkspace)
        #expect(workspace.panes.map(\.hostID) == fixture.hosts.prefix(count).map(\.id))
        #expect(workspace.focusedPaneID == workspace.panes.first?.id)
        #expect(workspace.panes.allSatisfy { $0.kind == (target == .sshSession ? .sshSession : .sftpChannel) })
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func metricsUsesTheBatchFormAndConfirmsOnlyAfterSelection(_ language: String) async throws {
        let fixture = ChooserFixture()
        defer { fixture.close() }
        fixture.mount(HostChooserView(purpose: .metrics).environment(\.locale, Locale(identifier: language)))
        try await fixture.settle()
        #expect(!fixture.views.contains { $0 is NSSegmentedControl })

        _ = try await fixture.quickOpenField()
        try fixture.key("\r", code: 36)
        try await fixture.settle()
        #expect(fixture.model.pendingMetricsHostIDs == [])
        fixture.model.pendingMetricsHostIDs = nil
        fixture.model.pendingMetricsEditableHostIDs = []
        fixture.mount(HostChooserView(purpose: .metrics).environment(\.locale, Locale(identifier: language)))
        try await fixture.settle()
        _ = try await fixture.quickOpenField()
        try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try fixture.key(" ", code: 49)
        try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try fixture.key(" ", code: 49)
        try await fixture.settle()
        #expect(fixture.model.pendingMetricsHostIDs == nil)
        #expect(fixture.app.serverMetrics.servers.isEmpty)
        let image = try fixture.capture()
        Attachment.record(image, named: "metrics-host-picker-\(language).png")

        try fixture.key("\r", code: 36)
        try await fixture.settle()
        #expect(fixture.model.pendingMetricsHostIDs == fixture.hosts.prefix(2).map(\.id))
        #expect(fixture.model.workspaces.isEmpty)
        #expect(fixture.app.serverMetrics.servers.isEmpty)
    }

    @Test
    func metricsPickerCanClearAnExistingSelectionButCancelDoesNothing() async throws {
        let fixture = ChooserFixture()
        defer { fixture.close() }
        #expect(fixture.app.serverMetrics.add(fixture.hosts[0]))

        fixture.mount(HostChooserView(purpose: .metrics))
        try await fixture.settle()
        try fixture.key("\u{1B}", code: 53)
        try await fixture.settle()
        #expect(fixture.model.pendingMetricsHostIDs == nil)
        #expect(fixture.app.serverMetrics.selections.map(\.id) == [fixture.hosts[0].id])

        fixture.mount(HostChooserView(purpose: .metrics))
        try await fixture.settle()
        _ = try await fixture.quickOpenField()
        try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try fixture.key(" ", code: 49)
        try fixture.key("\r", code: 36)
        try await fixture.settle()
        #expect(fixture.model.pendingMetricsHostIDs == [])
        #expect(fixture.model.pendingMetricsEditableHostIDs == [fixture.hosts[0].id])
        #expect(fixture.app.serverMetrics.selections.map(\.id) == [fixture.hosts[0].id])
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func batchHasOneConnectActionAndCancelCreatesNoSessions(_ language: String) async throws {
        let fixture = ChooserFixture()
        defer { fixture.close() }
        fixture.mount(HostChooserView(purpose: .batchStartup).environment(\.locale, Locale(identifier: language)))
        try await fixture.settle()
        _ = try await fixture.quickOpenField()
        try fixture.key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try fixture.key(" ", code: 49)
        try await fixture.settle()
        let view = try #require(fixture.window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(image, named: "batch-startup-\(language).png")
        try image.write(
            to: FileManager.default.temporaryDirectory.appending(path: "termind-batch-startup-\(language).png"))
        try fixture.key("\u{1B}", code: 53)
        try await fixture.settle()
        #expect(fixture.model.workspaces.isEmpty)
    }
}

private struct QuickOpenHarness: View {
    let workspace: Workspace?
    var reduceTransparency = false
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            if let workspace {
                WorkspaceContentView(workspace: workspace, isActive: model.selectedWorkspaceID == workspace.id)
            } else {
                VStack {
                    WindowToolbarFindField()
                    Spacer()
                }
            }
        }
        .frame(width: 800, height: 600)
        .overlay {
            if model.isQuickOpenPresented {
                QuickOpenOverlay { model.isQuickOpenPresented = false }
            }
        }
        .environment(\._accessibilityReduceTransparency, reduceTransparency)
    }
}

@MainActor
private final class ChooserFixture {
    let hosts: [Host]
    let app: AppModel
    let model = WindowModel()
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)

    init() {
        hosts = ["Alpha", "Bravo", "Charlie"].enumerated().map { index, name in
            Host(name: name, host: "\(name.lowercased()).invalid", sortIndex: Double(index))
        }
        app = AppModel(hosts: HostLibraryModel(hosts: hosts))
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
    }

    func mount(_ view: some View) {
        let controller = NSHostingController(rootView: view.environment(app).environment(model))
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = window.contentLayoutRect
        controller.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var views: [NSView] {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return window.contentView.map(descendants) ?? []
    }

    var elements: [AnyObject] {
        var seen = Set<ObjectIdentifier>()
        func descendants(_ element: AnyObject) -> [AnyObject] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            return [element]
                + (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }
                .flatMap(descendants)
        }
        return views.flatMap { descendants($0) }
    }

    func waitUntilQuickOpenCloses() async throws {
        for _ in 0..<100 {
            if !views.contains(where: { ($0 as? NSTextField)?.isEditable == true && !($0 is NSSearchField) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChooserTestError.searchDidNotClose
    }

    func quickOpenField() async throws -> NSTextField {
        for _ in 0..<100 {
            if let field = views.compactMap({ $0 as? NSTextField }).first(where: {
                $0.isEditable && !($0 is NSSearchField) && $0.currentEditor() === window.firstResponder
            }) {
                return field
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChooserTestError.searchDidNotTakeFocus
    }

    func quickOpenEditableField() async throws -> NSTextField {
        for _ in 0..<100 {
            if let field = views.compactMap({ $0 as? NSTextField }).first(where: {
                $0.isEditable && !($0 is NSSearchField)
            }) {
                return field
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ChooserTestError.searchDidNotMount
    }

    func type(_ text: String, into field: NSTextField) throws {
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    }

    func capture() throws -> Data {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    func key(_ characters: String, code: UInt16) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        for workspace in model.workspaces {
            for pane in workspace.panes { pane.disconnectConnection() }
        }
        app.shutdownForTermination()
    }
}

private enum ChooserTestError: Error {
    case searchDidNotTakeFocus
    case searchDidNotMount
    case searchDidNotClose
}
