import AppKit
import SwiftUI

/// Which Find the window titlebar is offering, decided by the content in front
/// rather than by whatever the sidebar happens to be showing.
///
/// A window has exactly one Find field. Pages used to grow their own — a strip
/// on each Vault page, a bar inside the SSH pane, a field in the SFTP path bar —
/// which meant ⌘F meant something different depending on where the caret was and
/// two of them could be on screen at once.
nonisolated enum WindowToolbarFindKind: String, Hashable, Sendable, CaseIterable {
    case hosts
    case keychain
    case snippets
    case assistant
    case terminal
    case sftp

    /// The tooltip. The field itself always reads "Search" — one placeholder for
    /// one control — so this is where the scope is actually named.
    var help: String {
        switch self {
        case .hosts: String(localized: "Search Hosts")
        case .keychain: String(localized: "Search Keychain")
        case .snippets: String(localized: "Search Snippets")
        case .assistant: String(localized: "Search Conversations")
        case .terminal: String(localized: "Find in Terminal")
        case .sftp: String(localized: "Find in SFTP")
        }
    }

    /// Whether Return and Shift-Return walk between matches. Only the terminal
    /// has matches to walk — everything else filters a list in place, where
    /// Return would have nothing to move to.
    var navigatesMatches: Bool { self == .terminal }
}

/// Everything the titlebar Find field needs, resolved once per body from the
/// front content.
struct WindowToolbarFindContext {
    let kind: WindowToolbarFindKind
    let query: Binding<String>
    /// Bumped by ⌘F. The field takes first responder when it changes, so
    /// pressing ⌘F again refocuses instead of doing nothing.
    var focusRequest: UInt64 = 0
    /// Return / Shift-Return, for the terminal.
    var navigate: ((TerminalFindDirection) -> Void)?
    /// Escape.
    var cancel: (() -> Void)?
    /// The magnifier menu. Today only Hosts has one — its tag filter.
    var menuItems: (() -> [NativeMenuEntry])?
}

// MARK: - The field

