import GhosttyTheme
import AppKit
import ListViewKit
import SwiftUI

nonisolated enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case pro, app, startup, sidebar
    case terminalAppearance, sftp
    case providers, modelRoles, assistant, webSearch, mcp, mcpServer
    case sync
    #if DEBUG
        case developer
    #endif

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .pro: "Termind Pro"
        case .app: "App"
        case .startup: "Startup"
        case .sidebar: "Sidebar"
        case .terminalAppearance: "Appearance"
        case .sftp: "SFTP"
        case .providers: "Providers"
        case .modelRoles: "Model Roles"
        case .assistant: "Assistant"
        case .webSearch: "Web Search"
        case .mcp: "MCP"
        case .mcpServer: "MCP Server"
        case .sync: "iCloud"
        #if DEBUG
            case .developer: "Developer"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .pro: "sparkles.rectangle.stack"
        case .app: "app.badge"
        case .startup: "arrow.clockwise"
        case .sidebar: "sidebar.left"
        case .terminalAppearance: "terminal"
        case .sftp: "arrow.up.arrow.down"
        case .providers: "network"
        case .modelRoles: "person.2.badge.gearshape"
        case .assistant: "brain"
        case .webSearch: "magnifyingglass"
        case .mcp: "wrench.and.screwdriver"
        case .mcpServer: "server.rack"
        case .sync: "icloud"
        #if DEBUG
            case .developer: "hammer"
        #endif
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
        .background(TermindColor.windowSurface)
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
        case .mcpServer(let id, let isNew):
            if app.proAccess.canUse(.remoteMCP) {
                MCPServerEditorPage(
                    serverID: id, isNew: isNew,
                    back: { route = .section(.mcp) },
                    deleted: { route = .section(.mcp) }
                )
            } else {
                ProLockedSettingsPage(
                    title: "MCP", feature: .remoteMCP,
                    back: { route = .section(.mcp) }
                )
            }
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
        case .pro:
            SettingsFormPage(
                title: "Termind Pro",
                subtitle: "Your permanent unlock and seven-day free trial."
            ) { ProSettings() }
        case .app:
            SettingsFormPage(title: "App", subtitle: "About this application.") { AppSettings() }
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
                TerminalSettings(
                    editConfiguration: { route = .terminalConfiguration($0) },
                    shellIntegrationChanged: {
                        app.shellIntegrationPreferenceDidChange(isEnabled: $0)
                    }
                )
            }
        case .sftp:
            SettingsFormPage(title: "SFTP", subtitle: "Control transfer concurrency across sessions.") {
                SFTPSettings()
            }
        case .providers:
            SettingsFormPage(title: "Providers", subtitle: "Endpoints and credentials used by the assistant.") {
                ModelProviderSettings { id, isNew in
                    route = .modelProvider(id, isNew: isNew)
                }
            }
        case .modelRoles:
            SettingsFormPage(title: "Model Roles", subtitle: "Choose which model handles each assistant task.") {
                ModelRoleSettings()
            }
        case .assistant:
            SettingsFormPage(
                title: "Assistant",
                subtitle: "What happens as a conversation approaches the model's limit."
            ) {
                AssistantSettings()
            }
        case .webSearch:
            SettingsFormPage(
                title: "Web Search",
                subtitle: "Choose between provider-native search and local Web Search on this Mac."
            ) {
                WebSearchSettings()
            }
        case .mcp:
            SettingsFormPage(title: "MCP", subtitle: "Remote MCP servers available to the assistant.") {
                MCPSettings { id, isNew in route = .mcpServer(id, isNew: isNew) }
            }
        case .mcpServer:
            SettingsFormPage(
                title: "MCP Server",
                subtitle: "Expose Termind's SSH and SFTP tools to local MCP clients."
            ) { MCPServerSettings() }
        case .sync:
            SettingsFormPage(title: "iCloud", subtitle: "Sync status and data protection.") { SyncSettings() }
        #if DEBUG
            case .developer:
                DeveloperSettingsPage()
        #endif
        }
    }

    private func cleanUpDraft(from route: SettingsRoute, movingTo newRoute: SettingsRoute) {
        switch route {
        case .modelProvider(let id, isNew: true):
            if case .providerModels(id, _) = newRoute { return }
            guard let provider = app.aiConfiguration.modelProvider(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(provider) { app.aiConfiguration.delete(modelProviderID: id) }
        case .providerModels(let id, isNew: true):
            if case .modelProvider(id, _) = newRoute { return }
            guard let provider = app.aiConfiguration.modelProvider(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(provider) { app.aiConfiguration.delete(modelProviderID: id) }
        case .mcpServer(let id, isNew: true):
            guard let server = app.aiConfiguration.mcpServer(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(server)
                || !app.aiConfiguration.lockMCPNamespace(for: id)
            {
                app.aiConfiguration.delete(serverID: id)
            }
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
        server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || server.effectiveNamespaceID.isEmpty
    }
}

private struct ProLockedSettingsPage: View {
    @Environment(AppModel.self) private var app
    let title: LocalizedStringKey
    let feature: ProFeature
    let back: () -> Void

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                Spacer()
            }
            .padding()
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.tint)
            Text(title).font(.title2.bold())
            Text("This configuration is available with Termind Pro.")
                .foregroundStyle(.secondary)
            Button("View Termind Pro") { app.proAccess.presentPaywall(for: feature) }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
    }
}

