import AgentKit
import GhosttyTheme
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

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
                select: { navigate(to: .category($0)) }
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
                AppInfoSettings()
            }
        case .terminal:
            SettingsFormPage {
                TerminalSettings(
                    editConfiguration: { navigate(to: .terminalConfiguration($0)) }
                )
            }
        case .sftp:
            SettingsFormPage { SFTPSettings() }
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
            SettingsFormPage {
                SyncSettings()
            }
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
        Section("Appearance") {
            Toggle("Show in Menu Bar", isOn: $showMetricsInMenuBar)
            Picker(
                "Theme",
                selection: Binding(
                    get: { AppAppearance(rawValue: appearanceID) ?? .system },
                    set: { appearanceID = $0.rawValue }
                )
            ) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }

            Picker("Language", selection: languageSelection) {
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
                    Button("Relaunch Now") { AppRelauncher.relaunch() }
                } label: {
                    Text("The new language will be used after Termind relaunches.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AppInfoSettings: View {
    @Environment(AppModel.self) private var app

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
            Link(destination: AppReviewController.reviewURL) {
                Label("Rate on the App Store", systemImage: "star")
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
        Group {
            Section("Access") {
                LabeledContent("Status") { statusLabel }
                if let expirationLabel, let expirationDate {
                    LabeledContent(expirationLabel) {
                        Text(expirationDate, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }

            Section("Termind Pro") {
                Text(
                    "Choose annual access or a permanent unlock for multi-pane workspaces, the AI Assistant, terminal uploads, MCP, and iCloud sync."
                )
                .foregroundStyle(.secondary)
                if app.proAccess.status.canPurchase {
                    Button("View Termind Pro") { app.proAccess.presentPaywall() }
                        .buttonStyle(.borderedProminent)
                }
                if canManageSubscription {
                    Link(
                        "Manage Subscription",
                        destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                Button("Restore Purchase") { Task { await app.proAccess.restorePurchases() } }
                    .disabled(app.proAccess.isProcessing)
                if let message = app.proAccess.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Options") {
                includedFeature("Annual Subscription", systemImage: "calendar")
                includedFeature("Permanent lifetime unlock", systemImage: "infinity")
                includedFeature("Apple Family Sharing", systemImage: "person.3")
                Text("AI provider usage and charges are separate from Termind Pro.")
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

    private var expirationLabel: LocalizedStringKey? {
        switch app.proAccess.status {
        case .subscription(let subscription):
            switch subscription.phase {
            case .introductoryTrial: "Trial Ends"
            case .subscribed: subscription.willAutoRenew == false ? "Access Ends" : "Renews"
            case .gracePeriod: "Grace Period Ends"
            case .billingRetry, .expired, .revoked: "Expired"
            }
        default:
            nil
        }
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
        case .subscription(let subscription): subscriptionStatusLabel(subscription)
        case .purchased(.purchased): Label("Lifetime", systemImage: "infinity")
        case .purchased(.familyShared): Label("Lifetime · Family Shared", systemImage: "person.3.fill")
        case .verificationFailed: Label("Verification Required", systemImage: "exclamationmark.shield")
        case .unrestrictedForTesting: Label("Development Access", systemImage: "hammer")
        }
    }

    @ViewBuilder
    private func subscriptionStatusLabel(_ subscription: ProSubscriptionStatus) -> some View {
        switch subscription.phase {
        case .introductoryTrial: Label("Free Trial", systemImage: "clock")
        case .subscribed:
            Label(
                subscription.ownership == .familyShared ? "Annual · Family Shared" : "Annual Subscription",
                systemImage: subscription.ownership == .familyShared ? "person.3.fill" : "checkmark.seal.fill")
        case .gracePeriod: Label("Billing Grace Period", systemImage: "clock.badge.exclamationmark")
        case .billingRetry: Label("Billing Issue", systemImage: "creditcard.trianglebadge.exclamationmark")
        case .expired: Label("Subscription Expired", systemImage: "calendar.badge.exclamationmark")
        case .revoked: Label("Subscription Revoked", systemImage: "xmark.seal")
        }
    }
}

private struct StartupSettings: View {
    @Environment(\.appearsActive) private var appearsActive
    @State private var loginItem = LoginItemController()
    @AppStorage(DesktopSettingsKey.openAtLoginQuietly) private var opensQuietly =
        DesktopSettingsKey.defaultOpenAtLoginQuietly

    var body: some View {
        Section("Startup") {
            Toggle(
                isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text("Open at Login")
                    Text(
                        "macOS opens Termind when you log in, which also starts the local MCP server if you have it enabled."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $opensQuietly) {
                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text("Open Hidden at Login")
                    Text("Termind opens behind your other windows. Click its icon in the Dock to show it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!loginItem.isEnabled)

            if loginItem.requiresApproval {
                LabeledContent {
                    Button("Open Login Items Settings") { loginItem.openSystemSettings() }
                } label: {
                    Text("macOS is waiting for you to allow Termind in Login Items.")
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

private struct SFTPSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.sftpGlobalTransferLimit) private var globalLimit = SettingsKey
        .defaultSFTPGlobalTransferLimit
    @AppStorage(SettingsKey.sftpPerHostTransferLimit) private var perHostLimit = SettingsKey
        .defaultSFTPPerHostTransferLimit

    var body: some View {
        Section("SFTP") {
            Stepper(value: $globalLimit, in: SettingsKey.sftpTransferLimitRange) {
                HStack {
                    Text("Concurrent Transfers")
                    Spacer()
                    Text(globalLimit, format: .number).monospacedDigit()
                }
            }
            Stepper(value: $perHostLimit, in: perHostRange) {
                HStack {
                    Text("Per-Host Transfers")
                    Spacer()
                    Text(perHostLimit, format: .number).monospacedDigit()
                }
            }
            Text(
                "Changes apply to queued transfers. Active transfers continue unchanged. Unsaved credentials limit a session to one transfer at a time."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { applyLimits() }
        .onChange(of: globalLimit) { applyLimits() }
        .onChange(of: perHostLimit) { applyLimits() }
    }

    private var perHostRange: ClosedRange<Int> {
        let minimum = SettingsKey.sftpTransferLimitRange.lowerBound
        return minimum...max(globalLimit, minimum)
    }

    private func applyLimits() {
        let normalizedGlobal = min(
            max(globalLimit, SettingsKey.sftpTransferLimitRange.lowerBound),
            SettingsKey.sftpTransferLimitRange.upperBound
        )
        if globalLimit != normalizedGlobal {
            globalLimit = normalizedGlobal
            return
        }
        let normalizedPerHost = min(
            max(perHostLimit, SettingsKey.sftpTransferLimitRange.lowerBound), normalizedGlobal)
        if perHostLimit != normalizedPerHost {
            perHostLimit = normalizedPerHost
            return
        }
        app.sftpTransfers.updateLimits(global: globalLimit, perHost: perHostLimit)
    }
}

private struct TerminalSettings: View {
    let editConfiguration: (TerminalCustomConfigurationScheme) -> Void
    @Environment(AppModel.self) private var app
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase
    private var darkTheme: String { app.terminalSettings.preferences.darkTheme }
    private var lightTheme: String { app.terminalSettings.preferences.lightTheme }
    private var darkCustomEnabled: Bool { app.terminalSettings.preferences.darkCustomEnabled }
    private var lightCustomEnabled: Bool { app.terminalSettings.preferences.lightCustomEnabled }

    private func binding<Value>(_ keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { app.terminalSettings.preferences[keyPath: keyPath] },
            set: { app.terminalSettings.set($0, for: keyPath) })
    }

    private var darkThemes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.allThemes.filter(\.isDark).sorted { $0.name < $1.name }
    }
    private var lightThemes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.allThemes.filter { !$0.isDark }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if let error = app.terminalSettings.storageError {
                Text(error).foregroundStyle(.orange)
            }
            Section("Light Configuration") {
                Picker("Theme", selection: binding(\.lightTheme)) {
                    ForEach(lightThemes) { Text($0.name).tag($0.name) }
                }
                .disabled(lightCustomEnabled)
                Toggle("Custom Configuration", isOn: binding(\.lightCustomEnabled))
                FormNavigationAction(title: "Edit Custom Configuration") {
                    editConfiguration(.light)
                }
            }
            Section("Dark Configuration") {
                Picker("Theme", selection: binding(\.darkTheme)) { ForEach(darkThemes) { Text($0.name).tag($0.name) } }
                    .disabled(darkCustomEnabled)
                Toggle("Custom Configuration", isOn: binding(\.darkCustomEnabled))
                FormNavigationAction(title: "Edit Custom Configuration") {
                    editConfiguration(.dark)
                }
            }
            Section("Font Configuration") {
                TerminalFontPicker(family: $font.family, families: TerminalFontCatalog.shared.families)
                Toggle("Font Size Follows Theme", isOn: $font.sizeFollowsTheme)
                if !font.sizeFollowsTheme {
                    LabeledContent("Font Size") {
                        HStack {
                            Slider(value: $font.size, in: 9...24, step: 1)
                            Text(font.size, format: .number.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 24, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Mouse") {
                Toggle(isOn: binding(\.copyOnSelect)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text("Copy on Selection")
                        Text("Copies selected terminal text to the clipboard when you release the mouse button.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: binding(\.pasteOnRightClick)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text("Paste on Right-Click")
                        Text(
                            "Right-click to paste. Hold Option to keep the usual right-click behavior. Applications that capture the mouse keep their mouse controls."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Integration") {
                Toggle(isOn: binding(\.shellIntegration)) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                        Text("Shell Integration")
                        Text(
                            "Keeps the remote working directory current, records confirmed commands, and provides detected distribution, kernel, and architecture details to AI features."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: binding(\.remoteWindowTitleInMenuBar)) {
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
            TerminalFontCatalog.shared.refresh()
            if TermindTerminalThemeCatalog.darkTheme(named: darkTheme) == nil {
                app.terminalSettings.set(SettingsKey.defaultTerminalThemeDark, for: \.darkTheme)
            }
            if TermindTerminalThemeCatalog.lightTheme(named: lightTheme) == nil {
                app.terminalSettings.set(SettingsKey.defaultTerminalThemeLight, for: \.lightTheme)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { TerminalFontCatalog.shared.refresh() }
        }
    }
}
