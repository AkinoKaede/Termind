import AppKit
import SwiftUI

/// Process-owned scene requests; live workspaces stay in their source until the
/// destination has a native window. Scene restoration never replays a move.
@MainActor
@Observable
final class MainWindowCoordinator {
    private enum Move: Equatable {
        case workspace(UUID)
        case pane(UUID)
    }

    private final class Entry {
        weak var window: NSWindow?
        weak var model: WindowModel?
        var normalSize: CGSize?
        var isTransitioningFullScreen = false
        var isReady = false
        init(window: NSWindow, model: WindowModel) {
            self.window = window
            self.model = model
        }
    }

    private final class Request {
        weak var source: WindowModel?
        let move: Move?
        let showsMetrics: Bool
        /// AppKit content coordinates, including the titlebar for the main
        /// window's full-size content view. Never a fullscreen frame.
        let sourceSize: CGSize
        let screenPoint: CGPoint?

        init(
            source: WindowModel? = nil, move: Move? = nil,
            showsMetrics: Bool = false, sourceSize: CGSize, screenPoint: CGPoint? = nil
        ) {
            self.source = source
            self.move = move
            self.showsMetrics = showsMetrics
            self.sourceSize = sourceSize
            self.screenPoint = screenPoint
        }

        func takeWorkspace() -> Workspace? {
            guard let source else { return nil }
            switch move {
            case .workspace(let id): return source.takeWorkspaceForMove(id)
            case .pane(let id): return source.takePaneForMove(id)
            case nil: return nil
            }
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let sizes: MainWindowSizeStore
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var requests: [UUID: Request] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var createScene: ((UUID) -> Void)?
    @ObservationIgnored private var isTerminating = false
    private(set) var paywallOwnerID: ObjectIdentifier?
    private var fullScreenWindows: Set<ObjectIdentifier> = []

    init(app: AppModel, sizes: MainWindowSizeStore) {
        self.app = app
        self.sizes = sizes
        for name in [
            NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    MainActor.assumeIsolated {
                        self?.handle(name, for: window)
                    }
                })
        }
    }

    private func handle(_ notification: Notification.Name, for native: NSWindow) {
        guard let entry = entries.first(where: { $0.window === native }), let model = entry.model else { return }
        switch notification {
        case NSWindow.willCloseNotification:
            close(native)
        case NSWindow.didBecomeKeyNotification:
            becameKey(native)
        case NSWindow.willEnterFullScreenNotification:
            recordSize(entry)
            entry.isTransitioningFullScreen = true
            fullScreenWindows.insert(ObjectIdentifier(model))
        case NSWindow.didEnterFullScreenNotification:
            entry.isTransitioningFullScreen = false
            fullScreenWindows.insert(ObjectIdentifier(model))
        case NSWindow.willExitFullScreenNotification:
            entry.isTransitioningFullScreen = true
        case NSWindow.didExitFullScreenNotification:
            entry.isTransitioningFullScreen = false
            fullScreenWindows.remove(ObjectIdentifier(model))
            recordSize(entry)
        default:
            recordSize(entry)
        }
    }

    /// Track every window's ordinary size, but only the most recently used
    /// main window updates the fallback. Auxiliary windows never register here.
    private func recordSize(_ entry: Entry) {
        guard entry.isReady, !isTerminating, !entry.isTransitioningFullScreen,
            let native = entry.window, let model = entry.model,
            !native.styleMask.contains(.fullScreen), !isFullScreen(model)
        else { return }
        let size = native.contentRect(forFrameRect: native.frame).size
        guard MainWindowSizeStore.isValid(size) else { return }
        entry.normalSize = size
        if entries.last === entry { sizes.save(size) }
    }

    func isFullScreen(_ model: WindowModel?) -> Bool {
        guard let model else { return false }
        return fullScreenWindows.contains(ObjectIdentifier(model))
    }

    func performNewWindowCommand(from source: WindowModel?) {
        if let source, isFullScreen(source) {
            app?.connect(in: source)
        } else {
            newWindow(from: source)
        }
    }

