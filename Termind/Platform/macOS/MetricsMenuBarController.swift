import AppKit
import SwiftUI

/// Owns the status item and popover independently of window and SwiftUI scene lifetimes.
@MainActor
final class MetricsMenuBarController: NSObject, NSPopoverDelegate {
    private let defaults: UserDefaults
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var observer: (any NSObjectProtocol)?
    private weak var model: ServerMetricsModel?
    private var clearsInitialFocus = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isVisible: Bool { item != nil }
    var isPopoverShown: Bool { popover.isShown }
    var hasNeutralInitialFocus: Bool {
        guard let window = popover.contentViewController?.view.window else { return false }
        return window.firstResponder == nil || window.firstResponder === window
    }

    func start(_ model: ServerMetricsModel) {
        self.model = model
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func refresh() {
        let enabled = defaults.object(forKey: SettingsKey.showMetricsInMenuBar) as? Bool ?? true
        guard enabled else {
            popover.close()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        guard item == nil, model != nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = ApplicationIdentity.displayName
        item.button?.setAccessibilityLabel(ApplicationIdentity.displayName)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        self.item = item
    }

    @objc func togglePopover() {
        guard let model, let button = item?.button else { return }
        if popover.isShown {
            popover.close()
            return
        }
        let event = NSApp.currentEvent
        let keyboardOpening = (event?.type == .keyDown || event?.type == .keyUp) && event?.window === button.window
        clearsInitialFocus = !keyboardOpening
        if clearsInitialFocus { UserInputModalityTracker.shared.notePointerInteraction() }
        let view = MetricsMenuView(model: model) { [weak self] in
            self?.popover.close()
            if !MetricsWindowPresenter.open() { MetricsWindowPresenter.reopen?() }
        }
        .environment(\.locale, AppLanguage.stored().locale)
        popover.delegate = self
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = MetricsMenuView.preferredSize(serverCount: model.servers.count)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        guard clearsInitialFocus, UserInputModalityTracker.shared.modality == .pointer else { return }
        let window = popover.contentViewController?.view.window
        window?.initialFirstResponder = nil
        window?.makeFirstResponder(nil)
    }

    func stop() {
        popover.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        model = nil
    }
}
