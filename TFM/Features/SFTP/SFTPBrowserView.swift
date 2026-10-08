import ListViewKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

nonisolated struct SFTPFileListItem: Identifiable, Hashable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        case parent
        case file(RemoteFile.ID)
    }

    let row: SFTPRow?
    let parentPath: String?
    let isSelected: Bool
    let isEmphasized: Bool
    let isHovered: Bool
    let layoutKey: Int

    var id: ID {
        if let row { return .file(row.id) }
        return .parent
    }
}

nonisolated struct SFTPFileScrollRequest: Equatable, Sendable {
    nonisolated enum Position: Equatable, Sendable {
        case nearest
        case top
    }

    let token = UUID()
    let targetID: RemoteFile.ID
    let position: Position
}

struct SFTPFileNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<SFTPFileListItem>
    typealias Renderer = @MainActor (SFTPFileListItem) -> AnyView

    let items: [SFTPFileListItem]
    let scrollRequest: SFTPFileScrollRequest?
    let bottomContentInset: CGFloat
    let onBackgroundClick: @MainActor () -> Void
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [SFTPFileListItem],
        scrollRequest: SFTPFileScrollRequest?,
        bottomContentInset: CGFloat = 0,
        onBackgroundClick: @escaping @MainActor () -> Void,
        @ViewBuilder renderer: @escaping @MainActor (SFTPFileListItem) -> some View
    ) {
        self.items = items
        self.scrollRequest = scrollRequest
        self.bottomContentInset = bottomContentInset
        self.onBackgroundClick = onBackgroundClick
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeListView()
    }

    func updateNSView(_ listView: NSViewType, context: Context) {
        if listView.contentInsets.bottom != bottomContentInset {
            listView.contentInsets.bottom = bottomContentInset
        }
        context.coordinator.update(
            listView: listView,
            items: items,
            scrollRequest: scrollRequest,
            onBackgroundClick: onBackgroundClick,
            renderer: renderer,
            locale: locale,
            colorScheme: colorScheme
        )
    }

    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {
        coordinator.stopObservingClicks()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let content = HostingListContent<SFTPFileListItem>()
        private var lastScrollToken: UUID?
        private var onBackgroundClick: (@MainActor () -> Void)?
        private weak var listView: NSViewType?
        private var clickMonitor: Any?

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            self.listView = listView
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 48
            listView.rows {
                ListRow(HostingListRow.self)
                    .height { _, _ in 48 }
                    .configure { [weak self] row, item, _ in
                        self?.configure(row, item: item)
                    }
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                self?.observeClick(event)
                return event
            }
            return listView
        }

        func update(
            listView: NSViewType,
            items: [SFTPFileListItem],
            scrollRequest: SFTPFileScrollRequest?,
            onBackgroundClick: @escaping @MainActor () -> Void,
            renderer: @escaping Renderer,
            locale: Locale,
            colorScheme: ColorScheme
        ) {
            self.onBackgroundClick = onBackgroundClick
            content.update(
                listView, items: items, renderer: renderer, locale: locale,
                colorScheme: colorScheme, animated: true
            )

            if let request = scrollRequest, request.token != lastScrollToken {
                lastScrollToken = request.token
                listView.scrollToRow(
                    with: SFTPFileListItem.ID.file(request.targetID),
                    at: request.position == .top ? .top : .nearest,
                    animated: false
                )
            }
        }

        private func configure(_ row: HostingListRow, item: SFTPFileListItem) {
            content.configure(row, item: item)
        }

        func stopObservingClicks() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        }

        private func observeClick(_ event: NSEvent) {
            guard let listView, event.window === listView.window else { return }
            let point = listView.convert(event.locationInWindow, from: nil)
            guard listView.bounds.contains(point) else { return }
            var hit = listView.hitTest(point)
            while let current = hit {
                if current is ListRowView { return }
                if current is NSScroller { return }
                if current === listView { break }
                hit = current.superview
            }
            onBackgroundClick?()
        }
    }
}

struct SFTPBrowserView: View {
    nonisolated private enum Layout: Equatable, Sendable {
        case full
        case medium
        case compact

        init(width: CGFloat) {
            if width >= 760 { self = .full } else if width >= 520 { self = .medium } else { self = .compact }
        }
    }

    let sftpChannel: SFTPChannelModel
    let isPaneFocused: Bool
    let focusPane: () -> Void
    let externalFileDrop: LocalFileDropRequest?
    let externalRemoteDrop: SFTPRemoteDropRequest?
    let closePane: () -> Void

    @AppStorage(DesktopSettingsKey.showStatusBar) private var showsStatusBar = true
    @Environment(AppModel.self) private var app
    @Environment(\.locale) private var locale
    @Environment(WindowModel.self) private var window
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameName = ""
    @State private var permissionTarget: RemoteFile?
    @State private var deleteTargets: [RemoteFile] = []
    @State private var conflictPresented = false
    @State private var selectionAnchor: RemoteFile.ID?
    @State private var selectionCursor: RemoteFile.ID?
    @State private var hoveredFileID: RemoteFile.ID?
    @State private var editsPath = false
    @State private var fileScrollRequest: SFTPFileScrollRequest?
    @FocusState private var listFocused: Bool
    @FocusState private var pathFocused: Bool

    @ScaledMetric private var editRowHeight = 76.0
    private var editedFiles: [SFTPEditedFile] { app.sftpEdits.model.modifiedFiles(for: sftpChannel.hostID) }
    private var editOverlayHeight: CGFloat { (editRowHeight + 1) * Double(min(3, editedFiles.count)) }

