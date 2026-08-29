import Foundation

nonisolated enum AppCommandSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case navigation
    case workspaces
    case hosts
    case actions

    nonisolated var id: Self { self }

    var title: String {
        switch self {
        case .navigation: String(localized: "Navigation")
        case .workspaces: String(localized: "Workspaces")
        case .hosts: String(localized: "Hosts")
        case .actions: String(localized: "Actions")
        }
    }
}

nonisolated enum AppCommandTarget: Hashable, Sendable {
    case vaultPage(VaultPage)
    case vault
    case assistant
    case settings
    case workspace(Workspace.ID)
    case connectHost(Host.ID, HostOpenTarget)
    case newChat
    case newHost
    case showAssistant
}

nonisolated struct AppCommandDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let section: AppCommandSection
    let keywords: [String]
    let target: AppCommandTarget

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return ([title, subtitle ?? ""] + keywords).contains {
            $0.localizedCaseInsensitiveContains(needle)
        }
    }
}

/// The single catalog used by Quick Open and menu-level navigation actions.
/// It owns command identity and routing; views only render descriptors.
@MainActor
final class AppCommandRegistry {
    func commands(app: AppModel, window: WindowModel) -> [AppCommandDescriptor] {
        fixedCommands + vaultCommands
            + window.workspaces.map { workspaceCommand($0, store: app.hostLibrary) }
            + app.hostLibrary.searchHosts("").flatMap(hostCommands)
            + actionCommands(canShowAssistant: window.selectedWorkspace != nil)
    }

    func perform(
        _ target: AppCommandTarget, app: AppModel, window: WindowModel,
        openSettings: () -> Void = {}
    ) {
        switch target {
        case .vaultPage(let page):
            window.openPage(page)
        case .vault:
            window.selectVault()
        case .assistant:
            window.selectAssistant()
        case .settings:
            openSettings()
        case .workspace(let id):
            window.select(id)
        case .connectHost(let id, let target):
            guard let host = app.hostLibrary.host(id) else { return }
            app.open(host, as: target, in: window)
        case .newChat:
            window.openNewAssistantChat()
        case .newHost:
            window.openHostEditor(host: nil)
        case .showAssistant:
            window.showAssistant()
        }
    }

    private var fixedCommands: [AppCommandDescriptor] {
        [
            AppCommandDescriptor(
                id: "fixed.vault", title: String(localized: "Vault"),
                subtitle: String(localized: "Navigator"), symbol: "lock.square.stack",
                section: .navigation,
                keywords: ["hosts", "keys", "snippets"], target: .vault
            ),
            AppCommandDescriptor(
                id: "fixed.assistant", title: String(localized: "Assistant"),
                subtitle: String(localized: "Chats"), symbol: "sparkles",
                section: .navigation,
                keywords: ["chat", "conversations"], target: .assistant
            ),
            AppCommandDescriptor(
                id: "fixed.settings", title: String(localized: "Settings"),
                subtitle: String(localized: "Window"), symbol: "gearshape",
                section: .navigation,
                keywords: ["preferences"], target: .settings
            ),
        ]
    }

    private var vaultCommands: [AppCommandDescriptor] {
        VaultPage.allCases.map { page in
            AppCommandDescriptor(
                id: "vault.\(page.rawValue)",
                title: page.title,
                subtitle: String(localized: "Vault"),
                symbol: page.symbol,
                section: .navigation,
                keywords: [page.rawValue],
                target: .vaultPage(page)
            )
        }
    }

    private func workspaceCommand(
        _ workspace: Workspace, store: HostLibraryModel
    ) -> AppCommandDescriptor {
        AppCommandDescriptor(
            id: "workspace.\(workspace.id.uuidString)",
            title: workspace.title(in: store),
            subtitle: String(localized: "Open Workspace"),
            symbol: workspace.symbol,
            section: .workspaces,
            keywords: workspace.panes.map { $0.sidebarTitle(in: store) },
            target: .workspace(workspace.id)
        )
    }

    private func hostCommands(_ host: Host) -> [AppCommandDescriptor] {
        let keywords = [host.host, host.displayAddress] + host.tags
        return [
            AppCommandDescriptor(
                id: "host.ssh.\(host.id.uuidString)",
                title: host.name,
                subtitle: String(localized: "Connect with SSH · \(host.displayAddress)"),
                symbol: "apple.terminal",
                section: .hosts,
                keywords: keywords + ["ssh"],
                target: .connectHost(host.id, .sshSession)
            ),
            AppCommandDescriptor(
                id: "host.sftp.\(host.id.uuidString)",
                title: host.name,
                subtitle: String(localized: "Browse with SFTP · \(host.displayAddress)"),
                symbol: "folder",
                section: .hosts,
                keywords: keywords + ["sftp", "files"],
                target: .connectHost(host.id, .sftpSession)
            ),
        ]
    }

    private func actionCommands(canShowAssistant: Bool) -> [AppCommandDescriptor] {
        var commands = [
            AppCommandDescriptor(
                id: "action.new-chat", title: String(localized: "New Chat"),
                subtitle: String(localized: "Action"), symbol: "plus.bubble",
                section: .actions,
                keywords: ["assistant", "conversation"], target: .newChat
            ),
            AppCommandDescriptor(
                id: "action.new-host", title: String(localized: "New Host"),
                subtitle: String(localized: "Action"), symbol: "plus.rectangle",
                section: .actions,
                keywords: ["server", "add"], target: .newHost
            ),
        ]
        if canShowAssistant {
            commands.append(AppCommandDescriptor(
                id: "action.show-assistant", title: String(localized: "Show Assistant in Sidebar"),
                subtitle: String(localized: "Action"), symbol: "sidebar.left",
                section: .actions,
                keywords: ["sidebar", "assistant", "context", "details"], target: .showAssistant
            ))
        }
        return commands
    }
}
