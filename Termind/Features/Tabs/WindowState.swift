import SwiftUI

/// A stable, feature-owned route into the ContextPanel.
///
/// The ContextPanel treats `kind` as an extension point.  `WindowModel` only needs
/// the page for selection scoping and never switches over business model types.
nonisolated struct ContextPanelDetailID: Hashable, Sendable, Identifiable {
    nonisolated enum Kind {
        static let host = "host"
        static let key = "key"
        static let identity = "identity"
        static let snippet = "snippet"
    }

    let kind: String
    let rawID: UUID
    let page: VaultPage

    nonisolated var id: Self { self }
    nonisolated func belongs(to page: VaultPage) -> Bool { self.page == page }

    nonisolated static func host(_ id: Host.ID) -> Self {
        Self(kind: Kind.host, rawID: id, page: .hosts)
    }

    nonisolated static func key(_ id: SSHKeyRef.ID) -> Self {
        Self(kind: Kind.key, rawID: id, page: .keychain)
    }

    nonisolated static func identity(_ id: Identity.ID) -> Self {
        Self(kind: Kind.identity, rawID: id, page: .keychain)
    }

    nonisolated static func snippet(_ id: Snippet.ID) -> Self {
        Self(kind: Kind.snippet, rawID: id, page: .snippets)
    }

    var hostID: Host.ID? { kind == Kind.host ? rawID : nil }
    var keyID: SSHKeyRef.ID? { kind == Kind.key ? rawID : nil }
    var identityID: Identity.ID? { kind == Kind.identity ? rawID : nil }
    var snippetID: Snippet.ID? { kind == Kind.snippet ? rawID : nil }
}

