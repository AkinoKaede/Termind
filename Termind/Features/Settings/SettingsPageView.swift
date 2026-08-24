import GhosttyTheme
import SwiftUI

/// Preferences: things that change how Termind behaves.
///
/// The content of the app's singleton native macOS Settings window. ⌘, is
/// provided by SwiftUI's Settings scene and never adds a top-level app tab.
///
/// One scrolling form rather than the four-tab `TabView` Apple's settings windows
/// use: tabs exist to keep a fixed-size window small, and this page has the whole
/// detail column. Everything is visible to one scroll and to ⌘F.
///
/// Keys are not here. A key is *content* — you add them, name them, delete them,
/// and look one up when a connection is refused — and content belongs on a page
/// you can leave open next to a terminal. See `KeychainPageView`.
struct SettingsPageView: View {
    var body: some View {
        Form {
            AppSettings()
            StartupSettings()
            SidebarSettings()
            TerminalSettings()
            SFTPSettings()
            // The AI block is three sections rather than one, and each lives in
            // its own file: providers are content you add and delete, roles are
            // a preference over that content, and MCP servers are a third thing
            // again. One `AISettings` holding all of it was already the longest
            // view in this file while it was still a stub.
            ModelProviderSettings()
            ModelRoleSettings()
            MCPSettings()
            CommandExecutionSettings()
            SyncSettings()
        }
        .formStyle(.grouped)
        // A reading width, centred. A `Form` stretched across an external display
        // puts every label and its control at opposite ends of the desk.
        .frame(maxWidth: Metrics.SettingsPage.width)
        .frame(maxWidth: .infinity)
        .background(.background)
    }
}

private struct SFTPSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SettingsKey.sftpGlobalTransferLimit) private var globalLimit =
        SettingsKey.defaultSFTPGlobalTransferLimit
    @AppStorage(SettingsKey.sftpPerHostTransferLimit) private var perHostLimit =
        SettingsKey.defaultSFTPPerHostTransferLimit

    var body: some View {
        Section("SFTP") {
            Stepper(value: $globalLimit, in: 1...8) {
                HStack {
                    Text("Concurrent transfers")
                    Spacer()
                    TextField("Global concurrent transfers", value: $globalLimit, format: .number)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 32)
                }
            }
            Stepper(value: $perHostLimit, in: 1...max(globalLimit, 1)) {
                HStack {
                    Text("Per-host transfers")
                    Spacer()
                    TextField(
                        "Concurrent transfers per host",
                        value: $perHostLimit,
                        format: .number
                    )
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 32)
                }
            }
            Text(
                "Changes apply to queued transfers. Active transfers continue unchanged. Unsaved credentials limit a session to one transfer at a time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { applyLimits() }
        .onChange(of: globalLimit) {
            applyLimits()
        }
        .onChange(of: perHostLimit) { applyLimits() }
    }

    private func applyLimits() {
        let normalizedGlobal = min(max(globalLimit, 1), 8)
        if globalLimit != normalizedGlobal {
            globalLimit = normalizedGlobal
            return
        }
        let normalizedPerHost = min(max(perHostLimit, 1), normalizedGlobal)
        if perHostLimit != normalizedPerHost {
            perHostLimit = normalizedPerHost
            return
        }
        app.sftpTransfers.updateLimits(global: globalLimit, perHost: perHostLimit)
    }
}

