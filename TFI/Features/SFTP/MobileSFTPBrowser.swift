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
    @Bindable var session: MobileSFTPSessionModel
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
        mobileSFTPListItems(path: session.path, files: session.visibleFiles)
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileSFTPPathBar(session: session, connected: connected)
            Divider()
            ZStack {
                MobileNativeList(
                    items: items,
                    estimatedRowHeight: 68,
                    refreshID: AnyHashable([connected, session.isRefreshing]),
                    onSelect: { item in
                        guard connected else { return }
                        switch item {
                        case .parent(let path): Task { await session.openDirectory(path) }
                        case .file(let file): open(file)
                        }
                    },
                    onRefresh: { await session.reload() },
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
                        if session.query.isEmpty {
                            ContentUnavailableView("Empty", systemImage: "folder")
                        } else {
                            ContentUnavailableView.search(text: session.query)
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
        .accessibilityLabel("Parent Directory")
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
            Button("Open", systemImage: "arrow.up.right") { open(file) }
            if !file.isDirectory {
                Button("Open With…", systemImage: "arrow.up.forward.app") { openWith(file) }
                    .disabled(!connected)
                if canImportEditedCopy(file) {
                    Button("Import Edited Copy…", systemImage: "square.and.arrow.down") { importEditedCopy(file) }
                }
            }
            Button("Download", systemImage: "square.and.arrow.down") { download(file) }
            Divider()
            Button("Copy", systemImage: "doc.on.doc") { copy(file) }
            Menu("Copy As", systemImage: "doc.on.doc") {
                Button("Name") { UIPasteboard.general.string = file.name }
                Button("Path") { UIPasteboard.general.string = file.path }
            }
            Button("Paste", systemImage: "doc.on.clipboard") { paste() }
            Button("Rename", systemImage: "pencil") { rename(file) }
            Button("Edit Permissions", systemImage: "lock.shield") { editPermissions(file) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { delete(file) }
        }
        .accessibilityHint(file.isDirectory ? Text("Open") : Text("Download"))
    }
}

private struct MobileSFTPPathBar: View {
    @Bindable var session: MobileSFTPSessionModel
    let connected: Bool
    @State private var editsPath = false
    @FocusState private var pathFocused: Bool

    var body: some View {
        Group {
            if editsPath {
                TextField("Remote Path", text: $session.pathText.singleLineText, axis: .horizontal).singleLinePaste()
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
        .frame(height: 44)
        .background(.bar)
        .onChange(of: pathFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused, editsPath else { return }
            cancelPathEditing()
        }
        .onChange(of: session.path) { _, path in
            if !editsPath { session.pathText = path }
        }
    }

    private var breadcrumbContent: some View {
        let components = RemotePath.components(of: session.path)
        let tailCount = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
        let collapses = components.count > tailCount + 1
        let visible = collapses ? Array(components.suffix(tailCount)) : Array(components.dropFirst())
        return HStack(spacing: 6) {
            breadcrumbLabel(components[0], isRoot: true)
            if collapses {
                separator
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            ForEach(visible) { component in
                separator
                breadcrumbLabel(component, isRoot: false)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(session.path))
        .accessibilityHint(Text("Edit Path"))
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
                .font(.body.weight(component.path == session.path ? .medium : .regular))
                .lineLimit(1)
        }
    }

    private func beginPathEditing() {
        session.pathText = session.path
        editsPath = true
        Task { @MainActor in pathFocused = true }
    }

    private func commitPath() {
        let destination = session.pathText
        editsPath = false
        pathFocused = false
        Task { await session.openDirectory(destination) }
    }

    private func cancelPathEditing() {
        session.pathText = session.path
        editsPath = false
        pathFocused = false
    }
}