    private var editUploadOverlay: some View {
        SFTPEditUploadOverlay(
            files: editedFiles, transfers: app.sftpTransfers.sftpTransfers,
            connected: sftpChannel.status == .connected,
            upload: { id, replacing in
                await sftpChannel.uploadEdit(id, using: app.sftpEdits, replacing: replacing)
            },
            resume: { app.sftpTransfers.resume($0) },
            open: { NSWorkspace.shared.open($0) },
            discard: { await app.sftpEdits.discard($0) },
            keepLocalCopy: { source in
                SFTPLocalCopyExporter.present(for: source) {
                    sftpChannel.operationError = $0.localizedDescription
                }
            }
        )
        .padding(.horizontal, 12)
        .padding(
            .bottom, Metrics.StatusBar.overlayClearance(isEnabled: showsStatusBar))
    }

    private var deleteConfirmationMessage: String {
        if deleteTargets.count == 1 {
            return AppLocalization.resolve(AppStrings.SFTP.recursiveDeletionWarning, locale: locale)
        }
        let paths = deleteTargets.prefix(6).map { sftpChannel.displayPath($0.path) }
            .joined(separator: "\n")
        let remainder = max(0, deleteTargets.count - 6)
        return AppStrings.SFTP.deletionMessage(paths: paths, remainingCount: remainder, locale: locale)
    }

    private var conflictTitle: String {
        let count = sftpChannel.conflictCount
        return String(localized: AppStrings.SFTP.existingItemsMessage(count: count))
    }

    /// The density is read from the *proposal* rather than from the browser's
    /// own frame.
    ///
    /// `onGeometryChange` reports the size a view settled at, and this one's
    /// floor is its widest arrangement — so measuring it meant deciding the
    /// arrangement from a number that arrangement had produced, and committing
    /// the answer a layout pass late. A `GeometryReader` reports what the pane
    /// offered no matter what the content does with it, which makes the
    /// threshold a single clean snap instead of one frame drawn at the old
    /// density and the new width.
    ///
    /// The pane floor is 160pt and this chrome cannot compress much below
    /// 260pt, so the content is clipped: a pane dragged past useful truncates
    /// its own path bar rather than drawing over its neighbour.
    var body: some View {
        GeometryReader { proxy in
            let layout = Layout(width: proxy.size.width)
            browser(layout: layout)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        // The file list is held focused by `listFocused`, and SwiftUI restores
        // that focus whenever the view rebuilds — which typing in the titlebar
        // Find field does, because it narrows this very list. Standing the list
        // down keeps the caret where the user is typing.
        .onChange(of: window.isToolbarFindFocused) { _, isFindFocused in
            if isFindFocused { listFocused = false }
        }
        // And again on every restoration, not only on the first. The line above
        // fires once, when the field takes the keyboard; the list then takes it
        // back on the *next* keystroke's rebuild, and on every one after that,
        // with nothing left to notice. Watching the focus itself is what makes
        // the stand-down hold for as long as the field is being typed into.
        .onChange(of: listFocused) { _, isListFocused in
            if isListFocused, window.isToolbarFindFocused { listFocused = false }
        }
    }

    private func browser(layout: Layout) -> some View {
        @Bindable var sftpChannel = sftpChannel
        return ZStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    pathBar(layout: layout)
                    columnHeader(layout: layout)
                }
                .background(TermindColor.windowSurface)

                browserContent(layout: layout)
                    .overlay(alignment: .bottom) { editUploadOverlay }
            }

