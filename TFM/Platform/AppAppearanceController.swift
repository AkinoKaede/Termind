import AppKit

/// Keeps SwiftUI, native controls, and terminal surfaces on one inherited appearance.
@MainActor
final class AppAppearanceController {
    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private let apply: (NSAppearance?) -> Void
    private var observer: (any NSObjectProtocol)?
    private var appliedAppearance: AppAppearance?

    init(
        defaults: UserDefaults = .standard,
        notifications: NotificationCenter = .default,
        apply: @escaping (NSAppearance?) -> Void = { NSApp.appearance = $0 }
    ) {
        self.defaults = defaults
        self.notifications = notifications
        self.apply = apply
    }

    isolated deinit {
        if let observer { notifications.removeObserver(observer) }
    }

    func start() {
        guard observer == nil else { return }
        observer = notifications.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        if let observer { notifications.removeObserver(observer) }
        observer = nil
        appliedAppearance = nil
    }

    private func refresh() {
        let selection = AppAppearance.stored(in: defaults)
        guard selection != appliedAppearance else { return }
        appliedAppearance = selection
        switch selection {
        case .system: apply(nil)
        case .light: apply(NSAppearance(named: .aqua))
        case .dark: apply(NSAppearance(named: .darkAqua))
        }
    }
}
