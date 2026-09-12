import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

struct MobileCommandHistoryView: View {
    let workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var clearing = false

    private var entries: [CommandHistoryEntry] {
        _ = workspace.commandHistory.revision
        return workspace.commandHistory.entries(for: workspace.descriptor.hostID, matching: query)
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No History", systemImage: "clock.arrow.circlepath")
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
                            Button("Copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = entry.command
                            }
                            Button("Insert", systemImage: "text.insert") { insert(entry) }
                                .disabled(!workspace.connected)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                workspace.commandHistory.delete(entry.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
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
            .searchable(text: $query)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "trash", role: .destructive) { clearing = true }.labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("Clear History?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { workspace.commandHistory.clear(for: workspace.descriptor.hostID) }
            }
        }.mobileSheetPresentation(compact: true)
            .onDisappear { workspace.terminal.requestFocus() }
    }

    private func historyRow(_ entry: CommandHistoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.command)
                    .font(.body.monospaced())
                    .lineLimit(2)
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
}
