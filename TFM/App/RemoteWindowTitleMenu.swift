import AppKit

/// A terminal title is authored by the remote host. Keep it on one printable
/// line before allowing it into AppKit's global menu structure.
nonisolated enum RemoteWindowTitle {
    static func sanitized(_ proposed: String) -> String? {
        enum EscapeState { case text, escape, controlSequence }

        var state = EscapeState.text
        var result = ""
        var insertsSeparator = false

        for scalar in proposed.unicodeScalars {
            switch state {
            case .escape:
                state = scalar.value == 0x5B ? .controlSequence : .text
            case .controlSequence:
                // ECMA-48 CSI sequences end at the first final byte.
                if (0x40...0x7E).contains(scalar.value) { state = .text }
            case .text:
                if scalar.value == 0x1B {
                    state = .escape
                } else if scalar.value == 0x9B {
                    state = .controlSequence
                } else if CharacterSet.controlCharacters.contains(scalar)
                    || CharacterSet.newlines.contains(scalar)
                {
                    insertsSeparator = !result.isEmpty
                } else {
                    if insertsSeparator, !CharacterSet.whitespaces.contains(scalar) {
                        result.append(" ")
                    }
                    insertsSeparator = false
                    result.unicodeScalars.append(scalar)
                }
            }
        }

        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Mirrors Kitty's macOS title item: an empty top-level item whose empty
/// submenu carries ` :: <active terminal title>`. Appending it to `mainMenu`
/// places it after the ordinary Help menu without turning the title into an
/// application command.
@MainActor
final class RemoteWindowTitleMenuCoordinator {
    static let shared = RemoteWindowTitleMenuCoordinator()

    private final class Report {
        weak var window: NSWindow?
        var title: String?
        var revision: UInt64

        init(window: NSWindow?, title: String?, revision: UInt64) {
            self.window = window
            self.title = title
            self.revision = revision
        }
    }

    private static let itemIdentifier = NSUserInterfaceItemIdentifier(
        "com.akinokaede.termind.remote-window-title"
    )

    private let mainMenuProvider: () -> NSMenu?
    private let keyWindowProvider: () -> NSWindow?
    private var reports: [UUID: Report] = [:]
    private var revision: UInt64 = 0
    private var keyWindowObservers: [any NSObjectProtocol] = []
    private var titleMenuItem: NSMenuItem?

    init(
        mainMenuProvider: @escaping () -> NSMenu? = { NSApp.mainMenu },
        keyWindowProvider: @escaping () -> NSWindow? = { NSApp.keyWindow },
        observesKeyWindowChanges: Bool = true
    ) {
        self.mainMenuProvider = mainMenuProvider
        self.keyWindowProvider = keyWindowProvider
        if observesKeyWindowChanges { observeKeyWindowChanges() }
    }

    func report(title: String?, for window: NSWindow?, token: UUID) {
        revision &+= 1
        reports[token] = Report(window: window, title: title, revision: revision)
        refresh()
    }

    func withdraw(token: UUID) {
        reports[token] = nil
        refresh()
    }

    func refresh() {
        reports = reports.filter { $0.value.window != nil }
        guard let keyWindow = keyWindowProvider() else {
            removeTitleMenuItem()
            return
        }
        let title = reports.values
            .filter { $0.window === keyWindow }
            .max { $0.revision < $1.revision }?
            .title
        guard let title = title.flatMap(RemoteWindowTitle.sanitized) else {
            removeTitleMenuItem()
            return
        }
        installOrUpdateTitleMenuItem(title)
    }

    private func observeKeyWindowChanges() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyWindowObservers.append(
                center.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
        }
    }

    private func installOrUpdateTitleMenuItem(_ title: String) {
        guard let mainMenu = mainMenuProvider() else { return }
        let item: NSMenuItem
        if let installed = titleMenuItem, installed.menu === mainMenu {
            item = installed
        } else if let existing = mainMenu.items.first(where: {
            $0.identifier == Self.itemIdentifier
        }) {
            titleMenuItem = existing
            item = existing
        } else {
            let created = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            created.identifier = Self.itemIdentifier
            created.submenu = NSMenu()
            mainMenu.addItem(created)
            titleMenuItem = created
            item = created
        }
        item.submenu?.title = " :: \(title)"
    }

    private func removeTitleMenuItem() {
        guard let item = titleMenuItem else { return }
        item.menu?.removeItem(item)
        titleMenuItem = nil
    }
}
