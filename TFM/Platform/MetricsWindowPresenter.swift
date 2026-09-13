import AppKit
import SwiftUI
import TermindApplication

/// Native window discovery stays outside the application monitoring service.
@MainActor
final class MetricsWindowPresenter {
    private final class Entry {
        weak var window: NSWindow?
        weak var model: WindowModel?
        init(window: NSWindow, model: WindowModel) {
            self.window = window
            self.model = model
        }
    }
    private static var entries: [Entry] = []
    static var reopen: (() -> Void)?

    static func register(window: NSWindow, model: WindowModel) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(Entry(window: window, model: model))
    }
    static func registerWindowCreation(_ createWindow: @escaping () -> Void) {
        reopen = createWindow
    }
    static func open() -> Bool {
        for window in NSApp.orderedWindows {
            guard let entry = entries.first(where: { $0.window === window }), let model = entry.model else { continue }
            model.selectedDestination = .metrics
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }
    /// Returning `true` lets SwiftUI create its initial WindowGroup during a cold launch.
    /// Once a window has appeared, the retained scene action can create later windows itself.
    static func handleReopen() -> Bool {
        handleReopen(openExistingWindow: open, createWindow: reopen)
    }
    static func handleReopen(
        openExistingWindow: () -> Bool,
        createWindow: (() -> Void)?
    ) -> Bool {
        if openExistingWindow() { return false }
        guard let createWindow else { return true }
        createWindow()
        return false
    }
    static func quit() { NSApp.terminate(nil) }
}

struct MetricsWindowRegistration: NSViewRepresentable {
    let model: WindowModel
    func makeNSView(context: Context) -> MetricsRegistrationView { MetricsRegistrationView(model: model) }
    func updateNSView(_ nsView: MetricsRegistrationView, context: Context) { nsView.model = model }
}

final class MetricsRegistrationView: NSView {
    var model: WindowModel
    init(model: WindowModel) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { MetricsWindowPresenter.register(window: window, model: model) }
    }
}

/// System and login-session notifications must remain active after the last window closes.
/// A wake alone is insufficient: the Data Protection Keychain remains unavailable
/// until the user's login session becomes active again.
@MainActor
final class MetricsActivityObserver {
    nonisolated enum Event: Sendable {
        case systemWillSleep
        case systemDidWake
        case sessionDidResignActive
        case sessionDidBecomeActive
    }

    private enum Blocker: Hashable {
        case systemSleep
        case inactiveSession
    }

    private var tokens: [any NSObjectProtocol] = []
    private var blockers: Set<Blocker> = []
    private weak var model: ServerMetricsModel?

    func start(_ model: ServerMetricsModel) {
        guard tokens.isEmpty else { return }
        self.model = model
        let notifications: [(Notification.Name, Event)] = [
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
        ]
        for (name, event) in notifications {
            tokens.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in
                        self?.receive(event)
                    }
                })
        }
    }

    func receive(_ event: Event) {
        let wasSuspended = !blockers.isEmpty
        switch event {
        case .systemWillSleep:
            blockers.insert(.systemSleep)
        case .systemDidWake:
            blockers.remove(.systemSleep)
        case .sessionDidResignActive:
            blockers.insert(.inactiveSession)
        case .sessionDidBecomeActive:
            blockers.remove(.inactiveSession)
        }
        let isSuspended = !blockers.isEmpty
        guard wasSuspended != isSuspended else { return }
        if isSuspended {
            model?.suspend()
        } else {
            model?.resume()
        }
    }

    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []
        blockers = []
        model = nil
    }
}