/// The one left sidebar's window-lifetime state.
///
/// Navigation and contextual tools share a physical column, but their mode is
/// remembered at the scope where it makes sense: one choice for Vault and one
/// for each Workspace. Assistant always uses its conversation navigator.
@Observable
final class WindowSidebarState {
    nonisolated enum Mode: String, Hashable, Sendable, CaseIterable, Identifiable {
        case navigation, assistant, snippets, history, details

        nonisolated var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .navigation: "Navigation"
            case .assistant: "Assistant"
            case .snippets: "Snippets"
            case .history: "History"
            case .details: "Details"
            }
        }

        var symbol: String {
            switch self {
            case .navigation: "sidebar.left"
            case .assistant: "sparkles"
            case .snippets: "text.badge.plus"
            case .history: "clock.arrow.circlepath"
            case .details: "info.circle"
            }
        }
    }

    var isPresented = true

    /// Global Assistant panel navigation is independent from the selected
    /// top-level tab. `nil` is the history + composer landing screen.
    var assistantConversationID: ConversationModel.ID?
    var assistantDraft = ConversationModel()

    private var vaultMode: Mode = .navigation
    private var workspaceModes: [Workspace.ID: Mode] = [:]

    private var selections: [VaultPage: [ContextPanelDetailID]] = [:]
    private var detailOverride: ContextPanelDetailID?
    private var detailOverridePaneID: Pane.ID?

    func availableModes(
        for topLevelTab: TopLevelTab,
        hasFocusedSSHSession: Bool
    ) -> [Mode] {
        switch topLevelTab {
        case .vault:
            [.navigation, .details]
        case .assistant:
            [.navigation]
        case .workspace:
            [.assistant, .snippets, .history, .details]
        }
    }

    func isModeEnabled(
        _ mode: Mode, for topLevelTab: TopLevelTab,
        hasFocusedSSHSession: Bool
    ) -> Bool {
        guard availableModes(
            for: topLevelTab, hasFocusedSSHSession: hasFocusedSSHSession
        ).contains(mode) else { return false }
        if case .workspace = topLevelTab,
            (mode == .snippets || mode == .history)
        {
            return hasFocusedSSHSession
        }
        return true
    }

    func mode(
        for topLevelTab: TopLevelTab,
        hasFocusedSSHSession: Bool
    ) -> Mode {
        let available = availableModes(
            for: topLevelTab,
            hasFocusedSSHSession: hasFocusedSSHSession
        )
        let stored: Mode
        switch topLevelTab {
        case .vault:
            stored = vaultMode
        case .assistant:
            stored = .navigation
        case .workspace(let id):
            stored = workspaceModes[id] ?? .assistant
        }
        if available.contains(stored), isModeEnabled(
            stored, for: topLevelTab,
            hasFocusedSSHSession: hasFocusedSSHSession
        ) { return stored }
        if (stored == .snippets || stored == .history), available.contains(.assistant) {
            return .assistant
        }
        return available[0]
    }

    func setMode(
        _ mode: Mode,
        for topLevelTab: TopLevelTab,
        hasFocusedSSHSession: Bool
    ) {
        guard isModeEnabled(
            mode, for: topLevelTab,
            hasFocusedSSHSession: hasFocusedSSHSession
        ) else { return }

        switch topLevelTab {
        case .vault:
            vaultMode = mode
        case .assistant:
            break
        case .workspace(let id):
            workspaceModes[id] = mode
        }
    }

    /// Commits a compatibility fallback, such as Snippets -> Assistant when an
    /// SFTP pane takes focus, so returning to SSH does not resurrect a mode the
    /// user has already been moved away from.
    func reconcileMode(
        for topLevelTab: TopLevelTab,
        hasFocusedSSHSession: Bool
    ) {
        let resolved = mode(
            for: topLevelTab,
            hasFocusedSSHSession: hasFocusedSSHSession
        )
        setMode(
            resolved,
            for: topLevelTab,
            hasFocusedSSHSession: hasFocusedSSHSession
        )
    }

    func selection(for page: VaultPage) -> [ContextPanelDetailID] {
        selections[page] ?? []
    }

    func setSelection(_ details: [ContextPanelDetailID], for page: VaultPage) {
        var seen: Set<ContextPanelDetailID> = []
        selections[page] = details.filter {
            $0.belongs(to: page) && seen.insert($0).inserted
        }
        if selections[page]?.isEmpty == false { vaultMode = .details }
    }

    func select(_ detail: ContextPanelDetailID, on page: VaultPage) {
        setSelection([detail], for: page)
    }

    func toggle(_ detail: ContextPanelDetailID, on page: VaultPage) {
        var details = selection(for: page)
        if let index = details.firstIndex(of: detail) {
            details.remove(at: index)
        } else {
            details.append(detail)
        }
        setSelection(details, for: page)
    }

    func clearSelection(for page: VaultPage) {
        selections[page] = []
    }

    func activeDetails(for pane: Pane?) -> [ContextPanelDetailID] {
        guard let pane else { return [] }
        if pane.id == detailOverridePaneID, let detailOverride {
            return [detailOverride]
        }
        return pane.hostID.map { [.host($0)] } ?? []
    }

    func show(_ detail: ContextPanelDetailID, scopedTo pane: Pane) {
        detailOverride = detail
        detailOverridePaneID = pane.id
    }

    func focusedPaneDidChange(to pane: Pane?) {
        guard pane?.id != detailOverridePaneID else { return }
        detailOverride = nil
        detailOverridePaneID = nil
    }

    func clearOverride() {
        detailOverride = nil
        detailOverridePaneID = nil
    }

    func validActiveDetails(for pane: Pane?, available: Set<ContextPanelDetailID>)
        -> [ContextPanelDetailID]
    {
        activeDetails(for: pane).filter(available.contains)
    }

    func pruneSelections(available: Set<ContextPanelDetailID>) {
        for page in VaultPage.allCases {
            let valid = selection(for: page).filter(available.contains)
            if valid != selection(for: page) { selections[page] = valid }
        }
        if let detailOverride, !available.contains(detailOverride) { clearOverride() }
    }
}

@Observable
final class WindowPresentationState {
    enum SheetRoute: Identifiable {
        case hostChooser(HostChooserPurpose)
        case quickOpen

        var id: String {
            switch self {
            case .hostChooser(let purpose): "host-chooser-\(purpose.id)"
            case .quickOpen: "quick-open"
            }
        }
    }

    var sheet: SheetRoute?

    var hostChooser: HostChooserPurpose? {
        get {
            guard case .hostChooser(let purpose) = sheet else { return nil }
            return purpose
        }
        set {
            sheet = newValue.map(SheetRoute.hostChooser)
        }
    }

    var isQuickOpenPresented: Bool {
        get {
            guard case .quickOpen = sheet else { return false }
            return true
        }
        set {
            if newValue {
                sheet = .quickOpen
            } else if case .quickOpen = sheet {
                sheet = nil
            }
        }
    }
}

@Observable
final class WorkspaceDragState {
    var payload: DragPayload?
}
