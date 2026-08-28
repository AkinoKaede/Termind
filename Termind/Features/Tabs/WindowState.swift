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
/// Navigation and contextual tools share a physical column. The selected mode
/// belongs to the window and remains unchanged as its destination changes.
@Observable
final class WindowSidebarState {
    nonisolated enum Mode: String, Hashable, Sendable, CaseIterable, Identifiable {
        case navigation, assistant, snippets, history

        nonisolated var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .navigation: "Navigator"
            case .assistant: "Assistant"
            case .snippets: "Snippets"
            case .history: "History"
            }
        }

        var symbol: String {
            switch self {
            case .navigation: "list.bullet"
            case .assistant: "sparkles"
            case .snippets: "text.badge.plus"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var isPresented = true

    /// Global Assistant panel navigation is independent from the selected
    /// top-level destination. `nil` is the history + composer landing screen.
    var assistantConversationID: ConversationModel.ID?
    var assistantDraft = ConversationModel()
    var isAssistantArchivePresented = false

    /// What the focused pane is, for whichever composer this column is showing.
    ///
    /// Here rather than on a conversation, because it describes the window's
    /// current view of a host — not the chat. `WindowModel.refreshSessionContext`
    /// is the only writer, and it clears this to `.none` when no Workspace is
    /// selected so a stale host and directory cannot be left on screen.
    var sessionContext: SessionContext = .none

    var mode: Mode = .navigation

    private var selections: [VaultPage: [ContextPanelDetailID]] = [:]
    private var detailOverride: ContextPanelDetailID?
    private var detailOverridePaneID: Pane.ID?

    var availableModes: [Mode] {
        Mode.allCases
    }

    func isModeEnabled(_ mode: Mode) -> Bool {
        availableModes.contains(mode)
    }

    func reconcileMode() {
        // Every mode has a useful global or focus-sensitive presentation.
    }

    func selection(for page: VaultPage) -> [ContextPanelDetailID] {
        selections[page] ?? []
    }

    func setSelection(_ details: [ContextPanelDetailID], for page: VaultPage) {
        var seen: Set<ContextPanelDetailID> = []
        selections[page] = details.filter {
            $0.belongs(to: page) && seen.insert($0).inserted
        }
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
