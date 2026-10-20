// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Keeps SwiftUI, native controls, and terminal surfaces on one inherited appearance.
@MainActor
final class AppAppearanceController {
    private let defaults = UserDefaults.standard
    private let notifications = NotificationCenter.default
    private var observer: (any NSObjectProtocol)?
    private var appliedAppearance: AppAppearance?

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
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