private struct SettingsSidebar: View {
    let selection: SettingsSection
    let select: (SettingsSection) -> Void

    var body: some View {
        SettingsNavigationNativeList(items: items) { item in
            switch item.content {
            case .group(let group):
                Text(group.title)
                    .textCase(.uppercase)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.Space.m)
            case .section(let section, _):
                sectionRow(section)
            }
        }
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.xl)
        .termindGlassBar()
    }

    private var items: [SettingsNavigationItem] {
        SettingsNavigationGroup.allCases.flatMap { group in
            [.group(group)] + group.sections.map {
                .section($0, selected: selection == $0)
            }
        }
    }

    private func sectionRow(_ section: SettingsSection) -> some View {
        SidebarNavigatorRow(
            title: section.title,
            symbol: section.symbol,
            isSelected: selection == section
        ) {
            select(section)
        }
    }
}

nonisolated enum SettingsNavigationGroup: CaseIterable, Hashable, Sendable {
    case general, terminal, ai, sync
    #if DEBUG
        case development
    #endif

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .ai: "AI"
        case .sync: "Sync"
        #if DEBUG
            case .development: "Development"
        #endif
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .general: [.pro, .app, .startup, .sidebar]
        case .terminal: [.terminalAppearance, .sftp]
        case .ai: [.providers, .modelRoles, .webSearch, .mcp, .mcpServer]
        case .sync: [.sync]
        #if DEBUG
            case .development: [.developer]
        #endif
        }
    }
}

nonisolated struct SettingsNavigationItem: Identifiable, Hashable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        case group(SettingsNavigationGroup)
        case section(SettingsSection)
    }
    nonisolated enum Content: Hashable, Sendable {
        case group(SettingsNavigationGroup)
        case section(SettingsSection, selected: Bool)
    }
    let id: ID
    let content: Content

    static func group(_ group: SettingsNavigationGroup) -> Self {
        .init(id: .group(group), content: .group(group))
    }
    static func section(_ section: SettingsSection, selected: Bool) -> Self {
        .init(id: .section(section), content: .section(section, selected: selected))
    }
    var height: CGFloat {
        switch content {
        case .group: 32
        case .section: 36
        }
    }
}

private struct SettingsNavigationNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<SettingsNavigationItem>
    typealias Renderer = @MainActor (SettingsNavigationItem) -> AnyView
    let items: [SettingsNavigationItem]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [SettingsNavigationItem],
        @ViewBuilder renderer: @escaping @MainActor (SettingsNavigationItem) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private let content = HostingListContent<SettingsNavigationItem>()

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.rows {
                ListRow(HostingListRow.self)
                    .height { item, _ in item.height }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }
        func update(
            listView: NSViewType, items: [SettingsNavigationItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
        ) {
            content.update(
                listView, items: items, renderer: renderer, locale: locale,
                colorScheme: colorScheme, animated: true
            )
        }
        private func configure(_ row: HostingListRow, item: SettingsNavigationItem) {
            content.configure(row, item: item)
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
        .termindGlassBar()
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
        .termindGlassBar()
    }
}

