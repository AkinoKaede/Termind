import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

struct MobileSFTPHistoryView: View {
    let workspace: MobileWorkspace
    let open: (SFTPHistoryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var entries: [SFTPHistoryEntry] {
        _ = workspace.sftpHistory.revision
        return MobileHistoryPresentation.limited(
            workspace.sftpHistory.entries(matching: query)
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
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .searchable(text: $query.singleLineText, prompt: AppStrings.Common.searchHistory.swiftUIKey)
            .navigationTitle(AppStrings.Common.history.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.done.swiftUIKey, systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
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
