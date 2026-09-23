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
    @State private var clearing = false
    @State private var snippetEntry: CommandHistoryEntry?
    @State private var snippetName = ""

    private var entries: [CommandHistoryEntry] {
        _ = workspace.commandHistory.revision
        return MobileHistoryPresentation.limited(
            workspace.commandHistory.entries(for: workspace.descriptor.hostID, matching: query)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(
                            TermindCopy.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath")
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
                            Button(TermindCopy.Common.copy.swiftUIKey, systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = entry.command
                            }
                            Button(TermindCopy.Common.insert.swiftUIKey, systemImage: "text.insert") { insert(entry) }
                                .disabled(!workspace.connected)
                            Button(TermindCopy.Snippets.saveAsSnippet.swiftUIKey, systemImage: "curlybraces") {
                                beginSavingSnippet(entry)
                            }
                            Divider()
                            Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                workspace.commandHistory.delete(entry.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                workspace.commandHistory.delete(entry.id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if let error = workspace.commandHistory.storageError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .searchable(text: $query.singleLineText)
            .navigationTitle(TermindCopy.Common.history.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TermindCopy.Common.done.swiftUIKey, systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(TermindCopy.Common.clear.swiftUIKey, systemImage: "trash", role: .destructive) {
                        clearing = true
                    }.labelStyle(.iconOnly)
                }
            }
            .confirmationDialog(
                TermindCopy.Terminal.clearHistoryConfirmation.swiftUIKey, isPresented: $clearing,
                titleVisibility: .visible
            ) {
                Button(TermindCopy.Common.clear.swiftUIKey, role: .destructive) {
                    workspace.commandHistory.clear(for: workspace.descriptor.hostID)
                }
            }
            .alert(
                TermindCopy.Snippets.saveAsSnippet.swiftUIKey,
                isPresented: Binding(
                    get: { snippetEntry != nil },
                    set: { if !$0 { cancelSavingSnippet() } }
                )
            ) {
                TextField(
                    TermindCopy.Snippets.snippetName.swiftUIKey, text: $snippetName.singleLineText, axis: .horizontal
                )
                .singleLinePaste()
                .lineLimit(1)
                Button(TermindCopy.Common.cancel.swiftUIKey, role: .cancel, action: cancelSavingSnippet)
                Button(TermindCopy.Common.save.swiftUIKey, action: saveSnippet)
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
                Text(CommandHistoryPresentation.subtitle(for: entry, locale: locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
