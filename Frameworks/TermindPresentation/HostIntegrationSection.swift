import SwiftUI
import TermindDomain

public struct HostSessionPersistenceSection: View {
    @Binding private var preferences: SessionPersistencePreferences

    public init(preferences: Binding<SessionPersistencePreferences>) { _preferences = preferences }

    public var body: some View {
        Section(AppStrings.SessionPersistence.section.swiftUIKey) {
            Toggle(isOn: $preferences.enabled) { Text(AppStrings.Common.enabled) }
            Picker(AppStrings.SessionPersistence.backend.swiftUIKey, selection: $preferences.backend) {
                ForEach(SessionPersistenceBackendID.supported, id: \.self) { backend in
                    Text(verbatim: backend == .herdr ? "Herdr" : backend == .zellij ? "Zellij" : backend.rawValue)
                        .tag(backend)
                }
                if !SessionPersistenceBackendID.supported.contains(preferences.backend) {
                    Text(verbatim: preferences.backend.rawValue).tag(preferences.backend)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            .disabled(!preferences.enabled)
            Picker(AppStrings.SessionPersistence.onConnect.swiftUIKey, selection: $preferences.onConnect) {
                Text(AppStrings.SessionPersistence.ask).tag(SessionPersistencePreferences.OnConnect.ask)
                Text(AppStrings.SessionPersistence.create).tag(SessionPersistencePreferences.OnConnect.createManaged)
                Text(AppStrings.SessionPersistence.normalShell).tag(SessionPersistencePreferences.OnConnect.plainShell)
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            .disabled(!preferences.enabled)
        }
    }
}

public struct HostIntegrationSection: View {
    @Binding private var mode: HostShellIntegrationMode

    public init(mode: Binding<HostShellIntegrationMode>) { _mode = mode }

    public var body: some View {
        Section(AppStrings.Settings.integration.swiftUIKey) {
            Picker(AppStrings.Settings.shellIntegration.swiftUIKey, selection: $mode) {
                Text("Default").tag(HostShellIntegrationMode.followGlobalSettings)
                Text(AppStrings.Settings.enable).tag(HostShellIntegrationMode.enabled)
                Text("Disable").tag(HostShellIntegrationMode.disabled)
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        }
    }
}

public struct HostSessionSection: View {
    @Binding private var charset: RemoteCharset
    @Binding private var sftpInitialPath: String
    @Binding private var agentForwardingEnabled: Bool
    @Binding private var sessionPersistence: SessionPersistencePreferences
    @Binding private var startupSnippetID: Snippet.ID?
    @Binding private var environmentVariables: [HostEnvironmentVariable]
    private let allowsAgentForwarding: Bool
    private let snippets: [Snippet]
    private let snippetPackagePath: (SnippetPackage.ID?) -> String?
    private let editEnvironmentVariable: (Int?) -> Void

    public init(
        charset: Binding<RemoteCharset>,
        sftpInitialPath: Binding<String>,
        startupSnippetID: Binding<Snippet.ID?> = .constant(nil),
        agentForwardingEnabled: Binding<Bool> = .constant(false),
        sessionPersistence: Binding<SessionPersistencePreferences> = .constant(.init()),
        allowsAgentForwarding: Bool = true,
        environmentVariables: Binding<[HostEnvironmentVariable]> = .constant([]),
        snippets: [Snippet] = [],
        snippetPackagePath: @escaping (SnippetPackage.ID?) -> String? = { _ in nil },
        editEnvironmentVariable: @escaping (Int?) -> Void = { _ in }
    ) {
        _charset = charset
        _sftpInitialPath = sftpInitialPath
        _startupSnippetID = startupSnippetID
        self.allowsAgentForwarding = allowsAgentForwarding
        _agentForwardingEnabled = agentForwardingEnabled
        _sessionPersistence = sessionPersistence
        _environmentVariables = environmentVariables
        self.snippets = snippets
        self.snippetPackagePath = snippetPackagePath
        self.editEnvironmentVariable = editEnvironmentVariable
    }

    public var body: some View {
        Section(AppStrings.Vault.session.swiftUIKey) {
            Picker(AppStrings.Vault.charset.swiftUIKey, selection: $charset) {
                ForEach(RemoteCharset.allCases) { charset in
                    Text(charset.displayName).tag(charset)
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            Picker("Startup Snippet", selection: $startupSnippetID) {
                Text(AppStrings.Common.none).tag(Snippet.ID?.none)
                if !snippets.isEmpty {
                    Divider()
                    ForEach(snippets) { snippet in
                        Text(snippetLabel(snippet)).tag(Snippet.ID?.some(snippet.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
            if allowsAgentForwarding {
                Toggle(isOn: $agentForwardingEnabled) { Text(AppStrings.Connections.agentForwarding) }
            }
            LabeledContent("SFTP Initial Path") {
                TextField("SFTP Initial Path", text: $sftpInitialPath.singleLineText, prompt: Text("~"))
                    .singleLinePaste()
                    .lineLimit(1)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
            }
        }

        HostSessionPersistenceSection(preferences: $sessionPersistence)

        Section("Environment Variables") {
            ForEach(environmentVariables.indices, id: \.self) { index in
                environmentVariableRow(at: index)
            }

            Button {
                editEnvironmentVariable(nil)
            } label: {
                HStack(spacing: 8) {
                    Text("Add Environment Variable")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func environmentVariableRow(at index: Int) -> some View {
        #if os(iOS)
            Button {
                editEnvironmentVariable(index)
            } label: {
                environmentVariableLabel(at: index)
            }
            .buttonStyle(.plain)
            .swipeActions {
                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                    environmentVariables.remove(at: index)
                }
            }
        #else
            HStack(spacing: 8) {
                Button {
                    editEnvironmentVariable(index)
                } label: {
                    environmentVariableLabel(at: index)
                }
                .buttonStyle(.plain)
                Button(AppStrings.Common.delete.swiftUIKey, systemImage: "xmark", role: .destructive) {
                    environmentVariables.remove(at: index)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        #endif
    }

    private func environmentVariableLabel(at index: Int) -> some View {
        Text("\(environmentVariables[index].variable)=\(environmentVariables[index].value)")
            .font(.body.monospaced())
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func snippetLabel(_ snippet: Snippet) -> String {
        guard let path = snippetPackagePath(snippet.packageID), !path.isEmpty else {
            return snippet.title
        }
        return "\(path) / \(snippet.title)"
    }
}
