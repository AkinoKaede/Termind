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

}

/// Everything the titlebar Find field needs, resolved once per body from the
/// front content.
struct WindowToolbarFindContext {
    let query: Binding<String>
    /// Bumped by ⌘F. The field takes first responder when it changes, so
    /// pressing ⌘F again refocuses instead of doing nothing.
    var focusRequest: UInt64 = 0
    /// Return / Shift-Return, for the terminal.
    var navigate: ((TerminalFindDirection) -> Void)?
    /// Escape.
    var cancel: (() -> Void)?
}

// MARK: - The field

/// One native field for the lifetime of the toolbar item. SwiftUI's macOS
/// toolbar bridge may rebuild the representable as its binding changes; reusing
/// the AppKit control prevents the focus ring and field editor from being torn
/// down and redrawn for every character.
@MainActor
final class NativeSearchFieldOwner {
    let field = NSSearchField()
}

/// `NSSearchField`, not `.searchable`, so Return, Shift-Return and Escape can
/// implement the terminal Find keyboard contract.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Supplied by the window toolbar. Sidebar search fields omit it and own an
    /// ordinary representable-scoped control.
    var owner: NativeSearchFieldOwner? = nil
    /// `.large` for the sidebar footer, whose field is the whole footer.
    /// `NSSearchField` stretches its bezel to an explicit frame height, so the
    /// capsule is the size it is given — and on macOS 26 that capsule is the
    /// system's own Liquid Glass, with the native bezel as the fallback below.
    var controlSize: NSControl.ControlSize = .regular
    var focusRequest: UInt64 = 0
    /// The toolbar bridge may recreate its AppKit view while the query changes.
    /// A replacement field inherits the window's existing keyboard claim without
    /// selecting the text again.
    var maintainsKeyboardFocus = false
    var navigate: ((TerminalFindDirection) -> Void)?
    var cancel: (() -> Void)?
    /// Handed a closure that focuses this field, the moment the field exists.
    ///
    /// ⌘F and Edit ▸ Find go through that closure rather than through
    /// `focusRequest` alone. The counter only reaches the field if SwiftUI
    /// delivers an update to the toolbar item holding it, and a toolbar item is
    /// not a view whose refresh this code owns — so relying on it made the Find
    /// command a coin toss.
    var installFocusHandler: ((@escaping () -> Void) -> Void)?
    /// Reported when this field takes the keyboard, and again when it gives it
    /// up for real, so a pane can stand down in between — see
    /// `WindowModel.isToolbarFindFocused`. A caret stolen mid-update and taken
    /// straight back is deliberately not reported: the field never stopped
    /// owning the keyboard, so the panes must not stand back up on the strength
    /// of a loss that is about to be undone.
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = owner?.field ?? NSSearchField()
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
        installFocusHandler? { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.focusFromCommand(field)
        }
        context.coordinator.restoreKeyboardClaimIfNeeded(to: field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.field = self
        context.coordinator.attach(to: field)
        installFocusHandler? { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.focusFromCommand(field)
        }
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.controlSize != controlSize { field.controlSize = controlSize }
        context.coordinator.applyFocusRequest(focusRequest, to: field)
        context.coordinator.restoreKeyboardClaimIfNeeded(to: field)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.detachForReplacement(from: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var field: NativeSearchField
        private var lastFocusRequest: UInt64 = 0
        private var hasSeenFocusRequest = false
        /// Whether this field is meant to be holding the keyboard right now.
        ///
        /// Focusing a Find field is not a one-shot act. What it searches reacts
        /// to the query, reacting rebuilds the pane, and a pane that asserts its
        /// own focus while rebuilding takes the caret straight back out. The
        /// claim therefore has to outlive the moment it was made — see
        /// `reclaimIfStolen`.
        private var holdsKeyboardIntent = false
        private weak var attachedSearchField: NSSearchField?
        private var userExitMonitor: Any?
        private var windowResignObserver: (any NSObjectProtocol)?
        private var pendingCommandExitTimestamp: TimeInterval?
        init(field: NativeSearchField) {
            self.field = field
            super.init()
        }

        func attach(to searchField: NSSearchField) {
            attachedSearchField = searchField
        }

        func detachForReplacement(from searchField: NSSearchField) {
            guard attachedSearchField === searchField else { return }
            stopUserExitObservers()
            holdsKeyboardIntent = false
            attachedSearchField = nil
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
            DispatchQueue.main.async { [weak self, weak searchField] in
                guard let self, let searchField else { return }
                claimKeyboard(searchField, selectingAll: true)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            field.text = searchField.stringValue
        }

        // MARK: Holding the keyboard

        /// ⌘F and Edit ▸ Find, arriving straight from `WindowModel` rather than
        /// through a SwiftUI update that may or may not reach the toolbar.
        func focusFromCommand(_ searchField: NSSearchField) {
            claimKeyboard(searchField, selectingAll: true)
        }

        /// Query changes can replace the toolbar's native view. The window-level
        /// claim survives that replacement; the new field resumes editing at the
        /// end of the existing query instead of behaving like a fresh ⌘F.
        func restoreKeyboardClaimIfNeeded(to searchField: NSSearchField) {
            guard field.maintainsKeyboardFocus else { return }
            holdsKeyboardIntent = true
            attachedSearchField = searchField
            installUserExitObservers(for: searchField)
            if searchField.window != nil {
                restoreKeyboardClaim(to: searchField)
                return
            }
            DispatchQueue.main.async { [weak self, weak searchField] in
                guard let self, let searchField else { return }
                restoreKeyboardClaim(to: searchField)
            }
        }

        private func restoreKeyboardClaim(to searchField: NSSearchField) {
            guard field.maintainsKeyboardFocus,
                let window = searchField.window,
                window.isKeyWindow
            else { return }
            let responder = window.firstResponder
            guard responder !== searchField,
                responder !== searchField.currentEditor()
            else { return }
            window.makeFirstResponder(searchField)
            let caretLocation = searchField.stringValue.utf16.count
            searchField.currentEditor()?.selectedRange = NSRange(location: caretLocation, length: 0)
            // AppKit may finish installing the shared field editor after
            // `makeFirstResponder` returns. Re-apply only the caret position on
            // the next turn; the responder itself never leaves the field.
            DispatchQueue.main.async { [weak searchField] in
                guard let searchField,
                    searchField.window?.firstResponder === searchField.currentEditor()
                else { return }
                searchField.currentEditor()?.selectedRange = NSRange(
                    location: searchField.stringValue.utf16.count,
                    length: 0
                )
            }
        }

        /// Takes first responder, and keeps taking it for as long as the update
        /// this set off is still landing.
        private func claimKeyboard(_ searchField: NSSearchField, selectingAll: Bool) {
            holdsKeyboardIntent = true
            pendingCommandExitTimestamp = nil
            attachedSearchField = searchField
            installUserExitObservers(for: searchField)
            guard let window = searchField.window else { return }
            window.makeFirstResponder(searchField)
            if selectingAll { searchField.currentEditor()?.selectAll(nil) }
        }

        /// Gives the claim up, and tells the window so the panes may hold the
        /// keyboard again. Every path out of editing ends here exactly once.
        private func releaseKeyboard() {
            pendingCommandExitTimestamp = nil
            stopUserExitObservers()
            guard holdsKeyboardIntent else { return }
            holdsKeyboardIntent = false
            field.onFocusChange?(false)
        }

        private func stopUserExitObservers() {
            if let userExitMonitor {
                NSEvent.removeMonitor(userExitMonitor)
                self.userExitMonitor = nil
            }
            if let windowResignObserver {
                NotificationCenter.default.removeObserver(windowResignObserver)
                self.windowResignObserver = nil
            }
        }

        private func installUserExitObservers(for searchField: NSSearchField) {
            guard userExitMonitor == nil else { return }
            userExitMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                self?.handleUserEvent(event)
                return event
            }
            guard let window = searchField.window else { return }
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseKeyboard() }
            }
        }

        /// A real pointer gesture outside the field or Tab is the user explicitly
        /// leaving. Release before AppKit routes the event so the destination is
        /// never fought by a delayed focus restoration.
        func handleUserEvent(_ event: NSEvent) {
            guard holdsKeyboardIntent else { return }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                guard let searchField = attachedSearchField,
                    event.window === searchField.window
                else {
                    releaseKeyboard()
                    return
                }
                let point = searchField.convert(event.locationInWindow, from: nil)
                if !searchField.bounds.contains(point) { releaseKeyboard() }
            case .keyDown:
                if event.keyCode == 48 {
                    releaseKeyboard()
                } else if event.modifierFlags.contains(.command) {
                    markPendingCommandExit(event)
                }
            default:
                break
            }
        }

        private func markPendingCommandExit(_ event: NSEvent) {
            let timestamp = event.timestamp
            pendingCommandExitTimestamp = timestamp
            DispatchQueue.main.async { [weak self] in
                guard self?.pendingCommandExitTimestamp == timestamp else { return }
                self?.pendingCommandExitTimestamp = nil
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            holdsKeyboardIntent = true
            if let searchField = notification.object as? NSSearchField {
                attachedSearchField = searchField
                installUserExitObservers(for: searchField)
            }
            field.onFocusChange?(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            // A query update can replace the toolbar's AppKit field. That old
            // field ends editing even though the window-level search is still
            // active and its replacement is about to inherit the caret. Real
            // exits release in `handleUserEvent`, Escape, or the window-resign
            // observer before this callback arrives.
            if pendingCommandExitTimestamp != nil {
                releaseKeyboard()
                return
            }
            guard !holdsKeyboardIntent else { return }
            stopUserExitObservers()
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
                // Escape hands the keyboard back on purpose — the terminal
                // takes it in `dismissFind`. Drop the claim first so the two do
                // not fight over the caret.
                releaseKeyboard()
                cancel()
                return true
            default:
                return false
            }
        }

        @objc func clear(_ sender: Any?) {
            field.text = ""
        }

    }
}

