import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import UIKit

nonisolated enum MobileCommandHistorySnippetFactory {
    static func make(name: String, command: String) -> Snippet? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Snippet(title: name, body: command)
    }
}

struct MobileCommandHistoryView: View {
    let library: HostLibraryModel
    let workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var snippetEntry: CommandHistoryEntry?
    @State private var snippetName = ""

    private var entries: [CommandHistoryEntry] {
        _ = workspace.commandHistory.revision
        return MobileHistoryPresentation.limited(
            workspace.commandHistory.entries(matching: query)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(
                            AppStrings.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath")
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List(entries) { entry in
                        Button {
                            insert(entry)
                        } label: {
                            historyRow(entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(AppStrings.Common.copy.swiftUIKey, systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = entry.command
                            }
                            Button(AppStrings.Common.insert.swiftUIKey, systemImage: "text.insert") { insert(entry) }
                                .disabled(!workspace.connected)
                            Button(AppStrings.Snippets.saveAsSnippet.swiftUIKey, systemImage: "curlybraces") {
                                beginSavingSnippet(entry)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .searchable(text: $query.singleLineText)
            .navigationTitle(AppStrings.Common.history.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.done.swiftUIKey, systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .alert(
                AppStrings.Snippets.saveAsSnippet,
                isPresented: Binding(
                    get: { snippetEntry != nil },
                    set: { if !$0 { cancelSavingSnippet() } }
                )
            ) {
                TextField(
                    AppStrings.Snippets.snippetName.swiftUIKey, text: $snippetName.singleLineText, axis: .horizontal
                )
                .singleLinePaste()
                .lineLimit(1)
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel, action: cancelSavingSnippet)
                Button(AppStrings.Common.save.swiftUIKey, action: saveSnippet)
                    .disabled(snippetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                if let snippetEntry {
                    Text(CommandHistoryPresentation.title(for: snippetEntry))
                }
            }
        }.mobileSheetPresentation(compact: true)
            .onDisappear { workspace.terminal.requestFocus() }
    }

    private func historyRow(_ entry: CommandHistoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(CommandHistoryPresentation.title(for: entry))
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .textSelection(.enabled)
                let subtitle = CommandHistoryPresentation.subtitle(for: entry, locale: locale)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            MobileTerminalRiskIndicator(assessment: CommandRiskClassifier.assess(entry.command))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func insert(_ entry: CommandHistoryEntry) {
        guard workspace.connected else { return }
        dismiss()
        workspace.insertTerminalText(entry.command)
    }

    private func beginSavingSnippet(_ entry: CommandHistoryEntry) {
        snippetName = ""
        snippetEntry = entry
    }

    private func cancelSavingSnippet() {
        snippetEntry = nil
        snippetName = ""
    }

    private func saveSnippet() {
        guard let snippetEntry,
            let snippet = MobileCommandHistorySnippetFactory.make(
                name: snippetName, command: snippetEntry.command
            )
        else { return }
        library.upsert(snippet)
        cancelSavingSnippet()
    }
}
