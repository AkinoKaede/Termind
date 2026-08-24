import SwiftUI

/// The one-line footer for focused-session context and app-wide transfers.
struct StatusBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    private var pane: Pane? { window.selectedTab?.focusedPane }
    private var showsSessionContext: Bool { pane?.kind.showsStatusBar == true }
    private var hasTransfers: Bool { !app.sftpTransfers.sftpTransfers.isEmpty }

    private var sshSession: SSHSessionModel? {
        guard case .sshSession(let sshSession)? = pane?.content else { return nil }
        return sshSession
    }

    private var sftpSession: SFTPSessionModel? { pane?.sftpSession }

    @ViewBuilder
    var body: some View {
        if showsSessionContext || hasTransfers {
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: Metrics.Space.l) {
            if showsSessionContext {
                connection

                if let sshSession, sshSession.status.isLive {
                    if let latency = sshSession.latencyMilliseconds {
                        item("bolt.horizontal", "\(latency) ms")
                    }
                    if let workingDirectory = sshSession.workingDirectory, host != nil {
                        workingDirectoryButton(workingDirectory)
                    }
                }

                if let sftpSession, sftpSession.status == .connected {
                    sftpDirectoryButton(sftpSession.path)
                }
            }

            Spacer()

            if hasTransfers {
                TransferCenterButton(
                    coordinator: app.sftpTransfers,
                    hosts: app.hosts
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .padding(.horizontal, Metrics.Space.l)
        .frame(height: Metrics.StatusBar.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var connection: some View {
        let status =
            sshSession?.status
            ?? sftpSession?.status
            ?? pane?.hostID.map { app.hosts.status(of: $0) }
            ?? .disconnected

        HStack(spacing: Metrics.Space.s) {
            StatusDot(status: status)
            if let host {
                Text(host.name)
                Text(host.host).foregroundStyle(.tertiary)
            } else {
                Text(status.label)
            }
        }
        .help(Text(host.map { app.hosts.loginAddress(for: $0) } ?? status.label))
    }

    private var host: Host? { pane?.hostID.flatMap { app.hosts.host($0) } }

    private func item(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).truncationMode(.head)
    }

    private func workingDirectoryButton(_ path: String) -> some View {
        Button {
            openInSFTP(path, placement: .newTab)
        } label: {
            item("folder", path)
        }
        .buttonStyle(.plain)
        .help(Text("Open in SFTP"))
        .accessibilityLabel(Text("Open in SFTP"))
        .contextMenu {
            Menu("Open in SFTP") {
                Button("New Tab") { openInSFTP(path, placement: .newTab) }
                Button("Current Workspace") {
                    openInSFTP(path, placement: .currentWorkspace)
                }
            }
            Button("Copy Path") { copyToPasteboard(path) }
        }
    }

    private func sftpDirectoryButton(_ path: String) -> some View {
        Button {
            openInSSH(path, placement: .newTab)
        } label: {
            item("folder", path)
        }
        .buttonStyle(.plain)
        .help(Text("Open in SSH"))
        .accessibilityLabel(Text("Open in SSH"))
        .contextMenu {
            Menu("Open in SSH") {
                Button("New Tab") { openInSSH(path, placement: .newTab) }
                Button("Current Workspace") {
                    openInSSH(path, placement: .currentWorkspace)
                }
            }
            Button("Copy Path") { copyToPasteboard(path) }
        }
    }

    private func openInSFTP(_ path: String, placement: SessionOpenPlacement) {
        guard let host else { return }
        window.openSFTPSession(host: host, initialPath: path, placement: placement)
    }

    private func openInSSH(_ path: String, placement: SessionOpenPlacement) {
        guard let host else { return }
        window.openSSHSession(host: host, initialPath: path, placement: placement)
    }
}

// MARK: - Transfer Center

private struct TransferCenterButton: View {
    let coordinator: SFTPTransferCoordinator
    let hosts: HostStore

    @State private var isPresented = false

    private var summaryValue: SFTPTransferSummary { coordinator.summary }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Metrics.Space.xs) {
                transferGlyph.frame(width: 18, height: 18)
                if summaryValue.activeCount > 0 {
                    Text(summaryValue.activeCount, format: .number)
                        .monospacedDigit()
                } else if summaryValue.failedCount > 0 {
                    Text(summaryValue.failedCount, format: .number)
                        .monospacedDigit()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(summary))
        .accessibilityLabel(Text(summary))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TransferCenterPopover(
                coordinator: coordinator,
                hosts: hosts,
                dismiss: { isPresented = false }
            )
        }
    }

    @ViewBuilder
    private var transferGlyph: some View {
        if summaryValue.activeCount > 0 {
            ZStack {
                Circle().stroke(.primary.opacity(0.14), lineWidth: 2)
                if let aggregateProgress = summaryValue.aggregateProgress {
                    Circle()
                        .trim(from: 0, to: aggregateProgress)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
            }
        } else if summaryValue.failedCount > 0 {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }

    private var summary: String {
        if summaryValue.activeCount > 0 {
            return summaryValue.activeCount == 1
                ? String(localized: "1 active transfer")
                : String(localized: "\(summaryValue.activeCount) active transfers")
        }
        if summaryValue.failedCount > 0 {
            return summaryValue.failedCount == 1
                ? String(localized: "1 failed transfer")
                : String(localized: "\(summaryValue.failedCount) failed transfers")
        }
        return String(localized: "Transfers")
    }
}

private struct TransferCenterPopover: View {
    let coordinator: SFTPTransferCoordinator
    let hosts: HostStore
    let dismiss: () -> Void

    private var transfers: [SFTPTransfer] {
        coordinator.sftpTransfers.sorted { $0.queuedAt > $1.queuedAt }
    }
    private var hasFinished: Bool {
        transfers.contains {
            switch $0.state {
            case .completed, .cancelled, .failed: true
            case .queued, .running, .paused: false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                if hasFinished {
                    Button("Clear") {
                        coordinator.clearFinished()
                        if coordinator.sftpTransfers.isEmpty { dismiss() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.l)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(transfers) { transfer in
                        TransferCenterRow(
                            transfer: transfer,
                            route: route(for: transfer),
                            cancel: { coordinator.cancel(transfer.id) }
                        )
                        if transfer.id != transfers.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: Metrics.TransferCenter.maxListHeight)
        }
        .frame(width: Metrics.TransferCenter.width)
    }

    private func route(for transfer: SFTPTransfer) -> String {
        func remote(_ hostID: Host.ID?, _ path: String) -> String {
            guard let hostID, let host = hosts.host(hostID) else { return path }
            return "\(host.name) · \(path)"
        }
        switch transfer.direction {
        case .upload:
            let destination = remote(transfer.destinationHostID, transfer.remotePath)
            return "\(transfer.localPath) → \(destination)"
        case .download:
            let source = remote(transfer.sourceHostID, transfer.remotePath)
            return "\(source) → \(transfer.localPath)"
        case .copy:
            let source = remote(transfer.sourceHostID, transfer.localPath)
            let destination = remote(transfer.destinationHostID, transfer.remotePath)
            return "\(source) → \(destination)"
        }
    }
}

private struct TransferCenterRow: View {
    let transfer: SFTPTransfer
    let route: String
    let cancel: () -> Void

    private var isActive: Bool {
        transfer.state == .queued || transfer.state == .running
    }
    private var isFailure: Bool {
        if case .failed = transfer.state { true } else { false }
    }
    private var detail: String {
        if case .failed(let reason) = transfer.state { return reason }
        if transfer.bytesPerSecond > 0 {
            return "\(transfer.bytesPerSecond.formatted(.byteCount(style: .file)))/s"
        }
        if transfer.byteCount > 0 {
            let transferred = transfer.transferredBytes.formatted(.byteCount(style: .file))
            let total = transfer.byteCount.formatted(.byteCount(style: .file))
            return "\(transferred) of \(total)"
        }
        return transfer.state.label
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Space.l) {
            Image(systemName: transfer.direction.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconStyle)
                .frame(width: 30, height: 30)
                .background(
                    .primary.opacity(0.055),
                    in: .rect(cornerRadius: Metrics.Radius.medium)
                )

            VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                HStack(spacing: Metrics.Space.s) {
                    Text(transfer.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: Metrics.Space.s)
                    Text(transfer.state.label)
                        .font(.caption)
                        .foregroundStyle(stateStyle)
                        .lineLimit(1)
                }

                Text(route)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isActive {
                    ProgressView(value: transfer.progress)
                        .progressViewStyle(.linear)
                }

                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(detailStyle)
                    .lineLimit(isFailure ? 2 : 1)
            }

            if isActive {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel transfer")
                .accessibilityLabel("Cancel transfer")
            }
        }
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.l)
    }

    private var iconStyle: AnyShapeStyle {
        if isFailure { return AnyShapeStyle(.orange) }
        if transfer.state == .completed { return AnyShapeStyle(.green) }
        return AnyShapeStyle(.tint)
    }
    private var stateStyle: AnyShapeStyle {
        isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    }
    private var detailStyle: AnyShapeStyle {
        isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary)
    }
}
