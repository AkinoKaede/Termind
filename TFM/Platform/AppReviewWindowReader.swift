import AppKit
import SwiftUI

/// Native focus and input belong to the window, including controls hosted outside
/// SwiftUI. A local event monitor observes input without consuming or storing it.
struct AppReviewWindowReader: NSViewRepresentable {
    let controller: AppReviewController
    let location: AppReviewController.Location
    let isBlocked: Bool
    let request: () -> Void

    func makeNSView(context: Context) -> ReviewActivityView {
        ReviewActivityView(controller: controller)
    }

    func updateNSView(_ view: ReviewActivityView, context: Context) {
        view.location = location
        view.isBlocked = isBlocked
        view.request = request
        view.refresh()
    }

    static func dismantleNSView(_ view: ReviewActivityView, coordinator: ()) {
        view.stop()
    }
}

final class ReviewActivityView: NSView {
    private let controller: AppReviewController
    private let windowID = UUID()
    var location: AppReviewController.Location = .other
    var isBlocked = false
    var request: () -> Void = {}
    private var observers: [any NSObjectProtocol] = []
    private var sleepObservers: [any NSObjectProtocol] = []
    private var monitor: Any?
    private var timer: Timer?
    private var isSleeping = false

    init(controller: AppReviewController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { stop() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        )
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        if let self, name == NSWindow.willBeginSheetNotification {
                            self.controller.recordInteraction(windowID: self.windowID)
                        }
                        self?.refresh()
                    }
                }
            )
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            sleepObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isSleeping = name == NSWorkspace.willSleepNotification
                        self?.refresh()
                    }
                }
            )
        }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .mouseMoved,
            ]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.window?.isKeyWindow == true {
                    self.controller.recordInteraction(windowID: self.windowID)
                }
            }
            return event
        }
        refresh()
    }

    func refresh() {
        let active =
            window.map {
                NSApp.isActive && $0.isKeyWindow && $0.isVisible && !$0.isMiniaturized && !isSleeping
            } ?? false
        controller.update(
            windowID: windowID,
            context: .init(
                location: location, isActive: active,
                isBlocked: isBlocked || window?.attachedSheet != nil || NSApp.modalWindow != nil
            )
        )
        if active {
            if timer == nil {
                let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                timer.tolerance = 0.1
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            controller.requestIfReady(windowID: windowID, request: request)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        controller.removeWindow(windowID)
    }
}