private struct AppSettings: View {
    @AppStorage(SettingsKey.appLanguage) private var languageID = AppLanguage.system.rawValue
    @State private var launchLanguage = AppLanguage.stored()

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageID) ?? .system
    }

    var body: some View {
        Section("Language") {
            Picker("Application Language", selection: $languageID) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }

            if selectedLanguage != launchLanguage {
                LabeledContent {
                    Button("Relaunch Now") { AppRelauncher.relaunch() }
                } label: {
                    Text("The new language will be used after Termind relaunches.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: languageID) {
            let language = AppLanguage(rawValue: languageID) ?? .system
            if language.rawValue != languageID { languageID = language.rawValue }
            AppLanguage.store(language)
        }

        Section("Version") {
            LabeledContent {
                Text(Bundle.termindDisplayVersion).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Text(verbatim: "App")
            }
            LabeledContent("Ghostty") {
                Text(RuntimeVersions.ghostty).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("libssh2") {
                Text(RuntimeVersions.libssh2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("OpenSSL") {
                Text(RuntimeVersions.openSSL).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }

        Section("Support") {
            Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                Label("Support", systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                Label("Privacy Policy", systemImage: "hand.raised")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ProSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section("Access") {
            LabeledContent("Status") { statusLabel }
            if case .trialActive(let expiresAt) = app.proAccess.status {
                LabeledContent("Trial Ends") {
                    Text(expiresAt, format: .dateTime.year().month().day().hour().minute())
                }
            }
        }

        Section("Termind Pro") {
            Text("Unlock multiple-pane workspaces, the AI Assistant, terminal drop uploads, MCP, and private iCloud Vault sync with one permanent purchase.")
                .foregroundStyle(.secondary)
            if app.proAccess.status.canPurchase {
                Button(purchaseEntryTitle) { app.proAccess.presentPaywall() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Restore Purchase") { Task { await app.proAccess.restorePurchases() } }
            if let message = app.proAccess.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }

        Section("Included") {
            includedFeature("Permanent unlock", systemImage: "infinity")
            includedFeature("Apple Family Sharing", systemImage: "person.3")
            includedFeature("No subscription or automatic renewal", systemImage: "checkmark.seal")
            Text("AI provider usage and charges are separate from Termind Pro.")
                .font(.caption).foregroundStyle(.secondary)
        }

    }

    private var purchaseEntryTitle: LocalizedStringKey {
        if case .trialActive = app.proAccess.status { return "Buy Termind Pro" }
        return "View Termind Pro"
    }

    private func includedFeature(
        _ title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: systemImage)
                .frame(width: 20, alignment: .center)
            Text(title)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch app.proAccess.status {
        case .loading: Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
        case .free: Label("Free", systemImage: "person.crop.circle")
        case .trialActive: Label("7-Day Trial", systemImage: "clock")
        case .trialExpired: Label("Trial Ended", systemImage: "clock.badge.xmark")
        case .purchased(.purchased): Label("Purchased", systemImage: "checkmark.seal.fill")
        case .purchased(.familyShared): Label("Family Shared", systemImage: "person.3.fill")
        case .purchasePending: Label("Purchase Pending", systemImage: "hourglass")
        case .verificationFailed: Label("Verification Required", systemImage: "exclamationmark.shield")
        case .unrestrictedForTesting: Label("Development Access", systemImage: "hammer")
        }
    }
}

private struct StartupSettings: View {
    @AppStorage(SettingsKey.restoreWorkspaces) private var restoreWorkspaces = true
    var body: some View {
        Section("Startup") {
            Toggle("Restore Workspaces from Last Session", isOn: $restoreWorkspaces)
        }
    }
}

private struct SidebarSettings: View {
    @AppStorage(SettingsKey.showRecents) private var showRecents = true
    var body: some View {
        Section("Sidebar") {
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
    let shellIntegrationChanged: (Bool) -> Void
    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = 12.0
    @AppStorage(SettingsKey.terminalFontFollowTheme) private var fontFollowTheme = true
    @AppStorage(SettingsKey.shellIntegration) private var shellIntegration = true
    @AppStorage(SettingsKey.remoteWindowTitleInMenuBar) private var remoteWindowTitleInMenuBar =
        SettingsKey.defaultRemoteWindowTitleInMenuBarEnabled
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
                if lightCustomEnabled {
                    FormNavigationAction(title: "Edit Custom Configuration") {
                        editConfiguration(.light)
                    }
                }
            }
            Section("Dark Configuration") {
                Picker("Theme", selection: $darkTheme) { ForEach(darkThemes) { Text($0.name).tag($0.name) } }
                    .disabled(darkCustomEnabled)
                Toggle("Custom Configuration", isOn: $darkCustomEnabled)
                if darkCustomEnabled {
                    FormNavigationAction(title: "Edit Custom Configuration") {
                        editConfiguration(.dark)
                    }
                }
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
                Text(
                    "Keeps the remote working directory current, records confirmed commands, and provides detected distribution, kernel, and architecture details to AI features."
                )
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Show Terminal Title in Menu Bar", isOn: $remoteWindowTitleInMenuBar)
                Text(
                    "Shows the focused SSH terminal's reported title after Help in the macOS menu bar."
                )
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if TermindTerminalThemeCatalog.darkTheme(named: darkTheme) == nil { darkTheme = SettingsKey.defaultTerminalThemeDark }
            if TermindTerminalThemeCatalog.lightTheme(named: lightTheme) == nil { lightTheme = SettingsKey.defaultTerminalThemeLight }
        }
        .onChange(of: shellIntegration) { _, isEnabled in
            shellIntegrationChanged(isEnabled)
        }
    }
}

private struct SyncSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @AppStorage(SettingsKey.vaultSyncEnabled) private var isEnabled =
        SettingsKey.defaultVaultSyncEnabled

    var body: some View {
        Section("iCloud") {
            Toggle("Sync Vault with iCloud", isOn: syncEnabled)
            LabeledContent("Status") { statusLabel }

            if case .accountChangeConfirmationRequired = status {
                Text("This Mac is signed in to a different iCloud account. Your local Vault will not be uploaded until you confirm the merge.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Merge with This iCloud Account") {
                    app.vaultSync?.confirmAccountSwitchMerge()
                }
            } else if case .failed = status {
                Button("Retry") { app.vaultSync?.retry() }
            }

            Text("Hosts, identities, public key metadata, Known Hosts, snippets, and port forwards sync through your private iCloud database. Passwords and private keys remain protected separately by Keychain. Credentials marked “This Mac” will be missing on other Macs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var syncEnabled: Binding<Bool> {
        Binding(
            get: { isEnabled && app.proAccess.canUse(.vaultSync) },
            set: { enabled in
                guard !enabled || app.proAccess.require(.vaultSync) else { return }
                isEnabled = enabled
                app.vaultSync?.setEnabled(enabled)
            }
        )
    }

    private var status: VaultSyncStatus {
        guard app.proAccess.canUse(.vaultSync) else { return .paused }
        return app.vaultSync?.status ?? (isEnabled ? .checkingAccount : .paused)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .checkingAccount:
            Label("Checking iCloud…", systemImage: "icloud")
        case .paused:
            Label("Paused", systemImage: "pause.circle")
        case .unavailable(let message):
            Label(message, systemImage: "icloud.slash").foregroundStyle(.secondary)
        case .accountChangeConfirmationRequired:
            Label("Waiting for confirmation", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .syncing(let pendingCount):
            Label(
                pendingCount == 1 ? "Syncing 1 change…" : "Syncing \(pendingCount) changes…",
                systemImage: "arrow.triangle.2.circlepath.icloud"
            )
        case .upToDate(let lastSync):
            if let lastSync {
                let formatted = lastSync.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
                )
                Label(
                    "Up to date · \(formatted)",
                    systemImage: "checkmark.icloud"
                )
            } else {
                Label("Up to date", systemImage: "checkmark.icloud")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(.red)
        }
    }
}
