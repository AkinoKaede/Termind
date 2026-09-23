import AppKit
import SwiftUI
import TermindPresentation

enum WorkspaceLayoutDropPreviewStyle {
    case insertion
    case pane
}

/// Mounted before a drag starts. AppKit can enter its tracking loop before
/// SwiftUI renders the source's drag state, so both eligibility and feedback
/// are resolved in the native callbacks instead of a subsequent render pass.
struct WorkspaceLayoutDropTarget: NSViewRepresentable {
    let draggedID: () -> UUID?
    var previewStyle: WorkspaceLayoutDropPreviewStyle = .pane
    let preview: (CGPoint, CGSize) -> CGRect?
    let perform: (CGPoint, CGSize) -> Bool

    func makeNSView(context _: Context) -> WorkspaceLayoutDropNSView {
        WorkspaceLayoutDropNSView()
    }

    func updateNSView(_ view: WorkspaceLayoutDropNSView, context _: Context) {
        view.draggedID = draggedID
        view.previewStyle = previewStyle
        view.preview = preview
        view.perform = perform
        view.clearPreviewIfInactive()
    }
}

@MainActor
final class WorkspaceLayoutDropNSView: NSView {
    var draggedID: () -> UUID? = { nil }
    var previewStyle = WorkspaceLayoutDropPreviewStyle.pane
    var preview: (CGPoint, CGSize) -> CGRect? = { _, _ in nil }
    var perform: (CGPoint, CGSize) -> Bool = { _, _ in false }

    private(set) var previewRect: CGRect?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Keep registration stable even for a parked workspace: picking up the
        // selected workspace can make its neighbour the live merge destination
        // before SwiftUI updates either view. Every entry point checks the live
        // owner so hidden and omitted panes still refuse the drag.
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return participates(
            at: localPoint,
            currentEventType: NSApp.currentEvent?.type,
            pasteboard: NSPasteboard(name: .drag)
        ) ? self : nil
    }

    /// Explicit ambient inputs keep tests independent of real mouse events and
    /// the machine-wide drag pasteboard. Points here are in this view's bounds.
    func participates(
        at point: CGPoint,
        currentEventType: NSEvent.EventType?,
        pasteboard: NSPasteboard
    ) -> Bool {
        !FileURLDropNSView.isOrdinaryPointerEvent(currentEventType)
            && accepts(point, pasteboard: pasteboard)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(at: location(of: sender), pasteboard: sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(at: location(of: sender), pasteboard: sender.draggingPasteboard)
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        clearPreview()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        receive(at: location(of: sender), pasteboard: sender.draggingPasteboard)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearPreview()
        super.concludeDragOperation(sender)
    }

    func update(at point: CGPoint, pasteboard: NSPasteboard) -> NSDragOperation {
        guard accepts(point, pasteboard: pasteboard) else {
            clearPreview()
            return []
        }
        previewRect = preview(point, bounds.size)
        needsDisplay = true
        // Invalid inner targets still finish an internal drag and clear its
        // transient state on release, matching the pane's cancellation policy.
        return .move
    }

    func receive(at point: CGPoint, pasteboard: NSPasteboard) -> Bool {
        defer { clearPreview() }
        guard accepts(point, pasteboard: pasteboard) else { return false }
        return perform(point, bounds.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let previewRect else { return }
        let accent = TermindColor.nativeAccent
        switch previewStyle {
        case .insertion:
            accent.setFill()
            NSBezierPath(roundedRect: previewRect, xRadius: 1, yRadius: 1).fill()
        case .pane:
            accent.withAlphaComponent(0.25).setFill()
            previewRect.fill()
            accent.setStroke()
            let border = NSBezierPath(rect: previewRect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func accepts(_ point: CGPoint, pasteboard: NSPasteboard) -> Bool {
        guard bounds.contains(point), let id = draggedID(),
            let value = pasteboard.string(forType: .string)
        else { return false }
        // The model can outlive a cancelled drag. An unrelated text/file drag
        // must not be mistaken for that old internal workspace payload.
        return UUID(uuidString: value) == id
    }

    private func clearPreview() {
        previewRect = nil
        needsDisplay = true
    }

    func clearPreviewIfInactive() {
        if draggedID() == nil { clearPreview() }
    }

    private func location(of sender: any NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }
}
