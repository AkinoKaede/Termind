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

/// ContextPanel state has window lifetime but no knowledge of HostStore or SwiftUI
/// detail views.  Availability and rendering are supplied by the catalog.
@Observable
final class WindowContextPanelState {
    nonisolated enum Mode: String, Hashable, Sendable, CaseIterable, Identifiable {
        case assistant, snippets, details

        nonisolated var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .assistant: "Assistant"
            case .snippets: "Snippets"
            case .details: "Details"
            }
        }
    }

    var isPresented = false
    var mode: Mode = .assistant

    private var selections: [VaultPage: [ContextPanelDetailID]] = [:]
    private var detailOverride: ContextPanelDetailID?
    private var detailOverridePaneID: Pane.ID?

    func selection(for page: VaultPage) -> [ContextPanelDetailID] {
        selections[page] ?? []
    }

    func setSelection(_ details: [ContextPanelDetailID], for page: VaultPage) {
        var seen: Set<ContextPanelDetailID> = []
        selections[page] = details.filter {
            $0.belongs(to: page) && seen.insert($0).inserted
        }
        if selections[page]?.isEmpty == false { mode = .details }
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
        mode = .details
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
