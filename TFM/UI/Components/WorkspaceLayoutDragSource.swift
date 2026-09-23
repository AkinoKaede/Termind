import AppKit
import SwiftUI

/// Keeps ordinary row/header interaction in SwiftUI while giving layout drags
/// a native completion callback on every supported macOS version.
struct WorkspaceLayoutDragSource: ViewModifier {
    let window: WindowModel
    let payload: DragPayload
    let title: String
    let symbol: String
    var excludedTrailingWidth: CGFloat = 0
    let onTearOff: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.background {
            WorkspaceLayoutDragSourceBridge(
                model: window, payload: payload, title: title, symbol: symbol,
                excludedTrailingWidth: excludedTrailingWidth, onTearOff: onTearOff
            )
        }
    }
}

private struct WorkspaceLayoutDragSourceBridge: NSViewRepresentable {
    let model: WindowModel
    let payload: DragPayload
    let title: String
    let symbol: String
    let excludedTrailingWidth: CGFloat
    let onTearOff: (CGPoint) -> Void

    func makeNSView(context _: Context) -> WorkspaceLayoutDragSourceNSView {
        WorkspaceLayoutDragSourceNSView()
    }

    func updateNSView(_ view: WorkspaceLayoutDragSourceNSView, context _: Context) {
        view.model = model
        view.payload = payload
        view.title = title
        view.symbol = symbol
        view.excludedTrailingWidth = excludedTrailingWidth
        view.onTearOff = onTearOff
        view.attachRecognizer()
    }

    static func dismantleNSView(_ view: WorkspaceLayoutDragSourceNSView, coordinator _: ()) {
        view.detachRecognizer()
    }
}

enum WorkspaceLayoutDragCompletion {
    /// SwiftUI's native List owns Workspace drags. Its existing completion
    /// callback can share the release policy without replacing its drag source.
    static func shouldTearOffAtCurrentPointer(outside sourceFrame: CGRect?, cancelled: Bool) -> Bool {
        guard let sourceFrame else { return false }
        let event = NSApp.currentEvent
        return shouldTearOff(
            operation: [], primaryButtonPressed: NSEvent.pressedMouseButtons & 1 != 0,
            cancelled: cancelled || (event?.type == .keyDown && event?.keyCode == 53),
            payloadMatches: true, screenPoint: NSEvent.mouseLocation,
            windowFrames: [sourceFrame]
        )
    }

    static func shouldTearOff(
        operation: NSDragOperation,
        primaryButtonPressed: Bool,
        cancelled: Bool,
        payloadMatches: Bool,
        screenPoint: CGPoint,
        windowFrames: [CGRect]
    ) -> Bool {
        operation.isEmpty && !primaryButtonPressed && !cancelled && payloadMatches
            && !windowFrames.contains { $0.contains(screenPoint) }
    }
}

@MainActor
final class WorkspaceLayoutDragSourceNSView: NSView, NSGestureRecognizerDelegate, NSDraggingSource {
    weak var model: WindowModel?
    var payload: DragPayload?
    var title = ""
    var symbol = ""
    var excludedTrailingWidth: CGFloat = 0
    var onTearOff: (CGPoint) -> Void = { _ in }

    private(set) lazy var panRecognizer: NSPanGestureRecognizer = {
        let recognizer = WorkspaceLayoutPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        recognizer.buttonMask = 1
        recognizer.delaysPrimaryMouseButtonEvents = false
        recognizer.delaysSecondaryMouseButtonEvents = false
        recognizer.delaysKeyEvents = false
        recognizer.delegate = self
        return recognizer
    }()

