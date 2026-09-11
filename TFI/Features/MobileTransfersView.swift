import SwiftUI
import TermindDomain
import TermindRemoteInfrastructure

struct MobileTransfersView: View {
    let transfers: SFTPTransferCoordinator

    var body: some View {
        List(transfers.sftpTransfers) { transfer in
            VStack(alignment: .leading, spacing: 8) {
                Label(transfer.fileName, systemImage: transfer.direction.symbol).font(.headline)
                Text(transfer.remotePath).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary)
                Text(transfer.state.label).font(.caption)
                if transfer.state == .queued || transfer.state == .running {
                    ProgressView(value: transfer.byteCount > 0 ? transfer.progress : nil)
                    Button("Cancel") { transfers.cancel(transfer.id) }
                }
                if transfer.direction == .download && transfer.state == .completed {
                    ShareLink("Save or Share", item: URL(fileURLWithPath: transfer.localPath))
                }
            }
        }
        .overlay {
            if transfers.sftpTransfers.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down")
            }
        }
        .navigationTitle("Transfers")
        .toolbar { Button("Clear Finished") { transfers.clearFinished() } }
    }
}