// MARK: - Toolbar content

/// Contributes the macOS 26 system search item from a background child that
/// owns no application content. Adding or removing this host can update toolbar
/// preferences without changing the `NavigationSplitView` branch that owns
/// persistent Ghostty surfaces.
struct WindowToolbarSearchHost: View {
    @Environment(WindowModel.self) private var window
    @State private var isPresented = false

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Group {
                if window.findKind != nil {
                    searchableHost
                } else {
                    Color.clear
                        .onAppear { dismissSearch() }
                }
            }
            .frame(width: 0, height: 0)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var searchableHost: some View {
        Color.clear
            .searchable(
                text: searchText,
                isPresented: $isPresented,
                placement: .automatic,
                prompt: Text("Search")
            )
            .onAppear { installFocusHandler() }
            .onChange(of: isPresented, initial: true) { _, presented in
                window.isToolbarFindFocused = presented
            }
            .onKeyPress(.return, phases: .down) { press in
                guard isPresented,
                    let navigate = window.findContext()?.navigate
                else { return .ignored }
                navigate(press.modifiers.contains(.shift) ? .next : .previous)
                return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
                guard isPresented,
                    let cancel = window.findContext()?.cancel
                else { return .ignored }
                cancel()
                dismissSearch()
                return .handled
            }
    }

