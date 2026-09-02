import AgentKit
import GhosttyTheme
import SwiftUI

nonisolated enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case pro, app, terminal, sftp, ai, sync
    #if DEBUG
        case developer
    #endif

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .pro: "Termind Pro"
        case .app: "App"
        case .terminal: "Terminal"
        case .sftp: "SFTP"
        case .ai: "AI"
        case .sync: "Sync"
        #if DEBUG
            case .developer: "Developer"
        #endif
        }
    }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .pro: AppLocalization.string("Termind Pro", locale: locale)
        case .app: AppLocalization.string("App", locale: locale)
        case .terminal: AppLocalization.string("Terminal", locale: locale)
        case .sftp: AppLocalization.string("SFTP", locale: locale)
        case .ai: AppLocalization.string("AI", locale: locale)
        case .sync: AppLocalization.string("Sync", locale: locale)
        #if DEBUG
            case .developer: AppLocalization.string("Developer", locale: locale)
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .pro: "sparkles.rectangle.stack"
        case .app: "app.badge"
        case .terminal: "terminal"
        case .sftp: "arrow.up.arrow.down"
        case .ai: "brain"
        case .sync: "icloud"
        #if DEBUG
            case .developer: "hammer"
        #endif
        }
    }
}

enum SettingsRoute: Hashable {
    case index
    case category(SettingsCategory)
    case modelProvider(ModelProvider.ID)
    case providerModels(ModelProvider.ID)
    case mcpServer(MCPServer.ID, isNew: Bool)
    case localMCPServer
    case skill(AgentSkill.ID, isNew: Bool)
    case terminalConfiguration(TerminalCustomConfigurationScheme)

    var parent: SettingsRoute? {
        switch self {
        case .index:
            nil
        case .category:
            .index
        case .modelProvider:
            .category(.ai)
        case .providerModels(let id):
            .modelProvider(id)
        case .mcpServer:
            .category(.ai)
        case .localMCPServer:
            .category(.ai)
        case .skill:
            .category(.ai)
        case .terminalConfiguration:
            .category(.terminal)
        }
    }
}

