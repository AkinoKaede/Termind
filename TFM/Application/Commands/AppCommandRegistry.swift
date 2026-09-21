import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

nonisolated enum AppCommandSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case navigation
    case conversations
    case workspaces
    case hosts
    case actions

    nonisolated var id: Self { self }

    var title: String {
        switch self {
        case .navigation: String(localized: "Navigation")
        case .conversations: String(localized: "Chats")
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
    case assistantConversation(ConversationModel.ID)
    case workspace(Workspace.ID)
    case workspaceTemplate(WorkspaceTemplate.ID)
    case connectHost(Host.ID, HostOpenTarget)
    case newWindow
    case moveWorkspaceToNewWindow(UUID)
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
            + conversationCommands(window.assistantLibrary)
            + window.workspaces.map { workspaceCommand($0, store: app.hostLibrary) }
            + app.hostLibrary.sortedWorkspaceTemplates.map {
                workspaceTemplateCommand($0, store: app.hostLibrary)
            }
            + app.hostLibrary.searchHosts("").flatMap(hostCommands)
            + actionCommands(workspaceID: window.selectedWorkspaceID)
    }

    func perform(_ target: AppCommandTarget, app: AppModel, window: WindowModel) {
        switch target {
        case .vaultPage(let page):
            window.openPage(page)
        case .vault:
            window.selectVault()
        case .assistant:
            window.selectAssistant()
        case .settings:
            window.openSettings()
        case .assistantConversation(let id):
            window.openAssistantFullScreen(id)
        case .workspace(let id):
            window.select(id)
        case .workspaceTemplate(let id):
            guard let template = app.hostLibrary.workspaceTemplate(id) else { return }
            window.openWorkspaceTemplate(template)
        case .connectHost(let id, let target):
            guard let host = app.hostLibrary.host(id) else { return }
            app.open(host, as: target, in: window)
        case .newWindow:
            app.mainWindows.newWindow(from: window)
        case .moveWorkspaceToNewWindow(let id):
            app.mainWindows.moveWorkspace(id, from: window)
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
                subtitle: String(localized: "Navigator"), symbol: "gearshape",
                section: .navigation,
                keywords: ["preferences"], target: .settings
            ),
        ]
    }

    private var vaultCommands: [AppCommandDescriptor] {
        VaultPage.allCases.map { page in
            AppCommandDescriptor(
                id: "vault.\(page.rawValue)",
                title: page.title(),
                subtitle: String(localized: "Vault"),
                symbol: page.symbol,
                section: .navigation,
                keywords: [page.rawValue],
                target: .vaultPage(page)
            )
        }
    }

    private func conversationCommands(
        _ library: AssistantLibraryModel
    ) -> [AppCommandDescriptor] {
        library.search("", scope: .active).map { conversation in
            AppCommandDescriptor(
                id: "conversation.\(conversation.id.uuidString)",
                title: conversation.derivedTitle,
                subtitle: String(localized: "Chat"),
                symbol: "sparkles",
                section: .conversations,
                // Search only what the conversation UI exposes. Hidden reasoning,
                // tool output, and the raw transcript deliberately stay out.
                keywords: conversation.messages.map(\.text),
                target: .assistantConversation(conversation.id)
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

    private func workspaceTemplateCommand(
        _ template: WorkspaceTemplate, store: HostLibraryModel
    ) -> AppCommandDescriptor {
        AppCommandDescriptor(
            id: "workspace-template.\(template.id.uuidString)",
            title: template.name,
            subtitle: String(localized: "Workspace Template"),
            symbol: "rectangle.split.2x1",
            section: .workspaces,
            keywords: template.layout.hostIDs.compactMap { store.host($0)?.name },
            target: .workspaceTemplate(template.id)
        )
    }

    private func hostCommands(_ host: Host) -> [AppCommandDescriptor] {
        let keywords = [host.host] + host.supportedTerminalProtocols.map { host.displayAddress(for: $0) } + host.tags
        var commands: [AppCommandDescriptor] = []
        if host.sshEnabled {
            commands.append(
                AppCommandDescriptor(
                    id: "host.ssh.\(host.id.uuidString)",
                    title: host.name,
                    subtitle: String(localized: "Connect with SSH · \(host.displayAddress(for: .ssh))"),
                    symbol: "apple.terminal",
                    section: .hosts,
                    keywords: keywords + ["ssh"],
                    target: .connectHost(host.id, .sshSession)
                ))
            commands.append(
                AppCommandDescriptor(
                    id: "host.sftp.\(host.id.uuidString)",
                    title: host.name,
                    subtitle: String(localized: "Browse with SFTP · \(host.displayAddress(for: .ssh))"),
                    symbol: "folder",
                    section: .hosts,
                    keywords: keywords + ["sftp", "files"],
                    target: .connectHost(host.id, .sftpChannel)
                ))
        }
        if host.telnetEnabled {
            commands.append(
                AppCommandDescriptor(
                    id: "host.telnet.\(host.id.uuidString)", title: host.name,
                    subtitle: String(localized: "Connect with Telnet · \(host.displayAddress(for: .telnet))"),
                    symbol: MenuSymbol.telnet, section: .hosts, keywords: keywords + ["telnet"],
                    target: .connectHost(host.id, .telnetSession)))
        }
        return commands
    }

    private func actionCommands(workspaceID: UUID?) -> [AppCommandDescriptor] {
        var commands = [
            AppCommandDescriptor(
                id: "action.new-window", title: String(localized: "New Window"),
                subtitle: String(localized: "Action"), symbol: MenuSymbol.newWindow,
                section: .actions, keywords: ["window"], target: .newWindow
            ),
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
        if let workspaceID {
            commands.append(
                AppCommandDescriptor(
                    id: "action.move-workspace-window", title: String(localized: "Move Workspace to New Window"),
                    subtitle: String(localized: "Action"), symbol: MenuSymbol.moveToNewWindow,
                    section: .actions, keywords: ["window", "move"], target: .moveWorkspaceToNewWindow(workspaceID)
                ))
            commands.append(
                AppCommandDescriptor(
                    id: "action.show-assistant", title: String(localized: "Show Assistant in Sidebar"),
                    subtitle: String(localized: "Action"), symbol: "sidebar.left",
                    section: .actions,
                    keywords: ["sidebar", "assistant", "context", "details"], target: .showAssistant
                ))
        }
        return commands
    }
}
