import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

struct MobileSFTPHistoryView: View {
    let workspace: MobileWorkspace
    let open: (SFTPHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var clearing = false

    private var entries: [SFTPHistoryEntry] {
        _ = workspace.sftpHistory.revision
        return MobileHistoryPresentation.limited(
            workspace.sftpHistory.entries(for: workspace.descriptor.hostID, matching: query)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(
                            AppStrings.Common.noHistory.swiftUIKey, systemImage: "clock.arrow.circlepath",
                            description: Text(AppStrings.SFTP.foldersYouVisitAndFilesYouOpenAppearHere)
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
                            Button(AppStrings.Common.open.swiftUIKey, systemImage: "arrow.up.forward.app") {
                                reopen(entry)
                            }
                            .disabled(!workspace.connected)
                            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                workspace.sftpHistory.delete(entry.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
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
            .searchable(text: $query.singleLineText, prompt: AppStrings.Common.searchHistory.swiftUIKey)
            .navigationTitle(AppStrings.Common.history.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.done.swiftUIKey, systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(AppStrings.Common.clear.swiftUIKey, systemImage: "trash", role: .destructive) {
                        clearing = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(entries.isEmpty)
                }
            }
            .confirmationDialog(
                AppStrings.SFTP.clearFileHistoryForThisHostConfirmation.swiftUIKey, isPresented: $clearing,
                titleVisibility: .visible
            ) {
                Button(AppStrings.Common.clearHistory.swiftUIKey, role: .destructive) {
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
        .accessibilityHint(entry.kind == .directory ? Text(AppStrings.Common.open) : Text(AppStrings.SFTP.download))
    }

    private func reopen(_ entry: SFTPHistoryEntry) {
        guard workspace.connected else { return }
        dismiss()
        open(entry)
    }
}
