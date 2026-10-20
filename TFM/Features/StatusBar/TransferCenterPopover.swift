// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure

struct TransferCenterPopover: View {
    let coordinator: SFTPTransferCoordinator
    let hosts: HostLibraryModel
    let dismiss: () -> Void
    @State private var confirmsClearFinished = false

    private var transfers: [SFTPTransfer] {
        coordinator.sftpTransfers.sorted { $0.queuedAt > $1.queuedAt }
    }
    private var hasFinished: Bool {
        transfers.contains { $0.state.isFinished }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppStrings.SFTP.transfers).font(.headline)
                Spacer()
                if hasFinished {
                    Button(AppStrings.Common.clear.swiftUIKey) {
                        confirmsClearFinished = true
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
                    if transferItems.isEmpty {
                        Text(AppStrings.SFTP.noTransfers)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: Metrics.TransferCenter.estimatedRowHeight)
                    }
                    ForEach(transferItems) { item in
                        VStack(spacing: 0) {
                            TransferCenterRow(
                                transfer: item.transfer,
                                route: item.route,
                                canPause: coordinator.canPause(item.id),
                                pause: { coordinator.pause(item.id) },
                                resume: { coordinator.resume(item.id) },
                                cancel: { coordinator.cancel(item.id) },
                                delete: {
                                    coordinator.removeFinished(item.id)
                                    if coordinator.sftpTransfers.isEmpty { dismiss() }
                                }
                            )
                            if item.id != transferItems.last?.id { Divider() }
                        }
                    }
                }
            }
            .frame(height: Metrics.TransferCenter.listHeight(itemCount: max(1, transferItems.count)))
        }
        .frame(width: Metrics.TransferCenter.width)
        .confirmationDialog(
            AppStrings.SFTP.clearFinishedTransfersConfirmation, isPresented: $confirmsClearFinished,
            titleVisibility: .visible
        ) {
            Button(AppStrings.SFTP.clearFinished.swiftUIKey, role: .destructive) {
                coordinator.clearFinished()
                if coordinator.sftpTransfers.isEmpty { dismiss() }
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        }
    }

    private var transferItems: [TransferCenterListItem] {
        transfers.map { transfer in
            TransferCenterListItem(
                transfer: transfer,
                route: transfer.routeLabel { hosts.host($0)?.name }
            )
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
    let canPause: Bool
    let pause: () -> Void
    let resume: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    private var isFailure: Bool {
        if case .failed = transfer.state { true } else { false }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
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
                    Text(transfer.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(transfer.statusLabel)
                        .font(.caption)
                        .foregroundStyle(stateStyle)
                        .lineLimit(1)
                }
                Spacer(minLength: Metrics.Space.s)

                if transfer.state.isActive {
                    controlButton("xmark.circle.fill", title: AppStrings.SFTP.cancelTransfer, action: cancel)
                } else if transfer.state == .paused {
                    controlButton("play.circle", title: AppStrings.SFTP.resumeTransfer, action: resume)
                }
            }

            Text(route)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if transfer.state.isActive {
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
            }
            Text(transfer.progressDetail ?? transfer.statusLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(detailStyle)
                .lineLimit(isFailure ? 2 : 1)
        }
        .padding(.vertical, Metrics.Space.m)
        .frame(maxWidth: .infinity, minHeight: Metrics.TransferCenter.estimatedRowHeight, alignment: .topLeading)
        .padding(.horizontal, Metrics.Space.l)
        .contentShape(.rect)
        .contextMenu {
            if canPause {
                Button(AppStrings.Metrics.pause.swiftUIKey, systemImage: "pause.circle", action: pause)
            } else if transfer.state == .paused {
                Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark.circle.fill", action: cancel)
            } else if transfer.state.isFinished {
                Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive, action: delete)
            }
        }
    }

    private func controlButton(
        _ symbol: String, title: LocalizedStringResource, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .termindInputAwareFocusEffect()
        .help(title.swiftUIKey)
        .accessibilityLabel(title.swiftUIKey)
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
