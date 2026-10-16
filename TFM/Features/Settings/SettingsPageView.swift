import AgentKit
import GhosttyTheme
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

nonisolated enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case app, notifications, terminal, connections, ai, sync
    #if DEBUG
        case developer
    #endif

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .notifications: AppStrings.Notifications.title
        case .app: AppStrings.Settings.app
        case .terminal: AppStrings.Settings.terminal
        case .connections: AppStrings.Settings.connections
        case .ai: AppStrings.Settings.ai
        case .sync: AppStrings.Settings.sync
        #if DEBUG
            case .developer: AppStrings.Settings.developer
        #endif
        }
    }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .notifications: AppLocalization.resolve(AppStrings.Notifications.title, locale: locale)
        case .app: AppLocalization.resolve(AppStrings.Settings.app, locale: locale)
        case .terminal: AppLocalization.resolve(AppStrings.Settings.terminal, locale: locale)
        case .connections: AppLocalization.resolve(AppStrings.Settings.connections, locale: locale)
        case .ai: AppLocalization.resolve(AppStrings.Settings.ai, locale: locale)
        case .sync: AppLocalization.resolve(AppStrings.Settings.sync, locale: locale)
        #if DEBUG
            case .developer: AppLocalization.resolve("Developer", locale: locale)
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .notifications: "bell.badge"
        case .app: "app.badge"
        case .terminal: "terminal"
        case .connections: MenuSymbol.connect
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
    case terminalThemes(TerminalCustomConfigurationScheme)
    case terminalCustomThemes
    case terminalCustomTheme(UUID)
    case logging

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
        case .terminalThemes:
            .category(.terminal)
        case .terminalCustomThemes:
            .category(.terminal)
        case .terminalCustomTheme:
            .terminalCustomThemes
        case .logging:
            .index
        }
    }
}

