import SwiftUI
import TermindDomain
import UIKit

struct MobileSFTPHistoryView: View {
    let workspace: MobileWorkspace
    let open: (SFTPHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var clearing = false

    private var entries: [SFTPHistoryEntry] {
        _ = workspace.sftpHistory.revision
        return workspace.sftpHistory.entries(for: workspace.descriptor.hostID, matching: query)
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "No History", systemImage: "clock.arrow.circlepath",
                            description: Text("Folders you visit and files you open appear here.")
                        )
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List(entries) { entry in
                        Button {
                            reopen(entry)
                        } label: {
                            historyRow(entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") {
                                reopen(entry)
                            }
                            .disabled(!workspace.connected)
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                workspace.sftpHistory.delete(entry.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                workspace.sftpHistory.delete(entry.id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                if let error = workspace.sftpHistory.storageError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .searchable(text: $query, prompt: "Search History")
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "trash", role: .destructive) { clearing = true }
                        .labelStyle(.iconOnly)
                        .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog(
                "Clear File History for this Host?", isPresented: $clearing,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    workspace.sftpHistory.clear(for: workspace.descriptor.hostID)
                }
            }
        }
        .mobileSheetPresentation(compact: true)
    }

    private func historyRow(_ entry: SFTPHistoryEntry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind == .directory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .contentShape(.rect)
        .accessibilityHint(entry.kind == .directory ? Text("Open") : Text("Download"))
    }

    private func reopen(_ entry: SFTPHistoryEntry) {
        guard workspace.connected else { return }
        dismiss()
        open(entry)
    }
}
