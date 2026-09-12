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
                    List(snippets) { snippet in
                        Button {
                            insert(snippet)
                        } label: {
                            snippetRow(snippet)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = snippet.body
                            }
                            Button("Insert", systemImage: "text.insert") { insert(snippet) }
                                .disabled(!workspace.connected)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(snippet.title).font(.body).lineLimit(1)
                Text(snippet.body)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            MobileTerminalRiskIndicator(assessment: CommandRiskClassifier.assess(snippet.body))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func insert(_ snippet: Snippet) {
        guard workspace.connected else { return }
        dismiss()
        workspace.insertTerminalText(snippet.body)
    }
}
