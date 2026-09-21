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
    private let snippets: [Snippet]
    private let snippetPackagePath: (SnippetPackage.ID?) -> String?

    public init(
        sftpInitialPath: Binding<String>,
        startupSnippetID: Binding<Snippet.ID?> = .constant(nil),
        snippets: [Snippet] = [],
        snippetPackagePath: @escaping (SnippetPackage.ID?) -> String? = { _ in nil }
    ) {
        _sftpInitialPath = sftpInitialPath
        _startupSnippetID = startupSnippetID
        self.snippets = snippets
        self.snippetPackagePath = snippetPackagePath
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
    }

    private func snippetLabel(_ snippet: Snippet) -> String {
        guard let path = snippetPackagePath(snippet.packageID), !path.isEmpty else {
            return snippet.title
        }
        return "\(path) / \(snippet.title)"
    }
}
