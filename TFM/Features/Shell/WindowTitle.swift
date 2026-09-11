import Foundation
import TermindApplication

/// What the titlebar calls whatever is in front.
///
/// A catalog of providers rather than a switch inside `WindowModel`, for the
/// the window should not have to
/// know that a Workspace is named after the host it connects to, or that the
/// Assistant is named after a conversation rather than after itself. Each
/// feature answers for its own destination and returns nil for the others; the
/// window only asks, and gains nothing to update when a new destination is added.
protocol WindowTitleProviding {
    /// nil when the destination in front is not this provider's to name.
    func title(in window: WindowModel, locale: Locale) -> String?
}

struct AnyWindowTitleProvider: WindowTitleProviding {
    private let resolve: (WindowModel, Locale) -> String?

    init<P: WindowTitleProviding>(_ provider: P) {
        resolve = provider.title(in:locale:)
    }

    func title(in window: WindowModel, locale: Locale) -> String? {
        resolve(window, locale)
    }
}

struct WindowTitleCatalog {
    private let providers: [AnyWindowTitleProvider]

    init(_ providers: [AnyWindowTitleProvider]) {
        self.providers = providers
    }

    /// The first provider that claims the destination. Empty when none does,
    /// which AppKit renders as no title at all rather than as a blank slot.
    func title(in window: WindowModel, locale: Locale) -> String {
        providers.lazy.compactMap { $0.title(in: window, locale: locale) }.first ?? ""
    }

    static func standard(hosts: HostLibraryModel) -> Self {
        Self([
            AnyWindowTitleProvider(MetricsWindowTitleProvider(hosts: hosts)),
            AnyWindowTitleProvider(VaultWindowTitleProvider()),
            AnyWindowTitleProvider(AssistantWindowTitleProvider()),
            AnyWindowTitleProvider(SettingsWindowTitleProvider()),
            AnyWindowTitleProvider(WorkspaceWindowTitleProvider(hosts: hosts)),
        ])
    }
}

struct SettingsWindowTitleProvider: WindowTitleProviding {
    func title(in window: WindowModel, locale: Locale) -> String? {
        guard window.selectedDestination == .settings else { return nil }
        switch window.settingsRoute {
        case .index:
            return AppLocalization.string("Settings", locale: locale)
        case .category(let category):
            return category.title(locale: locale)
        case .modelProvider:
            return AppLocalization.string("Model Provider", locale: locale)
        case .providerModels:
            return AppLocalization.string("Models", locale: locale)
        case .mcpServer:
            return AppLocalization.string("MCP", locale: locale)
        case .localMCPServer:
            return AppLocalization.string("MCP Server", locale: locale)
        case .skill:
            return AppLocalization.string("Skill", locale: locale)
        case .terminalConfiguration(let scheme):
            return scheme.title
        }
    }
}

/// Vault pages are named after themselves — except Welcome, which is the app's
/// front door and so is named after the app.
struct VaultWindowTitleProvider: WindowTitleProviding {
    func title(in window: WindowModel, locale: Locale) -> String? {
        guard window.selectedDestination == .vault,
            let page = window.vaultDestination.page
        else { return nil }
        return page == .welcome
            ? ApplicationIdentity.displayName : page.title(locale: locale)
    }
}

/// The Assistant names the conversation, not the destination. "Assistant" is
/// where you are; which chat you are in is the part worth reading from across
/// the desk.
struct AssistantWindowTitleProvider: WindowTitleProviding {
    func title(in window: WindowModel, locale: Locale) -> String? {
        guard window.selectedDestination == .assistant else { return nil }
        if window.isAssistantArchivePresented {
            return AppLocalization.string("Archived", locale: locale)
        }
        return window.assistantLibrary.selectedConversation?.derivedTitle
            ?? AppLocalization.string("New Chat", locale: locale)
    }
}

/// A Workspace is named by whatever it holds — see `Workspace.title(in:)`.
struct WorkspaceWindowTitleProvider: WindowTitleProviding {
    let hosts: HostLibraryModel

    func title(in window: WindowModel, locale: Locale) -> String? {
        guard let workspace = window.selectedWorkspace else { return nil }
        return workspace.title(in: hosts, locale: locale)
    }
}

struct MetricsWindowTitleProvider: WindowTitleProviding {
    var hosts: HostLibraryModel? = nil
    func title(in window: WindowModel, locale: Locale) -> String? {
        guard window.selectedDestination == .metrics else { return nil }
        return window.metricsHostID.flatMap { hosts?.host($0)?.name }
            ?? AppLocalization.string("Metrics", locale: locale)
    }
}
