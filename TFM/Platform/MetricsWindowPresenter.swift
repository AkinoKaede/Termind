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

/// NSWorkspace sleep notifications must remain active after the last window closes.
@MainActor
final class MetricsSleepObserver {
    private var tokens: [any NSObjectProtocol] = []
    func start(_ model: ServerMetricsModel) {
        guard tokens.isEmpty else { return }
        for (name, sleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            tokens.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak model] _ in
                    Task { @MainActor in
                        if sleep { model?.suspend() } else { model?.resume() }
                    }
                })
        }
    }
    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []
    }
}
