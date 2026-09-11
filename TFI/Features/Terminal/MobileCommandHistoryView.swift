import SwiftUI
import TermindDomain
import UIKit

struct MobileCommandHistoryView: View {
    let workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
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
                    MobileNativeList(
                        items: entries,
                        estimatedRowHeight: 96,
                        refreshID: workspace.connected,
                        onDelete: { workspace.commandHistory.delete($0.id) }
                    ) { entry in
                        historyRow(entry)
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(entry.executedAt, format: .dateTime)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let code = entry.exitStatus {
                    LabeledContent("Exit Status", value: code.formatted())
                }
                if let duration = entry.duration {
                    Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.command }
            Button("Insert", systemImage: "text.insert") {
                dismiss()
                workspace.insertTerminalText(entry.command)
            }
            .disabled(!workspace.connected)
            Button("Delete", systemImage: "trash", role: .destructive) {
                workspace.commandHistory.delete(entry.id)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}
