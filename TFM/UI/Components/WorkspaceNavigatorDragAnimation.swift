import AppKit
import SwiftUI

/// Configures native List drag animation without replacing its drag or drop behavior.
struct WorkspaceNavigatorDragAnimation: NSViewRepresentable {
    let configureSession: (NSDraggingSession) -> Void

    func makeNSView(context _: Context) -> WorkspaceNavigatorDragAnimationView {
        WorkspaceNavigatorDragAnimationView()
    }

    func updateNSView(_ view: WorkspaceNavigatorDragAnimationView, context _: Context) {
        view.configureSession = configureSession
        view.refreshBinding()
    }

    static func dismantleNSView(_ view: WorkspaceNavigatorDragAnimationView, coordinator _: ()) {
        view.unbind()
    }
}

@MainActor
final class WorkspaceNavigatorDragAnimationView: NSView {
    var configureSession: (NSDraggingSession) -> Void = { _ in }
    private weak var outline: NSOutlineView?
    private var proxy: WorkspaceNavigatorDragAnimationDataSource?
    private var dataSourceObservation: NSKeyValueObservation?
    private var refreshScheduled = false

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { unbind() } else { scheduleRefresh() }
    }

    override func layout() {
        super.layout()
        scheduleRefresh()
    }

    func refreshBinding() {
        guard window != nil, let candidate = enclosingOutline() else {
            unbind()
            return
        }
        if outline !== candidate {
            unbind()
            outline = candidate
            dataSourceObservation = candidate.observe(\.dataSource, options: [.new]) { [weak self] outline, _ in
                MainActor.assumeIsolated {
                    guard let self, outline.dataSource !== self.proxy else { return }
                    // Let SwiftUI finish assigning its replacement before wrapping it.
                    self.scheduleRefresh()
                }
            }
        }
        guard let original = candidate.dataSource, original !== proxy else { return }
        let replacement = WorkspaceNavigatorDragAnimationDataSource(forwarding: original) { [weak self] session in
            self?.configureSession(session)
        }
        proxy = replacement
        candidate.dataSource = replacement
    }

    func unbind() {
        dataSourceObservation = nil
        if let outline, let proxy, outline.dataSource === proxy {
            outline.dataSource = proxy.forwardedDataSource
        }
        outline = nil
        proxy = nil
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshBinding()
        }
    }

    /// The marker is the List's background. Search its nearest enclosing native
    /// hierarchy, requiring the List viewport to cover the marker's center; never
    /// select an unrelated outline elsewhere in the window.
    private func enclosingOutline() -> NSOutlineView? {
        guard !bounds.isEmpty else { return nil }
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        var ancestor = superview
        while let container = ancestor {
            let candidates = outlines(in: container).filter { outline in
                let viewport: NSView = outline.enclosingScrollView ?? outline
                return viewport.convert(viewport.bounds, to: nil).contains(center)
            }
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 { return nil }
            ancestor = container.superview
        }
        return nil
    }

    private func outlines(in view: NSView) -> [NSOutlineView] {
        if let outline = view as? NSOutlineView { return [outline] }
        return view.subviews.flatMap { outlines(in: $0) }
    }
}

/// NSObject's metadata forwarding is nonisolated; AppKit invokes data-source
/// behavior on the main actor through NSOutlineViewDataSource's annotations.
nonisolated final class WorkspaceNavigatorDragAnimationDataSource: NSObject, NSOutlineViewDataSource {
    weak var forwardedDataSource: (any NSOutlineViewDataSource)?
    @MainActor var configureSession: (NSDraggingSession) -> Void

    @MainActor
    init(
        forwarding original: any NSOutlineViewDataSource,
        configureSession: @escaping (NSDraggingSession) -> Void
    ) {
        forwardedDataSource = original
        self.configureSession = configureSession
        super.init()
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDataSource?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDataSource?.responds(to: selector) == true { return forwardedDataSource }
        return super.forwardingTarget(for: selector)
    }

    @MainActor
    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        forwardedDataSource?.outlineView?(
            outlineView, draggingSession: session, willBeginAt: screenPoint, forItems: draggedItems
        )
        configureSession(session)
    }
}