/// `NSSearchField`, not `.searchable`.
///
/// `.searchable` gives no access to `searchMenuTemplate`, which is where the
/// Hosts tag filter now lives, and no way to intercept Return, Shift-Return and
/// Escape — which is the whole keyboard contract the terminal find needs.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// `.large` for the sidebar footer, whose field is the whole footer.
    /// `NSSearchField` stretches its bezel to an explicit frame height, so the
    /// capsule is the size it is given — and on macOS 26 that capsule is the
    /// system's own Liquid Glass, with the native bezel as the fallback below.
    var controlSize: NSControl.ControlSize = .regular
    var focusRequest: UInt64 = 0
    var navigate: ((TerminalFindDirection) -> Void)?
    var cancel: (() -> Void)?
    var menuItems: (() -> [NativeMenuEntry])?
    /// Reported on begin and end editing, so a pane can stand down while this
    /// field holds the keyboard — see `WindowModel.isToolbarFindFocused`.
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.controlSize = controlSize
        field.focusRingType = .default
        // Filter as the user types. The default batches until Return, which for
        // a list that narrows in place means the field looks broken.
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = context.coordinator
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.action =
            #selector(Coordinator.clear)
        context.coordinator.attach(to: field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.field = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.controlSize != controlSize { field.controlSize = controlSize }
        context.coordinator.updateMenu(on: field, hasItems: menuItems != nil)
        context.coordinator.applyFocusRequest(focusRequest, to: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate, NSMenuDelegate {
        var field: NativeSearchField
        private var lastFocusRequest: UInt64 = 0
        private var hasSeenFocusRequest = false
        private let menu = NSMenu()

        init(field: NativeSearchField) {
            self.field = field
            super.init()
            menu.delegate = self
        }

        func attach(to searchField: NSSearchField) {
            updateMenu(on: searchField, hasItems: field.menuItems != nil)
        }

        /// One long-lived menu whose contents are rebuilt in `menuNeedsUpdate`.
        /// Reassigning a freshly built `NSMenu` on every SwiftUI update would
        /// swap the menu out from under itself while it is open.
        func updateMenu(on searchField: NSSearchField, hasItems: Bool) {
            let template = hasItems ? menu : nil
            guard searchField.searchMenuTemplate !== template else { return }
            searchField.searchMenuTemplate = template
        }

        func applyFocusRequest(_ request: UInt64, to searchField: NSSearchField) {
            guard hasSeenFocusRequest else {
                hasSeenFocusRequest = true
                lastFocusRequest = request
                return
            }
            guard request != lastFocusRequest else { return }
            lastFocusRequest = request
            // After this update pass: the field may not be in a window yet on
            // the first layout that carries a request.
            DispatchQueue.main.async { [weak searchField] in
                guard let searchField else { return }
                searchField.window?.makeFirstResponder(searchField)
                searchField.currentEditor()?.selectAll(nil)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            field.text = searchField.stringValue
            reclaimKeyboardIfTaken(from: searchField)
        }

        /// Some destinations take the keyboard as a *side effect of being
        /// searched*: Ghostty focuses its terminal surface when a `search:`
        /// binding runs, and the SFTP list is held focused declaratively and
        /// gets it back when filtering rebuilds the rows. Either way the caret
        /// left after one letter and the rest of the word went to the pane.
        ///
        /// Only ever runs immediately after a text change, so clicking away
        /// deliberately is untouched — that produces no change to react to.
        private func reclaimKeyboardIfTaken(from searchField: NSSearchField) {
            DispatchQueue.main.async { [weak searchField] in
                guard let searchField, let window = searchField.window else { return }
                let responder = window.firstResponder
                guard responder !== searchField,
                    responder !== searchField.currentEditor()
                else { return }
                window.makeFirstResponder(searchField)
                // Back to where the user was typing, not the start of the word.
                searchField.currentEditor()?.selectedRange = NSRange(
                    location: searchField.stringValue.utf16.count, length: 0
                )
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            field.onFocusChange?(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            field.onFocusChange?(false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                guard let navigate = field.navigate else { return false }
                navigate(.previous)
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard let navigate = field.navigate else { return false }
                navigate(.next)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let cancel = field.cancel else { return false }
                field.text = ""
                (control as? NSSearchField)?.stringValue = ""
                cancel()
                return true
            default:
                return false
            }
        }

        @objc func clear(_ sender: Any?) {
            field.text = ""
        }

        // MARK: NSMenuDelegate

        func menuNeedsUpdate(_ menu: NSMenu) {
            NativeMenuEntry.fill(menu, with: field.menuItems?() ?? [])
        }
    }
}

// MARK: - Toolbar content

/// The trailing half of the titlebar: one Find field, or nothing at all on
/// Welcome and on a workspace that has no searchable pane in front.
struct WindowToolbarFindField: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        Group {
            if let context = window.findContext() {
                NativeSearchField(
                    text: context.query,
                    placeholder: String(localized: "Search"),
                    focusRequest: context.focusRequest,
                    navigate: context.navigate,
                    cancel: context.cancel,
                    menuItems: context.menuItems,
                    onFocusChange: { window.isToolbarFindFocused = $0 }
                )
                .frame(width: Metrics.Toolbar.searchFieldWidth)
                .help(Text(context.kind.help))
                .accessibilityLabel(Text(context.kind.help))
            } else {
                // Zero width, full height. A toolbar with nothing in it is
                // shorter than one holding a search field, and the titlebar
                // resizing takes the window's content up with it — which is
                // what made a connection started from the sidebar shove the
                // journey view upward as the destination changed from Vault
                // to a Workspace. Reserving the height keeps the toolbar one
                // size for every destination, without leaving a phantom slot.
                Color.clear.frame(width: 0)
            }
        }
        .frame(height: Metrics.Toolbar.height)
    }
}

/// The leading half: Notes' `square.and.pencil`, holding whatever the content in
/// front can create, plus the Assistant's Archive toggle.
///
/// Read from the main content, never from `window.sidebarMode` — a New Host item
/// that appeared because the sidebar was showing the Navigator would create
/// something the page in front cannot show.
struct WindowToolbarLeadingActions: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        let actions = window.creationActions

        if actions.count == 1, let only = actions.first {
            Button(action: only.perform) {
                Label(only.title, systemImage: "square.and.pencil")
            }
            .help(Text(only.title))
        } else if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(action.title, action: action.perform)
                }
            } label: {
                Label("New", systemImage: "square.and.pencil")
            }
            .help(Text("New"))
        }
        // Archived is deliberately not here. It belongs beside the list it
        // filters, which is the sidebar's own bottom bar — see
        // `AssistantSidebarView`.
    }
}

/// One thing the titlebar's New control can make.
struct WindowToolbarCreationAction: Identifiable {
    let id: String
    let title: LocalizedStringKey
    /// The same string for AppKit, which takes a `String` rather than a key.
    let localizedTitle: String
    let perform: () -> Void

