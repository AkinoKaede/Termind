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

    private var items: [SFTPTransfer] {
        transfers.sftpTransfers.sorted { $0.queuedAt > $1.queuedAt }
    }

    private var hasFinished: Bool {
        items.contains {
            switch $0.state {
            case .completed, .cancelled, .failed: true
            case .queued, .running, .paused: false
            }
        }
    }

    var body: some View {
        MobileCardPage {
            if items.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down")
            }
            MobileCardGrid {
                ForEach(items) { transfer in
                    MobileCard { transferCard(transfer) }
                }
            }
        }
        .navigationTitle("Transfers")
        .quickLookPreview($previewURL)
        .toolbar {
            if hasFinished {
                Button("Clear Finished", systemImage: "trash") { transfers.clearFinished() }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private func transferCard(_ transfer: SFTPTransfer) -> some View {
        let active = transfer.state == .queued || transfer.state == .running
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MobileCardIcon(symbol: transfer.direction.symbol, tint: tint(for: transfer))
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.fileName).font(.headline).lineLimit(1)
                    Text(status(for: transfer)).font(.caption).foregroundStyle(tint(for: transfer))
                }
                Spacer(minLength: 8)
                if transfers.canPause(transfer.id) {
                    Button("Pause transfer", systemImage: "pause.circle") { transfers.pause(transfer.id) }
                        .labelStyle(.iconOnly).font(.title3)
                } else if transfer.state == .paused {
                    Button("Resume transfer", systemImage: "play.circle") { transfers.resume(transfer.id) }
                        .labelStyle(.iconOnly).font(.title3)
                }
                if active || transfer.state == .paused {
                    Button("Cancel transfer", systemImage: "xmark.circle.fill") {
                        transfers.cancel(transfer.id)
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                }
            }

            Text(route(for: transfer))
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)

            if active {
                ProgressView(value: transfer.byteCount > 0 ? transfer.progress : nil)
            }
            Text(detail(for: transfer))
                .font(.caption.monospacedDigit())
                .foregroundStyle(detailTint(for: transfer))
                .lineLimit(2)

            if transfer.direction == .download, transfer.state == .completed {
                let url = URL(fileURLWithPath: transfer.localPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    HStack {
                        Button("Open", systemImage: "eye") { previewURL = url }
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func status(for transfer: SFTPTransfer) -> String {
        switch (transfer.direction, transfer.state) {
        case (.upload, .queued): String(localized: "Upload Queued")
        case (.upload, .running): String(localized: "Uploading")
        case (.upload, .paused): String(localized: "Upload Paused")
        case (.upload, .completed): String(localized: "Uploaded")
        case (.upload, .cancelled): String(localized: "Upload Cancelled")
        case (.upload, .failed): String(localized: "Upload Failed")
        case (.download, .queued): String(localized: "Download Queued")
        case (.download, .running): String(localized: "Downloading")
        case (.download, .paused): String(localized: "Download Paused")
        case (.download, .completed): String(localized: "Downloaded")
        case (.download, .cancelled): String(localized: "Download Cancelled")
        case (.download, .failed): String(localized: "Download Failed")
        case (.copy, .queued): String(localized: "Copy Queued")
        case (.copy, .running): String(localized: "Copying")
        case (.copy, .paused): String(localized: "Copy Paused")
        case (.copy, .completed): String(localized: "Copied")
        case (.copy, .cancelled): String(localized: "Copy Cancelled")
        case (.copy, .failed): String(localized: "Copy Failed")
        }
    }

    private func detail(for transfer: SFTPTransfer) -> String {
        if case .failed(let reason) = transfer.state { return reason }
        if transfer.bytesPerSecond > 0 { return DataSizeFormat.rate(transfer.bytesPerSecond) }
        if transfer.byteCount > 0 {
            return "\(DataSizeFormat.bytes(transfer.transferredBytes)) of \(DataSizeFormat.bytes(transfer.byteCount))"
        }
        return DataSizeFormat.bytes(transfer.byteCount)
    }

    private func route(for transfer: SFTPTransfer) -> String {
        func remote(_ hostID: Host.ID?, _ path: String) -> String {
            guard let hostID, let host = hosts.host(hostID) else { return path }
            return "\(host.name) · \(path)"
        }
        switch transfer.direction {
        case .upload:
            return "\(transfer.localPath) → \(remote(transfer.destinationHostID, transfer.remotePath))"
        case .download:
            return "\(remote(transfer.sourceHostID, transfer.remotePath)) → \(transfer.localPath)"
        case .copy:
            return
                "\(remote(transfer.sourceHostID, transfer.localPath)) → \(remote(transfer.destinationHostID, transfer.remotePath))"
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
