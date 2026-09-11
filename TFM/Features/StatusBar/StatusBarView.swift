import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

/// What the capsule shrinks to.
nonisolated enum StatusBarCollapsedGlyph: Hashable, Sendable {
    case connection(ConnectionStatus)
    case transfers
}

/// Whether the floating capsule appears, and what it says when collapsed.
///
/// Pure, and therefore testable: the same call answers both questions, so a
/// capsule can never be on screen with nothing to shrink to, or shrink to
/// something it is not showing.
nonisolated enum StatusBarPresentation {
    /// nil when the capsule does not appear at all.
    static func collapsedGlyph(
        hasSessionContext: Bool,
        status: ConnectionStatus,
        hasTransfers: Bool
    ) -> StatusBarCollapsedGlyph? {
        // The connection wins when there is one. A transfer is a thing that is
        // happening; the connection is the thing you are looking at, and the
        // dot's colour is the only state worth a glance while collapsed.
        if hasSessionContext { return .connection(status) }
        if hasTransfers { return .transfers }
        return nil
    }
}

/// Focused-session context and app-wide transfers, as one floating capsule.
///
/// It used to be a docked strip with a hairline above it, which read as a piece
/// of window chrome bolted under the content. Floating, it belongs to the pane
/// it describes and matches the other glass objects in the app — the mode rail,
/// the composer, the sidebar's search.
///
/// It hugs its content and sits in the trailing corner rather than spanning the
/// width: a full-width bar over a terminal covers whole lines of output, and the
/// prompt lives on the left. Anything else anchored to the bottom of a pane
/// clears it by `Metrics.StatusBar.overlayClearance`.
struct StatusBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(DesktopSettingsKey.statusBarExpanded) private var isExpanded = true

    private var pane: Pane? { window.selectedWorkspace?.focusedPane }
    private var showsSessionContext: Bool { pane?.kind.showsStatusBar == true }
    private var hasTransfers: Bool { !app.sftpTransfers.sftpTransfers.isEmpty }

    private var sshSession: SSHSessionModel? {
        guard case .sshSession(let sshSession)? = pane?.content else { return nil }
        return sshSession
    }

    private var sftpSession: SFTPSessionModel? { pane?.sftpSession }
    private var serialSession: SerialSessionModel? { pane?.serialSession }

    /// One rule decides both whether the capsule appears at all and what it
    /// shrinks to, so the two can never disagree — see `StatusBarPresentation`.
    private var collapsedGlyph: StatusBarCollapsedGlyph? {
        StatusBarPresentation.collapsedGlyph(
            hasSessionContext: showsSessionContext,
            status: status,
            hasTransfers: hasTransfers
        )
    }

    @ViewBuilder
    var body: some View {
        if let collapsedGlyph {
            capsule(collapsedGlyph)
        }
    }

    /// Expanded and collapsed share one chain from here down, so the two states
    /// cannot drift apart in radius, height or how they sit in the corner.
    ///
    /// Both are the same `.capsule` too. A capsule as wide as it is tall *is* a
    /// circle, so collapsing morphs the shape rather than swapping one
    /// container for another and cross-fading between them.
    private func capsule(_ glyph: StatusBarCollapsedGlyph) -> some View {
        Group {
            if isExpanded {
                expandedContent
                    .padding(.horizontal, Metrics.Space.l)
            } else {
                collapsedContent(glyph)
                    .frame(width: Metrics.StatusBar.height)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .frame(height: Metrics.StatusBar.height)
        .termindGlassCapsule()
        // A ceiling on what the capsule is *offered*, not a width it takes.
        // The row inside has no `Spacer`, so it hugs its text; this only stops a
        // very long working directory from spanning the pane, and the trailing
        // alignment keeps the capsule pinned to the corner as it grows and
        // shrinks rather than drifting from the edge.
        .frame(maxWidth: Metrics.StatusBar.maxWidth, alignment: .trailing)
        .animation(Motion.panel(reduceMotion: reduceMotion), value: isExpanded)
    }

    private var expandedContent: some View {
        HStack(spacing: Metrics.Space.l) {
            if showsSessionContext {
                connection

                if let sshSession, sshSession.status.isLive {
                    if let workingDirectory = sshSession.workingDirectory,
                        let displayed = sshSession.displayedWorkingDirectory, host != nil
                    {
                        workingDirectoryButton(workingDirectory, displayed: displayed)
                    }
                }

                if let sftpSession, sftpSession.status == .connected {
                    if sftpSession.isLoading || sftpSession.canCancelOperation {
                        sftpOperationStatus(sftpSession)
                    } else {
                        if let displayed = sftpSession.displayedPath {
                            sftpDirectoryButton(sftpSession.path, displayed: displayed)
                        }
                    }
                }
            }

            if hasTransfers {
                TransferCenterButton(
                    coordinator: app.sftpTransfers,
                    hosts: app.hostLibrary
                )
            }

            collapseButton
        }
    }

    /// Inside the capsule rather than floating beside it, so it reads as part of
    /// the object it closes rather than as a stray control over the terminal.
    private var collapseButton: some View {
        Button {
            isExpanded = false
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12, height: Metrics.StatusBar.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text("Hide Session Details"))
        .accessibilityLabel(Text("Hide Session Details"))
    }

    /// The whole circle is the target. Its content still carries the one fact
    /// worth keeping at a glance — whether the connection is live — which is
    /// the reason this is what the capsule shrinks to.
    private func collapsedContent(_ glyph: StatusBarCollapsedGlyph) -> some View {
        Button {
            isExpanded = true
        } label: {
            Group {
                switch glyph {
                case .connection(let status):
                    Circle()
                        .fill(status.tint)
                        .frame(
                            width: Metrics.Sidebar.statusDot,
                            height: Metrics.Sidebar.statusDot
                        )
                case .transfers:
                    TransferGlyph(summary: app.sftpTransfers.summary)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(
                width: Metrics.StatusBar.height,
                height: Metrics.StatusBar.height
            )
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(Text(collapsedHelp(glyph)))
        .accessibilityLabel(Text("Show Session Details"))
        .accessibilityValue(Text(collapsedHelp(glyph)))
    }

    private func collapsedHelp(_ glyph: StatusBarCollapsedGlyph) -> String {
        switch glyph {
        case .connection(let status):
            host.map { "\(app.hostLibrary.loginAddress(for: $0)) — \(status.label)" }
                ?? status.label
        case .transfers:
            String(localized: "Transfers")
        }
    }

    private var status: ConnectionStatus {
        sshSession?.status
            ?? sftpSession?.status
            ?? serialSession?.status
            ?? pane?.hostID.map { app.hostLibrary.status(of: $0) }
            ?? .disconnected
    }

    @ViewBuilder
    private var connection: some View {
        HStack(spacing: Metrics.Space.s) {
            Circle()
                .fill(status.tint)
                .frame(
                    width: Metrics.Sidebar.statusDot,
                    height: Metrics.Sidebar.statusDot
                )
                .accessibilityLabel(Text(status.label))
            if let host {
                Text(host.name)
                Text(host.host).foregroundStyle(.tertiary)
            } else if let serialSession {
                Text(serialSession.title)
                Text(serialSession.subtitle).foregroundStyle(.tertiary)
            } else {
                Text(status.label)
            }
        }
        .help(
            Text(
                host.map { app.hostLibrary.loginAddress(for: $0) }
                    ?? serialSession?.subtitle ?? status.label
            ))
    }

    private var host: Host? { pane?.hostID.flatMap { app.hostLibrary.host($0) } }

    private func item(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).truncationMode(.head)
    }

    private func workingDirectoryButton(_ path: String, displayed: String) -> some View {
        Button {
            app.onboarding.recordUse(of: .statusBarPath)
            openInSFTP(path, placement: .currentWorkspace)
        } label: {
            StatusBarPathLabel(
                symbol: "folder", text: displayed, destinationSymbol: "arrow.up.right"
            )
        }
        .buttonStyle(.plain)
        .help(Text("Open current directory with SFTP — right-click for more options"))
        .accessibilityLabel(Text("Open with SFTP"))
        .contextMenu {
            // The children read on from the parent — "Open with SFTP ▸ in New
            // Workspace" — and take the same pair of glyphs Duplicate's do.
            Menu("Open with SFTP", systemImage: MenuSymbol.sftp) {
                Button("in Current Workspace", systemImage: MenuSymbol.currentWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSFTP(path, placement: .currentWorkspace)
                }
                Button("in New Workspace", systemImage: MenuSymbol.newWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSFTP(path, placement: .newWorkspace)
                }
            }
            Button("Copy Path", systemImage: MenuSymbol.copy) {
                app.onboarding.recordUse(of: .statusBarPath)
                copyToPasteboard(path)
            }
        }
    }

    private func sftpDirectoryButton(_ path: String, displayed: String) -> some View {
        Button {
            app.onboarding.recordUse(of: .statusBarPath)
            openInSSH(path, placement: .currentWorkspace)
        } label: {
            StatusBarPathLabel(
                symbol: "apple.terminal", text: displayed, destinationSymbol: "arrow.up.right"
            )
        }
        .buttonStyle(.plain)
        .help(Text("Open current directory with SSH — right-click for more options"))
        .accessibilityLabel(Text("Open with SSH"))
        .contextMenu {
            Menu("Open with SSH", systemImage: MenuSymbol.ssh) {
                Button("in Current Workspace", systemImage: MenuSymbol.currentWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSSH(path, placement: .currentWorkspace)
                }
                Button("in New Workspace", systemImage: MenuSymbol.newWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSSH(path, placement: .newWorkspace)
                }
            }
            Button("Copy Path", systemImage: MenuSymbol.copy) {
                app.onboarding.recordUse(of: .statusBarPath)
                copyToPasteboard(path)
            }
        }
    }

    private func sftpOperationStatus(_ session: SFTPSessionModel) -> some View {
        HStack(spacing: Metrics.Space.s) {
            ProgressView().controlSize(.mini)
            Text(session.hint.isEmpty ? String(localized: "Working") : session.hint)
                .truncationMode(.middle)
            if session.canCancelOperation {
                Button {
                    session.cancelOperation()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Cancel operation")
                .accessibilityLabel("Cancel operation")
            }
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

private struct StatusBarPathLabel: View {
    let symbol: String
    let text: String
    let destinationSymbol: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: symbol)
            Text(text).truncationMode(.head)
            Image(systemName: destinationSymbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, Metrics.Space.xxs)
        .background(
            isHovering ? Color.accentColor.opacity(0.12) : .clear,
            in: .rect(cornerRadius: Metrics.Radius.small)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Transfer Center

/// The transfer state as one glyph: a progress ring while anything is running,
/// a warning once something has failed, and the idle arrows otherwise.
///
/// Its own view because the collapsed capsule shows it too, in the one case
/// where there is no session to describe — a transfer running with no pane in
/// front of it.
private struct TransferGlyph: View {
    let summary: SFTPTransferSummary

    @ViewBuilder
    var body: some View {
        if summary.activeCount > 0 {
            ZStack {
                Circle().stroke(.primary.opacity(0.14), lineWidth: 2)
                if let aggregateProgress = summary.aggregateProgress {
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
        } else if summary.failedCount > 0 {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }
}

private struct TransferCenterButton: View {
    let coordinator: SFTPTransferCoordinator
    let hosts: HostLibraryModel

    @State private var isPresented = false

    private var summaryValue: SFTPTransferSummary { coordinator.summary }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: Metrics.Space.xs) {
                TransferGlyph(summary: summaryValue).frame(width: 18, height: 18)
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
        .termindInputAwareFocusEffect()
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
    let hosts: HostLibraryModel
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
                    .termindInputAwareFocusEffect()
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.l)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(transferItems) { item in
                        VStack(spacing: 0) {
                            TransferCenterRow(
                                transfer: item.transfer,
                                route: item.route,
                                cancel: { coordinator.cancel(item.id) }
                            )
                            if item.id != transferItems.last?.id { Divider() }
                        }
                    }
                }
            }
            .frame(height: Metrics.TransferCenter.listHeight(itemCount: transferItems.count))
        }
        .frame(width: Metrics.TransferCenter.width)
    }

    private var transferItems: [TransferCenterListItem] {
        transfers.map { TransferCenterListItem(transfer: $0, route: route(for: $0)) }
    }

    private func route(for transfer: SFTPTransfer) -> String {
        func remote(_ hostID: Host.ID?, _ path: String, home: String?) -> String {
            let displayed = RemotePath.displayed(
                path, home: home.map(RemoteHomeResolutionState.resolved) ?? .unavailable
            )
            guard let hostID, let host = hosts.host(hostID) else { return displayed }
            return "\(host.name) · \(displayed)"
        }
        switch transfer.direction {
        case .upload:
            let destination = remote(
                transfer.destinationHostID, transfer.remotePath,
                home: transfer.destinationHomeDirectory
            )
            return "\(transfer.localPath) → \(destination)"
        case .download:
            let source = remote(
                transfer.sourceHostID, transfer.remotePath,
                home: transfer.sourceHomeDirectory
            )
            return "\(source) → \(transfer.localPath)"
        case .copy:
            let source = remote(
                transfer.sourceHostID, transfer.localPath,
                home: transfer.sourceHomeDirectory
            )
            let destination = remote(
                transfer.destinationHostID, transfer.remotePath,
                home: transfer.destinationHomeDirectory
            )
            return "\(source) → \(destination)"
        }
    }
}

nonisolated struct TransferCenterListItem: Identifiable, Hashable, Sendable {
    let transfer: SFTPTransfer
    let route: String
    var id: SFTPTransfer.ID { transfer.id }
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
                .termindInputAwareFocusEffect()
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