    init(id: String, title: String, perform: @escaping () -> Void) {
        self.id = id
        self.title = LocalizedStringKey(title)
        self.localizedTitle = title
        self.perform = perform
    }
}

// MARK: - Resolving the context

extension WindowModel {
    /// The creation verbs belonging to the content in front.
    var creationActions: [WindowToolbarCreationAction] {
        switch selectedDestination {
        case .assistant:
            return [
                WindowToolbarCreationAction(id: "chat", title: "New Chat") {
                    self.openNewAssistantChat()
                }
            ]
        case .workspace:
            return []
        case .vault:
            return vaultDestination.page.map(creationActions(for:)) ?? []
        }
    }

    /// The same verbs for a page that is not necessarily in front — what a
    /// right-click on that page's row in the Navigator offers, so a host can be
    /// added without first visiting the page to add it on.
    func creationActions(for page: VaultPage) -> [WindowToolbarCreationAction] {
        switch page {
        case .welcome:
            return []
        case .hosts:
            return [
                WindowToolbarCreationAction(id: "host", title: "New Host") {
                    self.openHostEditor(host: nil)
                },
                WindowToolbarCreationAction(id: "group", title: "New Group") {
                    self.openVaultWork(
                        .hostGroupEditor(groupID: nil, parentID: nil), on: .hosts
                    )
                },
            ]
        case .keychain:
            return [
                WindowToolbarCreationAction(id: "import", title: "Import Key") {
                    self.openVaultWork(.importKey, on: .keychain)
                },
                WindowToolbarCreationAction(id: "generate", title: "Generate Key") {
                    self.openVaultWork(.generateKey, on: .keychain)
                },
                WindowToolbarCreationAction(id: "identity", title: "New Identity") {
                    self.openVaultWork(.identityEditor(nil), on: .keychain)
                },
            ]
        case .snippets:
            return [
                WindowToolbarCreationAction(id: "snippet", title: "New Snippet") {
                    self.openVaultWork(
                        .snippetEditor(snippetID: nil, packageID: nil), on: .snippets
                    )
                },
                WindowToolbarCreationAction(id: "package", title: "New Package") {
                    self.openVaultWork(
                        .snippetPackageEditor(packageID: nil, parentID: nil), on: .snippets
                    )
                },
            ]
        }
    }

    /// Those verbs as native menu entries, for the Navigator's own rows.
    func creationMenu(for page: VaultPage) -> [NativeMenuEntry] {
        creationActions(for: page).map { action in
            NativeMenuEntry(title: action.localizedTitle, action: action.perform)
        }
    }

    /// Binds the resolved `findKind` to whatever actually owns that query.
    func findContext() -> WindowToolbarFindContext? {
        guard let kind = findKind else { return nil }
        switch kind {
        case .hosts:
            let state = vaultPages.hosts
            // No magnifier menu, and so the ordinary search glyph rather than
            // the one with a disclosure chevron: every page's field looks the
            // same. The tag filter lives on the page, in the canvas menu.
            return WindowToolbarFindContext(
                kind: kind,
                query: Binding(get: { state.query }, set: { state.query = $0 }),
                focusRequest: findFocusRequest
            )
        case .keychain:
            let state = vaultPages.keychain
            return WindowToolbarFindContext(
                kind: kind,
                query: Binding(get: { state.query }, set: { state.query = $0 }),
                focusRequest: findFocusRequest
            )
        case .snippets:
            let state = vaultPages.snippets
            return WindowToolbarFindContext(
                kind: kind,
                query: Binding(get: { state.query }, set: { state.query = $0 }),
                focusRequest: findFocusRequest
            )
        case .assistant:
            return WindowToolbarFindContext(
                kind: kind,
                query: Binding(
                    get: { self.assistantQuery }, set: { self.assistantQuery = $0 }
                ),
                focusRequest: findFocusRequest
            )
        case .terminal:
            guard let sshSession = focusedSSHSession else { return nil }
            return WindowToolbarFindContext(
                kind: kind,
                query: Binding(
                    get: { sshSession.find.query },
                    set: { sshSession.updateFindQuery($0) }
                ),
                focusRequest: findFocusRequest,
                navigate: { sshSession.presentFindAndNavigate($0) },
                cancel: { sshSession.dismissFind() }
            )
        case .sftp:
            guard let sftpSession = focusedSFTPSession else { return nil }
            return WindowToolbarFindContext(
                kind: kind,
                query: Binding(
                    get: { sftpSession.query }, set: { sftpSession.query = $0 }
                ),
                focusRequest: findFocusRequest,
                cancel: { sftpSession.query = "" }
            )
        }
    }

}
