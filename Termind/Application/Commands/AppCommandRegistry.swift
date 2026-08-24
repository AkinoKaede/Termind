import Foundation

nonisolated enum AppCommandTarget: Hashable, Sendable {
    case vaultPage(VaultPage)
    case vault
    case chat
    case settings
    case workspace(Workspace.ID)
    case connectHost(Host.ID, HostOpenTarget)
    case newChat
    case newHost
    case toggleContextPanel
}

nonisolated struct AppCommandDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
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
            + window.tabs.map { workspaceCommand($0, store: app.hosts) }
            + app.hosts.searchHosts("").flatMap(hostCommands)
            + actionCommands
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
        case .chat:
            window.selectChat()
        case .settings:
            openSettings()
        case .workspace(let id):
            window.select(id)
        case .connectHost(let id, let target):
            guard let host = app.hosts.host(id) else { return }
            app.open(host, as: target, in: window)
        case .newChat:
            window.openChat()
        case .newHost:
            window.openHostEditor(host: nil)
        case .toggleContextPanel:
            window.showsContextPanel.toggle()
        }
    }

    private var fixedCommands: [AppCommandDescriptor] {
        [
            AppCommandDescriptor(
                id: "fixed.vault", title: String(localized: "Vault"),
                subtitle: String(localized: "Pinned Tab"), symbol: "lock.square.stack",
                keywords: ["hosts", "keys", "snippets"], target: .vault
            ),
            AppCommandDescriptor(
                id: "fixed.chat", title: String(localized: "Chat"),
                subtitle: String(localized: "Pinned Tab"), symbol: "sparkles",
                keywords: ["assistant", "conversations"], target: .chat
            ),
            AppCommandDescriptor(
                id: "fixed.settings", title: String(localized: "Settings"),
                subtitle: String(localized: "Window"), symbol: "gearshape",
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
                keywords: [page.rawValue],
                target: .vaultPage(page)
            )
        }
    }

    private func workspaceCommand(
        _ workspace: Workspace, store: HostStore
    ) -> AppCommandDescriptor {
        AppCommandDescriptor(
            id: "workspace.\(workspace.id.uuidString)",
            title: workspace.title(in: store),
            subtitle: String(localized: "Open Workspace"),
            symbol: workspace.symbol,
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
                keywords: keywords + ["ssh"],
                target: .connectHost(host.id, .sshSession)
            ),
            AppCommandDescriptor(
                id: "host.sftp.\(host.id.uuidString)",
                title: host.name,
                subtitle: String(localized: "Browse with SFTP · \(host.displayAddress)"),
                symbol: "folder",
                keywords: keywords + ["sftp", "files"],
                target: .connectHost(host.id, .sftpSession)
            ),
        ]
    }

    private var actionCommands: [AppCommandDescriptor] {
        [
            AppCommandDescriptor(
                id: "action.new-chat", title: String(localized: "New Chat"),
                subtitle: String(localized: "Action"), symbol: "plus.bubble",
                keywords: ["assistant", "conversation"], target: .newChat
            ),
            AppCommandDescriptor(
                id: "action.new-host", title: String(localized: "New Host"),
                subtitle: String(localized: "Action"), symbol: "plus.rectangle",
                keywords: ["server", "add"], target: .newHost
            ),
            AppCommandDescriptor(
                id: "action.context-panel", title: String(localized: "Toggle Context Panel"),
                subtitle: String(localized: "Action"), symbol: "sidebar.right",
                keywords: ["context panel", "assistant", "details"], target: .toggleContextPanel
            ),
        ]
    }
}
