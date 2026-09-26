import QuickLook
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

struct MobileTransfersView: View {
    let transfers: SFTPTransferCoordinator
    let hosts: HostLibraryModel
    @State private var previewURL: URL?
    @State private var confirmsClearFinished = false

    private var items: [SFTPTransfer] {
        transfers.sftpTransfers.sorted { $0.queuedAt > $1.queuedAt }
    }

    private var hasFinished: Bool {
        items.contains { $0.state.isFinished }
    }

    var body: some View {
        MobileCardPage {
            if items.isEmpty {
                ContentUnavailableView(AppStrings.SFTP.noTransfers.swiftUIKey, systemImage: "arrow.up.arrow.down")
            }
            MobileCardGrid {
                ForEach(items) { transfer in
                    transferItem(transfer)
                }
            }
        }
        .navigationTitle(AppStrings.SFTP.transfers.swiftUIKey)
        .quickLookPreview($previewURL)
        .toolbar {
            if hasFinished {
                Button(AppStrings.SFTP.clearFinished.swiftUIKey, systemImage: "trash") { confirmsClearFinished = true }
                    .labelStyle(.iconOnly)
            }
        }
        .confirmationDialog(
            AppStrings.SFTP.clearFinishedTransfersConfirmation, isPresented: $confirmsClearFinished,
            titleVisibility: .visible
        ) {
            Button(AppStrings.SFTP.clearFinished.swiftUIKey, role: .destructive) { transfers.clearFinished() }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        }
    }

    @ViewBuilder
    private func transferItem(_ transfer: SFTPTransfer) -> some View {
        if openableURL(for: transfer) != nil || transfers.canPause(transfer.id) || transfer.state == .paused {
            MobileActionCard(
                action: { performDefaultAction(for: transfer.id) },
                content: { transferCard(transfer) },
                actions: { transferActions(for: transfer) }
            )
        } else {
            MobileCard { transferCard(transfer) }
                .contextMenu { transferActions(for: transfer) }
        }
    }

    private func transferCard(_ transfer: SFTPTransfer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIcon(symbol: transfer.direction.symbol, tint: tint(for: transfer))
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.fileName).font(.headline).lineLimit(1)
                    Text(transfer.statusLabel).font(.caption).foregroundStyle(tint(for: transfer))
                }
            }

            Text(transfer.routeLabel { hosts.host($0)?.name })
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)

            if transfer.state.isActive {
                ProgressView(value: transfer.byteCount > 0 ? transfer.progress : nil)
            }
            Text(transfer.progressDetail ?? DataSizeFormat.bytes(transfer.byteCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(detailTint(for: transfer))
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func transferActions(for transfer: SFTPTransfer) -> some View {
        if let url = openableURL(for: transfer) {
            Button(AppStrings.Common.open.swiftUIKey, systemImage: "eye") { previewURL = url }
            ShareLink(item: url) {
                Label(AppStrings.Common.share.swiftUIKey, systemImage: "square.and.arrow.up")
            }
            Divider()
        }
        if transfers.canPause(transfer.id) {
            Button(AppStrings.Metrics.pause.swiftUIKey, systemImage: "pause.circle") {
                transfers.pause(transfer.id)
            }
        } else if transfer.state == .paused {
            Button(AppStrings.Metrics.resume.swiftUIKey, systemImage: "play.circle") {
                transfers.resume(transfer.id)
            }
        }
        if transfer.state.isFinished {
            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                transfers.removeFinished(transfer.id)
            }
        } else {
            Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark.circle.fill") {
                transfers.cancel(transfer.id)
            }
        }
    }

    private func openableURL(for transfer: SFTPTransfer) -> URL? {
        guard transfer.direction == .download, transfer.state == .completed else { return nil }
        let url = URL(fileURLWithPath: transfer.localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func performDefaultAction(for id: SFTPTransfer.ID) {
        guard let transfer = transfers.sftpTransfers.first(where: { $0.id == id }) else { return }
        if let url = openableURL(for: transfer) {
            previewURL = url
        } else if transfers.canPause(id) {
            transfers.pause(id)
        } else if transfer.state == .paused {
            transfers.resume(id)
        }
    }

    private func tint(for transfer: SFTPTransfer) -> Color {
        switch transfer.state {
        case .failed: .red
        case .cancelled: .secondary
        case .completed: .green
        case .queued, .running, .paused: .accentColor
        }
    }

    private func detailTint(for transfer: SFTPTransfer) -> Color {
        if case .failed = transfer.state { return .red }
        return .secondary
    }
}
