import SwiftUI
import TermindApplication
import TermindDomain
import UIKit

struct MobileTerminalSnippetsView: View {
    let library: HostLibraryModel
    let workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var snippets: [Snippet] { library.searchSnippets(query) }

    var body: some View {
        NavigationStack {
            Group {
                if snippets.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No Snippets", systemImage: "curlybraces")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    MobileNativeList(
                        items: snippets,
                        estimatedRowHeight: 76,
                        refreshID: workspace.connected,
                        onSelect: insert
                    ) { snippet in
                        snippetRow(snippet)
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Snippets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
        .mobileSheetPresentation(compact: true)
        .onDisappear { workspace.terminal.requestFocus() }
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(snippet.title).font(.body.weight(.medium)).lineLimit(1)
            Text(snippet.body)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = snippet.body }
            Button("Insert", systemImage: "text.insert") { insert(snippet) }
                .disabled(!workspace.connected)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func insert(_ snippet: Snippet) {
        guard workspace.connected else { return }
        dismiss()
        workspace.insertTerminalText(snippet.body)
    }
}
