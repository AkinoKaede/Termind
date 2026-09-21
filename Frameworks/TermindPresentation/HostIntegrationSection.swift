import SwiftUI
import TermindDomain

public struct HostIntegrationSection: View {
    @Binding private var mode: HostShellIntegrationMode
    @Binding private var startupSnippetID: Snippet.ID?
    private let snippets: [Snippet]
    private let snippetPackagePath: (SnippetPackage.ID?) -> String?

    public init(
        mode: Binding<HostShellIntegrationMode>,
        startupSnippetID: Binding<Snippet.ID?> = .constant(nil),
        snippets: [Snippet] = [],
        snippetPackagePath: @escaping (SnippetPackage.ID?) -> String? = { _ in nil }
    ) {
        _mode = mode
        _startupSnippetID = startupSnippetID
        self.snippets = snippets
        self.snippetPackagePath = snippetPackagePath
    }

    public var body: some View {
        Section("Integration") {
            Picker("Shell Integration", selection: $mode) {
                Text("Default").tag(HostShellIntegrationMode.followGlobalSettings)
                Text("Enable").tag(HostShellIntegrationMode.enabled)
                Text("Disable").tag(HostShellIntegrationMode.disabled)
            }
            .pickerStyle(.menu)
            .menuOrder(.fixed)

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
