import SwiftUI
import TermindDomain

public struct HostIntegrationSection: View {
    @Binding private var mode: HostShellIntegrationMode

    public init(mode: Binding<HostShellIntegrationMode>) { _mode = mode }

    public var body: some View {
        Section("Integration") {
            Picker("Shell Integration", selection: $mode) {
                Text("Default").tag(HostShellIntegrationMode.followGlobalSettings)
                Text("Enable").tag(HostShellIntegrationMode.enabled)
                Text("Disable").tag(HostShellIntegrationMode.disabled)
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        }
    }
}

public struct HostSessionSection: View {
    @Binding private var sftpInitialPath: String
    @Binding private var startupSnippetID: Snippet.ID?
    @Binding private var environmentVariables: [HostEnvironmentVariable]
    private let snippets: [Snippet]
    private let snippetPackagePath: (SnippetPackage.ID?) -> String?
    private let editEnvironmentVariable: (Int?) -> Void

    public init(
        sftpInitialPath: Binding<String>,
        startupSnippetID: Binding<Snippet.ID?> = .constant(nil),
        environmentVariables: Binding<[HostEnvironmentVariable]> = .constant([]),
        snippets: [Snippet] = [],
        snippetPackagePath: @escaping (SnippetPackage.ID?) -> String? = { _ in nil },
        editEnvironmentVariable: @escaping (Int?) -> Void = { _ in }
    ) {
        _sftpInitialPath = sftpInitialPath
        _startupSnippetID = startupSnippetID
        _environmentVariables = environmentVariables
        self.snippets = snippets
        self.snippetPackagePath = snippetPackagePath
        self.editEnvironmentVariable = editEnvironmentVariable
    }

    public var body: some View {
        Section("Session") {
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
            Picker("Startup Snippet", selection: $startupSnippetID) {
                Text("None").tag(Snippet.ID?.none)
                if !snippets.isEmpty {
                    Divider()
                    ForEach(snippets) { snippet in
                        Text(snippetLabel(snippet)).tag(Snippet.ID?.some(snippet.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)
        }

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
                Button("Delete", role: .destructive) {
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
                Button("Delete", systemImage: "xmark", role: .destructive) {
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