/// Each group is a `View` returning `Section`s rather than a whole `Form`, so the
/// settings compose into one scroll instead of several nested forms.
private struct AppSettings: View {
    var body: some View {
        Section("App") {
            LabeledContent("Version") {
                Text(Bundle.termindDisplayVersion)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct StartupSettings: View {
    @AppStorage(SettingsKey.restoreTabs) private var restoreTabs = true

    var body: some View {
        Section("Startup") {
            Toggle("Restore tabs from last session", isOn: $restoreTabs)
        }
    }
}

private struct SidebarSettings: View {
    @AppStorage(SettingsKey.compactSidebar) private var compactSidebar = false
    @AppStorage(SettingsKey.showRecents) private var showRecents = true

    var body: some View {
        Section("Sidebar") {
            Toggle("Compact rows", isOn: $compactSidebar)
            Toggle("Show recents", isOn: $showRecents)
        }
    }
}

private struct TerminalSettings: View {
    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = 12.0
    @AppStorage(SettingsKey.terminalFontFollowTheme) private var fontFollowTheme = true
    @AppStorage(SettingsKey.shellIntegration) private var shellIntegration = true
    @AppStorage(SettingsKey.terminalThemeDark) private var darkTheme =
        SettingsKey.defaultTerminalThemeDark
    @AppStorage(SettingsKey.terminalThemeLight) private var lightTheme =
        SettingsKey.defaultTerminalThemeLight
    @AppStorage(SettingsKey.terminalCustomConfigurationDarkEnabled)
    private var darkCustomEnabled = false
    @AppStorage(SettingsKey.terminalCustomConfigurationLightEnabled)
    private var lightCustomEnabled = false

    @State private var editingCustomConfiguration: TerminalCustomConfigurationScheme?

    private var darkThemes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.allThemes.filter(\.isDark).sorted { $0.name < $1.name }
    }

    private var lightThemes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.allThemes.filter { !$0.isDark }.sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            Section("Light Configuration") {
                Picker("Theme", selection: $lightTheme) {
                    ForEach(lightThemes) { Text($0.name).tag($0.name) }
                }
                .disabled(lightCustomEnabled)
                Toggle("Custom Configuration", isOn: $lightCustomEnabled)
                if lightCustomEnabled {
                    Button("Edit Custom Configuration") {
                        editingCustomConfiguration = .light
                    }
                }
            }

            Section("Dark Configuration") {
                Picker("Theme", selection: $darkTheme) {
                    ForEach(darkThemes) { Text($0.name).tag($0.name) }
                }
                .disabled(darkCustomEnabled)
                Toggle("Custom Configuration", isOn: $darkCustomEnabled)
                if darkCustomEnabled {
                    Button("Edit Custom Configuration") {
                        editingCustomConfiguration = .dark
                    }
                }
            }

            Section("Font Configuration") {
                Toggle("Follow Theme", isOn: $fontFollowTheme)
                if !fontFollowTheme {
                    LabeledContent("Font size") {
                        HStack {
                            Slider(value: $fontSize, in: 9...24, step: 1)
                            Text(fontSize, format: .number.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }
            }

            Section("Terminal") {
                Toggle("Shell integration", isOn: $shellIntegration)
                Text(
                    "Keeps the remote working directory current in the status bar and assistant context."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $editingCustomConfiguration) { scheme in
            TerminalCustomConfigurationEditorSheet(scheme: scheme)
        }
        .onAppear {
            // `@AppStorage` defaults cover missing values. Repair stale or
            // removed names as well so the picker never opens with no row
            // selected, while preserving every valid choice the user made.
            if TermindTerminalThemeCatalog.darkTheme(named: darkTheme) == nil {
                darkTheme = SettingsKey.defaultTerminalThemeDark
            }
            if TermindTerminalThemeCatalog.lightTheme(named: lightTheme) == nil {
                lightTheme = SettingsKey.defaultTerminalThemeLight
            }
        }
    }
}

/// The AI preferences that are about *behaviour* rather than about which
/// endpoint to call, which is why they stayed here when the provider, model and
/// MCP sections moved into files of their own.
///
/// Approve for Me is deliberately *not* here. It is a stance you take on one
/// conversation — this thread may run things, that one may not — so it belongs
/// on the Chat page next to the thread it governs, not in a preference that
/// silently applies to every session at once.
private struct CommandExecutionSettings: View {
    @AppStorage(SettingsKey.allowOneClickSafeCommands) private var allowOneClickSafe = false

    var body: some View {
        Section("Commands") {
            Toggle("Run read-only suggestions with ⏎", isOn: $allowOneClickSafe)
            Text(
                "Commands that write, delete, or escalate still require a click. Destructive commands also require confirmation."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SyncSettings: View {
    var body: some View {
        Section("iCloud") {
            LabeledContent("Status") { Text("Off") }
            Text(
                "iCloud sync is not available yet. Private keys and passwords remain in the Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
