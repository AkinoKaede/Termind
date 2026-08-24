import GhosttyTheme
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case app, startup, sidebar
    case terminalAppearance, sftp
    case aiGeneral, providers, modelRoles, mcp
    case iCloud

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .app: "App"
        case .startup: "Startup"
        case .sidebar: "Sidebar"
        case .terminalAppearance: "Appearance"
        case .sftp: "SFTP"
        case .aiGeneral: "General"
        case .providers: "Providers"
        case .modelRoles: "Model Roles"
        case .mcp: "MCP"
        case .iCloud: "Sync"
        }
    }

    var symbol: String {
        switch self {
        case .app: "app.badge"
        case .startup: "arrow.clockwise"
        case .sidebar: "sidebar.left"
        case .terminalAppearance: "terminal"
        case .sftp: "arrow.up.arrow.down"
        case .aiGeneral: "sparkles"
        case .providers: "network"
        case .modelRoles: "person.2.badge.gearshape"
        case .mcp: "wrench.and.screwdriver"
        case .iCloud: "icloud"
        }
    }
}

enum SettingsRoute: Hashable {
    case section(SettingsSection)
    case modelProvider(ModelProvider.ID, isNew: Bool)
    case providerModels(ModelProvider.ID, isNew: Bool)
    case mcpServer(MCPServer.ID, isNew: Bool)
    case terminalConfiguration(TerminalCustomConfigurationScheme)

    var section: SettingsSection {
        switch self {
        case .section(let section): section
        case .modelProvider, .providerModels: .providers
        case .mcpServer: .mcp
        case .terminalConfiguration: .terminalAppearance
        }
    }
}