struct SettingsPageView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TermindColor.windowSurface)
        .onChange(of: window.settingsRoute) { oldRoute, newRoute in
            cleanUpDraft(from: oldRoute, movingTo: newRoute)
        }
        .onDisappear {
            cleanUpDraft(from: window.settingsRoute, movingTo: .index)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch window.settingsRoute {
        case .index:
            SettingsIndexPage(
                categories: SettingsCategory.allCases,
                select: { navigate(to: .category($0)) }
            )
        case .category(let category):
            categoryPage(category)
        case .modelProvider(let id):
            ModelProviderEditorPage(
                modelProviderID: id,
                showModels: { navigate(to: .providerModels(id)) },
                deleted: { navigate(to: .category(.ai)) }
            )
        case .providerModels(let id):
            ModelListEditor(modelProviderID: id)
        case .mcpServer(let id, _):
            if app.proAccess.canUse(.remoteMCP) {
                MCPServerEditorPage(
                    serverID: id,
                    deleted: { navigate(to: .category(.ai)) }
                )
            } else {
                ProLockedSettingsPage(title: "MCP", feature: .remoteMCP)
            }
        case .localMCPServer:
            SettingsFormPage { MCPServerSettings() }
        case .skill(let id, _):
            SkillEditorPage(skillID: id, deleted: { navigate(to: .category(.ai)) })
        case .terminalConfiguration(let scheme):
            TerminalCustomConfigurationEditorPage(scheme: scheme)
        }
    }

    @ViewBuilder
    private func categoryPage(_ category: SettingsCategory) -> some View {
        switch category {
        case .pro:
            SettingsFormPage { ProSettings() }
        case .app:
            SettingsFormPage {
                AppSettings()
                StartupSettings()
                SidebarSettings()
                AppInfoSettings()
            }
        case .terminal:
            SettingsFormPage {
                TerminalSettings(
                    editConfiguration: { navigate(to: .terminalConfiguration($0)) },
                    shellIntegrationChanged: {
                        app.shellIntegrationPreferenceDidChange(isEnabled: $0)
                    }
                )
            }
        case .sftp:
            SettingsFormPage { SFTPSettings() }
        case .ai:
            SettingsFormPage {
                ModelProviderSettings { id, _ in
                    navigate(to: .modelProvider(id))
                }
                ModelRoleSettings()
                WebSearchSettings()
                SkillSettings(
                    edit: { id, isNew in navigate(to: .skill(id, isNew: isNew)) }
                )
                MCPSettings(
                    edit: { id, isNew in navigate(to: .mcpServer(id, isNew: isNew)) },
                    openServer: { navigate(to: .localMCPServer) }
                )
            }
        case .sync:
            SettingsFormPage { SyncSettings() }
        #if DEBUG
            case .developer:
                DeveloperSettingsPage()
        #endif
        }
    }

    private func navigate(to route: SettingsRoute) {
        window.settingsRoute = route
    }

    private func cleanUpDraft(from route: SettingsRoute, movingTo newRoute: SettingsRoute) {
        switch route {
        case .modelProvider(let id):
            if case .providerModels(id) = newRoute { return }
            guard let provider = app.aiConfiguration.modelProvider(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(provider) { app.aiConfiguration.delete(modelProviderID: id) }
        case .providerModels(let id):
            if case .modelProvider(id) = newRoute { return }
            guard let provider = app.aiConfiguration.modelProvider(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(provider) { app.aiConfiguration.delete(modelProviderID: id) }
        case .mcpServer(let id, isNew: true):
            guard let server = app.aiConfiguration.mcpServer(id) else { return }
            if SettingsDraftPolicy.shouldDiscard(server)
                || !app.aiConfiguration.lockMCPNamespace(for: id)
            {
                app.aiConfiguration.delete(serverID: id)
            }
        case .skill(let id, isNew: true):
            guard let skill = app.skills.skill(id) else { return }
            // Unlike an MCP server, a skill that cannot be named yet is kept.
            // It is inert either way — an unnamed skill is never listed to a
            // model — and someone who wrote the procedure before the title has
            // done the expensive part of the work. It shows as a draft in the
            // list until they finish it.
            if SettingsDraftPolicy.shouldDiscard(skill) {
                app.skills.delete(id: id)
            } else {
                app.skills.lockName(for: id)
            }
        default:
            break
        }
    }
}

private struct SettingsIndexPage: View {
    let categories: [SettingsCategory]
    let select: (SettingsCategory) -> Void

    var body: some View {
        Form {
            Section {
                categoryButton(.pro)
            }

            Section {
                ForEach(regularCategories) { category in
                    categoryButton(category)
                }
            }

            #if DEBUG
                if categories.contains(.developer) {
                    Section { categoryButton(.developer) }
                }
            #endif
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var regularCategories: [SettingsCategory] {
        categories.filter { category in
            switch category {
            case .pro:
                false
            #if DEBUG
                case .developer:
                    false
            #endif
            default:
                true
            }
        }
    }

    private func categoryButton(_ category: SettingsCategory) -> some View {
        Button { select(category) } label: {
            SettingsCategoryRow(category: category)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            Label(category.title, systemImage: category.symbol)

            Spacer(minLength: Metrics.Space.m)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
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

    /// A skill nobody typed anything into. Judged on all three fields rather
    /// than on the name alone: someone who wrote the instructions first and
    /// walked away has a draft worth keeping, not an accident to clean up.
    static func shouldDiscard(_ skill: AgentSkill) -> Bool {
        skill.effectiveName.isEmpty
            && skill.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && skill.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ProLockedSettingsPage: View {
    @Environment(AppModel.self) private var app
    let title: LocalizedStringKey
    let feature: ProFeature

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text(title).font(.title2.bold())
            Text("This configuration is available with Termind Pro.")
                .foregroundStyle(.secondary)
            Button("View Termind Pro") { app.proAccess.presentPaywall(for: feature) }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsFormPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }
}

private struct AppInfoSettings: View {
    var body: some View {
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
            Section("Integration") {
                Toggle(isOn: $shellIntegration) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text("Shell Integration")
                        Text(
                            "Keeps the remote working directory current, records confirmed commands, and provides detected distribution, kernel, and architecture details to AI features."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $remoteWindowTitleInMenuBar) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text("Show Terminal Title in Menu Bar")
                        Text(
                            "Shows the focused SSH terminal's reported title after Help in the macOS menu bar."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
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
