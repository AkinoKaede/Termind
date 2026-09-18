import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A private, process-local identifier, never a text or file export to another app.
nonisolated enum WorkspaceDragType {
    static let identifier = "com.akinokaede.Termind.workspace-drag"
    static let pasteboard = NSPasteboard.PasteboardType(identifier)
    static let content = UTType(exportedAs: identifier)
}

struct WorkspaceWindowDragSource: NSViewRepresentable {
    let model: WindowModel
    let workspaceID: UUID
    let title: String
    let hint: String
    let coordinator: MainWindowCoordinator

    func makeNSView(context: Context) -> WorkspaceDragSourceView { WorkspaceDragSourceView() }

    func updateNSView(_ view: WorkspaceDragSourceView, context: Context) {
        view.model = model
        view.workspaceID = workspaceID
        view.title = title
        view.hint = hint
        view.coordinator = coordinator
    }

    static func dismantleNSView(_ view: WorkspaceDragSourceView, coordinator: ()) {
        view.stopObserving()
    }
}

/// Observes the row without intercepting clicks, its rename editor, context menu,
/// or trailing close button. Only a drag beyond the native-style threshold is consumed.
final class WorkspaceDragSourceView: NSView {
    weak var model: WindowModel?
    var workspaceID: UUID?
    var title = ""
    var hint = ""
    weak var coordinator: MainWindowCoordinator?
    private var monitor: Any?
    private var mouseDownPoint: CGPoint?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.receive(event) == nil
            }
            return consumed ? nil : event
        }
    }

    isolated deinit { stopObserving() }

    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        mouseDownPoint = nil
    }

    private func receive(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !isHiddenOrHasHiddenAncestor else {
            mouseDownPoint = nil
            return event
        }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            // The last 28 points belong to Close and its hover affordance.
            mouseDownPoint = bounds.contains(point) && point.x < bounds.maxX - 28 ? point : nil
        case .leftMouseUp:
            mouseDownPoint = nil
        case .leftMouseDragged:
            guard let start = mouseDownPoint,
                hypot(point.x - start.x, point.y - start.y) >= 6,
                let model, !model.isClosed, let workspaceID,
                model.workspaces.contains(where: { $0.id == workspaceID }),
                let coordinator, coordinator.activeWorkspaceDrag == nil
            else { return event }
            mouseDownPoint = nil
            let source = WorkspaceWindowDragSession(
                model: model, workspaceID: workspaceID, title: title, hint: hint, coordinator: coordinator)
            coordinator.activeWorkspaceDrag = source
            model.dragging = .workspace(workspaceID)
            let pasteboard = NSPasteboardItem()
            pasteboard.setString(workspaceID.uuidString, forType: WorkspaceDragType.pasteboard)
            let item = NSDraggingItem(pasteboardWriter: pasteboard)
            let image = source.image(outside: false)
            item.setDraggingFrame(
                CGRect(
                    x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                    width: image.size.width, height: image.size.height), contents: image)
            let session = beginDraggingSession(with: [item], event: event, source: source)
            session.draggingFormation = .none
            return nil
        default:
            break
        }
        return event
    }
}

/// Retained by the process coordinator until AppKit ends the drag, even when an
/// internal merge removes the source row. Cancellation is distinct from a refused drop.
final class WorkspaceWindowDragSession: NSObject, NSDraggingSource {
    private weak var model: WindowModel?
    private let workspaceID: UUID
    private let title: String
    private let hint: String
    private weak var coordinator: MainWindowCoordinator?
    private var keyMonitor: Any?
    private var cancelled = false
    private var finished = false
    private var outside = false

    init(model: WindowModel, workspaceID: UUID, title: String, hint: String, coordinator: MainWindowCoordinator) {
        self.model = model
        self.workspaceID = workspaceID
        self.title = title
        self.hint = hint
        self.coordinator = coordinator
        super.init()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 { self?.cancelled = true }
            }
            return event
        }
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        let next = !Self.appWindowFrames.contains { $0.contains(screenPoint) }
        guard next != outside else { return }
        outside = next
        session.animatesToStartingPositionsOnCancelOrFail = !outside
        let image = image(outside: outside)
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) {
            item, _, _ in
            item.setDraggingFrame(CGRect(origin: item.draggingFrame.origin, size: image.size), contents: image)
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard !finished else { return }
        finished = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let currentEvent = NSApp.currentEvent
        let escaped = currentEvent?.type == .keyDown && currentEvent?.keyCode == 53
        let shouldMove = Self.shouldOpenWindow(
            cancelled: cancelled || escaped,
            mouseReleased: NSEvent.pressedMouseButtons & 1 == 0,
            operation: operation,
            hasUnhandledWorkspace: model?.isClosed == false && model?.dragging == .workspace(workspaceID),
            at: screenPoint, windowFrames: Self.appWindowFrames)
        if model?.dragging == .workspace(workspaceID) { model?.dragging = nil }
        if coordinator?.activeWorkspaceDrag === self { coordinator?.activeWorkspaceDrag = nil }
        if shouldMove, let model {
            // Leave AppKit's drag callback before creating/activating a scene.
            Task { @MainActor [weak coordinator] in
                coordinator?.moveWorkspace(workspaceID, from: model, at: screenPoint)
            }
        }
    }

    static func shouldOpenWindow(
        cancelled: Bool, mouseReleased: Bool, operation: NSDragOperation,
        hasUnhandledWorkspace: Bool, at point: CGPoint, windowFrames: [CGRect]
    ) -> Bool {
        !cancelled && mouseReleased && operation.isEmpty && hasUnhandledWorkspace
            && !windowFrames.contains { $0.contains(point) }
    }

    private static var appWindowFrames: [CGRect] {
        NSApp.windows.filter {
            $0.isVisible && !$0.isMiniaturized && $0.isOnActiveSpace
                && ($0.canBecomeKey || $0.styleMask.contains(.titled))
        }.map(\.frame)
    }

    func image(outside: Bool) -> NSImage {
        let size = NSSize(width: 280, height: outside ? 62 : 36)
        let title = title
        let hint = hint
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(
                in: CGRect(x: 12, y: rect.height - 27, width: rect.width - 24, height: 20),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                ])
            if outside {
                (hint as NSString).draw(
                    in: CGRect(x: 12, y: 9, width: rect.width - 24, height: 18),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
                    ])
            }
            return true
        }
    }
}