struct SettingsPageView: View {
    @Environment(AppModel.self) private var app
    @State private var route: SettingsRoute = .section(.app)

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: route.section) { section in
                route = .section(section)
            }
            .frame(width: Metrics.SettingsPage.sidebarWidth)

            Divider()

            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .onChange(of: route) { oldRoute, newRoute in
            cleanUpDraft(from: oldRoute, movingTo: newRoute)
        }
        .onDisappear {
            cleanUpDraft(from: route, movingTo: .section(route.section))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .section(let section):
            sectionPage(section)
        case .modelProvider(let id, let isNew):
            ModelProviderEditorPage(
                modelProviderID: id,
                back: { route = .section(.providers) },
                showModels: { route = .providerModels(id, isNew: isNew) },
                deleted: { route = .section(.providers) }
            )
        case .providerModels(let id, let isNew):
            ModelListEditor(
                modelProviderID: id,
                back: { route = .modelProvider(id, isNew: isNew) }
            )
        case .mcpServer(let id, _):
            MCPServerEditorPage(
                serverID: id,
                back: { route = .section(.mcp) },
                deleted: { route = .section(.mcp) }
            )
        case .terminalConfiguration(let scheme):
            TerminalCustomConfigurationEditorPage(
                scheme: scheme,
                back: { route = .section(.terminalAppearance) }
            )
        }
    }

    @ViewBuilder
    private func sectionPage(_ section: SettingsSection) -> some View {
        switch section {
        case .app:
            SettingsFormPage(title: "App", subtitle: "About this installation.") { AppSettings() }
        case .startup:
            SettingsFormPage(title: "Startup", subtitle: "Choose what Termind restores when it opens.") {
                StartupSettings()
            }
        case .sidebar:
            SettingsFormPage(title: "Sidebar", subtitle: "Tune the density and content of the workspace sidebar.") {
                SidebarSettings()
            }
        case .terminalAppearance:
            SettingsFormPage(title: "Appearance", subtitle: "Themes, custom configuration, and terminal typography.") {
                TerminalSettings { route = .terminalConfiguration($0) }
            }
        case .sftp:
            SettingsFormPage(title: "SFTP", subtitle: "Control transfer concurrency across sessions.") {
                SFTPSettings()
            }
        case .aiGeneral:
            SettingsFormPage(title: "AI General", subtitle: "Control how assistant suggestions behave.") {
                AIBehaviorSettings()
            }
        case .providers:
            SettingsCollectionPage(title: "Providers", subtitle: "Endpoints and credentials used by the assistant.") {
                ModelProviderSettings { id, isNew in
                    route = .modelProvider(id, isNew: isNew)
                }
            }
        case .modelRoles:
            SettingsFormPage(title: "Model Roles", subtitle: "Choose which model handles each assistant task.") {
                ModelRoleSettings()
            }
        case .mcp:
            SettingsCollectionPage(title: "MCP", subtitle: "Remote tool servers available to the assistant.") {
                MCPSettings { id, isNew in route = .mcpServer(id, isNew: isNew) }
            }
        case .iCloud:
            SettingsFormPage(title: "iCloud", subtitle: "Sync status and data protection.") { SyncSettings() }
        }
    }

    private func cleanUpDraft(from route: SettingsRoute, movingTo newRoute: SettingsRoute) {
        switch route {
        case .modelProvider(let id, isNew: true):
            if case .providerModels(id, _) = newRoute { return }
            guard let provider = app.ai.modelProvider(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(provider) { app.ai.delete(modelProviderID: id) }
        case .providerModels(let id, isNew: true):
            if case .modelProvider(id, _) = newRoute { return }
            guard let provider = app.ai.modelProvider(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(provider) { app.ai.delete(modelProviderID: id) }
        case .mcpServer(let id, isNew: true):
            guard let server = app.ai.mcpServer(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(server) { app.ai.delete(serverID: id) }
        default:
            break
        }
    }
}

enum SettingsDraftPolicy {
    static func shouldDiscard(_ provider: ModelProvider) -> Bool {
        let hasDefaultName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            == String(localized: "New Provider")
        let hasConfiguration = !provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !provider.apiPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || provider.hasCredential || !provider.models.isEmpty
        return hasDefaultName && !hasConfiguration
    }

    static func shouldDiscard(_ server: MCPServer) -> Bool {
        let hasDefaultName = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            == String(localized: "New Server")
        return hasDefaultName && server.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct SettingsSidebar: View {
    let selection: SettingsSection
    let select: (SettingsSection) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Space.xl) {
                group("GENERAL", sections: [.app, .startup, .sidebar])
                group("TERMINAL", sections: [.terminalAppearance, .sftp])
                group("AI", sections: [.aiGeneral, .providers, .modelRoles, .mcp])
                group("iCloud", sections: [.iCloud])
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.xl)
        }
        .background(.bar)
    }

    private func group(_ title: String, sections: [SettingsSection]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.7)
                .padding(.horizontal, Metrics.Space.m)

            ForEach(sections) { section in
                Button { select(section) } label: {
                    Label(section.title, systemImage: section.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.Space.m)
                        .padding(.vertical, Metrics.Space.s)
                        .background(
                            Highlight.fill(isSelected: selection == section),
                            in: .rect(cornerRadius: Metrics.Radius.medium)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
    }
}

struct SettingsFormPage<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: title, subtitle: subtitle)
            Divider()
            Form { content }
                .formStyle(.grouped)
                .frame(maxWidth: Metrics.SettingsPage.contentWidth)
                .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsCollectionPage<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: title, subtitle: subtitle)
            Divider()
            Form { content }
                .formStyle(.grouped)
                .frame(maxWidth: Metrics.SettingsPage.contentWidth)
                .frame(maxWidth: .infinity)
        }
    }
}

struct SettingsPageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: Metrics.SettingsPage.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.Space.xxl)
        .padding(.vertical, Metrics.Space.xl)
        .background(.bar)
    }
}

