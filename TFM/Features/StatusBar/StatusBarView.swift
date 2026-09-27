import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
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

/// The direction worth showing inside the active transfer progress ring.
///
/// Only work that is actually moving bytes participates. Queued and historical
/// transfers still contribute to the transfer center's existing counts and
/// state, but they must not make a running upload or download look mixed.
nonisolated enum StatusBarTransferPresentation {
    static let idleDirectionSymbol = "arrow.up.arrow.down"

    static func runningDirectionSymbol(for transfers: [SFTPTransfer]) -> String {
        let directions = Set(
            transfers.lazy
                .filter { $0.state == .running }
                .map(\.direction)
        )
        if directions == [.upload] { return "arrow.up" }
        if directions == [.download] { return "arrow.down" }
        return "arrow.up.arrow.down"
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

    private var sftpChannel: SFTPChannelModel? { pane?.sftpChannel }
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

                if let sftpChannel, sftpChannel.status == .connected {
                    if sftpChannel.isLoading || sftpChannel.canCancelOperation {
                        sftpOperationStatus(sftpChannel)
                    } else {
                        if let displayed = sftpChannel.displayedPath {
                            sftpDirectoryButton(sftpChannel.path, displayed: displayed)
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
        .help(Text(AppStrings.Workspace.hideSessionDetails))
        .accessibilityLabel(Text(AppStrings.Workspace.hideSessionDetails))
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
                    TransferGlyph(
                        summary: app.sftpTransfers.summary,
                        transfers: app.sftpTransfers.sftpTransfers
                    )
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
        .accessibilityLabel(Text(AppStrings.Workspace.showSessionDetails))
        .accessibilityValue(Text(collapsedHelp(glyph)))
    }

    private func collapsedHelp(_ glyph: StatusBarCollapsedGlyph) -> String {
        switch glyph {
        case .connection(let status):
            host.map { "\(app.hostLibrary.loginAddress(for: $0)) — \(status.label)" }
                ?? status.label
        case .transfers:
            String(localized: AppStrings.SFTP.transfers)
        }
    }

    private var status: ConnectionStatus {
        sshSession?.status
            ?? sftpChannel?.status
            ?? serialSession?.status
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
        .help(Text(AppStrings.SFTP.openDirectoryWithSFTPHelp))
        .accessibilityLabel(Text(AppStrings.SFTP.openWithSftp))
        .contextMenu {
            // The children read on from the parent — "Open with SFTP ▸ in New
            // Workspace" — and take the same pair of glyphs Duplicate's do.
            Menu(AppStrings.SFTP.openWithSftp.swiftUIKey, systemImage: MenuSymbol.sftp) {
                Button(AppStrings.Workspace.inCurrentWorkspace.swiftUIKey, systemImage: MenuSymbol.currentWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSFTP(path, placement: .currentWorkspace)
                }
                Button(AppStrings.Workspace.inNewWorkspace.swiftUIKey, systemImage: MenuSymbol.newWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSFTP(path, placement: .newWorkspace)
                }
            }
            Button(AppStrings.Workspace.copyPath.swiftUIKey, systemImage: MenuSymbol.copy) {
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
        .help(Text(AppStrings.Workspace.openDirectoryWithSSHHelp))
        .accessibilityLabel(Text(AppStrings.Connections.openWithSsh))
        .contextMenu {
            Menu(AppStrings.Connections.openWithSsh.swiftUIKey, systemImage: MenuSymbol.ssh) {
                Button(AppStrings.Workspace.inCurrentWorkspace.swiftUIKey, systemImage: MenuSymbol.currentWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSSH(path, placement: .currentWorkspace)
                }
                Button(AppStrings.Workspace.inNewWorkspace.swiftUIKey, systemImage: MenuSymbol.newWorkspace) {
                    app.onboarding.recordUse(of: .statusBarPath)
                    openInSSH(path, placement: .newWorkspace)
                }
            }
            Button(AppStrings.Workspace.copyPath.swiftUIKey, systemImage: MenuSymbol.copy) {
                app.onboarding.recordUse(of: .statusBarPath)
                copyToPasteboard(path)
            }
        }
    }

    private func sftpOperationStatus(_ session: SFTPChannelModel) -> some View {
        HStack(spacing: Metrics.Space.s) {
            ProgressView().controlSize(.mini)
            Text(session.hint.isEmpty ? String(localized: AppStrings.Workspace.working) : session.hint)
                .truncationMode(.middle)
            if session.canCancelOperation {
                Button {
                    session.cancelOperation()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help(AppStrings.Workspace.cancelOperation.swiftUIKey)
                .accessibilityLabel(AppStrings.Workspace.cancelOperation.swiftUIKey)
            }
        }
    }

    private func openInSFTP(_ path: String, placement: SessionOpenPlacement) {
        guard let host else { return }
        window.openSFTPChannel(host: host, initialPath: path, placement: placement)
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
struct TransferGlyph: View {
    static let size: CGFloat = 18

    let summary: SFTPTransferSummary
    let transfers: [SFTPTransfer]

    var body: some View {
        Group {
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
                    directionGlyph(
                        StatusBarTransferPresentation.runningDirectionSymbol(for: transfers)
                    )
                }
            } else if summary.failedCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            } else {
                directionGlyph(StatusBarTransferPresentation.idleDirectionSymbol)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    private func directionGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
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
                TransferGlyph(summary: summaryValue, transfers: coordinator.sftpTransfers)
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
                ? String(localized: AppStrings.SFTP.oneActiveTransfer)
                : String(localized: AppStrings.SFTP.activeTransfers(summaryValue.activeCount))
        }
        if summaryValue.failedCount > 0 {
            return summaryValue.failedCount == 1
                ? String(localized: AppStrings.SFTP.oneFailedTransfer)
                : String(localized: AppStrings.SFTP.failedTransfers(summaryValue.failedCount))
        }
        return String(localized: AppStrings.SFTP.transfers)
    }
}
