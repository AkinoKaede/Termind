import SwiftUI
import TermindApplication
import TermindDomain

/// Window-scoped ownership for the dynamic workspace collection and its
/// recoverable close history. Navigation remains in `WindowModel`; workspace
/// lifetime no longer shares storage with Assistant and Vault state.
@Observable
final class WorkspaceDeckModel {
    var workspaces: [Workspace]
    var reopenStack: [Workspace] = []

    init(workspaces: [Workspace] = []) {
        self.workspaces = workspaces
    }
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
            case .snippets: "curlybraces"
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
}

@Observable
final class WindowPresentationState {
    enum PresentationRoute: Identifiable {
        case hostChooser(HostChooserPurpose)
        case quickOpen

        var id: String {
            switch self {
            case .hostChooser(let purpose): "host-chooser-\(purpose.id)"
            case .quickOpen: "quick-open"
            }
        }
    }

    var route: PresentationRoute?

    var hostChooser: HostChooserPurpose? {
        get {
            guard case .hostChooser(let purpose) = route else { return nil }
            return purpose
        }
        set {
            route = newValue.map(PresentationRoute.hostChooser)
        }
    }

    var isQuickOpenPresented: Bool {
        get {
            guard case .quickOpen = route else { return false }
            return true
        }
        set {
            if newValue {
                route = .quickOpen
            } else if case .quickOpen = route {
                route = nil
            }
        }
    }
}

@Observable
final class WorkspaceDragState {
    var payload: DragPayload?
}