struct SettingsDetailHeader: View {
    let backLabel: LocalizedStringKey
    let title: String
    var subtitle: String?
    let back: () -> Void
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: Metrics.Space.l) {
            Button(action: back) { Label(backLabel, systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

            Divider().frame(height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.vertical, Metrics.Space.m)
        .background(.bar)
    }
}

private struct AppSettings: View {
    var body: some View {
        Section("App") {
            LabeledContent("Version") {
                Text(Bundle.termindDisplayVersion).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct StartupSettings: View {
    @AppStorage(SettingsKey.restoreTabs) private var restoreTabs = true
    var body: some View {
        Section("Startup") { Toggle("Restore Tabs from Last Session", isOn: $restoreTabs) }
    }
}

private struct SidebarSettings: View {
    @AppStorage(SettingsKey.compactSidebar) private var compactSidebar = false
    @AppStorage(SettingsKey.showRecents) private var showRecents = true
    var body: some View {
        Section("Sidebar") {
            Toggle("Compact Rows", isOn: $compactSidebar)
            Toggle("Show Recents", isOn: $showRecents)
        }
    }
}

private struct SFTPSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.sftpGlobalTransferLimit) private var globalLimit = SettingsKey.defaultSFTPGlobalTransferLimit
    @AppStorage(SettingsKey.sftpPerHostTransferLimit) private var perHostLimit = SettingsKey.defaultSFTPPerHostTransferLimit

    var body: some View {
        Section("SFTP") {
            Stepper(value: $globalLimit, in: 1...8) {
                HStack {
                    Text("Concurrent Transfers")
                    Spacer()
                    Text(globalLimit, format: .number).monospacedDigit()
                }
            }
            Stepper(value: $perHostLimit, in: 1...max(globalLimit, 1)) {
                HStack {
                    Text("Per-Host Transfers")
                    Spacer()
                    Text(perHostLimit, format: .number).monospacedDigit()
                }
            }
            Text("Changes apply to queued transfers. Active transfers continue unchanged. Unsaved credentials limit a session to one transfer at a time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { applyLimits() }
        .onChange(of: globalLimit) { applyLimits() }
        .onChange(of: perHostLimit) { applyLimits() }
    }

    private func applyLimits() {
        let normalizedGlobal = min(max(globalLimit, 1), 8)
        if globalLimit != normalizedGlobal { globalLimit = normalizedGlobal; return }
        let normalizedPerHost = min(max(perHostLimit, 1), normalizedGlobal)
        if perHostLimit != normalizedPerHost { perHostLimit = normalizedPerHost; return }
        app.sftpTransfers.updateLimits(global: globalLimit, perHost: perHostLimit)
    }
}

private struct TerminalSettings: View {
    let editConfiguration: (TerminalCustomConfigurationScheme) -> Void
    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = 12.0
    @AppStorage(SettingsKey.terminalFontFollowTheme) private var fontFollowTheme = true
    @AppStorage(SettingsKey.shellIntegration) private var shellIntegration = true
    @AppStorage(SettingsKey.terminalThemeDark) private var darkTheme = SettingsKey.defaultTerminalThemeDark
    @AppStorage(SettingsKey.terminalThemeLight) private var lightTheme = SettingsKey.defaultTerminalThemeLight
    @AppStorage(SettingsKey.terminalCustomConfigurationDarkEnabled) private var darkCustomEnabled = false
    @AppStorage(SettingsKey.terminalCustomConfigurationLightEnabled) private var lightCustomEnabled = false

    private var darkThemes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.allThemes.filter(\.isDark).sorted { $0.name < $1.name }
    }
    private var lightThemes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.allThemes.filter { !$0.isDark }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            Section("Light Configuration") {
                Picker("Theme", selection: $lightTheme) { ForEach(lightThemes) { Text($0.name).tag($0.name) } }
                    .disabled(lightCustomEnabled)
                Toggle("Custom Configuration", isOn: $lightCustomEnabled)
                if lightCustomEnabled { Button("Edit Custom Configuration") { editConfiguration(.light) } }
            }
            Section("Dark Configuration") {
                Picker("Theme", selection: $darkTheme) { ForEach(darkThemes) { Text($0.name).tag($0.name) } }
                    .disabled(darkCustomEnabled)
                Toggle("Custom Configuration", isOn: $darkCustomEnabled)
                if darkCustomEnabled { Button("Edit Custom Configuration") { editConfiguration(.dark) } }
            }
            Section("Font Configuration") {
                Toggle("Follow Theme", isOn: $fontFollowTheme)
                if !fontFollowTheme {
                    LabeledContent("Font Size") {
                        HStack {
                            Slider(value: $fontSize, in: 9...24, step: 1)
                            Text(fontSize, format: .number.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 24, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Terminal") {
                Toggle("Shell Integration", isOn: $shellIntegration)
                Text("Keeps the remote working directory current in the status bar and assistant context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if TermindTerminalThemeCatalog.darkTheme(named: darkTheme) == nil { darkTheme = SettingsKey.defaultTerminalThemeDark }
            if TermindTerminalThemeCatalog.lightTheme(named: lightTheme) == nil { lightTheme = SettingsKey.defaultTerminalThemeLight }
        }
    }
}

private struct AIBehaviorSettings: View {
    @AppStorage(SettingsKey.allowOneClickSafeCommands) private var allowOneClickSafe = false
    var body: some View {
        Section("Suggestions") {
            Toggle("Run Read-Only Suggestions with ⏎", isOn: $allowOneClickSafe)
            Text("Commands that write, delete, or escalate still require a click. Destructive commands also require confirmation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SyncSettings: View {
    var body: some View {
        Section("iCloud") {
            LabeledContent("Status") { Text("Off") }
            Text("iCloud sync is not available yet. Private keys and passwords remain in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