    private var searchText: Binding<String> {
        Binding(
            get: { window.findContext()?.query.wrappedValue ?? "" },
            set: { window.findContext()?.query.wrappedValue = $0 }
        )
    }

    private func installFocusHandler() {
        let presentation = $isPresented
        window.focusToolbarFindField = { presentation.wrappedValue = true }
        if window.isToolbarFindFocused { isPresented = true }
    }

    private func dismissSearch() {
        isPresented = false
        window.isToolbarFindFocused = false
    }
}

/// The toolbar slot is selected once by OS availability, never by the current
/// page. Runtime navigation therefore cannot reparent persistent terminal views.
struct WindowToolbarSearchSlot: View {
    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.frame(width: 0, height: Metrics.Toolbar.height)
        } else {
            WindowToolbarFindField()
        }
    }
}

/// The trailing half of the titlebar: one Find field, or nothing at all on
/// Welcome and on a workspace that has no searchable pane in front.
struct WindowToolbarFindField: View {
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale
    @State private var searchFieldOwner = NativeSearchFieldOwner()

    var body: some View {
        Group {
            if let context = window.findContext() {
                NativeSearchField(
                    text: context.query,
                    placeholder: AppLocalization.string("Search", locale: locale),
                    owner: searchFieldOwner,
                    focusRequest: context.focusRequest,
                    maintainsKeyboardFocus: window.isToolbarFindFocused,
                    navigate: context.navigate,
                    cancel: context.cancel,
                    installFocusHandler: { window.focusToolbarFindField = $0 },
                    onFocusChange: { window.isToolbarFindFocused = $0 }
                )
                .frame(width: Metrics.Toolbar.searchFieldWidth)
                .help(Text(AppLocalization.string("Search", locale: locale)))
                .accessibilityLabel(
                    Text(AppLocalization.string("Search", locale: locale))
                )
            } else {
                // Zero width, full height. A toolbar with nothing in it is
                // shorter than one holding a search field, and the titlebar
                // resizing takes the window's content up with it — which is
                // what made a connection started from the sidebar shove the
                // journey view upward as the destination changed from Vault
                // to a Workspace. Reserving the height keeps the toolbar one
                // size for every destination, without leaving a phantom slot.
                Color.clear.frame(width: 0)
                    .onAppear { window.isToolbarFindFocused = false }
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
    @Environment(\.locale) private var locale

    var body: some View {
        let actions = window.creationActions

        if window.selectedDestination == .settings {
            Button(action: window.navigateBackInSettings) {
                Label("Back", systemImage: "chevron.backward")
                    .labelStyle(.iconOnly)
            }
            .keyboardShortcut(.cancelAction)
            .help(Text("Back"))
        } else if actions.count == 1, let only = actions.first {
            Button(action: only.perform) {
                Label(
                    only.localizedTitle(locale: locale),
                    systemImage: "square.and.pencil"
                )
            }
            .help(Text(only.localizedTitle(locale: locale)))
        } else if !actions.isEmpty {
            Menu {
                ForEach(actions) { action in
                    Button(
                        action.localizedTitle(locale: locale),
                        systemImage: action.symbol,
                        action: action.perform
                    )
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
    private let titleKey: String.LocalizationValue
    /// Required rather than defaulted: this action is drawn both as a SwiftUI
    /// menu item and as a `NativeMenuEntry`, and a new verb that forgot its
    /// glyph would go unnoticed in one of the two.
    let symbol: String
    let perform: () -> Void

    init(
        id: String, title: String.LocalizationValue, symbol: String,
        perform: @escaping () -> Void
    ) {
        self.id = id
        titleKey = title
        self.symbol = symbol
        self.perform = perform
    }

    func localizedTitle(locale: Locale) -> String {
        AppLocalization.string(titleKey, locale: locale)
    }
}

// MARK: - Resolving the context

extension WindowModel {
    /// The creation verbs belonging to the content in front.
    var creationActions: [WindowToolbarCreationAction] {
        switch selectedDestination {
        case .assistant:
            return [
                WindowToolbarCreationAction(
                    id: "chat", title: "New Chat", symbol: MenuSymbol.newChat
                ) {
                    self.openNewAssistantChat()
                }
            ]
        case .workspace:
            return []
        case .settings:
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
                WindowToolbarCreationAction(
                    id: "host", title: "New Host", symbol: MenuSymbol.newHost
                ) {
                    self.openHostEditor(host: nil)
                },
                WindowToolbarCreationAction(
                    id: "group", title: "New Group", symbol: MenuSymbol.newGroup
                ) {
                    self.openVaultWork(
                        .hostGroupEditor(groupID: nil, parentID: nil), on: .hosts
                    )
                },
            ]
        case .keychain:
            return [
                WindowToolbarCreationAction(
                    id: "import", title: "Import Key", symbol: MenuSymbol.importItem
                ) {
                    self.openVaultWork(.importKey, on: .keychain)
                },
                WindowToolbarCreationAction(
                    id: "generate", title: "Generate Key", symbol: MenuSymbol.generateKey
                ) {
                    self.openVaultWork(.generateKey, on: .keychain)
                },
                WindowToolbarCreationAction(
                    id: "identity", title: "New Identity", symbol: MenuSymbol.newIdentity
                ) {
                    self.openVaultWork(.identityEditor(nil), on: .keychain)
                },
            ]
        case .snippets:
            return [
                WindowToolbarCreationAction(
                    id: "snippet", title: "New Snippet", symbol: MenuSymbol.newSnippet
                ) {
                    self.openVaultWork(
                        .snippetEditor(snippetID: nil, packageID: nil), on: .snippets
                    )
                },
                WindowToolbarCreationAction(
                    id: "package", title: "New Package", symbol: MenuSymbol.newPackage
                ) {
                    self.openVaultWork(
                        .snippetPackageEditor(packageID: nil, parentID: nil), on: .snippets
                    )
                },
            ]
        }
    }

    /// Those verbs as native menu entries, for the Navigator's own rows.
    func creationMenu(for page: VaultPage, locale: Locale) -> [NativeMenuEntry] {
        creationActions(for: page).map { action in
            NativeMenuEntry(
                title: action.localizedTitle(locale: locale),
                symbol: action.symbol,
                action: action.perform
            )
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
                query: Binding(get: { state.query }, set: { state.query = $0 }),
                focusRequest: findFocusRequest
            )
        case .keychain:
            let state = vaultPages.keychain
            return WindowToolbarFindContext(
                query: Binding(get: { state.query }, set: { state.query = $0 }),
                focusRequest: findFocusRequest
            )
        case .snippets:
            let state = vaultPages.snippets
            return WindowToolbarFindContext(
                query: Binding(get: { state.query }, set: { state.query = $0 }),
                focusRequest: findFocusRequest
            )
        case .assistant:
            return WindowToolbarFindContext(
                query: Binding(
                    get: { self.assistantQuery }, set: { self.assistantQuery = $0 }
                ),
                focusRequest: findFocusRequest
            )
        case .terminal:
            if let serialSession = focusedSerialSession {
                return WindowToolbarFindContext(
                    query: Binding(
                        get: { serialSession.findQuery },
                        set: { serialSession.updateFindQuery($0) }
                    ),
                    focusRequest: findFocusRequest,
                    navigate: { serialSession.presentFindAndNavigate($0) },
                    cancel: { serialSession.dismissFind() }
                )
            }
            guard let sshSession = focusedSSHSession else { return nil }
            return WindowToolbarFindContext(
                query: Binding(
                    get: { sshSession.findQuery },
                    set: { sshSession.updateFindQuery($0) }
                ),
                focusRequest: findFocusRequest,
                navigate: { sshSession.presentFindAndNavigate($0) },
                cancel: { sshSession.dismissFind() }
            )
        case .sftp:
            guard let sftpSession = focusedSFTPSession else { return nil }
            return WindowToolbarFindContext(
                query: Binding(
                    get: { sftpSession.query }, set: { sftpSession.query = $0 }
                ),
                focusRequest: findFocusRequest,
                cancel: { sftpSession.query = "" }
            )
        }
    }

}
