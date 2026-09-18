import AppKit
import SwiftUI
import TermindApplication

/// Process-owned scene requests; live workspaces stay in their source until the
/// destination has a native window. Scene restoration never replays a move.
@MainActor
@Observable
final class MainWindowCoordinator {
    private final class Entry {
        weak var window: NSWindow?
        weak var model: WindowModel?
        init(window: NSWindow, model: WindowModel) {
            self.window = window
            self.model = model
        }
    }

    private final class Request {
        weak var source: WindowModel?
        let workspaceID: UUID?
        let showsMetrics: Bool
        let dropPoint: CGPoint?
        let sourceSize: CGSize?

        init(
            source: WindowModel? = nil, workspaceID: UUID? = nil,
            showsMetrics: Bool = false, dropPoint: CGPoint? = nil, sourceSize: CGSize? = nil
        ) {
            self.source = source
            self.workspaceID = workspaceID
            self.showsMetrics = showsMetrics
            self.dropPoint = dropPoint
            self.sourceSize = sourceSize
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var requests: [UUID: Request] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored var activeWorkspaceDrag: WorkspaceWindowDragSession?
    @ObservationIgnored var createScene: ((UUID) -> Void)?
    private(set) var paywallOwnerID: ObjectIdentifier?

    init(app: AppModel) {
        self.app = app
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name == NSWindow.willCloseNotification {
                            self.close(window)
                        } else {
                            self.becameKey(window)
                        }
                    }
                })
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func registerWindowCreation(_ create: @escaping (UUID) -> Void) {
        createScene = create
    }

    @discardableResult
    func newWindow(showsMetrics: Bool = false) -> UUID? {
        request(Request(showsMetrics: showsMetrics))
    }

    @discardableResult
    func moveWorkspace(_ id: UUID, from source: WindowModel, at point: CGPoint? = nil) -> UUID? {
        guard !source.isClosed, source.workspaces.contains(where: { $0.id == id }) else { return nil }
        if let existing = requests.first(where: { $0.value.source === source && $0.value.workspaceID == id }) {
            createScene?(existing.key)
            return existing.key
        }
        let native = entries.first(where: { $0.model === source })?.window
        let size = native.flatMap { $0.styleMask.contains(.fullScreen) ? nil : $0.frame.size }
        return request(Request(source: source, workspaceID: id, dropPoint: point, sourceSize: size))
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
        if !entries.contains(where: { $0.window === native && $0.model === model }) {
            entries.append(Entry(window: native, model: model))
        }
        app?.registerWindow(model)
        if let requestID, let request = requests.removeValue(forKey: requestID) {
            if let workspaceID = request.workspaceID, let source = request.source,
                let workspace = source.takeWorkspaceForMove(workspaceID)
            {
                model.open(workspace)
                model.refreshSessionContext()
                model.reconcileSidebarMode()
            } else if request.showsMetrics {
                model.selectedDestination = .metrics
            }
            if let point = request.dropPoint,
                let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? native.screen
            {
                let size =
                    request.sourceSize
                    ?? CGSize(
                        width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
                native.setFrame(Self.frame(at: point, size: size, within: screen.visibleFrame), display: true)
            }
        }
        synchronizePaywall()
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
        guard let model = entries.first(where: { $0.window === native })?.model else { return }
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

    static func frame(at point: CGPoint, size: CGSize, within available: CGRect) -> CGRect {
        let width = min(size.width, available.width)
        let height = min(size.height, available.height)
        return CGRect(
            x: min(max(point.x - width / 2, available.minX), available.maxX - width),
            y: min(max(point.y - height + 20, available.minY), available.maxY - height),
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
        register()
    }

    func register() {
        if let window { coordinator.register(window, model: model, requestID: requestID) }
    }
}