struct SettingsPageView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var newlyCreatedProviderID: ModelProvider.ID?

    var body: some View {
        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TermindColor.windowSurface)
            .onChange(of: window.settingsRoute) { oldRoute, newRoute in
                cleanUpDraft(from: oldRoute, movingTo: newRoute)
                if case .modelProvider = oldRoute { newlyCreatedProviderID = nil }
            }
            .onDisappear {
                cleanUpDraft(from: window.settingsRoute, movingTo: .index)
            }
            .confirmationDialog(
                window.terminalThemeDraft?.isNew == true
                    ? AppStrings.Settings.discardNewCustomThemeQuestion : AppStrings.Common.discardChangesQuestion,
                isPresented: Binding(
                    get: { window.showsDiscardTerminalTheme },
                    set: { if !$0 { window.showsDiscardTerminalTheme = false } }),
                titleVisibility: .visible
            ) {
                Button(AppStrings.Common.discardChanges.swiftUIKey, role: .destructive) {
                    window.discardTerminalThemeAndNavigate()
                }
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {
                    window.cancelTerminalThemeNavigation()
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        switch window.settingsRoute {
        case .index:
            SettingsIndexPage(
                categories: SettingsCategory.allCases,
                select: { navigate(to: .category($0)) },
                openLogging: { navigate(to: .logging) },
                openPro: { app.proAccess.presentPaywall() }
            )
        case .category(let category):
            categoryPage(category)
        case .modelProvider(let id):
            ModelProviderEditorPage(
                modelProviderID: id,
                isNew: newlyCreatedProviderID == id,
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
                ProLockedSettingsPage(title: AppStrings.Settings.mcp)
            }
        case .localMCPServer:
            SettingsFormPage { MCPServerSettings() }
        case .skill(let id, _):
            SkillEditorPage(skillID: id, deleted: { navigate(to: .category(.ai)) })
        case .terminalThemes(let scheme):
            TerminalThemePage(scheme: scheme)
        case .terminalCustomThemes:
            TerminalCustomThemesPage()
        case .terminalCustomTheme:
            if let draft = window.terminalThemeDraft {
                TerminalCustomConfigurationEditorPage(
                    draft: draft, model: app.terminalSettings,
                    availableFontFamilies: TerminalFontCatalog.shared.families
                )
            }
        case .logging:
            SettingsFormPage { LoggingFilesSettings() }
        }
    }

    @ViewBuilder
    private func categoryPage(_ category: SettingsCategory) -> some View {
        switch category {
        case .app:
            SettingsFormPage {
                AppSettings()
                StartupSettings()
                DiagnosisSettingsSection(controller: app.diagnosis)
                AppInfoSettings()
            }
        case .notifications:
            SettingsFormPage {
                NotificationSettingsFields(
                    model: app.notificationSettings, service: app.notifications,
                    openSettings: TerminalNotificationPlatform.openSettings)
            }
        case .terminal:
            SettingsFormPage {
                TerminalSettings(
                    chooseTheme: { navigate(to: .terminalThemes($0)) },
                    manageCustomThemes: { navigate(to: .terminalCustomThemes) }
                )
            }
        case .connections:
            SettingsFormPage { ConnectionSettings() }
        case .ai:
            SettingsFormPage {
                ModelProviderSettings { id, isNew in
                    newlyCreatedProviderID = isNew ? id : nil
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
                MemorySettingsSection(memory: app.memory, ai: app.aiConfiguration)
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
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false
    let categories: [SettingsCategory]
    let select: (SettingsCategory) -> Void
    let openLogging: () -> Void
    let openPro: () -> Void

    var body: some View {
        Form {
            Section {
                Button(action: openPro) {
                    Label(AppStrings.Pro.termindPro.swiftUIKey, systemImage: "sparkles.rectangle.stack")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.openPro")
            }

            Section {
                ForEach(regularCategories) { category in
                    categoryButton(category)
                }
            }

            if debugSectionEnabled {
                Section {
                    Button(action: openLogging) {
                        HStack {
                            Label(AppStrings.Settings.logging.swiftUIKey, systemImage: "doc.text")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    LabeledContent {
                        Text(verbatim: String(DeviceCensorship.canDisplayTaiwanFlag))
                    } label: {
                        Label(AppStrings.Settings.taiwanFlagAvailable.swiftUIKey, systemImage: "touchid")
                    }
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
        Button {
            select(category)
        } label: {
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
        let hasEmptyName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasConfiguration =
            !provider.inferenceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || provider.hasCredential || !provider.models.isEmpty
        return hasEmptyName && !hasConfiguration
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
    let title: LocalizedStringResource

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text(title).font(.title2.bold())
            Text(AppStrings.Settings.thisConfigurationIsAvailableWithTermindPro)
                .foregroundStyle(.secondary)
            Button(AppStrings.Settings.viewTermindPro.swiftUIKey) { app.proAccess.presentPaywall() }
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
    @Environment(AppModel.self) private var app
    @AppStorage(DesktopSettingsKey.showStatusBar) private var showsStatusBar = true
    @AppStorage(DesktopSettingsKey.showMetricsInMenuBar) private var showMetricsInMenuBar = true
    @AppStorage(DesktopSettingsKey.appAppearance) private var appearanceID = AppAppearance.system.rawValue
    @AppStorage(SettingsKey.appLanguage) private var languageID = AppLanguage.system.rawValue
    @State private var launchLanguage = AppLanguage.stored()

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageID) ?? AppLanguage.stored()
    }

    private var languageSelection: Binding<AppLanguage> {
        Binding(
            get: { selectedLanguage },
            set: { language in
                languageID = language.rawValue
                AppLanguage.store(language)
            })
    }

    var body: some View {
        Section(AppStrings.Settings.appearance.swiftUIKey) {
            Toggle(AppStrings.Settings.showInMenuBar.swiftUIKey, isOn: $showMetricsInMenuBar)
            Toggle(
                AppStrings.Settings.showStatusBar.swiftUIKey,
                isOn: $showsStatusBar
            )
            Picker(
                AppStrings.Settings.theme.swiftUIKey,
                selection: Binding(
                    get: { AppAppearance(rawValue: appearanceID) ?? .system },
                    set: { appearanceID = $0.rawValue }
                )
            ) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }

            Picker(AppStrings.Settings.language.swiftUIKey, selection: languageSelection) {
                ForEach(AppLanguage.allCases) { language in
                    Text(
                        language.displayName(
                            deviceRegion: Locale.autoupdatingCurrent.region?.identifier,
                            canDisplayTaiwanFlag: DeviceCensorship.canDisplayTaiwanFlag
                        )
                    ).tag(language)
                }
            }

            if selectedLanguage != launchLanguage {
                Text(
                    verbatim: AppLocalization.resolve(
                        AppStrings.Settings.theNewLanguageWillBeUsedAfterTermindRelaunches,
                        locale: selectedLanguage.locale)
                )
                .foregroundStyle(.secondary)
            }
        }

        Section {
            Toggle(
                AppStrings.Settings.automaticallyRenameWorkspaces.swiftUIKey,
                isOn: Binding(
                    get: { app.workspaceSettings.preferences.automaticallyRenamesWorkspaces },
                    set: { _ = app.workspaceSettings.setAutomaticRenaming($0) }
                )
            )
            if let error = app.workspaceSettings.storageError {
                Text(error).foregroundStyle(.orange)
            }
        } header: {
            Text(AppStrings.Navigation.workspaces)
        } footer: {
            Text(AppStrings.Settings.workspaceNumberingExplanation)
        }
    }
}

private struct AppInfoSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false

    var body: some View {
        Section(AppStrings.Settings.version.swiftUIKey) {
            LabeledContent {
                Text(Bundle.termindDisplayVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Text(AppStrings.Settings.app)
            }
            .contentShape(.rect)
            .simultaneousGesture(
                TapGesture(count: 3)
                    .onEnded { debugSectionEnabled.toggle() }
            )
            LabeledContent(AppStrings.Settings.ghostty.swiftUIKey) {
                Text(RuntimeVersions.ghostty).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent(AppStrings.Settings.libssh2.swiftUIKey) {
                Text(RuntimeVersions.libssh2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent(AppStrings.Settings.openSSL.swiftUIKey) {
                Text(RuntimeVersions.openSSL).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent(AppStrings.Tailscale.title.swiftUIKey) {
                Text(RuntimeVersions.tailscale).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }

        Section(AppStrings.Settings.support.swiftUIKey) {
            AppReviewLink(controller: app.appReview) {
                Label(AppStrings.Settings.rateOnTheAppStore.swiftUIKey, systemImage: "star")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                Label(AppStrings.Settings.support.swiftUIKey, systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                Label(AppStrings.Pro.privacyPolicy.swiftUIKey, systemImage: "hand.raised")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct StartupSettings: View {
    @Environment(\.appearsActive) private var appearsActive
    @State private var loginItem = LoginItemController()
    @AppStorage(DesktopSettingsKey.openAtLoginQuietly) private var opensQuietly =
        DesktopSettingsKey.defaultOpenAtLoginQuietly

    var body: some View {
        Section(AppStrings.Settings.startup.swiftUIKey) {
            Toggle(
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text(AppStrings.Settings.openAtLogin)
                    Text(
                        AppStrings.Settings.loginItemExplanation
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Toggle(AppStrings.Settings.startMinimizedToSystemTray.swiftUIKey, isOn: $opensQuietly)
                .disabled(!loginItem.isEnabled)

            if loginItem.requiresApproval {
                LabeledContent {
                    Button(AppStrings.Settings.openLoginItemsSettings.swiftUIKey) { loginItem.openSystemSettings() }
                } label: {
                    Text(AppStrings.Settings.macOSIsWaitingForYouToAllowTermindInLoginItems)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = loginItem.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        // The registration lives in System Settings, where it can be revoked
        // without telling us. Re-read it whenever this window is looked at.
        .onAppear { loginItem.refresh() }
        .onChange(of: appearsActive) { _, isActive in
            if isActive { loginItem.refresh() }
        }
    }
}

private struct ConnectionSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section(AppStrings.Vault.ssh.swiftUIKey) { SSHSettingsFields(model: app.sshSettings) }
        Section(AppStrings.SFTP.sftp.swiftUIKey) {
            SFTPSettingsFields(
                model: app.sftpSettings,
                access: .init(isAllowed: app.proAccess.canUse(.sftpMultiConnection)) {
                    app.proAccess.require(.sftpMultiConnection)
                })
        }
    }
}

private struct TerminalSettings: View {
    let chooseTheme: (TerminalCustomConfigurationScheme) -> Void
    let manageCustomThemes: () -> Void
    @Environment(AppModel.self) private var app
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase

    private func binding<Value>(_ keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { app.terminalSettings.preferences[keyPath: keyPath] },
            set: { app.terminalSettings.set($0, for: keyPath) })
    }

    private func themeRow(_ scheme: TerminalCustomConfigurationScheme) -> some View {
        let options = TerminalThemeOptions(
            preferences: app.terminalSettings.preferences, isDark: scheme == .dark,
            library: app.terminalSettings.themeLibrary)
        return Button {
            chooseTheme(scheme)
        } label: {
            HStack {
                Text(options.title)
                Spacer()
                options.summary.foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(options.title))
        .accessibilityValue(options.summary)
    }

    var body: some View {
        Group {
            if let error = app.terminalSettings.storageError {
                Text(error).foregroundStyle(.orange)
            }
            Section(AppStrings.Settings.theme.swiftUIKey) {
                themeRow(.light)
                themeRow(.dark)
                Button(action: manageCustomThemes) {
                    HStack {
                        Text(AppStrings.Settings.customThemes)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }
            Section(AppStrings.Settings.font.swiftUIKey) {
                TerminalFontFields(preferences: $font, families: TerminalFontCatalog.shared.families)
            }
            Section(AppStrings.Settings.mouse.swiftUIKey) {
                Toggle(AppStrings.Settings.copyOnSelection.swiftUIKey, isOn: binding(\.copyOnSelect))
                Toggle(isOn: binding(\.pasteOnRightClick)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text(AppStrings.Settings.pasteOnRightClick)
                        Text(
                            AppStrings.Settings.rightClickPasteExplanation
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section(AppStrings.Settings.integration.swiftUIKey) {
                Toggle(isOn: binding(\.shellIntegration)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text(AppStrings.Settings.shellIntegration)
                        Text(
                            AppStrings.Settings.shellIntegrationExplanation
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            TerminalFontCatalog.shared.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { TerminalFontCatalog.shared.refresh() }
        }
    }
}
