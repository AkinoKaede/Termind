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
                MobileNativeList(
                    items: items,
                    estimatedRowHeight: 68,
                    refreshID: AnyHashable([connected, channel.isRefreshing]),
                    onSelect: { item in
                        guard connected else { return }
                        switch item {
                        case .parent(let path): Task { await channel.openDirectory(path) }
                        case .file(let file): open(file)
                        }
                    },
                    onRefresh: { await channel.reload() },
                    bottomContentInset: bottomContentInset
                ) { item in
                    switch item {
                    case .parent:
                        parentRow
                    case .file(let file):
                        fileRow(file)
                    }
                }
                if items.isEmpty {
                    Group {
                        if channel.query.isEmpty {
                            ContentUnavailableView(TermindCopy.Common.empty.swiftUIKey, systemImage: "folder")
                        } else {
                            ContentUnavailableView.search(text: channel.query)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
        .accessibilityLabel(TermindCopy.SFTP.parentDirectory.swiftUIKey)
    }

    private func fileRow(_ file: RemoteFile) -> some View {
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
        .contentShape(.rect)
        .contextMenu {
            Button(TermindCopy.Common.open.swiftUIKey, systemImage: "arrow.up.right") { open(file) }
            if !file.isDirectory {
                Button(TermindCopy.SFTP.openWithProgress.swiftUIKey, systemImage: "arrow.up.forward.app") {
                    openWith(file)
                }
                .disabled(!connected)
                if canImportEditedCopy(file) {
                    Button(TermindCopy.SFTP.importEditedCopyProgress.swiftUIKey, systemImage: "square.and.arrow.down") {
                        importEditedCopy(file)
                    }
                }
            }
            Button(TermindCopy.SFTP.download.swiftUIKey, systemImage: "square.and.arrow.down") { download(file) }
            Divider()
            Button(TermindCopy.Common.copy.swiftUIKey, systemImage: "doc.on.doc") { copy(file) }
            Menu(TermindCopy.SFTP.copyAs.swiftUIKey, systemImage: "doc.on.doc") {
                Button(TermindCopy.Common.name.swiftUIKey) { UIPasteboard.general.string = file.name }
                Button(TermindCopy.SFTP.path.swiftUIKey) { UIPasteboard.general.string = file.path }
            }
            Button(TermindCopy.Common.paste.swiftUIKey, systemImage: "doc.on.clipboard") { paste() }
            Button(TermindCopy.Common.rename.swiftUIKey, systemImage: "pencil") { rename(file) }
            Button(TermindCopy.SFTP.editPermissions.swiftUIKey, systemImage: "lock.shield") { editPermissions(file) }
            Divider()
            Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) { delete(file) }
        }
        .accessibilityHint(file.isDirectory ? Text(TermindCopy.Common.open) : Text(TermindCopy.SFTP.download))
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
                    TermindCopy.SFTP.remotePath.swiftUIKey, text: $channel.pathText.singleLineText, axis: .horizontal
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
        .accessibilityHint(Text(TermindCopy.SFTP.editPath))
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