    private var activePayload: DragPayload?
    private weak var activeModel: WindowModel?
    private var cancelled = false
    private var escapeMonitor: Any?

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachRecognizer()
    }

    func attachRecognizer() {
        let destination = window?.contentView
        guard panRecognizer.view !== destination else { return }
        panRecognizer.view?.removeGestureRecognizer(panRecognizer)
        if let destination {
            destination.addGestureRecognizer(panRecognizer)
        } else {
            cancelTracking()
        }
    }

    func detachRecognizer() {
        panRecognizer.view?.removeGestureRecognizer(panRecognizer)
        cancelTracking()
    }

    func gestureRecognizer(
        _: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1,
            event.window === window, activePayload == nil,
            isEligible
        else { return false }
        return acceptsDragStart(at: convert(event.locationInWindow, from: nil))
    }

    func gestureRecognizer(
        _: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith _: NSGestureRecognizer
    ) -> Bool {
        true
    }

    var isEligible: Bool {
        guard let model, !model.isClosed, model.dragging == nil else { return false }
        switch payload {
        case .workspace(let id):
            return model.sidebar.isPresented && model.sidebarMode == .navigation
                && model.workspaces.contains { $0.id == id }
        case .pane(let id):
            return model.displayedWorkspace?.layout.pane(id)?.isCombinable == true
        case .assistantConversation, nil:
            return false
        }
    }

    /// Includes clipping by the native List/scroll view, so a parked row or
    /// collapsed pane cannot claim a gesture at its old frame.
    func acceptsDragStart(at point: CGPoint) -> Bool {
        guard bounds.contains(point), !isHiddenOrHasHiddenAncestor, visibleRect.contains(point) else { return false }
        guard point.x < bounds.maxX - excludedTrailingWidth else { return false }
        if let root = window?.contentView {
            var hit = root.hitTest(convert(point, to: root.superview))
            while let view = hit, view !== root {
                // NSTableView is also NSControl; excluding that ancestor would
                // disable every row in the native Navigator List.
                if view is NSButton || view is NSTextField || view is NSTextView { return false }
                hit = view.superview
            }
        }
        return true
    }

    @objc private func drag(_ recognizer: WorkspaceLayoutPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed,
            activePayload == nil, let event = recognizer.dragEvent,
            let payload, let writer = pasteboardItem(for: payload), window != nil
        else { return }

        let image = dragImage()
        let point = convert(event.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(
            CGRect(
                x: point.x - 12, y: point.y - image.size.height / 2, width: image.size.width, height: image.size.height),
            contents: image
        )
        guard beginTracking() else { return }
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Escape and an unhandled drop both report an empty operation. End
        // immediately so button state still distinguishes Escape from release.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    @discardableResult
    func beginTracking() -> Bool {
        guard activePayload == nil, isEligible, let model, let payload else { return false }
        activePayload = payload
        activeModel = model
        cancelled = false
        model.dragging = payload
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelled = true }
            return event
        }
        return true
    }

    func draggingSession(
        _: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // The UUID is an internal routing value, never text to insert in a
        // foreign application. An outside release belongs to our tear-off.
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for _: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        let event = NSApp.currentEvent
        finishTracking(
            at: screenPoint, operation: operation,
            primaryButtonPressed: NSEvent.pressedMouseButtons & 1 != 0,
            currentEventIsEscape: event?.type == .keyDown && event?.keyCode == 53,
            windowFrames: window.map { [$0.frame] } ?? []
        )
    }

    func finishTracking(
        at screenPoint: CGPoint,
        operation: NSDragOperation,
        primaryButtonPressed: Bool,
        currentEventIsEscape: Bool,
        windowFrames: [CGRect]
    ) {
        guard let activePayload, let model = activeModel else {
            stopEscapeMonitor()
            return
        }
        let shouldTearOff = WorkspaceLayoutDragCompletion.shouldTearOff(
            operation: operation, primaryButtonPressed: primaryButtonPressed,
            cancelled: cancelled || currentEventIsEscape,
            payloadMatches: model.dragging == activePayload,
            screenPoint: screenPoint, windowFrames: windowFrames
        )
        self.activePayload = nil
        activeModel = nil
        stopEscapeMonitor()
        // Destinations mutate first and clear preview state second, preserving
        // the single native terminal parent during pane reparenting.
        defer {
            if model.dragging == activePayload { model.dragging = nil }
        }
        if shouldTearOff { onTearOff(screenPoint) }
    }

    private func cancelTracking() {
        if let activePayload, activeModel?.dragging == activePayload {
            activeModel?.dragging = nil
        }
        activePayload = nil
        activeModel = nil
        stopEscapeMonitor()
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func pasteboardItem(for payload: DragPayload) -> NSPasteboardItem? {
        let id: UUID
        switch payload {
        case .workspace(let value), .pane(let value): id = value
        case .assistantConversation: return nil
        }
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .string)
        return item
    }

    private func dragImage() -> NSImage {
        let renderer = ImageRenderer(content: ItemDragPreview(title: title, symbol: symbol))
        renderer.scale = window?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: CGSize(width: 120, height: 32))
    }
}

/// AppKit schedules recognizer actions after processing their event. Retain the
/// actual drag event instead of depending on NSApp.currentEvent still being it.
@MainActor
private final class WorkspaceLayoutPanGestureRecognizer: NSPanGestureRecognizer {
    private(set) var dragEvent: NSEvent?

    override func mouseDragged(with event: NSEvent) {
        dragEvent = event
        super.mouseDragged(with: event)
    }

    override func reset() {
        dragEvent = nil
        super.reset()
    }
}
