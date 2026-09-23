import AgentKit
import GhosttyTheme
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

nonisolated enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case pro, app, terminal, connections, ai, sync
    #if DEBUG
        case developer
    #endif

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .pro: TermindCopy.Pro.termindPro
        case .app: TermindCopy.Settings.app
        case .terminal: TermindCopy.Settings.terminal
        case .connections: TermindCopy.Settings.connections
        case .ai: TermindCopy.Settings.ai
        case .sync: TermindCopy.Settings.sync
        #if DEBUG
            case .developer: TermindCopy.Settings.developer
        #endif
        }
    }

    func title(locale: Locale = .current) -> String {
        switch self {
        case .pro: AppLocalization.resolve(TermindCopy.Pro.termindPro, locale: locale)
        case .app: AppLocalization.resolve(TermindCopy.Settings.app, locale: locale)
        case .terminal: AppLocalization.resolve(TermindCopy.Settings.terminal, locale: locale)
        case .connections: AppLocalization.resolve(TermindCopy.Settings.connections, locale: locale)
        case .ai: AppLocalization.resolve(TermindCopy.Settings.ai, locale: locale)
        case .sync: AppLocalization.resolve(TermindCopy.Settings.sync, locale: locale)
        #if DEBUG
            case .developer: AppLocalization.resolve("Developer", locale: locale)
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .pro: "sparkles.rectangle.stack"
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
    case terminalConfiguration(TerminalCustomConfigurationScheme)
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
        case .terminalConfiguration:
            .category(.terminal)
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
    }

    @ViewBuilder
    private var detail: some View {
        switch window.settingsRoute {
        case .index:
            SettingsIndexPage(
                categories: SettingsCategory.allCases,
                select: { navigate(to: .category($0)) },
                openLogging: { navigate(to: .logging) }
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
                ProLockedSettingsPage(title: TermindCopy.Settings.mcp, feature: .remoteMCP)
            }
        case .localMCPServer:
            SettingsFormPage { MCPServerSettings() }
        case .skill(let id, _):
            SkillEditorPage(skillID: id, deleted: { navigate(to: .category(.ai)) })
        case .terminalConfiguration(let scheme):
            TerminalCustomConfigurationEditorPage(scheme: scheme)
        case .logging:
            SettingsFormPage { LoggingFilesSettings() }
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
                AppInfoSettings()
            }
        case .terminal:
            SettingsFormPage {
                TerminalSettings(
                    editConfiguration: { navigate(to: .terminalConfiguration($0)) }
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

            if debugSectionEnabled {
                Section {
                    Button(action: openLogging) {
                        HStack {
                            Label(TermindCopy.Settings.logging.swiftUIKey, systemImage: "doc.text")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    LabeledContent {
                        Text(verbatim: String(DeviceCensorship.canDisplayTaiwanFlag))
                    } label: {
                        Label(TermindCopy.Settings.taiwanFlagAvailable.swiftUIKey, systemImage: "touchid")
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
    let feature: ProFeature

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text(title).font(.title2.bold())
            Text(TermindCopy.Settings.thisConfigurationIsAvailableWithTermindPro)
                .foregroundStyle(.secondary)
            Button(TermindCopy.Settings.viewTermindPro.swiftUIKey) { app.proAccess.presentPaywall(for: feature) }
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
        Section(TermindCopy.Settings.appearance.swiftUIKey) {
            Toggle(TermindCopy.Settings.showInMenuBar.swiftUIKey, isOn: $showMetricsInMenuBar)
            Picker(
                TermindCopy.Settings.theme.swiftUIKey,
                selection: Binding(
                    get: { AppAppearance(rawValue: appearanceID) ?? .system },
                    set: { appearanceID = $0.rawValue }
                )
            ) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }

            Picker(TermindCopy.Settings.language.swiftUIKey, selection: languageSelection) {
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
                LabeledContent {
                    Button(TermindCopy.Settings.relaunchNow.swiftUIKey) { AppRelauncher.relaunch() }
                } label: {
                    Text(TermindCopy.Settings.theNewLanguageWillBeUsedAfterTermindRelaunches)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            Toggle(
                TermindCopy.Settings.automaticallyRenameWorkspaces.swiftUIKey,
                isOn: Binding(
                    get: { app.workspaceSettings.preferences.automaticallyRenamesWorkspaces },
                    set: { _ = app.workspaceSettings.setAutomaticRenaming($0) }
                )
            )
            if let error = app.workspaceSettings.storageError {
                Text(error).foregroundStyle(.orange)
            }
        } header: {
            Text(TermindCopy.Navigation.workspaces)
        } footer: {
            Text(TermindCopy.Settings.workspaceNumberingExplanation)
        }
    }
}

private struct AppInfoSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.debugSectionEnabled) private var debugSectionEnabled = false

    var body: some View {
        Section(TermindCopy.Settings.version.swiftUIKey) {
            LabeledContent {
                Text(Bundle.termindDisplayVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Text(TermindCopy.Settings.app)
            }
            .contentShape(.rect)
            .simultaneousGesture(
                TapGesture(count: 3)
                    .onEnded { debugSectionEnabled.toggle() }
            )
            LabeledContent(TermindCopy.Settings.ghostty.swiftUIKey) {
                Text(RuntimeVersions.ghostty).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent(TermindCopy.Settings.libssh2.swiftUIKey) {
                Text(RuntimeVersions.libssh2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent(TermindCopy.Settings.openSSL.swiftUIKey) {
                Text(RuntimeVersions.openSSL).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }

        Section(TermindCopy.Settings.support.swiftUIKey) {
            Link(destination: AppReviewController.reviewURL) {
                Label(TermindCopy.Settings.rateOnTheAppStore.swiftUIKey, systemImage: "star")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .environment(
                \.openURL,
                OpenURLAction { url in
                    app.appReview.recordManualReview()
                    return .systemAction(url)
                }
            )
            Link(destination: URL(string: "https://termind.akinokaede.com/support/")!) {
                Label(TermindCopy.Settings.support.swiftUIKey, systemImage: "questionmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Link(destination: URL(string: "https://termind.akinokaede.com/privacy/")!) {
                Label(TermindCopy.Pro.privacyPolicy.swiftUIKey, systemImage: "hand.raised")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ProSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            Section(TermindCopy.Settings.access.swiftUIKey) {
                LabeledContent(TermindCopy.Common.status.swiftUIKey) { statusLabel }
                if let expirationLabel, let expirationDate {
                    LabeledContent(expirationLabel.swiftUIKey) {
                        Text(expirationDate, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }

            Section(TermindCopy.Pro.termindPro.swiftUIKey) {
                Text(
                    TermindCopy.Settings.proPlanExplanation
                )
                .foregroundStyle(.secondary)
                if app.proAccess.status.canPurchase {
                    Button(TermindCopy.Settings.viewTermindPro.swiftUIKey) { app.proAccess.presentPaywall() }
                        .buttonStyle(.borderedProminent)
                }
                if canManageSubscription {
                    Link(
                        TermindCopy.Pro.manageSubscription.swiftUIKey,
                        destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                Button(TermindCopy.Pro.restorePurchase.swiftUIKey) { Task { await app.proAccess.restorePurchases() } }
                    .disabled(app.proAccess.isProcessing)
                if let message = app.proAccess.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }

            Section(TermindCopy.Settings.options.swiftUIKey) {
                includedFeature(TermindCopy.Pro.annualSubscription, systemImage: "calendar")
                includedFeature(TermindCopy.Settings.permanentLifetimeUnlock, systemImage: "infinity")
                includedFeature(TermindCopy.Settings.appleFamilySharing, systemImage: "person.3")
                Text(TermindCopy.Settings.aiProviderUsageAndChargesAreSeparateFromTermindPro)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canManageSubscription: Bool {
        guard case .subscription(let subscription) = app.proAccess.status else { return false }
        return subscription.ownership == .purchased
    }

    private var expirationDate: Date? {
        switch app.proAccess.status {
        case .subscription(let subscription): subscription.expiresAt
        default: nil
        }
    }

    private var expirationLabel: LocalizedStringResource? {
        switch app.proAccess.status {
        case .subscription(let subscription):
            switch subscription.phase {
            case .introductoryTrial: TermindCopy.Settings.trialEnds
            case .subscribed:
                subscription.willAutoRenew == false ? TermindCopy.Settings.accessEnds : TermindCopy.Settings.renews
            case .gracePeriod: TermindCopy.Settings.gracePeriodEnds
            case .billingRetry, .expired, .revoked: TermindCopy.Settings.expired
            }
        default:
            nil
        }
    }

    private func includedFeature(
        _ title: LocalizedStringResource,
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
        case .loading: Label(TermindCopy.Pro.checkingProgress.swiftUIKey, systemImage: "arrow.triangle.2.circlepath")
        case .free: Label(TermindCopy.Pro.free.swiftUIKey, systemImage: "person.crop.circle")
        case .subscription(let subscription): subscriptionStatusLabel(subscription)
        case .purchased(.purchased): Label(TermindCopy.Pro.lifetime.swiftUIKey, systemImage: "infinity")
        case .purchased(.familyShared):
            Label(TermindCopy.Settings.lifetimeFamilyShared.swiftUIKey, systemImage: "person.3.fill")
        case .verificationFailed:
            Label(TermindCopy.Settings.verificationRequired.swiftUIKey, systemImage: "exclamationmark.shield")
        case .unrestrictedForTesting: Label(TermindCopy.Settings.developmentAccess.swiftUIKey, systemImage: "hammer")
        }
    }

    @ViewBuilder
    private func subscriptionStatusLabel(_ subscription: ProSubscriptionStatus) -> some View {
        switch subscription.phase {
        case .introductoryTrial: Label(TermindCopy.Pro.freeTrial.swiftUIKey, systemImage: "clock")
        case .subscribed:
            Label(
                subscription.ownership == .familyShared
                    ? TermindCopy.Settings.annualFamilyShared.swiftUIKey
                    : TermindCopy.Pro.annualSubscription.swiftUIKey,
                systemImage: subscription.ownership == .familyShared ? "person.3.fill" : "checkmark.seal.fill")
        case .gracePeriod:
            Label(TermindCopy.Pro.billingGracePeriod.swiftUIKey, systemImage: "clock.badge.exclamationmark")
        case .billingRetry:
            Label(TermindCopy.Pro.billingIssue.swiftUIKey, systemImage: "creditcard.trianglebadge.exclamationmark")
        case .expired:
            Label(TermindCopy.Pro.subscriptionExpired.swiftUIKey, systemImage: "calendar.badge.exclamationmark")
        case .revoked: Label(TermindCopy.Pro.subscriptionRevoked.swiftUIKey, systemImage: "xmark.seal")
        }
    }
}

private struct StartupSettings: View {
    @Environment(\.appearsActive) private var appearsActive
    @State private var loginItem = LoginItemController()
    @AppStorage(DesktopSettingsKey.openAtLoginQuietly) private var opensQuietly =
        DesktopSettingsKey.defaultOpenAtLoginQuietly

    var body: some View {
        Section(TermindCopy.Settings.startup.swiftUIKey) {
            Toggle(
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text(TermindCopy.Settings.openAtLogin)
                    Text(
                        TermindCopy.Settings.loginItemExplanation
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Toggle(TermindCopy.Settings.openHiddenAtLogin.swiftUIKey, isOn: $opensQuietly)
                .disabled(!loginItem.isEnabled)

            if loginItem.requiresApproval {
                LabeledContent {
                    Button(TermindCopy.Settings.openLoginItemsSettings.swiftUIKey) { loginItem.openSystemSettings() }
                } label: {
                    Text(TermindCopy.Settings.macOSIsWaitingForYouToAllowTermindInLoginItems)
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
        Section(TermindCopy.Vault.ssh.swiftUIKey) { SSHSettingsFields(model: app.sshSettings) }
        Section(TermindCopy.SFTP.sftp.swiftUIKey) { SFTPSettingsFields(model: app.sftpSettings) }
    }
}

private struct TerminalSettings: View {
    let editConfiguration: (TerminalCustomConfigurationScheme) -> Void
    @Environment(AppModel.self) private var app
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase

    private func binding<Value>(_ keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { app.terminalSettings.preferences[keyPath: keyPath] },
            set: { app.terminalSettings.set($0, for: keyPath) })
    }

    var body: some View {
        Group {
            if let error = app.terminalSettings.storageError {
                Text(error).foregroundStyle(.orange)
            }
            Section(TermindCopy.Settings.light.swiftUIKey) {
                TerminalThemePicker(selection: binding(\.lightTheme), isDark: false)
                Toggle(TermindCopy.Settings.customConfiguration.swiftUIKey, isOn: binding(\.lightCustomEnabled))
                FormNavigationAction(title: TermindCopy.Settings.editCustomConfiguration) {
                    editConfiguration(.light)
                }
            }
            Section {
                TerminalThemePicker(selection: binding(\.darkTheme), isDark: true)
                Toggle(TermindCopy.Settings.customConfiguration.swiftUIKey, isOn: binding(\.darkCustomEnabled))
                FormNavigationAction(title: TermindCopy.Settings.editCustomConfiguration) {
                    editConfiguration(.dark)
                }
            } header: {
                Text(TermindCopy.Settings.dark)
            } footer: {
                Text(
                    TermindCopy.Settings.terminalConfigurationExplanation
                )
            }
            Section(TermindCopy.Settings.font.swiftUIKey) {
                TerminalFontFields(preferences: $font, families: TerminalFontCatalog.shared.families)
            }
            Section(TermindCopy.Settings.mouse.swiftUIKey) {
                Toggle(TermindCopy.Settings.copyOnSelection.swiftUIKey, isOn: binding(\.copyOnSelect))
                Toggle(isOn: binding(\.pasteOnRightClick)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text(TermindCopy.Settings.pasteOnRightClick)
                        Text(
                            TermindCopy.Settings.rightClickPasteExplanation
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section(TermindCopy.Settings.integration.swiftUIKey) {
                Toggle(isOn: binding(\.shellIntegration)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text(TermindCopy.Settings.shellIntegration)
                        Text(
                            TermindCopy.Settings.shellIntegrationExplanation
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Toggle(
                    TermindCopy.Settings.showTerminalTitleInMenuBar.swiftUIKey,
                    isOn: binding(\.remoteWindowTitleInMenuBar))
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
