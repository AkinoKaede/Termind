import SwiftUI
import UniformTypeIdentifiers
import ListViewKit

#if canImport(AppKit)
    import AppKit
#endif

nonisolated struct SFTPFileListItem: Identifiable, Hashable, Sendable {
    let row: SFTPRow
    let isSelected: Bool
    let isEmphasized: Bool
    let isHovered: Bool
    let layoutKey: Int

    var id: RemoteFile.ID { row.id }
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

private struct SFTPFileNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<SFTPFileListItem>
    typealias Renderer = @MainActor (SFTPFileListItem) -> AnyView

    let items: [SFTPFileListItem]
    let scrollRequest: SFTPFileScrollRequest?
    let onBackgroundClick: @MainActor () -> Void
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [SFTPFileListItem],
        scrollRequest: SFTPFileScrollRequest?,
        onBackgroundClick: @escaping @MainActor () -> Void,
        @ViewBuilder renderer: @escaping @MainActor (SFTPFileListItem) -> some View
    ) {
        self.items = items
        self.scrollRequest = scrollRequest
        self.onBackgroundClick = onBackgroundClick
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        context.coordinator.makeListView()
    }

    func updateNSView(_ listView: NSViewType, context: Context) {
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
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [SFTPFileListItem] = []
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
                ListRow(SFTPFileHostingRow.self)
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
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            self.onBackgroundClick = onBackgroundClick

            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items)
            }
            content = items

            if let request = scrollRequest, request.token != lastScrollToken {
                lastScrollToken = request.token
                listView.scrollToRow(
                    with: request.targetID,
                    at: request.position == .top ? .top : .nearest,
                    animated: false
                )
            }
        }

        private func configure(_ row: SFTPFileHostingRow, item: SFTPFileListItem) {
            guard let renderer else { return }
            let content = renderer(item)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(content))
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

@MainActor
private final class SFTPFileHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView.rootView = AnyView(EmptyView())
    }

    func configure(rootView: AnyView) {
        hostingView.rootView = rootView
    }
}

struct SFTPBrowserView: View {
    nonisolated private enum Layout: Equatable, Sendable {
        case full
        case medium
        case compact

        init(width: CGFloat) {
            if width >= 760 { self = .full }
            else if width >= 520 { self = .medium }
            else { self = .compact }
        }
    }

    let sftpSession: SFTPSessionModel
    let isPaneFocused: Bool
    let focusPane: () -> Void
    let externalFileDrop: LocalFileDropRequest?
    let isExternalFileDropTargeted: Bool
    let closePane: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameName = ""
    @State private var permissionTarget: RemoteFile?
    @State private var deleteTargets: [RemoteFile] = []
    @State private var conflictPresented = false
    @State private var isRemoteDropTargeted = false
    @State private var selectionAnchor: RemoteFile.ID?
    @State private var selectionCursor: RemoteFile.ID?
    @State private var hoveredFileID: RemoteFile.ID?
    @State private var editsPath = false
    @State private var showsCompactSearch = false
    @State private var fileScrollRequest: SFTPFileScrollRequest?
    @FocusState private var listFocused: Bool
    @FocusState private var pathFocused: Bool
    @FocusState private var searchFocused: Bool

    private var deleteConfirmationMessage: String {
        let paths = deleteTargets.prefix(6).map(\.path).joined(separator: "\n")
        let remainder = max(0, deleteTargets.count - 6)
        let suffix = remainder > 0 ? "\nand \(remainder) more" : ""
        return "\(paths)\(suffix)\n\nDirectories are deleted recursively. This cannot be undone."
    }

