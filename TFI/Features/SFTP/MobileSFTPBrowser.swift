import SwiftUI
import TermindDomain
import TermindPresentation
import UIKit

struct MobileSFTPBrowser: View {
    @Bindable var session: MobileSFTPSessionModel
    let connected: Bool
    let open: (RemoteFile) -> Void
    let rename: (RemoteFile) -> Void
    let editPermissions: (RemoteFile) -> Void
    let delete: (RemoteFile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            MobileSFTPPathBar(session: session, connected: connected)
            Divider()
            ZStack {
                MobileNativeList(
                    items: session.visibleFiles,
                    estimatedRowHeight: 52,
                    refreshID: connected,
                    onSelect: { file in
                        guard connected else { return }
                        open(file)
                    },
                    onDelete: { file in
                        guard connected else { return }
                        delete(file)
                    },
                    onRefresh: { await session.reload() }
                ) { file in
                    fileRow(file)
                }
                if session.visibleFiles.isEmpty {
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

    private func fileRow(_ file: RemoteFile) -> some View {
        Label(file.name, systemImage: file.kind.symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect)
            .contextMenu {
                Button("Rename", systemImage: "pencil") { rename(file) }
                Button("Edit Permissions", systemImage: "lock.shield") { editPermissions(file) }
                Button("Delete", systemImage: "trash", role: .destructive) { delete(file) }
            }
            .overlay(alignment: .bottom) { Divider().padding(.leading, 52) }
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
                TextField("Remote Path", text: $session.pathText)
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
