import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@MainActor
@Suite(.serialized)
struct WorkspaceNavigatorDropTests {
    @Test(.requiresVisibleWindow)
    func aSingleClickSwitchesWorkspacesWithoutStartingALayoutDrag() async throws {
        let workspaces = [workspace("First"), workspace("Middle"), workspace("Last")]
        let fixture = try Fixture(workspaces: workspaces)
        defer { fixture.close() }
        _ = try await fixture.mount()
        let outline = try #require(descendant(in: fixture.hosting, ofType: NSOutlineView.self))
        let rows = (0..<outline.numberOfRows).filter { row in
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true),
                let menu = descendant(in: cell, ofType: NativeRowContextMenu.RowMenuView.self)
            else { return false }
            return menu.entries().contains { $0.title == "Close Workspace" }
        }
        try #require(rows.count == workspaces.count)
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.model.select(workspaces[0].id)
        for index in [1, 2, 0] {
            let point = outline.convert(CGPoint(x: 100, y: outline.rect(ofRow: rows[index]).midY), to: nil)
            for (eventNumber, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime + Double(eventNumber) * 0.05,
                        windowNumber: fixture.window.windowNumber, context: nil,
                        eventNumber: eventNumber, clickCount: 1, pressure: 1
                    )
                )
                NSApp.postEvent(event, atStart: false)
            }
            let deadline = Date(timeIntervalSinceNow: 0.2)
            while Date() < deadline {
                if let event = NSApp.nextEvent(
                    matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true
                ) {
                    NSApp.sendEvent(event)
                }
            }
            #expect(fixture.model.selectedWorkspace === workspaces[index])
            #expect(fixture.model.displayedWorkspace === workspaces[index])
            #expect(fixture.model.dragging == nil)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func insertionPreviewAlignsWithTheNativeWorkspaceRowUnderThePointer(
        afterScrolling: Bool, hasTitlebarAndSidebarInset: Bool
    ) async throws {
        let workspaces = (0..<24).map { workspace("Workspace \($0)") }
        let fixture = try Fixture(
            workspaces: workspaces,
            topInset: hasTitlebarAndSidebarInset ? 80 : 0,
            styleMask: hasTitlebarAndSidebarInset ? [.titled, .fullSizeContentView] : .borderless
        )
        defer { fixture.close() }
        let receiver = try await fixture.mount()
        let outline = try #require(descendant(in: fixture.hosting, ofType: NSOutlineView.self))
        if afterScrolling {
            outline.scrollRowToVisible(20)
            fixture.hosting.layoutSubtreeIfNeeded()
        }
        let rows = (0..<outline.numberOfRows).filter { row in
            let frame = outline.rect(ofRow: row)
            // A partially clipped row can have its top outside the receiver.
            // Compare only insertion boundaries the pointer can actually reach.
            guard outline.visibleRect.contains(CGPoint(x: frame.midX, y: frame.minY + 2)) else { return false }
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true),
                let menu = descendant(in: cell, ofType: NativeRowContextMenu.RowMenuView.self)
            else { return false }
            return menu.entries().contains { $0.title == "Close Workspace" }
        }
        #expect(!rows.isEmpty)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(workspaces[0].id.uuidString, forType: .string)
        fixture.model.dragging = .workspace(workspaces[0].id)
        for row in rows {
            let frame = receiver.convert(outline.rect(ofRow: row), from: outline)
            let point = CGPoint(x: frame.midX, y: frame.minY + 2)
            #expect(receiver.update(at: point, pasteboard: pasteboard) == .move)
            let preview = try #require(receiver.previewRect)
            #expect(abs(preview.midY - frame.minY) < 3)
        }
    }

    @Test(.requiresVisibleWindow)
    @available(macOS 26.0, *)
    func mouseDraggingAWorkspaceRowStartsANativeDraggingSession() async throws {
        let workspaces = [workspace("First"), workspace("Middle"), workspace("Last")]
        let fixture = try Fixture(workspaces: workspaces, topInset: 80)
        defer { fixture.close() }
        let receiver = try await fixture.mount()
        let outline = try #require(descendant(in: fixture.hosting, ofType: NSOutlineView.self))
        let row = try #require(
            (0..<outline.numberOfRows).first { row in
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true),
                    let menu = descendant(in: cell, ofType: NativeRowContextMenu.RowMenuView.self)
                else { return false }
                return menu.entries().contains { $0.title == "Close Workspace" }
            }
        )
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.model.select(workspaces[0].id)
        fixture.hosting.layoutSubtreeIfNeeded()
        let start = outline.convert(CGPoint(x: 100, y: outline.rect(ofRow: row).midY), to: nil)
        let pasteboard = NSPasteboard(name: .drag)
        let previousChangeCount = pasteboard.changeCount
        // AppKit consumes drag events inside its tracking loop before local
        // event monitors see them. Observe that loop without changing the
        // source state, so the preview is checked during a real live session.
        let observer = try #require(
            CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, _ in
                MainActor.assumeIsolated {
                    if fixture.dragPreviewChecks == 0,
                        fixture.model.dragging == .workspace(workspaces[0].id),
                        pasteboard.string(forType: .string) == workspaces[0].id.uuidString
                    {
                        fixture.dragPreviewChecks += 1
                        let frame = receiver.convert(outline.rect(ofRow: row + 1), from: outline)
                        let point = CGPoint(x: frame.midX, y: frame.minY + 2)
                        #expect(receiver.update(at: point, pasteboard: pasteboard) == .move)
                        #expect(receiver.previewRect != nil)
                        if let preview = receiver.previewRect {
                            #expect(abs(preview.midY - frame.minY) < 3)
                        }
                    }
                }
            }
        )
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopAddObserver(
            CFRunLoopGetMain(), observer, CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString)
        )
        defer { CFRunLoopObserverInvalidate(observer) }
        let types: [NSEvent.EventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp]
        for (index, type) in types.enumerated() {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: CGPoint(x: start.x + CGFloat(index * 20), y: start.y - CGFloat(index * 20)),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                    windowNumber: fixture.window.windowNumber,
                    context: nil,
                    eventNumber: index,
                    clickCount: 1,
                    pressure: 1
                )
            )
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
        // Only real mouse dispatch may populate the native drag pasteboard;
        // this test never requests a writer or sets the model's drag state.
        #expect(pasteboard.changeCount > previousChangeCount)
        #expect(pasteboard.string(forType: .string) == workspaces[0].id.uuidString)
        #expect(fixture.dragPreviewChecks > 0)
        #expect(fixture.model.dragging == nil)
        #expect(fixture.model.displayedWorkspace === fixture.model.selectedWorkspace)
    }

    @Test
    @available(macOS 26.0, *)
    func queryingWorkspaceDragPayloadDoesNotStartALayoutDrag() async throws {
        let workspaces = [workspace("First"), workspace("Middle"), workspace("Last")]
        let fixture = try Fixture(workspaces: workspaces)
        defer { fixture.close() }
        _ = try await fixture.mount()

        let outline = try #require(descendant(in: fixture.hosting, ofType: NSOutlineView.self))
        let source = try #require(outline.dataSource)
        #expect(fixture.model.dragging == nil)
        var writtenIDs: [UUID] = []
        for row in 0..<outline.numberOfRows {
            let item = try #require(outline.item(atRow: row))
            // List also requests writers after ordinary clicks. Reading a
            // payload must not alter selection or enter the drag preview.
            guard let writer = source.outlineView?(outline, pasteboardWriterForItem: item) else {
                #expect(fixture.model.dragging == nil)
                continue
            }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            #expect(pasteboard.writeObjects([writer]))
            let value = try #require(pasteboard.string(forType: .string))
            let writtenID = try #require(UUID(uuidString: value))
            #expect(fixture.model.dragging == nil)
            writtenIDs.append(writtenID)
        }
        #expect(writtenIDs == workspaces.map(\.id))
    }

    @Test(.requiresVisibleWindow)
    @available(macOS 26.0, *)
    func draggingASplitWorkspaceOutsideItsSourceMovesTheWholeLayout() async throws {
        let workspace = workspace("Split")
        workspace.splitFocusedPane(
            axis: .horizontal,
            with: .sshSession(host: TermindDomain.Host(name: "Second", host: "second.invalid"))
        )
        let paneIDs = workspace.panes.map(\.id)
        let fixture = try Fixture(workspaces: [workspace])
        defer { fixture.close() }
        _ = try await fixture.mount()
        fixture.app.mainWindows.register(fixture.window, model: fixture.model, requestID: nil)
        var requests: [UUID] = []
        fixture.app.mainWindows.createScene = { requests.append($0) }

        let release = NSEvent.mouseLocation
        let screen = try #require(NSScreen.main).visibleFrame
        let originX = release.x < screen.midX ? screen.maxX - fixture.window.frame.width : screen.minX
        fixture.window.setFrameOrigin(CGPoint(x: originX, y: screen.minY))
        try #require(!fixture.window.frame.contains(release))
        let other = NSWindow(
            contentRect: CGRect(x: release.x - 50, y: release.y - 50, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.orderFrontRegardless()
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(200))
        let outline = try #require(descendant(in: fixture.hosting, ofType: NSOutlineView.self))
        let dragSource = try #require(outline.dataSource as? WorkspaceNavigatorDragAnimationDataSource)
        let configureSession = dragSource.configureSession
        var configuredSessions = 0
        dragSource.configureSession = { session in
            configureSession(session)
            #expect(!session.animatesToStartingPositionsOnCancelOrFail)
            configuredSessions += 1
        }
        let row = try #require(
            (0..<outline.numberOfRows).first { row in
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true),
                    let menu = descendant(in: cell, ofType: NativeRowContextMenu.RowMenuView.self)
                else { return false }
                return menu.entries().contains { $0.title == "Close Workspace" }
            })
        let start = outline.convert(CGPoint(x: 100, y: outline.rect(ofRow: row).midY), to: nil)
        let end = fixture.window.convertPoint(fromScreen: release)
        let events: [(NSEvent.EventType, CGPoint)] = [
            (.leftMouseDown, start),
            (.leftMouseDragged, CGPoint(x: start.x + 20, y: start.y - 20)),
            (.leftMouseDragged, end), (.leftMouseUp, end),
        ]
        for (index, entry) in events.enumerated() {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: entry.0, location: entry.1, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.05,
                    windowNumber: fixture.window.windowNumber, context: nil,
                    eventNumber: index, clickCount: 1, pressure: 1
                ))
            NSApp.postEvent(event, atStart: false)
        }
        let deadline = Date(timeIntervalSinceNow: 1)
        while Date() < deadline {
            if let event = NSApp.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true
            ) {
                NSApp.sendEvent(event)
            }
        }
        #expect(requests.count == 1)
        #expect(configuredSessions == 1)
        #expect(fixture.model.selectedWorkspace === workspace)
        #expect(fixture.model.dragging == nil)
        let request = try #require(requests.first)
        let destination = WindowModel()
        // Claim the request only after native drag completion, as a real scene does.
        fixture.app.mainWindows.register(other, model: destination, requestID: request)
        #expect(destination.selectedWorkspace === workspace)
        #expect(workspace.panes.map(\.id) == paneIDs)
        #expect(fixture.model.workspaces.isEmpty)
    }

    @Test(arguments: [false, true])
    func mountedNavigatorReordersUsingDragStateSetBeforeTheNextRender(moveToEnd: Bool) async throws {
        let workspaces = [workspace("First"), workspace("Middle"), workspace("Last")]
        let fixture = try Fixture(workspaces: workspaces)
        defer { fixture.close() }
        let receiver = try await fixture.mount()
        #expect(fixture.model.dragging == nil)
        #expect(receiver.draggedID() == nil)
        #expect(receiver.previewRect == nil)

        let source = moveToEnd ? workspaces[0] : workspaces[2]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.id.uuidString, forType: .string)

        // Do not yield or lay out after this mutation: AppKit can call the
        // already-mounted receiver before SwiftUI renders the new drag state.
        fixture.model.dragging = .workspace(source.id)
        let firstPoint = CGPoint(x: receiver.bounds.midX, y: receiver.bounds.minY + 1)
        let lastPoint = CGPoint(x: receiver.bounds.midX, y: receiver.bounds.maxY - 1)
        #expect(receiver.update(at: firstPoint, pasteboard: pasteboard) == .move)
        let firstPreview = try #require(receiver.previewRect)
        #expect(receiver.update(at: lastPoint, pasteboard: pasteboard) == .move)
        let lastPreview = try #require(receiver.previewRect)
        #expect(lastPreview.minY > firstPreview.maxY)
        #expect(firstPreview.height == 2 && lastPreview.height == 2)

        let point = moveToEnd ? lastPoint : firstPoint
        #expect(receiver.receive(at: point, pasteboard: pasteboard))
        let expected =
            moveToEnd
            ? [workspaces[1], workspaces[2], workspaces[0]]
            : [
                workspaces[2], workspaces[0], workspaces[1],
            ]
        #expect(fixture.model.workspaces.map(\.id) == expected.map(\.id))
        #expect(fixture.model.dragging == nil)
        #expect(receiver.previewRect == nil)
    }

    @Test
    func mountedNavigatorDetachesAPaneWithoutRenderingTheDragState() async throws {
        let source = workspace("Source")
        let originalPane = source.focusedPane
        source.splitFocusedPane(
            axis: .horizontal,
            with: .sshSession(host: TermindDomain.Host(name: "Detached", host: "detached.invalid"))
        )
        let draggedPane = source.focusedPane
        let neighbour = workspace("Neighbour")
        let fixture = try Fixture(workspaces: [source, neighbour])
        defer { fixture.close() }
        let receiver = try await fixture.mount()
        #expect(receiver.draggedID() == nil)

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(draggedPane.id.uuidString, forType: .string)
        fixture.model.dragging = .pane(draggedPane.id)
        let point = CGPoint(x: receiver.bounds.midX, y: receiver.bounds.minY + 1)
        #expect(receiver.update(at: point, pasteboard: pasteboard) == .move)
        #expect(receiver.previewRect != nil)
        #expect(receiver.receive(at: point, pasteboard: pasteboard))

        let detached = try #require(fixture.model.workspaces.first)
        #expect(fixture.model.workspaces.map(\.id) == [detached.id, source.id, neighbour.id])
        #expect(detached.focusedPane === draggedPane)
        #expect(source.panes.map(\.id) == [originalPane.id])
        #expect(fixture.model.selectedWorkspace === detached)
        #expect(fixture.model.dragging == nil)
        #expect(receiver.previewRect == nil)
    }

    @Test
    func mountedNavigatorRejectsDropsAfterTheSidebarModeChangesWithoutRendering() async throws {
        let workspaces = [workspace("First"), workspace("Last")]
        let fixture = try Fixture(workspaces: workspaces)
        defer { fixture.close() }
        let receiver = try await fixture.mount()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(workspaces[0].id.uuidString, forType: .string)
        fixture.model.dragging = .workspace(workspaces[0].id)
        let point = CGPoint(x: receiver.bounds.midX, y: receiver.bounds.maxY - 1)
        #expect(receiver.update(at: point, pasteboard: pasteboard) == .move)
        #expect(receiver.previewRect != nil)

        fixture.model.sidebarMode = .assistant
        #expect(receiver.update(at: point, pasteboard: pasteboard).isEmpty)
        #expect(receiver.previewRect == nil)
        #expect(!receiver.receive(at: point, pasteboard: pasteboard))
        #expect(fixture.model.workspaces.map(\.id) == workspaces.map(\.id))
    }

    private func workspace(_ name: String) -> Workspace {
        .sshSession(host: TermindDomain.Host(name: name, host: "\(name.lowercased()).invalid"))
    }

    private func descendant<T: NSView>(in view: NSView, ofType type: T.Type) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { descendant(in: $0, ofType: type) }.first
    }

    private final class Fixture {
        let app = AppModel(hosts: HostLibraryModel())
        let model: WindowModel
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
        let defaults: UserDefaults
        let defaultsName = "WorkspaceNavigatorDropTests.\(UUID().uuidString)"
        var dragPreviewChecks = 0

        init(
            workspaces: [Workspace], topInset: CGFloat = 0,
            styleMask: NSWindow.StyleMask = .borderless
        ) throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            defaults.set(false, forKey: DesktopSettingsKey.vaultSectionExpanded)
            defaults.set(true, forKey: DesktopSettingsKey.workspaceSectionExpanded)
            model = WindowModel(workspaces: workspaces)
            model.sidebarMode = .navigation
            hosting = NSHostingView(
                rootView: AnyView(
                    WorkspaceNavigatorView()
                        .padding(.top, topInset)
                        .environment(app)
                        .environment(model)
                        .environment(\.locale, Locale(identifier: "en"))
                        .defaultAppStorage(defaults)
                )
            )
            let bounds = CGRect(x: 0, y: 0, width: 320, height: 800)
            window = NSWindow(contentRect: bounds, styleMask: styleMask, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosting.sizingOptions = []
            window.contentView = hosting
            hosting.frame = bounds
        }

        func mount() async throws -> WorkspaceLayoutDropNSView {
            hosting.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let receiver = try #require(dropReceiver(in: hosting))
            #expect(receiver.bounds.width > 300 && receiver.bounds.height > 600)
            #expect(!window.isVisible)
            return receiver
        }

        func close() {
            window.contentView = nil
            window.close()
            model.closeAll()
            app.shutdownForTermination()
            defaults.removePersistentDomain(forName: defaultsName)
        }

        private func dropReceiver(in view: NSView) -> WorkspaceLayoutDropNSView? {
            if let receiver = view as? WorkspaceLayoutDropNSView { return receiver }
            return view.subviews.lazy.compactMap { self.dropReceiver(in: $0) }.first
        }
    }
}