    func saveSizeForTermination() {
        guard !isTerminating else { return }
        if let entry = entries.last {
            recordSize(entry)
            if let size = entry.normalSize { sizes.save(size) }
        }
        // Shutdown may close windows in a different order from their focus order.
        isTerminating = true
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func registerWindowCreation(_ create: @escaping (UUID) -> Void) {
        createScene = create
    }

    func frame(for model: WindowModel) -> CGRect? {
        entries.first(where: { $0.model === model })?.window?.frame
    }

    @discardableResult
    func newWindow(from source: WindowModel? = nil, showsMetrics: Bool = false) -> UUID? {
        request(Request(showsMetrics: showsMetrics, sourceSize: sourceSize(from: source)))
    }

    @discardableResult
    func moveWorkspace(_ id: UUID, from source: WindowModel, at screenPoint: CGPoint? = nil) -> UUID? {
        guard !source.isClosed, source.workspaces.contains(where: { $0.id == id }) else { return nil }
        return move(.workspace(id), from: source, at: screenPoint)
    }

    @discardableResult
    func movePane(_ id: UUID, from source: WindowModel, at screenPoint: CGPoint? = nil) -> UUID? {
        guard !source.isClosed, source.pane(id)?.isCombinable == true else { return nil }
        return move(.pane(id), from: source, at: screenPoint)
    }

    private func move(_ move: Move, from source: WindowModel, at screenPoint: CGPoint?) -> UUID? {
        if let existing = requests.first(where: { $0.value.source === source && $0.value.move == move }) {
            return existing.key
        }
        return request(
            Request(source: source, move: move, sourceSize: sourceSize(from: source), screenPoint: screenPoint))
    }

    private func sourceSize(from source: WindowModel?) -> CGSize {
        let entry = source.flatMap { source in entries.first(where: { $0.model === source }) } ?? entries.last
        if let entry {
            recordSize(entry)
            if let size = entry.normalSize { return size }
        }
        return sizes.defaultSize
    }

    private func request(_ request: Request) -> UUID? {
        guard let createScene else { return nil }
        let id = UUID()
        requests[id] = request
        createScene(id)
        return id
    }

    func register(_ native: NSWindow, model: WindowModel, requestID: UUID?) {
        guard !model.isClosed else { return }
        native.tabbingMode = .disallowed
        entries.removeAll { $0.window == nil || $0.model == nil }
        guard !entries.contains(where: { $0.window === native && $0.model === model }) else { return }
        let entry = Entry(window: native, model: model)
        entries.append(entry)
        if native.styleMask.contains(.fullScreen) { fullScreenWindows.insert(ObjectIdentifier(model)) }
        app?.registerWindow(model)
        if let requestID, let request = requests.removeValue(forKey: requestID) {
            // A tear-off should appear at the release point immediately, without
            // another document-opening animation after the drag completes.
            if request.screenPoint != nil { native.animationBehavior = .none }
            if let workspace = request.takeWorkspace() {
                model.open(workspace)
                model.refreshSessionContext()
                model.reconcileSidebarMode()
            } else if request.showsMetrics {
                model.selectedDestination = .metrics
            }
            applySize(request.sourceSize, to: native, model: model, at: request.screenPoint)
        }
        // A restored scene has no pending request. Its system-restored frame
        // must not be replaced with another window's shared fallback.
        entry.isReady = true
        recordSize(entry)
        synchronizePaywall()
    }

    private func applySize(_ size: CGSize, to native: NSWindow, model: WindowModel, at screenPoint: CGPoint?) {
        let contentSize = CGSize(
            width: max(
                size.width, native.contentMinSize.width, Metrics.Window.minWidth(showsSidebar: model.showsSidebar)),
            height: max(size.height, native.contentMinSize.height, Metrics.Window.minHeight))
        let frameSize = native.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let screen =
            screenPoint.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
            ?? native.screen ?? NSScreen.main
        var frame = CGRect(
            x: screenPoint.map { $0.x - frameSize.width / 2 } ?? native.frame.minX,
            y: (screenPoint?.y ?? native.frame.maxY) - frameSize.height,
            width: frameSize.width, height: frameSize.height)
        if let screen {
            frame = Self.fittingFrame(frame, within: screen.visibleFrame)
        }
        native.setFrame(frame, display: true)
    }

    /// A selected pane consumes the command, even when it was the last one.
    /// Window fallback uses the native dismissal path so confirmation can veto it.
    func closeSelectionOrWindow(in model: WindowModel) {
        guard !model.isClosed else { return }
        if model.selectedWorkspace != nil {
            model.closeSelected()
        } else {
            closeWindow(in: model)
        }
    }

    func closeWindow(in model: WindowModel) {
        guard !model.isClosed else { return }
        entries.first(where: { $0.model === model })?.window?.performClose(nil)
    }

    func close(_ native: NSWindow) {
        guard let entry = entries.first(where: { $0.window === native }), let model = entry.model else { return }
        recordSize(entry)
        if entries.last === entry, !isTerminating, let size = entry.normalSize { sizes.save(size) }
        fullScreenWindows.remove(ObjectIdentifier(model))
        entries.removeAll { $0.window === native || $0.window == nil || $0.model == nil }
        requests = requests.filter { $0.value.source !== model }
        if paywallOwnerID == ObjectIdentifier(model) {
            paywallOwnerID = nil
            app?.proAccess.isPaywallPresented = false
        }
        app?.unregisterWindow(model)
        model.closeForWindow()
    }

    private func becameKey(_ native: NSWindow) {
        guard let index = entries.firstIndex(where: { $0.window === native }) else { return }
        entries.append(entries.remove(at: index))
        if let entry = entries.last {
            recordSize(entry)
            if !isTerminating, let size = entry.normalSize { sizes.save(size) }
        }
        synchronizePaywall()
    }

    @discardableResult
    func openExisting(showsMetrics: Bool = false) -> Bool {
        guard let entry = entries.reversed().first(where: { $0.window != nil && $0.model?.isClosed == false }),
            let native = entry.window, let model = entry.model
        else { return false }
        if showsMetrics { model.selectedDestination = .metrics }
        native.deminiaturize(nil)
        native.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func openMetrics() {
        if !openExisting(showsMetrics: true) { newWindow(showsMetrics: true) }
    }

    /// Only a cold launch without a scene factory needs SwiftUI's default reopening.
    func handleReopen() -> Bool {
        Self.handleReopen(
            openExistingWindow: { openExisting() },
            createWindow: createScene == nil ? nil : { self.newWindow() })
    }

    static func handleReopen(openExistingWindow: () -> Bool, createWindow: (() -> Void)?) -> Bool {
        if openExistingWindow() { return false }
        guard let createWindow else { return true }
        createWindow()
        return false
    }

    func synchronizePaywall() {
        guard app?.proAccess.isPaywallPresented == true else {
            paywallOwnerID = nil
            return
        }
        guard paywallOwnerID == nil else { return }
        let entry =
            entries.first(where: { $0.window?.isKeyWindow == true })
            ?? entries.reversed().first(where: { $0.window != nil && $0.model?.isClosed == false })
        paywallOwnerID = entry?.model.map(ObjectIdentifier.init)
    }

    static func fittingFrame(_ frame: CGRect, within available: CGRect) -> CGRect {
        let width = min(frame.width, available.width)
        let height = min(frame.height, available.height)
        return CGRect(
            x: min(max(frame.minX, available.minX), available.maxX - width),
            y: min(max(frame.maxY - height, available.minY), available.maxY - height),
            width: width, height: height)
    }
}

struct MainWindowRegistration: NSViewRepresentable {
    let coordinator: MainWindowCoordinator
    let model: WindowModel
    let requestID: UUID?

    func makeNSView(context: Context) -> MainWindowRegistrationView {
        MainWindowRegistrationView(coordinator: coordinator, model: model, requestID: requestID)
    }

    func updateNSView(_ view: MainWindowRegistrationView, context: Context) {
        view.register()
    }
}

final class MainWindowRegistrationView: NSView {
    private let coordinator: MainWindowCoordinator
    private let model: WindowModel
    private let requestID: UUID?
    private var documentEditedObservation: NSKeyValueObservation?

    init(coordinator: MainWindowCoordinator, model: WindowModel, requestID: UUID?) {
        self.coordinator = coordinator
        self.model = model
        self.requestID = requestID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        documentEditedObservation = nil
        // SwiftUI marks a window with dismissal confirmation as edited. Workspaces
        // are not documents; suppress that decoration without changing dismissal.
        documentEditedObservation = window?.observe(\.isDocumentEdited, options: [.initial, .new]) { window, change in
            guard change.newValue == true else { return }
            MainActor.assumeIsolated { window.isDocumentEdited = false }
        }
        register()
    }

    func register() {
        guard let window else { return }
        // Establish the content coordinate system before reading or applying a
        // size. A separate bridge could otherwise register before this style.
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        coordinator.register(window, model: model, requestID: requestID)
    }
}