            if sftpChannel.connectionJourney.isPresented {
                ConnectionJourneyView(
                    journey: sftpChannel.connectionJourney,
                    authenticationPrompt: sftpChannel.pendingAuthentication,
                    hostKey: sftpChannel.pendingHostKey,
                    submitAuthentication: {
                        identityID, username, password, passphrase, keyID, save in
                        sftpChannel.continueAuthentication(
                            identityID: identityID, username: username, password: password,
                            passphrase: passphrase, keyID: keyID, save: save, using: app.hostLibrary
                        )
                    },
                    continueHostKey: {
                        sftpChannel.continueWithTemporaryHostKey($0)
                    },
                    trustHostKey: { sftpChannel.trustAndConnect($0, using: app.hostLibrary) },
                    denyHostKey: {
                        cancelConnection()
                    },
                    retry: { sftpChannel.connect(using: app.hostLibrary) },
                    cancel: cancelConnection,
                    reconnectState: sftpChannel.reconnectState,
                    retryReconnectNow: sftpChannel.retryReconnectNow,
                    stopReconnecting: sftpChannel.stopReconnecting,
                    securityKeySigning: sftpChannel.connection.securityKeySigning,
                    keyboardAuthentication: sftpChannel.connection.keyboardAuthentication
                )
                .zIndex(10)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await app.sftpEdits.recheck() }
        }
        .contextMenu { browserLocationMenu }
        .background(TermindColor.windowSurface)
        .onAppear {
            sftpChannel.bindTransfers(to: app.sftpTransfers)
            sftpChannel.connectIfNeeded(using: app.hostLibrary)
            sftpChannel.startAutomaticRefresh()
        }
        .alert(AppStrings.SFTP.newFolder, isPresented: $newFolderPresented) {
            TextField(AppStrings.SFTP.folderName.swiftUIKey, text: $newFolderName.singleLineText, axis: .horizontal)
                .singleLinePaste()
                .lineLimit(1)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
            Button(AppStrings.Common.create.swiftUIKey) {
                let name = newFolderName
                newFolderName = ""
                Task { await sftpChannel.createFolder(named: name) }
            }
        }
        .alert(
            AppStrings.Common.rename,
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField(AppStrings.Common.name.swiftUIKey, text: $renameName.singleLineText, axis: .horizontal)
                .singleLinePaste().lineLimit(1)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { renameTarget = nil }
            Button(AppStrings.Common.rename.swiftUIKey) {
                guard let target = renameTarget else { return }
                let name = renameName
                renameTarget = nil
                Task { await sftpChannel.rename(target, to: name) }
            }
        }
        .sheet(item: $permissionTarget) { file in
            SFTPEditPermissionsSheet(
                file: file, displayedPath: sftpChannel.displayPath(file.path)
            ) { permissions in
                await sftpChannel.updatePermissions(for: file, to: permissions)
            }
            .allowsApplicationTerminationWhenModal()
        }
        .confirmationDialog(
            deleteTargets.count == 1
                ? AppStrings.SFTP.deleteConfirmation(
                    deleteTargets.first.map { sftpChannel.displayPath($0.path) } ?? ""
                )
                : AppStrings.SFTP.deleteItemsConfirmation(deleteTargets.count),
            isPresented: Binding(
                get: { !deleteTargets.isEmpty },
                set: { if !$0 { deleteTargets = [] } }
            ), titleVisibility: .visible
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                let targets = deleteTargets
                deleteTargets = []
                Task { await sftpChannel.delete(targets) }
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { deleteTargets = [] }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .confirmationDialog(
            conflictTitle,
            isPresented: $conflictPresented, titleVisibility: .visible
        ) {
            Button(AppStrings.SFTP.replace.swiftUIKey) { enqueue(.replace) }
            Button(AppStrings.SFTP.skipExisting.swiftUIKey) { enqueue(.skip) }
            Button(AppStrings.SFTP.keepBoth.swiftUIKey) { enqueue(.keepBoth) }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {
                sftpChannel.cancelPendingBatch()
            }
        } message: {
            Text(AppStrings.SFTP.applyToAllConflicts)
        }
        .alert(
            AppStrings.SFTP.sftpError,
            isPresented: Binding(
                get: { sftpChannel.operationError != nil },
                set: { if !$0 { sftpChannel.operationError = nil } }
            )
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { sftpChannel.operationError = nil }
        } message: {
            Text(sftpChannel.operationError ?? "")
        }
        .background {
            Button("") { beginPathEditing() }
                .termindShortcut("l")
                .disabled(sftpChannel.connectionJourney.isPresented)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func cancelConnection() {
        sftpChannel.disconnect()
        closePane()
    }

    private func pathBar(layout: Layout) -> some View {
        @Bindable var sftpChannel = sftpChannel
        return VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.xs) {
                    navigationButton("chevron.left", help: AppStrings.Common.back, enabled: sftpChannel.canGoBack) {
                        sftpChannel.goBack()
                    }
                    navigationButton("chevron.right", help: AppStrings.SFTP.forward, enabled: sftpChannel.canGoForward)
                    {
                        sftpChannel.goForward()
                    }
                }

                if editsPath {
                    TextField(
                        AppStrings.SFTP.remotePath.swiftUIKey, text: $sftpChannel.pathText.singleLineText,
                        axis: .horizontal
                    )
                    .singleLinePaste().lineLimit(1)
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($pathFocused)
                    .onSubmit { commitPathEditing() }
                    .onKeyPress(.escape) {
                        cancelPathEditing()
                        return .handled
                    }
                } else {
                    breadcrumbs(layout: layout)
                }

                Button(action: chooseUploadItems) {
                    if layout == .full {
                        Label(AppStrings.SFTP.upload.swiftUIKey, systemImage: "arrow.up.doc")
                    } else {
                        Image(systemName: "arrow.up.doc")
                    }
                }
                .disabled(sftpChannel.status != .connected)
                .help(AppStrings.SFTP.upload.swiftUIKey)

                actionsMenu(layout: layout)
            }
            .padding(.horizontal, Metrics.Space.l)
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .onChange(of: pathFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused, editsPath else { return }
            cancelPathEditing()
        }
    }

    private func navigationButton(
        _ symbol: String, help: LocalizedStringResource, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .disabled(!enabled)
        .help(help)
    }

    private func actionsMenu(layout: Layout) -> some View {
        Menu {
            Button(AppStrings.SFTP.newFolder.swiftUIKey, systemImage: MenuSymbol.newFolder) {
                newFolderPresented = true
            }
            .disabled(sftpChannel.status != .connected)
            Button(AppStrings.Common.paste.swiftUIKey, systemImage: MenuSymbol.paste) { pasteRemoteItems() }
                .disabled(sftpChannel.status != .connected || !canPasteRemoteItems)
            Divider()
            Menu(AppStrings.Connections.openWithSsh.swiftUIKey, systemImage: MenuSymbol.ssh) {
                Button(AppStrings.Workspace.inCurrentWorkspace.swiftUIKey, systemImage: MenuSymbol.currentWorkspace) {
                    window.openCompanionSession(from: sftpChannel.id, placement: .currentWorkspace)
                }
                Button(AppStrings.Workspace.inNewWorkspace.swiftUIKey, systemImage: MenuSymbol.newWorkspace) {
                    window.openCompanionSession(from: sftpChannel.id, placement: .newWorkspace)
                }
            }
            .disabled(!window.canOpenCompanionSession(from: sftpChannel.id))
            Button(
                (app.mainWindows.isTransfersWindowOpen
                    ? AppStrings.SFTP.closeTransfers : AppStrings.SFTP.openTransfers).swiftUIKey,
                systemImage: "arrow.up.arrow.down"
            ) {
                app.mainWindows.toggleTransfers()
            }
            Divider()
            if sftpChannel.showsHiddenFiles {
                Button(AppStrings.SFTP.hideHiddenFiles.swiftUIKey, systemImage: MenuSymbol.hideHiddenFiles) {
                    sftpChannel.showsHiddenFiles = false
                }
            } else {
                Button(AppStrings.SFTP.showHiddenFiles.swiftUIKey, systemImage: MenuSymbol.showHiddenFiles) {
                    sftpChannel.showsHiddenFiles = true
                }
            }
            Button(AppStrings.SFTP.editPath.swiftUIKey, systemImage: MenuSymbol.editPath) { beginPathEditing() }
            Button(AppStrings.Common.refresh.swiftUIKey, systemImage: MenuSymbol.refresh) { sftpChannel.reloadNow() }
                .disabled(sftpChannel.status != .connected || sftpChannel.isLoading)
        } label: {
            if layout == .full {
                HStack(spacing: Metrics.Space.s) {
                    Image(systemName: MenuSymbol.actions)
                    Text(AppStrings.Common.actions)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .help(AppStrings.Common.actions.swiftUIKey)
    }

    private func breadcrumbs(layout: Layout) -> some View {
        let components = RemotePath.displayedComponents(
            of: sftpChannel.path, home: sftpChannel.homeResolution
        )
        let tailCount =
            switch layout {
            case .full: 3
            case .medium: 2
            case .compact: 1
            }
        let collapses = components.count > tailCount + 1
        let visible = collapses ? Array(components.suffix(tailCount)) : Array(components.dropFirst())
        let hidden =
            collapses
            ? Array(components.dropFirst().dropLast(tailCount))
            : []

        return Button(action: beginPathEditing) {
            HStack(spacing: Metrics.Space.xs) {
                breadcrumbLabel(components[0], isRoot: true)

                if !hidden.isEmpty {
                    breadcrumbSeparator
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }

                ForEach(visible) { component in
                    breadcrumbSeparator
                    breadcrumbLabel(component, isRoot: false)
                }

                Spacer(minLength: Metrics.Space.s)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(sftpChannel.displayPath(sftpChannel.path))
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func breadcrumbLabel(
        _ component: RemotePath.Component, isRoot: Bool
    ) -> some View {
        HStack(spacing: Metrics.Space.s) {
            if isRoot { Image(systemName: "folder.fill").foregroundStyle(.tint) }
            Text(component.name)
                .font(.body.weight(component.path == sftpChannel.path ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Metrics.Space.xs)
        .frame(minHeight: 28)
    }

    private func beginPathEditing() {
        sftpChannel.pathText = sftpChannel.path
        editsPath = true
        Task { @MainActor in pathFocused = true }
    }

    private func commitPathEditing() {
        sftpChannel.commitPathText()
        editsPath = false
        pathFocused = false
    }

    private func cancelPathEditing() {
        sftpChannel.pathText = sftpChannel.path
        editsPath = false
        pathFocused = false
    }

    @ViewBuilder
    private func browserContent(layout: Layout) -> some View {
        ZStack {
            fileList(layout: layout)

            if sftpChannel.status == .disconnected, !sftpChannel.connectionJourney.isPresented {
                VStack(spacing: Metrics.Space.l) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text(AppStrings.Connections.notConnected).foregroundStyle(.secondary)
                    Button(AppStrings.Common.connect.swiftUIKey) { sftpChannel.connect(using: app.hostLibrary) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TermindColor.windowSurface)
            } else if sftpChannel.files.isEmpty, sftpChannel.isLoading {
                centeredState(AppStrings.SFTP.loading, symbol: "arrow.triangle.2.circlepath", progress: true)
                    .background(TermindColor.windowSurface)
            } else if sftpChannel.files.isEmpty, sftpChannel.status == .connected {
                centeredState(AppStrings.SFTP.thisFolderIsEmpty, symbol: "folder", progress: false)
                    .background(TermindColor.windowSurface)
            } else if sftpChannel.visibleRows.isEmpty, !sftpChannel.query.isEmpty {
                ContentUnavailableView.search(text: sftpChannel.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TermindColor.windowSurface)
            }
        }
        .onCopyCommand { remoteCopyProviders(for: sftpChannel.selectedFiles) }
        .onPasteCommand(of: [.termindSFTPItems]) { providers in
            _ = receiveRemoteItemProviders(providers)
        }
        .onChange(of: externalFileDrop?.id) {
            guard let externalFileDrop else { return }
            _ = receiveDroppedURLs(externalFileDrop.urls)
        }
        .onChange(of: externalRemoteDrop?.id) {
            guard let externalRemoteDrop else { return }
            receiveRemoteDrop(externalRemoteDrop.data)
        }
    }

    @ViewBuilder
    private var browserLocationMenu: some View {
        Button(AppStrings.Common.paste.swiftUIKey, systemImage: MenuSymbol.paste) { pasteRemoteItems() }
            .disabled(sftpChannel.status != .connected || !canPasteRemoteItems)
        Divider()
        Button(AppStrings.SFTP.newFolder.swiftUIKey, systemImage: MenuSymbol.newFolder) { newFolderPresented = true }
            .disabled(sftpChannel.status != .connected)
        Button(AppStrings.SFTP.upload.swiftUIKey, systemImage: MenuSymbol.upload) { chooseUploadItems() }
            .disabled(sftpChannel.status != .connected)
        Button(AppStrings.Common.refresh.swiftUIKey, systemImage: MenuSymbol.refresh) { sftpChannel.reloadNow() }
            .disabled(sftpChannel.status != .connected || sftpChannel.isLoading)
    }

    private func fileList(layout: Layout) -> some View {
        SFTPFileNativeList(
            items: fileListItems(layout: layout),
            scrollRequest: fileScrollRequest,
            bottomContentInset: editedFiles.isEmpty
                ? 0
                : editOverlayHeight
                    + Metrics.StatusBar.overlayClearance(isEnabled: showsStatusBar)
                    + 12,
            onBackgroundClick: clearFileSelection
        ) { item in
            fileListRow(item, layout: layout)
        }
        .focusable(!window.isToolbarFindFocused)
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) {
            moveSelection(
                by: -1, extending: NSEvent.modifierFlags.contains(.shift)
            )
        }
        .onKeyPress(.downArrow) {
            moveSelection(
                by: 1, extending: NSEvent.modifierFlags.contains(.shift)
            )
        }
        .onKeyPress(.return) {
            guard let file = keyboardTarget else { return .ignored }
            primaryAction(file)
            return .handled
        }
        .onKeyPress("a", phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            sftpChannel.selection = Set(sftpChannel.filteredFiles.map(\.id))
            selectionAnchor = sftpChannel.filteredFiles.first?.id
            selectionCursor = sftpChannel.filteredFiles.last?.id
            return .handled
        }
        .background(TermindColor.windowSurface)
    }

    private func fileListItems(layout: Layout) -> [SFTPFileListItem] {
        let emphasized =
            isPaneFocused && !pathFocused
            && controlActiveState == .key
        let layoutKey: Int
        switch layout {
        case .full: layoutKey = 2
        case .medium: layoutKey = 1
        case .compact: layoutKey = 0
        }
        var items = sftpChannel.visibleRows.map { row in
            SFTPFileListItem(
                row: row, parentPath: nil,
                isSelected: sftpChannel.selection.contains(row.id),
                isEmphasized: emphasized,
                isHovered: hoveredFileID == row.id,
                layoutKey: layoutKey
            )
        }
        if sftpChannel.path != "/" {
            items.insert(
                SFTPFileListItem(
                    row: nil, parentPath: RemotePath.parent(of: sftpChannel.path),
                    isSelected: false, isEmphasized: false, isHovered: false,
                    layoutKey: layoutKey
                ),
                at: 0
            )
        }
        return items
    }

    @ViewBuilder
    private func fileListRow(_ item: SFTPFileListItem, layout: Layout) -> some View {
        if let row = item.row {
            fileRow(row, layout: layout)
        } else if let parentPath = item.parentPath {
            parentDirectoryRow(path: parentPath)
        }
    }

    private func parentDirectoryRow(path: String) -> some View {
        HStack(spacing: Metrics.Space.m) {
            Image(systemName: "folder.fill")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(verbatim: "..")
                .font(.body.weight(.medium))
            Spacer()
        }
        .padding(.leading, Metrics.Space.xxl)
        .padding(.trailing, Metrics.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(.rect)
        .onTapGesture {
            focusPane()
            focusListForUserGesture()
            if NSApp.currentEvent?.clickCount == 2 { sftpChannel.navigate(to: path) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppStrings.SFTP.parentDirectory.swiftUIKey)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { sftpChannel.navigate(to: path) }
    }

    private func clearFileSelection() {
        focusPane()
        sftpChannel.selection.removeAll()
        selectionAnchor = nil
        selectionCursor = nil
        focusListForUserGesture()
    }

    /// Clicking in this list is the user taking the keyboard back off the
    /// titlebar Find field, and is the only legitimate way the list gains focus
    /// while that field is being typed into.
    ///
    /// Saying so here is what lets the guard in `body` treat every *other*
    /// restoration as what it is — a rebuild handing focus back to a view that
    /// nobody asked to focus.
    private func focusListForUserGesture() {
        window.isToolbarFindFocused = false
        listFocused = true
    }

    private func columnHeader(layout: Layout) -> some View {
        HStack(spacing: 0) {
            sortHeader(AppStrings.Common.name, field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)

            if layout != .compact {
                sortHeader(AppStrings.SFTP.dateModified, field: .modified, separated: true)
                    .frame(width: 220, alignment: .leading)
            }
            if layout == .full {
                sortHeader(AppStrings.Common.size, field: .size, separated: true)
                    .frame(width: 150, alignment: .leading)
                sortHeader(AppStrings.Common.kind, field: .kind, separated: true)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .padding(.leading, Metrics.Space.xxl)
        .padding(.trailing, Metrics.Space.xl)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Divider().opacity(0.7) }
    }

    private func sortHeader(
        _ title: LocalizedStringResource, field: RemoteFileSortField, separated: Bool = false
    ) -> some View {
        let isSorted = sftpChannel.sortField == field
        return Button {
            sftpChannel.sort(by: field)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                Text(title).font(.body.weight(isSorted ? .semibold : .regular))
                if isSorted {
                    Image(
                        systemName: sftpChannel.sortDirection == .ascending
                            ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.semibold))
                }
                Spacer(minLength: Metrics.Space.s)
            }
            .padding(.horizontal, Metrics.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if separated {
                Rectangle().fill(.quaternary.opacity(0.55)).frame(width: 1)
            }
        }
    }

    private func fileRow(_ row: SFTPRow, layout: Layout) -> some View {
        let file = row.file
        let selected = sftpChannel.selection.contains(file.id)
        // In a split workspace the pane owns durable focus. SwiftUI can clear
        // the ScrollView's FocusState while the outer pane handles the same
        // click even though this remains the active pane. Text editing and an
        // inactive window still deliberately use the subdued selection style.
        let emphasized =
            selected && isPaneFocused && !pathFocused
            && controlActiveState == .key
        return HStack(spacing: 0) {
            nameColumn(row, layout: layout, emphasized: emphasized)
                .frame(maxWidth: .infinity, alignment: .leading)

            if layout != .compact {
                metadataText(row.modifiedText, emphasized: emphasized)
                    .frame(width: 220, alignment: .leading)
            }
            if layout == .full {
                metadataText(row.sizeText, emphasized: emphasized, monospaced: true)
                    .frame(width: 150, alignment: .leading)
                metadataText(row.kindText, emphasized: emphasized)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .padding(.leading, Metrics.Space.xxl)
        .padding(.trailing, Metrics.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(rowBackground(selected: selected, emphasized: emphasized, file: file))
        .contentShape(.rect)
        .onTapGesture {
            select(file)
            if NSApp.currentEvent?.clickCount == 2 { primaryAction(file) }
        }
        .onHover { hovering in hoveredFileID = hovering ? file.id : nil }
        .onDrag { remoteDragProvider(for: file) }
        .overlay {
            NativeRowContextMenu(
                entries: {
                    selectForContextMenu(file)
                    return fileMenu(file)
                },
                isPresented: .constant(false)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .opacity(file.isHidden && !selected ? 0.55 : 1)
    }

    private func nameColumn(
        _ row: SFTPRow, layout: Layout, emphasized: Bool
    ) -> some View {
        let file = row.file
        return HStack(spacing: Metrics.Space.m) {
            Image(systemName: file.kind.symbol)
                .font(.system(size: file.isDirectory ? 23 : 20, weight: .regular))
                .foregroundStyle(iconStyle(for: file, emphasized: emphasized))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(
                        emphasized
                            ? AnyShapeStyle(TermindColor.selectedForeground)
                            : AnyShapeStyle(.primary)
                    )
                    .lineLimit(1)
                Text(secondaryText(for: row, layout: layout))
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        emphasized
                            ? AnyShapeStyle(TermindColor.selectedForeground.opacity(0.78))
                            : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(1)
            }
            .padding(.vertical, Metrics.Space.xs)
        }
    }

    private func metadataText(
        _ value: String, emphasized: Bool, monospaced: Bool = false
    ) -> some View {
        Text(value)
            .font(monospaced ? .body.monospacedDigit() : .body)
            .foregroundStyle(
                emphasized
                    ? AnyShapeStyle(TermindColor.selectedForeground.opacity(0.88))
                    : AnyShapeStyle(.secondary)
            )
            .lineLimit(1)
            .padding(.horizontal, Metrics.Space.l)
    }

    private func rowBackground(
        selected: Bool, emphasized: Bool, file: RemoteFile
    ) -> AnyShapeStyle {
        if emphasized { return AnyShapeStyle(Color.accentColor) }
        if selected {
            return AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        }
        if hoveredFileID == file.id { return AnyShapeStyle(Color.primary.opacity(0.045)) }
        return AnyShapeStyle(Color.clear)
    }

    private func iconStyle(for file: RemoteFile, emphasized: Bool) -> AnyShapeStyle {
        if emphasized {
            return AnyShapeStyle(
                TermindColor.selectedForeground.opacity(file.isDirectory ? 0.82 : 0.72)
            )
        }
        return file.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }

    /// Whatever the columns to the right of the name are not showing at this
    /// density, so a narrow browser is still a complete listing. Assembled from
    /// `SFTPRow`'s already-rendered strings — no formatter runs here.
    private func secondaryText(for row: SFTPRow, layout: Layout) -> String {
        switch layout {
        case .full:
            return row.permissionText
        case .medium:
            return [row.permissionText, row.kindText, row.sizeText].filter { !$0.isEmpty }
                .joined(separator: "  ·  ")
        case .compact:
            return [
                row.kindText, row.sizeText, row.modifiedText, row.permissionText,
            ].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        }
    }

    private func fileMenu(_ file: RemoteFile) -> [NativeMenuEntry] {
        // Capture targets once, before AppKit starts tracking the menu. Later
        // selection, hover and directory updates must not retarget its actions.
        let targets = menuTargets(for: file)
        return SFTPFileContextMenu(
            file: file, targets: targets,
            connected: sftpChannel.status == .connected,
            allowsRemoteMutations: sftpChannel.allowsRemoteMutations,
            canPaste: canPasteRemoteItems, isLoading: sftpChannel.isLoading,
            locale: locale
        ).entries { action in
            switch action {
            case .open: primaryAction(file)
            case .openWith(let application): open(file, with: application)
            case .download: chooseDownloadDestination(for: targets)
            case .copy: copyRemoteItems(targets)
            case .copyNames: copyToPasteboard(targets.map(\.name).joined(separator: "\n"))
            case .copyPaths:
                copyToPasteboard(targets.map { RemoteShellCommand.escapeArgument($0.path) }.joined(separator: " "))
            case .paste: pasteRemoteItems()
            case .rename:
                renameTarget = file
                renameName = file.name
            case .editPermissions: permissionTarget = file
            case .delete: deleteTargets = targets
            case .newFolder: newFolderPresented = true
            case .upload: chooseUploadItems()
            case .refresh: sftpChannel.reloadNow()
            }
        }
    }

    private func primaryAction(_ file: RemoteFile) {
        if file.isDirectory {
            sftpChannel.navigate(to: file.path)
        } else {
            sftpChannel.open(file, coordinator: app.sftpTransfers, edits: app.sftpEdits) {
                [history = sftpChannel.history] localURL in
                if NSWorkspace.shared.open(localURL) {
                    history.record(kind: .file, path: file.path)
                }
            }
        }
    }

    private func open(_ file: RemoteFile, with application: URL) {
        sftpChannel.open(file, coordinator: app.sftpTransfers, edits: app.sftpEdits) {
            [history = sftpChannel.history] localURL in
            Task {
                do {
                    try await SFTPApplicationOpener.open(localURL, with: application)
                    history.record(kind: .file, path: file.path)
                } catch { sftpChannel.operationError = error.localizedDescription }
            }
        }
    }

    private func menuTargets(for file: RemoteFile) -> [RemoteFile] {
        sftpChannel.menuTargets(for: file)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func select(_ file: RemoteFile) {
        focusPane()
        focusListForUserGesture()
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
            let anchor = selectionAnchor ?? sftpChannel.selection.first,
            let anchorIndex = sftpChannel.filteredFiles.firstIndex(where: { $0.id == anchor }),
            let fileIndex = sftpChannel.filteredFiles.firstIndex(where: { $0.id == file.id })
        {
            let bounds = min(anchorIndex, fileIndex)...max(anchorIndex, fileIndex)
            let range = Set(sftpChannel.filteredFiles[bounds].map(\.id))
            if modifiers.contains(.command) {
                sftpChannel.selection.formUnion(range)
            } else {
                sftpChannel.selection = range
            }
            selectionCursor = file.id
            return
        }

        selectionAnchor = file.id
        selectionCursor = file.id
        if modifiers.contains(.command) {
            if sftpChannel.selection.contains(file.id) {
                sftpChannel.selection.remove(file.id)
            } else {
                sftpChannel.selection.insert(file.id)
            }
        } else {
            sftpChannel.selection = [file.id]
        }
    }

    private func selectForContextMenu(_ file: RemoteFile) {
        guard sftpChannel.selectForContextMenu(file) else { return }
        selectionAnchor = file.id
        selectionCursor = file.id
        focusListForUserGesture()
    }

    private var keyboardTarget: RemoteFile? {
        let target = selectionCursor ?? sftpChannel.selectedFiles.first?.id
        return target.flatMap { id in sftpChannel.filteredFiles.first { $0.id == id } }
    }

    private func moveSelection(
        by offset: Int, extending: Bool
    ) -> KeyPress.Result {
        let files = sftpChannel.filteredFiles
        guard !files.isEmpty else { return .ignored }
        let currentID = selectionCursor ?? sftpChannel.selectedFiles.first?.id
        let currentIndex =
            currentID.flatMap { id in files.firstIndex { $0.id == id } }
            ?? (offset > 0 ? -1 : files.count)
        let targetIndex = min(max(currentIndex + offset, 0), files.count - 1)
        let target = files[targetIndex]

        if extending {
            let anchorID = selectionAnchor ?? currentID ?? target.id
            let anchorIndex = files.firstIndex { $0.id == anchorID } ?? targetIndex
            let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            sftpChannel.selection = Set(files[bounds].map(\.id))
            selectionAnchor = anchorID
        } else {
            sftpChannel.selection = [target.id]
            selectionAnchor = target.id
        }
        selectionCursor = target.id
        fileScrollRequest = SFTPFileScrollRequest(
            targetID: target.id,
            position: targetIndex == 0 ? .top : .nearest
        )
        return .handled
    }

    private func remoteDragProvider(for file: RemoteFile) -> NSItemProvider {
        let targets = menuTargets(for: file)
        guard let source = sftpChannel.remoteCopySource(for: targets) else {
            return NSItemProvider()
        }
        let payload = app.sftpTransfers.registerRemoteCopySource(source)
        let provider =
            file.isDirectory
            ? NSItemProvider()
            : Self.promisedFileProvider(
                for: file, sftpChannel: sftpChannel, coordinator: app.sftpTransfers
            )
        Self.register(payload, on: provider)
        return provider
    }

    private func remoteCopyProviders(for files: [RemoteFile]) -> [NSItemProvider] {
        guard let source = sftpChannel.remoteCopySource(for: files) else { return [] }
        let payload = app.sftpTransfers.registerRemoteCopySource(source)
        let provider = NSItemProvider()
        Self.register(payload, on: provider)
        return [provider]
    }

    private func copyRemoteItems(_ files: [RemoteFile]) {
        guard let source = sftpChannel.remoteCopySource(for: files) else { return }
        let payload = app.sftpTransfers.registerRemoteCopySource(source)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier))
        item.setString(files.map(\.name).joined(separator: "\n"), forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    private var canPasteRemoteItems: Bool {
        guard let payload = remotePayloadOnPasteboard else { return false }
        return app.sftpTransfers.remoteCopySource(for: payload) != nil
    }

    private func pasteRemoteItems() {
        guard let payload = remotePayloadOnPasteboard,
            app.sftpTransfers.remoteCopySource(for: payload) != nil
        else { return }
        prepareRemoteItems(payload)
    }

    private var remotePayloadOnPasteboard: SFTPRemoteItemsPayload? {
        let type = NSPasteboard.PasteboardType(UTType.termindSFTPItems.identifier)
        guard let data = NSPasteboard.general.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(SFTPRemoteItemsPayload.self, from: data)
    }

    private static func register(
        _ payload: SFTPRemoteItemsPayload, on provider: NSItemProvider
    ) {
        let data = try? JSONEncoder().encode(payload)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.termindSFTPItems.identifier, visibility: .ownProcess
        ) { completion in
            completion(
                data, data == nil ? SFTPError.operation(String(localized: AppStrings.SFTP.unableToCopyItems)) : nil)
            return nil
        }
    }

    static func promisedFileProvider(
        for file: RemoteFile, sftpChannel: SFTPChannelModel,
        coordinator: SFTPTransferCoordinator
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [], visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Termind", isDirectory: true)
                    .appendingPathComponent("Drag", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                } catch {
                    completion(nil, false, error)
                    return
                }
                let localURL = directory.appendingPathComponent(file.name)
                sftpChannel.downloadPromisedFile(
                    file, to: directory, coordinator: coordinator
                ) { error in
                    progress.completedUnitCount = 1
                    completion(error == nil ? localURL : nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    private func centeredState(_ title: LocalizedStringResource, symbol: String, progress: Bool) -> some View {
        VStack(spacing: Metrics.Space.l) {
            if progress {
                ProgressView()
            } else {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
            }
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseUploadItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            await sftpChannel.prepareUpload(panel.urls)
            finishPreparingBatch()
        }
    }

    private func receiveDroppedURLs(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard sftpChannel.status == .connected, !files.isEmpty else { return false }
        Task {
            await sftpChannel.prepareUpload(files)
            finishPreparingBatch()
        }
        return true
    }

    private func receiveRemoteItemProviders(_ providers: [NSItemProvider]) -> Bool {
        guard sftpChannel.status == .connected,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.termindSFTPItems.identifier)
            })
        else { return false }
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.termindSFTPItems.identifier
        ) { data, error in
            Task { @MainActor in
                if let error {
                    sftpChannel.operationError = error.localizedDescription
                    return
                }
                guard let data,
                    let payload = try? JSONDecoder().decode(
                        SFTPRemoteItemsPayload.self, from: data
                    )
                else {
                    sftpChannel.operationError = String(localized: AppStrings.SFTP.theCopiedSftpItemsAreInvalid)
                    return
                }
                prepareRemoteItems(payload)
            }
        }
        return true
    }

    private func receiveRemoteDrop(_ data: Data) {
        guard sftpChannel.status == .connected else { return }
        guard let payload = try? JSONDecoder().decode(SFTPRemoteItemsPayload.self, from: data)
        else {
            sftpChannel.operationError = String(localized: AppStrings.SFTP.theCopiedSftpItemsAreInvalid)
            return
        }
        prepareRemoteItems(payload)
    }

    private func prepareRemoteItems(_ payload: SFTPRemoteItemsPayload) {
        Task {
            await sftpChannel.prepareRemoteCopy(payload, coordinator: app.sftpTransfers)
            finishPreparingBatch()
        }
    }

    private func chooseDownloadDestination(for files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            await sftpChannel.prepareDownload(files, to: directory)
            finishPreparingBatch()
        }
    }

    private func finishPreparingBatch() {
        guard sftpChannel.hasPendingBatch else { return }
        if sftpChannel.conflictCount > 0 { conflictPresented = true } else { enqueue(.replace) }
    }

    private func enqueue(_ policy: TransferConflictPolicy) {
        Task {
            if sftpChannel.pendingRemoteCopyBatch != nil {
                await sftpChannel.enqueuePendingRemoteCopy(
                    policy: policy, coordinator: app.sftpTransfers
                )
            } else {
                await sftpChannel.enqueuePending(policy: policy, coordinator: app.sftpTransfers)
            }
        }
    }
}

private struct SFTPEditPermissionsSheet: View {
    let file: RemoteFile
    let displayedPath: String
    let save: (UInt32) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var modeFieldFocused: Bool
    @State private var draft: SFTPPermissionDraft
    @State private var isSaving = false

    init(
        file: RemoteFile, displayedPath: String,
        save: @escaping (UInt32) async -> Bool
    ) {
        self.file = file
        self.displayedPath = displayedPath
        self.save = save
        _draft = State(initialValue: SFTPPermissionDraft(permissions: file.permissions))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                HStack(spacing: Metrics.Space.l) {
                    Text(displayedPath)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(displayedPath)
                    Spacer(minLength: Metrics.Space.xl)
                    TextField(AppStrings.SFTP.mode.swiftUIKey, text: modeText.singleLineText, axis: .horizontal)
                        .singleLinePaste().lineLimit(1)
                        .labelsHidden()
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                        .focused($modeFieldFocused)
                        .accessibilityLabel(AppStrings.SFTP.octalPermissions.swiftUIKey)
                }

                permissionGrid

                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Text(AppStrings.SFTP.ownership).font(.headline)
                    ownershipRow(AppStrings.SFTP.uid, value: file.ownerUID)
                    Divider()
                    ownershipRow(AppStrings.SFTP.gid, value: file.ownerGID)
                }
            }
            .padding(Metrics.Space.xxl)
        }
        .frame(width: 520)
        .background(TermindColor.windowSurface)
        .disabled(isSaving)
        .onChange(of: modeFieldFocused) { _, focused in
            if !focused { draft.normalizeText() }
        }
    }

    private var topBar: some View {
        HStack {
            glassActionButton(AppStrings.Common.cancel, symbol: "xmark", identifier: "sftp-permissions.cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            glassActionButton(
                AppStrings.Common.save, symbol: "checkmark", identifier: "sftp-permissions.save",
                showsProgress: isSaving
            ) {
                Task { await commit() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canSave || isSaving)
        }
        .frame(maxWidth: .infinity)
        .overlay {
            Text(AppStrings.SFTP.editPermissions).font(.headline)
        }
        .padding(.horizontal, Metrics.Space.xl)
        .padding(.top, Metrics.Space.l)
        .padding(.bottom, Metrics.Space.s)
        .accessibilityElement(children: .contain)
    }

    private func glassActionButton(
        _ label: LocalizedStringResource,
        symbol: String,
        identifier: String,
        showsProgress: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Label(label, systemImage: symbol)
                    .labelStyle(.iconOnly)
                    .opacity(showsProgress ? 0 : 1)
                if showsProgress {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 30, height: 30)
            .contentShape(.circle)
            .accessibilityIdentifier(identifier)
        }
        .accessibilityIdentifier(identifier)
        .buttonStyle(.plain)
        .termindInputAwareFocusEffect()
        .termindGlassCircle(isInteractive: true)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var modeText: Binding<String> {
        Binding(
            get: { draft.text },
            set: { _ = draft.accept($0) }
        )
    }

    private var permissionGrid: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text(AppStrings.SFTP.fileAccess).font(.headline)
            UnixPermissionGrid(draft: $draft, horizontalSpacing: Metrics.Space.xxl, verticalSpacing: Metrics.Space.l)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.Space.s)
        }
    }

    private func ownershipRow(_ label: LocalizedStringResource, value: UInt32) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.formatted())
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Metrics.Space.xs)
    }

    @MainActor
    private func commit() async {
        guard !isSaving, let permissions = draft.parsedMode, draft.canSave else { return }
        modeFieldFocused = false
        isSaving = true
        if await save(permissions) {
            dismiss()
        } else {
            isSaving = false
        }
    }
}
