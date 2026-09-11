import SwiftUI
import TermindDomain
import TermindRemoteInfrastructure

struct MobileTransfersView: View {
    let transfers: SFTPTransferCoordinator

    var body: some View {
        MobileCardPage {
            if transfers.sftpTransfers.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down")
            }
            MobileCardGrid {
                ForEach(transfers.sftpTransfers) { transfer in
                    MobileCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(transfer.fileName, systemImage: transfer.direction.symbol).font(.headline)
                            Text(transfer.remotePath).font(.caption.monospaced()).lineLimit(2)
                                .truncationMode(.middle).foregroundStyle(.secondary)
                            Text(transfer.state.label).font(.caption)
                            if transfer.state == .queued || transfer.state == .running {
                                ProgressView(value: transfer.byteCount > 0 ? transfer.progress : nil)
                                Button("Cancel", systemImage: "xmark") { transfers.cancel(transfer.id) }.frame(
                                    minHeight: 44)
                            }
                            if transfer.direction == .download && transfer.state == .completed {
                                ShareLink(item: URL(fileURLWithPath: transfer.localPath)) {
                                    Label("Save or Share", systemImage: "square.and.arrow.up")
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Transfers")
        .toolbar { Button("Clear Finished", systemImage: "trash") { transfers.clearFinished() }.labelStyle(.iconOnly) }
    }
}