    private var conflictTitle: String {
        let count = sftpSession.conflictCount
        return count == 1
            ? String(localized: "1 item already exists")
            : String(localized: "\(count) items already exist")
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
                .onChange(of: layout) { _, density in
                    if density == .full { showsCompactSearch = false }
                    else if !sftpSession.query.isEmpty { showsCompactSearch = true }
                }
        }
    }

    private func browser(layout: Layout) -> some View {
        @Bindable var sftpSession = sftpSession
        return ZStack {
            VStack(spacing: 0) {
                pathBar(layout: layout)
                browserContent(layout: layout)
            }

            if sftpSession.connectionJourney.isPresented {
                SSHConnectionJourneyView(
                    journey: sftpSession.connectionJourney,
                    authenticationPrompt: sftpSession.pendingAuthentication,
                    hostKey: sftpSession.pendingHostKey,
                    submitAuthentication: {
                        identityID, username, password, passphrase, keyID, save in
                        sftpSession.continueAuthentication(
                            identityID: identityID, username: username, password: password,
                            passphrase: passphrase, keyID: keyID, save: save, using: app.transfers
                        )
                    },
                    continueHostKey: {
                        sftpSession.continueWithTemporaryHostKey($0, using: app.transfers)
                    },
                    trustHostKey: { sftpSession.trustAndConnect($0, using: app.transfers) },
                    denyHostKey: {
                        cancelConnection()
                    },
                    retry: { sftpSession.connect(using: app.transfers) },
                    cancel: cancelConnection,
                    reconnectState: sftpSession.reconnectState,
                    retryReconnectNow: sftpSession.retryReconnectNow,
                    stopReconnecting: sftpSession.stopReconnecting
                )
                .zIndex(10)
            }
        }
        .contextMenu { browserLocationMenu }
        .background(.background)
        .onAppear {
            sftpSession.bindTransfers(to: app.sftpTransfers)
            if sftpSession.status == .disconnected {
                sftpSession.connect(using: app.transfers)
            } else {
                sftpSession.startAutomaticRefresh()
            }
        }
        .alert("New Folder", isPresented: $newFolderPresented) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await sftpSession.createFolder(named: name) }
            }
        }
        .alert(
            "Rename",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                guard let target = renameTarget else { return }
                let name = renameName
                renameTarget = nil
                Task { await sftpSession.rename(target, to: name) }
            }
        }
        .sheet(item: $permissionTarget) { file in
            SFTPEditPermissionsSheet(file: file) { permissions in
                await sftpSession.updatePermissions(for: file, to: permissions)
            }
        }
        .confirmationDialog(
            deleteTargets.count == 1
                ? "Delete \(deleteTargets.first?.path ?? "")?"
                : "Delete \(deleteTargets.count) items?",
            isPresented: Binding(
                get: { !deleteTargets.isEmpty },
                set: { if !$0 { deleteTargets = [] } }
            ), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let targets = deleteTargets
                deleteTargets = []
                Task { await sftpSession.delete(targets) }
            }
            Button("Cancel", role: .cancel) { deleteTargets = [] }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .confirmationDialog(
            conflictTitle,
            isPresented: $conflictPresented, titleVisibility: .visible
        ) {
            Button("Replace") { enqueue(.replace) }
            Button("Skip Existing") { enqueue(.skip) }
            Button("Keep Both") { enqueue(.keepBoth) }
            Button("Cancel", role: .cancel) {
                sftpSession.pendingBatch = nil
                sftpSession.pendingRemoteCopyBatch = nil
            }
        } message: {
            Text("Use this choice for all conflicts in this batch.")
        }
        .alert(
            "SFTP Error",
            isPresented: Binding(
                get: { sftpSession.operationError != nil },
                set: { if !$0 { sftpSession.operationError = nil } }
            )
        ) {
            Button("OK") { sftpSession.operationError = nil }
        } message: {
            Text(sftpSession.operationError ?? "")
        }
        .background {
            Button("") { beginPathEditing() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(sftpSession.connectionJourney.isPresented)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func cancelConnection() {
        sftpSession.disconnect()
        closePane()
    }

    private func pathBar(layout: Layout) -> some View {
        @Bindable var sftpSession = sftpSession
        return VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.xs) {
                    navigationButton("chevron.left", help: "Back", enabled: sftpSession.canGoBack) {
                        sftpSession.goBack()
                    }
                    navigationButton("chevron.right", help: "Forward", enabled: sftpSession.canGoForward) {
                        sftpSession.goForward()
                    }
                }

                if editsPath {
                    TextField("Remote Path", text: $sftpSession.pathText)
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

                if layout == .full {
                    TermindSearchField(
                        text: $sftpSession.query, prompt: "Filter", density: .compact,
                        externalFocus: $searchFocused
                    )
                    .frame(width: 180)
                } else {
                    Button {
                        showsCompactSearch.toggle()
                        if showsCompactSearch {
                            Task { @MainActor in searchFocused = true }
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Filter")
                }

                Button(action: chooseUploadItems) {
                    if layout == .full {
                        Label("Upload", systemImage: "arrow.up.doc")
                    } else {
                        Image(systemName: "arrow.up.doc")
                    }
                }
                .disabled(sftpSession.status != .connected)
                .help("Upload")

                actionsMenu(layout: layout)
            }
            .padding(.horizontal, Metrics.Space.l)
            .frame(height: 48)

            if layout != .full, showsCompactSearch {
                TermindSearchField(
                    text: $sftpSession.query, prompt: "Filter", density: .compact,
                    externalFocus: $searchFocused
                )
                .padding(.horizontal, Metrics.Space.l)
                .padding(.bottom, Metrics.Space.m)
            }
        }
        .buttonStyle(.plain)
        .background(.background)
        .onChange(of: pathFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused, editsPath else { return }
            cancelPathEditing()
        }
    }

    private func navigationButton(
        _ symbol: String, help: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void
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
            Button("New Folder") { newFolderPresented = true }
                .disabled(sftpSession.status != .connected)
            Button("Paste") { pasteRemoteItems() }
                .disabled(sftpSession.status != .connected || !canPasteRemoteItems)
            Divider()
            if sftpSession.showsHiddenFiles {
                Button("Hide Hidden Files") { sftpSession.showsHiddenFiles = false }
            } else {
                Button("Show Hidden Files") { sftpSession.showsHiddenFiles = true }
            }
            Button("Edit Path") { beginPathEditing() }
            Button("Refresh") { sftpSession.reloadNow() }
                .disabled(sftpSession.status != .connected || sftpSession.isLoading)
        } label: {
            if layout == .full {
                HStack(spacing: Metrics.Space.s) {
                    Text("Actions")
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .help("Actions")
    }

    private func breadcrumbs(layout: Layout) -> some View {
        let components = RemotePath.components(of: sftpSession.path)
        let tailCount = switch layout {
        case .full: 3
        case .medium: 2
        case .compact: 1
        }
        let collapses = components.count > tailCount + 1
        let visible = collapses ? Array(components.suffix(tailCount)) : Array(components.dropFirst())
        let hidden = collapses
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
        .help(sftpSession.path)
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
                .font(.body.weight(component.path == sftpSession.path ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Metrics.Space.xs)
        .frame(minHeight: 28)
    }

    private func beginPathEditing() {
        sftpSession.pathText = sftpSession.path
        editsPath = true
        Task { @MainActor in pathFocused = true }
    }

    private func commitPathEditing() {
        sftpSession.commitPathText()
        editsPath = false
        pathFocused = false
    }

    private func cancelPathEditing() {
        sftpSession.pathText = sftpSession.path
        editsPath = false
        pathFocused = false
    }

    @ViewBuilder
    private func browserContent(layout: Layout) -> some View {
        ZStack {
            fileList(layout: layout)

            if sftpSession.status == .disconnected, !sftpSession.connectionJourney.isPresented {
                VStack(spacing: Metrics.Space.l) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Not connected").foregroundStyle(.secondary)
                    Button("Connect") { sftpSession.connect(using: app.transfers) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            } else if sftpSession.files.isEmpty, sftpSession.isLoading {
                centeredState("Loading", symbol: "arrow.triangle.2.circlepath", progress: true)
                    .background(.background)
            } else if sftpSession.files.isEmpty, sftpSession.status == .connected {
                centeredState("This folder is empty", symbol: "folder", progress: false)
                    .background(.background)
            } else if sftpSession.visibleRows.isEmpty, !sftpSession.query.isEmpty {
                ContentUnavailableView.search(text: sftpSession.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        .onDrop(
            of: [.termindSFTPItems], isTargeted: $isRemoteDropTargeted,
            perform: receiveRemoteItemProviders
        )
        .onCopyCommand { remoteCopyProviders(for: sftpSession.selectedFiles) }
        .onPasteCommand(of: [.termindSFTPItems]) { providers in
            _ = receiveRemoteItemProviders(providers)
        }
        .overlay {
            if isRemoteDropTargeted || isExternalFileDropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.06)
                    RoundedRectangle(cornerRadius: Metrics.Radius.large)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(Metrics.Space.m)
                    Label(
                        isRemoteDropTargeted
                            ? "Copy to \(sftpSession.path)" : "Upload to \(sftpSession.path)",
                        systemImage: isRemoteDropTargeted
                            ? "doc.on.doc.fill" : "arrow.up.doc.fill"
                    )
                    .font(.headline)
                    .padding(.horizontal, Metrics.Space.xl)
                    .padding(.vertical, Metrics.Space.l)
                    .background(.regularMaterial, in: .rect(cornerRadius: Metrics.Radius.medium))
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(
            Motion.tabSwitch,
            value: isRemoteDropTargeted || isExternalFileDropTargeted
        )
        .onChange(of: externalFileDrop?.id) {
            guard let externalFileDrop else { return }
            _ = receiveDroppedURLs(externalFileDrop.urls)
        }
    }

    @ViewBuilder
    private var browserLocationMenu: some View {
        Button("Paste") { pasteRemoteItems() }
            .disabled(sftpSession.status != .connected || !canPasteRemoteItems)
        Divider()
        Button("New Folder") { newFolderPresented = true }
            .disabled(sftpSession.status != .connected)
        Button("Upload") { chooseUploadItems() }
            .disabled(sftpSession.status != .connected)
        Divider()
        Button("Refresh") { sftpSession.reloadNow() }
            .disabled(sftpSession.status != .connected || sftpSession.isLoading)
    }

    private func fileList(layout: Layout) -> some View {
        VStack(spacing: 0) {
            columnHeader(layout: layout)

            SFTPFileNativeList(
                items: fileListItems(layout: layout),
                scrollRequest: fileScrollRequest,
                onBackgroundClick: clearFileSelection
            ) { item in
                fileRow(item.row, layout: layout)
            }
                .focusable()
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
                    sftpSession.selection = Set(sftpSession.filteredFiles.map(\.id))
                    selectionAnchor = sftpSession.filteredFiles.first?.id
                    selectionCursor = sftpSession.filteredFiles.last?.id
                    return .handled
                }
        }
        .background(.background)
    }

    private func fileListItems(layout: Layout) -> [SFTPFileListItem] {
        let emphasized = isPaneFocused && !pathFocused && !searchFocused
            && controlActiveState == .key
        let layoutKey: Int
        switch layout {
        case .full: layoutKey = 2
        case .medium: layoutKey = 1
        case .compact: layoutKey = 0
        }
        return sftpSession.visibleRows.map { row in
            SFTPFileListItem(
                row: row,
                isSelected: sftpSession.selection.contains(row.id),
                isEmphasized: emphasized,
                isHovered: hoveredFileID == row.id,
                layoutKey: layoutKey
            )
        }
    }

    private func clearFileSelection() {
        focusPane()
        sftpSession.selection.removeAll()
        selectionAnchor = nil
        selectionCursor = nil
        listFocused = true
    }

    private func columnHeader(layout: Layout) -> some View {
        HStack(spacing: 0) {
            sortHeader("Name", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)

            if layout != .compact {
                sortHeader("Date Modified", field: .modified, separated: true)
                    .frame(width: 220, alignment: .leading)
            }
            if layout == .full {
                sortHeader("Size", field: .size, separated: true)
                    .frame(width: 150, alignment: .leading)
                sortHeader("Kind", field: .kind, separated: true)
                    .frame(width: 150, alignment: .leading)
            }
        }
        .padding(.leading, Metrics.Space.xxl)
        .padding(.trailing, Metrics.Space.xl)
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.7) }
    }

    private func sortHeader(
        _ title: LocalizedStringKey, field: SFTPFileSortField, separated: Bool = false
    ) -> some View {
        Button {
            sftpSession.sort(by: field)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                Text(title).font(.body.weight(.semibold))
                if sftpSession.sortField == field {
                    Image(
                        systemName: sftpSession.sortDirection == .ascending
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
        let selected = sftpSession.selection.contains(file.id)
        // In a split workspace the pane owns durable focus. SwiftUI can clear
        // the ScrollView's FocusState while the outer pane handles the same
        // click even though this remains the active pane. Text editing and an
        // inactive window still deliberately use the subdued selection style.
        let emphasized =
            selected && isPaneFocused && !pathFocused && !searchFocused
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
        .contextMenu {
            Group { fileMenu(file) }
                .onAppear { selectForContextMenu(file) }
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
                    .foregroundStyle(emphasized ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(secondaryText(for: row, layout: layout))
                    .font(.caption.monospaced())
                    .foregroundStyle(
                        emphasized ? AnyShapeStyle(.white.opacity(0.78)) : AnyShapeStyle(.secondary)
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
                emphasized ? AnyShapeStyle(.white.opacity(0.88)) : AnyShapeStyle(.secondary)
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
            return AnyShapeStyle(Color.white.opacity(file.isDirectory ? 0.82 : 0.72))
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
            return [row.permissionText, row.kindText, row.sizeText]
                .joined(separator: "  ·  ")
        case .compact:
            return [
                row.kindText, row.sizeText, row.modifiedText, row.permissionText,
            ].joined(separator: "  ·  ")
        }
    }

    @ViewBuilder
    private func fileMenu(_ file: RemoteFile) -> some View {
        let targets = menuTargets(for: file)
        if targets.count == 1 {
            Button("Open") { primaryAction(file) }
        }
        Button(targets.count == 1 ? "Download" : "Download \(targets.count) Items") {
            chooseDownloadDestination(for: targets)
        }
        Divider()
        Button(targets.count == 1 ? "Copy" : "Copy \(targets.count) Items") {
            copyRemoteItems(targets)
        }
        Menu("Copy As") {
            Button(targets.count == 1 ? "Name" : "Names") {
                copyToPasteboard(targets.map(\.name).joined(separator: "\n"))
            }
            Button(targets.count == 1 ? "Path" : "Paths") {
                copyToPasteboard(targets.map(\.path).joined(separator: "\n"))
            }
        }
        Button("Paste") { pasteRemoteItems() }
            .disabled(sftpSession.status != .connected || !canPasteRemoteItems)
        if targets.count == 1 {
            Button("Rename") {
                renameTarget = file
                renameName = file.name
            }
            .disabled(!sftpSession.allowsRemoteMutations)
            if file.kind == .file || file.kind == .directory {
                Button("Edit Permissions") { permissionTarget = file }
                    .disabled(!sftpSession.allowsRemoteMutations)
            }
        }
        Button(targets.count == 1 ? "Delete" : "Delete \(targets.count) Items", role: .destructive) {
            deleteTargets = targets
        }
        .disabled(!sftpSession.allowsRemoteMutations)
        Divider()
        Button("New Folder") { newFolderPresented = true }
            .disabled(sftpSession.status != .connected)
        Button("Upload") { chooseUploadItems() }
            .disabled(sftpSession.status != .connected)
        Button("Refresh") { sftpSession.reloadNow() }
            .disabled(sftpSession.status != .connected || sftpSession.isLoading)
    }

    private func primaryAction(_ file: RemoteFile) {
        if file.isDirectory {
            sftpSession.navigate(to: file.path)
        } else {
            sftpSession.open(file, coordinator: app.sftpTransfers) { localURL in
                if NSWorkspace.shared.open(localURL) {
                    sftpSession.recordOpenedFile(at: file.path)
                }
            }
        }
    }

    private func menuTargets(for file: RemoteFile) -> [RemoteFile] {
        guard sftpSession.selection.contains(file.id), sftpSession.selection.count > 1 else {
            return [file]
        }
        return sftpSession.selectedFiles
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func select(_ file: RemoteFile) {
        focusPane()
        listFocused = true
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
            let anchor = selectionAnchor ?? sftpSession.selection.first,
            let anchorIndex = sftpSession.filteredFiles.firstIndex(where: { $0.id == anchor }),
            let fileIndex = sftpSession.filteredFiles.firstIndex(where: { $0.id == file.id })
        {
            let bounds = min(anchorIndex, fileIndex)...max(anchorIndex, fileIndex)
            let range = Set(sftpSession.filteredFiles[bounds].map(\.id))
            if modifiers.contains(.command) {
                sftpSession.selection.formUnion(range)
            } else {
                sftpSession.selection = range
            }
            selectionCursor = file.id
            return
        }

        selectionAnchor = file.id
        selectionCursor = file.id
        if modifiers.contains(.command) {
            if sftpSession.selection.contains(file.id) {
                sftpSession.selection.remove(file.id)
            } else {
                sftpSession.selection.insert(file.id)
            }
        } else {
            sftpSession.selection = [file.id]
        }
    }

    private func selectForContextMenu(_ file: RemoteFile) {
        guard !sftpSession.selection.contains(file.id) else { return }
        sftpSession.selection = [file.id]
        selectionAnchor = file.id
        selectionCursor = file.id
        listFocused = true
    }

    private var keyboardTarget: RemoteFile? {
        let target = selectionCursor ?? sftpSession.selectedFiles.first?.id
        return target.flatMap { id in sftpSession.filteredFiles.first { $0.id == id } }
    }

    private func moveSelection(
        by offset: Int, extending: Bool
    ) -> KeyPress.Result {
        let files = sftpSession.filteredFiles
        guard !files.isEmpty else { return .ignored }
        let currentID = selectionCursor ?? sftpSession.selectedFiles.first?.id
        let currentIndex = currentID.flatMap { id in files.firstIndex { $0.id == id } }
            ?? (offset > 0 ? -1 : files.count)
        let targetIndex = min(max(currentIndex + offset, 0), files.count - 1)
        let target = files[targetIndex]

        if extending {
            let anchorID = selectionAnchor ?? currentID ?? target.id
            let anchorIndex = files.firstIndex { $0.id == anchorID } ?? targetIndex
            let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            sftpSession.selection = Set(files[bounds].map(\.id))
            selectionAnchor = anchorID
        } else {
            sftpSession.selection = [target.id]
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
        guard let source = sftpSession.remoteCopySource(for: targets) else {
            return NSItemProvider()
        }
        let payload = app.sftpTransfers.registerRemoteCopySource(source)
        let provider =
            file.isDirectory
            ? NSItemProvider()
            : Self.promisedFileProvider(
                for: file, sftpSession: sftpSession, coordinator: app.sftpTransfers
            )
        Self.register(payload, on: provider)
        return provider
    }

    private func remoteCopyProviders(for files: [RemoteFile]) -> [NSItemProvider] {
        guard let source = sftpSession.remoteCopySource(for: files) else { return [] }
        let payload = app.sftpTransfers.registerRemoteCopySource(source)
        let provider = NSItemProvider()
        Self.register(payload, on: provider)
        return [provider]
    }

    private func copyRemoteItems(_ files: [RemoteFile]) {
        guard let source = sftpSession.remoteCopySource(for: files) else { return }
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
            completion(data, data == nil ? SFTPError.operation("Unable to copy SFTP items.") : nil)
            return nil
        }
    }

    static func promisedFileProvider(
        for file: RemoteFile, sftpSession: SFTPSessionModel,
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
                sftpSession.downloadPromisedFile(
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

    private func centeredState(_ title: LocalizedStringKey, symbol: String, progress: Bool) -> some View {
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
            await sftpSession.prepareUpload(panel.urls)
            finishPreparingBatch()
        }
    }

    private func receiveDroppedURLs(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard sftpSession.status == .connected, !files.isEmpty else { return false }
        Task {
            await sftpSession.prepareUpload(files)
            finishPreparingBatch()
        }
        return true
    }

    private func receiveRemoteItemProviders(_ providers: [NSItemProvider]) -> Bool {
        guard sftpSession.status == .connected,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.termindSFTPItems.identifier)
            })
        else { return false }
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.termindSFTPItems.identifier
        ) { data, error in
            Task { @MainActor in
                if let error {
                    sftpSession.operationError = error.localizedDescription
                    return
                }
                guard let data,
                    let payload = try? JSONDecoder().decode(
                        SFTPRemoteItemsPayload.self, from: data
                    )
                else {
                    sftpSession.operationError = "The copied SFTP items are invalid."
                    return
                }
                prepareRemoteItems(payload)
            }
        }
        return true
    }

    private func prepareRemoteItems(_ payload: SFTPRemoteItemsPayload) {
        Task {
            await sftpSession.prepareRemoteCopy(payload, coordinator: app.sftpTransfers)
            finishPreparingBatch()
        }
    }

    private func chooseDownloadDestination(for file: RemoteFile) {
        chooseDownloadDestination(for: [file])
    }

    private func chooseDownloadDestination(for files: [RemoteFile]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            await sftpSession.prepareDownload(files, to: directory)
            finishPreparingBatch()
        }
    }

    private func finishPreparingBatch() {
        guard sftpSession.pendingBatch != nil || sftpSession.pendingRemoteCopyBatch != nil else { return }
        if sftpSession.conflictCount > 0 { conflictPresented = true } else { enqueue(.replace) }
    }

    private func enqueue(_ policy: TransferConflictPolicy) {
        Task {
            if sftpSession.pendingRemoteCopyBatch != nil {
                await sftpSession.enqueuePendingRemoteCopy(
                    policy: policy, coordinator: app.sftpTransfers
                )
            } else {
                await sftpSession.enqueuePending(policy: policy, coordinator: app.sftpTransfers)
            }
        }
    }
}

private struct SFTPEditPermissionsSheet: View {
    private struct AccessRow: Identifiable {
        let title: String
        let read: UInt32
        let write: UInt32
        let execute: UInt32

        var id: UInt32 { read }
    }

    let file: RemoteFile
    let save: (UInt32) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var modeFieldFocused: Bool
    @State private var draft: SFTPPermissionDraft
    @State private var isSaving = false

    private let accessRows = [
        AccessRow(title: "Owner", read: 0o400, write: 0o200, execute: 0o100),
        AccessRow(title: "Group", read: 0o040, write: 0o020, execute: 0o010),
        AccessRow(title: "Others", read: 0o004, write: 0o002, execute: 0o001),
    ]

    init(file: RemoteFile, save: @escaping (UInt32) async -> Bool) {
        self.file = file
        self.save = save
        _draft = State(initialValue: SFTPPermissionDraft(permissions: file.permissions))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                Label("Edit Permissions", systemImage: "lock.shield")
                    .font(.title2.weight(.semibold))

                HStack(spacing: Metrics.Space.l) {
                    Text(file.path)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    Spacer(minLength: Metrics.Space.xl)
                    TextField("Mode", text: modeText)
                        .labelsHidden()
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 68)
                        .focused($modeFieldFocused)
                        .accessibilityLabel("Octal permissions")
                }

                permissionGrid

                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Text("Ownership").font(.headline)
                    ownershipRow("UID", value: file.ownerUID)
                    Divider()
                    ownershipRow("GID", value: file.ownerGID)
                }
            }
            .padding(Metrics.Space.xxl)

            Divider()

            HStack(spacing: Metrics.Space.m) {
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save") { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave || isSaving)
            }
            .padding(.horizontal, Metrics.Space.xxl)
            .padding(.vertical, Metrics.Space.l)
            .background(.bar)
        }
        .frame(width: 520)
        .disabled(isSaving)
        .onChange(of: modeFieldFocused) { _, focused in
            if !focused { draft.normalizeText() }
        }
    }

    private var modeText: Binding<String> {
        Binding(
            get: { draft.text },
            set: { _ = draft.accept($0) }
        )
    }

    private var permissionGrid: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("File Access").font(.headline)
            Grid(horizontalSpacing: Metrics.Space.xxl, verticalSpacing: Metrics.Space.l) {
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    Text("Read")
                    Text("Write")
                    Text("Execute")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(accessRows) { row in
                    GridRow {
                        Text(row.title)
                            .frame(width: 72, alignment: .leading)
                            .foregroundStyle(.secondary)
                        permissionToggle(row.read, label: "\(row.title) read")
                        permissionToggle(row.write, label: "\(row.title) write")
                        permissionToggle(row.execute, label: "\(row.title) execute")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.Space.s)
        }
    }

    private func permissionToggle(_ permission: UInt32, label: String) -> some View {
        Toggle(
            label,
            isOn: Binding(
                get: { draft.contains(permission) },
                set: { draft.set(permission, enabled: $0) }
            )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(label)
    }

    private func ownershipRow(_ label: LocalizedStringKey, value: UInt32) -> some View {
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
        guard let permissions = draft.parsedMode, draft.canSave else { return }
        modeFieldFocused = false
        isSaving = true
        if await save(permissions) {
            dismiss()
        } else {
            isSaving = false
        }
    }
}
