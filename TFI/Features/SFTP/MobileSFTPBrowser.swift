// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

nonisolated enum MobileSFTPListItem: Identifiable, Hashable, Sendable {
    case parent(String)
    case file(RemoteFile)

    var id: String {
        switch self {
        case .parent: "\u{0}parent"
        case .file(let file): file.id
        }
    }
}

nonisolated func mobileSFTPListItems(path: String, files: [RemoteFile]) -> [MobileSFTPListItem] {
    var items = files.map(MobileSFTPListItem.file)
    if path != "/" {
        items.insert(.parent(RemotePath.parent(of: path)), at: 0)
    }
    return items
}

struct MobileSFTPBrowser: View {
    @Bindable var channel: MobileSFTPChannelModel
    let connected: Bool
    var bottomContentInset: CGFloat = 0
    let open: (RemoteFile) -> Void
    let openWith: (RemoteFile) -> Void
    let canImportEditedCopy: (RemoteFile) -> Bool
    let importEditedCopy: (RemoteFile) -> Void
    let download: (RemoteFile) -> Void
    let copy: (RemoteFile) -> Void
    let paste: () -> Void
    let rename: (RemoteFile) -> Void
    let editPermissions: (RemoteFile) -> Void
    let delete: (RemoteFile) -> Void

    private var items: [MobileSFTPListItem] {
        mobileSFTPListItems(path: channel.path, files: channel.visibleFiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileSFTPPathBar(channel: channel, connected: connected)
            Divider()
            ZStack {
                GeometryReader { geometry in
                    MobileNativeList(
                        items: items,
                        estimatedRowHeight: 68,
                        refreshID: AnyHashable([
                            AnyHashable(connected), AnyHashable(channel.isRefreshing), AnyHashable(geometry.size.width),
                        ]),
                        onSelect: { item in
                            guard connected else { return }
                            switch item {
                            case .parent(let path): Task { await channel.openDirectory(path) }
                            case .file(let file): open(file)
                            }
                        },
                        onRefresh: { await channel.reload() },
                        bottomContentInset: bottomContentInset,
                        surface: .plain
                    ) { item in
                        switch item {
                        case .parent:
                            parentRow
                        case .file(let file):
                            MobileSFTPFileDeletion(file: file, delete: delete) { requestDelete in
                                fileRow(file, previewWidth: geometry.size.width, requestDelete: requestDelete)
                            }
                        }
                    }
                }
                if items.isEmpty {
                    Group {
                        if channel.query.isEmpty {
                            ContentUnavailableView(AppStrings.Common.empty.swiftUIKey, systemImage: "folder")
                        } else {
                            ContentUnavailableView.search(text: channel.query)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
    }

    private var parentRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 34)
            Text(verbatim: "..").font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppStrings.SFTP.parentDirectory.swiftUIKey)
    }

    private func fileRow(_ file: RemoteFile, previewWidth: CGFloat, requestDelete: @escaping () -> Void) -> some View {
        MobileSFTPFileRowContent(file: file)
            .contentShape(.rect)
            .contextMenu {
                Button(AppStrings.Common.open.swiftUIKey, systemImage: "arrow.up.right") { open(file) }
                if !file.isDirectory {
                    Button(AppStrings.SFTP.openWithProgress.swiftUIKey, systemImage: "arrow.up.forward.app") {
                        openWith(file)
                    }
                    .disabled(!connected)
                    if canImportEditedCopy(file) {
                        Button(
                            AppStrings.SFTP.importEditedCopyProgress.swiftUIKey, systemImage: "square.and.arrow.down"
                        ) {
                            importEditedCopy(file)
                        }
                    }
                }
                Button(AppStrings.SFTP.download.swiftUIKey, systemImage: "square.and.arrow.down") { download(file) }
                Divider()
                Button(AppStrings.Common.copy.swiftUIKey, systemImage: "doc.on.doc") { copy(file) }
                Menu(AppStrings.SFTP.copyAs.swiftUIKey, systemImage: "doc.on.doc") {
                    Button(AppStrings.Common.name.swiftUIKey) { UIPasteboard.general.string = file.name }
                    Button(AppStrings.SFTP.path.swiftUIKey) {
                        UIPasteboard.general.string = RemoteShellCommand.escapeArgument(file.path)
                    }
                }
                Button(AppStrings.Common.paste.swiftUIKey, systemImage: "doc.on.clipboard") { paste() }
                Button(AppStrings.Common.rename.swiftUIKey, systemImage: "pencil") { rename(file) }
                Button(AppStrings.SFTP.editPermissions.swiftUIKey, systemImage: "lock.shield") { editPermissions(file) }
                Divider()
                Button(
                    AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive, action: requestDelete
                )
            } preview: {
                MobileSFTPFilePreview(file: file, width: previewWidth)
            }
            .accessibilityHint(file.isDirectory ? Text(AppStrings.Common.open) : Text(AppStrings.SFTP.download))
    }
}

/// The lifted preview must carry its own background; the list's UIKit background stays behind.
struct MobileSFTPFilePreview: View {
    let file: RemoteFile
    let width: CGFloat

    var body: some View {
        MobileSFTPFileRowContent(file: file)
            .frame(width: width)
            .background(Color(uiColor: .systemBackground))
    }
}

private struct MobileSFTPFileRowContent: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: file.kind.symbol)
                .font(.system(size: file.isDirectory ? 28 : 25))
                .foregroundStyle(file.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(file.permissionDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if file.isDirectory {
                    Text(verbatim: "0")
                        .font(.subheadline.monospacedDigit())
                        .hidden()
                        .accessibilityHidden(true)
                } else {
                    Text(DataSizeFormat.bytes(file.size))
                        .font(.subheadline.monospacedDigit())
                }
                Text(file.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Lives in the hosted file row so its presentation and anchor survive list refreshes together.
private struct MobileSFTPFileDeletion<Content: View>: View {
    let file: RemoteFile
    let delete: (RemoteFile) -> Void
    @ViewBuilder let content: (@escaping () -> Void) -> Content
    @Environment(\.locale) private var locale
    @State private var confirmsDeletion = false

    var body: some View {
        content { confirmsDeletion = true }
            .operationConfirmation(
                .init(AppStrings.SFTP.deleteConfirmation(file.name)), isPresented: $confirmsDeletion,
                actions: [
                    .init(AppStrings.Common.delete, role: .destructive) { delete(file) },
                    .init(AppStrings.Common.cancel, role: .cancel) {},
                ],
                message: .init(AppStrings.SFTP.deletionMessage(paths: file.path, remainingCount: 0, locale: locale))
            )
    }
}

private struct MobileSFTPPathBar: View {
    @Bindable var channel: MobileSFTPChannelModel
    let connected: Bool
    @State private var editsPath = false
    @FocusState private var pathFocused: Bool

    var body: some View {
        Group {
            if editsPath {
                TextField(
                    AppStrings.SFTP.remotePath.swiftUIKey, text: $channel.pathText.singleLineText, axis: .horizontal
                ).singleLinePaste()
                    .lineLimit(1)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($pathFocused)
                    .onSubmit(commitPath)
                    .onKeyPress(.escape) {
                        cancelPathEditing()
                        return .handled
                    }
            } else {
                Button(action: beginPathEditing) {
                    breadcrumbContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!connected)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(.bar)
        .onChange(of: pathFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused, editsPath else { return }
            cancelPathEditing()
        }
        .onChange(of: channel.path) { _, path in
            if !editsPath { channel.pathText = path }
        }
    }

    private var breadcrumbContent: some View {
        ViewThatFits(in: .horizontal) {
            breadcrumbs(tailCount: 3).fixedSize(horizontal: true, vertical: false)
            breadcrumbs(tailCount: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(channel.path))
        .accessibilityHint(Text(AppStrings.SFTP.editPath))
    }

    private func breadcrumbs(tailCount: Int) -> some View {
        let components = RemotePath.components(of: channel.path)
        let collapses = components.count > tailCount + 1
        let visible = collapses ? Array(components.suffix(tailCount)) : Array(components.dropFirst())
        return HStack(spacing: 6) {
            breadcrumbLabel(components[0], isRoot: true)
            if collapses {
                separator
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)
            }
            ForEach(visible) { component in
                separator
                breadcrumbLabel(component, isRoot: false)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func breadcrumbLabel(_ component: RemotePath.Component, isRoot: Bool) -> some View {
        HStack(spacing: 6) {
            if isRoot { Image(systemName: "folder.fill").foregroundStyle(.tint) }
            Text(component.name)
                .font(.body.weight(component.path == channel.path ? .medium : .regular))
                .lineLimit(1)
        }
        .fixedSize(horizontal: isRoot, vertical: false)
    }

    private func beginPathEditing() {
        channel.pathText = channel.path
        editsPath = true
        Task { @MainActor in pathFocused = true }
    }

    private func commitPath() {
        let destination = channel.pathText
        editsPath = false
        pathFocused = false
        Task { await channel.openDirectory(destination) }
    }

    private func cancelPathEditing() {
        channel.pathText = channel.path
        editsPath = false
        pathFocused = false
    }
}
