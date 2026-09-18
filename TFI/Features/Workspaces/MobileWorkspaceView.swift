import GhosttyTerminal
import QuickLook
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import UIKit
import UniformTypeIdentifiers

struct MobileWorkspaceView: View {
    private enum TerminalSheet: String, Identifiable {
        case snippets
        case commandHistory
        case sftpHistory

        var id: String { rawValue }
    }

    let library: HostLibraryModel
    let pro: ProAccessController
    let commandGenerator: any CommandGenerating
    @Bindable var workspace: MobileWorkspace
    let workspaces: [MobileWorkspace]
    let selectWorkspace: (UUID) -> Void
    let renameWorkspace: (MobileWorkspace) -> Void
    let openSameDirectory: (MobileWorkspaceDirectoryLaunch) -> Void
    let closeWorkspace: (UUID) -> Void
    @State private var terminalSheet: TerminalSheet?
    @State private var importing = false
    @State private var directoryName = ""
    @State private var creatingDirectory = false
    @State private var deleting: RemoteFile?
    @State private var renaming: RemoteFile?
    @State private var editingPermissions: RemoteFile?
    @State private var showingTransfers = false
    @State private var uploadConflictPresented = false
    @State private var uploadDropTargeted = false
    @State private var workspaceIsVisible = false
    @State private var uploadDropTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @TerminalFontSettings private var font
    @State private var downloadTarget: RemoteFile?
    @State private var previewURL: URL?
    @State private var openWithPresenter = MobileSFTPOpenWithPresenter()
    @State private var importingEditedCopy = false
    @State private var editedCopyTarget: UUID?
    @State private var exportedEditURL: URL?
    @State private var showsExportedEdit = false
    @ScaledMetric private var editRowHeight = 76.0

    private var resolvedFont: TerminalFontPreferences {
        font.resolvingFamily(in: TerminalFontCatalog.shared.families)
    }

    private var editedFiles: [SFTPEditedFile] {
        workspace.sftpEdits?.model.modifiedFiles(for: workspace.descriptor.hostID) ?? []
    }

    var body: some View {
        workspaceAlerts
            .overlay {
                if uploadDropTargeted {
                    DropTargetOverlay(presentation: uploadDropPresentation)
                }
            }
            .background {
                MobileSFTPOpenWithAnchor(
                    presenter: openWithPresenter,
                    isEnabled: workspaceIsVisible && scenePhase == .active,
                    failed: { [workspace] in workspace.operationError = $0 },
                    finished: { [edits = workspace.sftpEdits] in Task { await edits?.recheck() } }
                )
                MobileWindowDropTarget(
                    isTargeted: $uploadDropTargeted,
                    isEnabled: workspaceIsVisible && scenePhase == .active,
                    terminalView: workspace.uploadTerminalView,
                    receive: receiveUploadProviders
                )
                .id(workspace.id)
            }
            .onAppear { workspaceIsVisible = true }
            .onDisappear {
                openWithPresenter.isEnabled = false
                workspaceIsVisible = false
                uploadDropTargeted = false
                cancelDropLoading()
            }
            .onChange(of: workspace.id) { _, _ in
                openWithPresenter.invalidate()
                uploadDropTargeted = false
                cancelDropLoading()
            }
            .onChange(of: workspace.uploadDestination) { _, _ in cancelDropLoading() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { openWithPresenter.isEnabled = false }
                if phase == .active { TerminalFontCatalog.shared.refresh() }
            }
    }

    private var workspaceChrome: some View {
        workspaceContent
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    if showsCommandGeneratorOverlay {
                        MobileCommandGeneratorOverlay(state: workspace.commandGeneratorState)
                    }
                    if let notice = workspace.uploadNotice {
                        MobileUploadNoticeOverlay(notice: notice)
                    }
                }
                .padding()
                .allowsHitTesting(false)
            }
            .navigationTitle(workspace.descriptor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbarTitleMenu {
                ForEach(workspaces) { candidate in
                    Button {
                        guard candidate.id != workspace.id else { return }
                        selectWorkspace(candidate.id)
                    } label: {
                        workspaceTitleMenuLabel(for: candidate)
                    }
                }
            }
            .modifier(MobileWorkspaceSearchModifier(workspace: workspace))
            .toolbar { workspaceToolbar }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if workspace.descriptor.kind == .ssh {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Generate Command", systemImage: "sparkles") {
                        workspace.generateCommand(using: commandGenerator)
                    }
                    Divider()
                    Button("Snippets", systemImage: "curlybraces") { terminalSheet = .snippets }
                    Button("History", systemImage: "clock") { terminalSheet = .commandHistory }
                    Divider()
                    Button("Next Match", systemImage: "chevron.down") {
                        workspace.find.presentAndNavigate(.previous)
                    }
                    Button("Previous Match", systemImage: "chevron.up") {
                        workspace.find.presentAndNavigate(.next)
                    }
                    Divider()
                    sameDirectoryMenuAction
                    Button("Rename", systemImage: "pencil") { renameWorkspace(workspace) }
                    Button("Close", systemImage: "xmark", role: .destructive) {
                        closeWorkspace(workspace.id)
                    }
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
        }
        if isSFTP {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Previous Location", systemImage: "chevron.left") {
                        Task { await workspace.sftpSession.goBack() }
                    }
                    .disabled(!workspace.connected || !workspace.sftpSession.canGoBack)
                    Button("Next Location", systemImage: "chevron.right") {
                        Task { await workspace.sftpSession.goForward() }
                    }
                    .disabled(!workspace.connected || !workspace.sftpSession.canGoForward)
                    Divider()
                    Button("Transfers", systemImage: "arrow.up.arrow.down") { showingTransfers = true }
                    Button("History", systemImage: "clock") { terminalSheet = .sftpHistory }
                    Divider()
                    Button("Upload", systemImage: "square.and.arrow.up") { importing = true }
                        .disabled(!workspace.connected)
                    Button("New Folder", systemImage: "folder.badge.plus") { creatingDirectory = true }
                        .disabled(!workspace.connected)
                    Button("Paste", systemImage: "doc.on.clipboard", action: pasteRemoteItems)
                        .disabled(!workspace.connected)
                    sortMenu
                    if workspace.sftpSession.showsHiddenFiles {
                        Button("Hide Hidden Files", systemImage: "eye.slash") {
                            workspace.sftpSession.showsHiddenFiles = false
                        }
                    } else {
                        Button("Show Hidden Files", systemImage: "eye") {
                            workspace.sftpSession.showsHiddenFiles = true
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await workspace.sftpSession.reload() }
                    }
                    .disabled(!workspace.connected || workspace.sftpSession.isRefreshing)
                    Divider()
                    sameDirectoryMenuAction
                    Button("Rename", systemImage: "pencil") { renameWorkspace(workspace) }
                    Button("Close", systemImage: "xmark", role: .destructive) {
                        closeWorkspace(workspace.id)
                    }
                } label: {
                    MobileOverflowMenuLabel("More")
                }
                .menuOrder(.fixed)
            }
        }
    }

    private var workspaceSheets: some View {
        workspaceChrome
            .sheet(item: $terminalSheet) { sheet in
                switch sheet {
                case .snippets:
                    MobileTerminalSnippetsView(library: library, workspace: workspace)
                case .commandHistory:
                    MobileCommandHistoryView(workspace: workspace)
                case .sftpHistory:
                    MobileSFTPHistoryView(workspace: workspace, open: reopenHistory)
                }
            }
            .sheet(
                item: Binding(
                    get: { workspace.terminalTextSelection },
                    set: { if $0 == nil { workspace.dismissTerminalTextSelection() } }
                ),
                onDismiss: { workspace.terminal.requestFocus() }
            ) { selection in
                MobileTerminalTextSelectionView(selection: selection)
                    .mobileSheetPresentation(compact: true)
            }
            .sheet(item: $renaming) { MobileRemoteFileEditor(workspace: workspace, file: $0, mode: .rename) }
            .sheet(item: $editingPermissions) {
                MobileRemoteFileEditor(workspace: workspace, file: $0, mode: .permissions)
            }
            .sheet(isPresented: $showingTransfers) {
                NavigationStack {
                    if let transfers = workspace.transfers {
                        MobileTransfersView(transfers: transfers, hosts: library)
                    }
                }.mobileSheetPresentation(compact: true)
            }
            .sheet(
                isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } }),
                onDismiss: {
                    Task { await workspace.sftpEdits?.recheck() }
                    showsExportedEdit = exportedEditURL != nil
                }
            ) {
                if let previewURL {
                    MobileSFTPEditPreview(
                        url: previewURL,
                        allowsEditing: workspace.sftpEdits?.model.files.contains { $0.localURL == previewURL } == true,
                        changed: { Task { await workspace.sftpEdits?.recheck() } },
                        export: { exportedEditURL = $0 },
                        failed: { workspace.operationError = $0 },
                        dismiss: { self.previewURL = nil }
                    )
                }
            }
            .sheet(isPresented: $showsExportedEdit) {
                if let exportedEditURL {
                    VStack(spacing: 20) {
                        Text("The edited copy uses a different format").font(.headline)
                        Text("Save this copy separately to keep the original remote file format.")
                        ShareLink(item: exportedEditURL) {
                            Label("Keep Local Copy", systemImage: "square.and.arrow.up")
                        }
                    }
                    .padding()
                    .mobileSheetPresentation(compact: true)
                }
            }
            .fileImporter(
                isPresented: $importingEditedCopy, allowedContentTypes: [.data], allowsMultipleSelection: false
            ) { result in
                let target = editedCopyTarget
                editedCopyTarget = nil
                switch result {
                case .success(let urls):
                    if let target, let source = urls.first {
                        Task { await workspace.importEditedCopy(source, for: target) }
                    }
                case .failure(let error): workspace.operationError = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.data, .folder],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    _ = receiveUpload(urls)
                case .failure(let error): workspace.operationError = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { downloadTarget != nil },
                    set: { if !$0 { downloadTarget = nil } }
                ),
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                let target = downloadTarget
                downloadTarget = nil
                switch result {
                case .success(let urls):
                    if let target, let destination = urls.first {
                        workspace.prepareDownload(target, to: destination)
                    }
                case .failure(let error):
                    workspace.operationError = error.localizedDescription
                }
            }
    }

    private var workspaceDialogs: some View {
        workspaceSheets
            .onChange(of: workspace.transferConflictCount) { _, count in
                uploadConflictPresented = count > 0
            }
            .onChange(of: uploadConflictPresented) { wasPresented, isPresented in
                if wasPresented, !isPresented, workspace.hasPendingTransferConflict {
                    workspace.cancelPendingUpload()
                }
            }
            .onDisappear {
                workspace.cancelPendingUpload()
                workspace.cancelCommandGeneration()
            }
            .confirmationDialog(
                uploadConflictTitle,
                isPresented: $uploadConflictPresented,
                titleVisibility: .visible
            ) {
                Button("Replace") { enqueuePendingUpload(.replace) }
                Button("Skip Existing") { enqueuePendingUpload(.skip) }
                Button("Keep Both") { enqueuePendingUpload(.keepBoth) }
                Button("Cancel", role: .cancel) { workspace.cancelPendingUpload() }
            } message: {
                Text("Use this choice for all conflicts in this batch.")
            }
            .alert("New Folder", isPresented: $creatingDirectory) {
                TextField("Name", text: $directoryName.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                Button("Create") {
                    Task {
                        await workspace.sftpSession.createDirectory(directoryName)
                        directoryName = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete File?", isPresented: deletingPresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let file = deleting { Task { await workspace.sftpSession.delete(file) } }
                    deleting = nil
                }
            }
    }

    private var workspaceAlerts: some View {
        workspaceDialogs
            .alert(
                operationAlertTitle,
                isPresented: operationErrorPresented
            ) {
                Button("OK", role: .cancel) {
                    workspace.operationError = nil
                    workspace.sftpSession.operationError = nil
                }
            } message: {
                Text(presentedOperationError ?? "")
            }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if workspace.descriptor.kind == .ssh {
            ZStack {
                VStack(spacing: 0) {
                    TerminalSurfaceView(context: workspace.terminal)
                        .id(workspace.id)
                        .onChange(of: workspace.terminalSettings.preferences, initial: true) { _, value in
                            workspace.terminal.applyPreferences(value, font: resolvedFont)
                        }
                        .onChange(of: resolvedFont) { _, value in
                            workspace.terminal.applyPreferences(workspace.terminalSettings.preferences, font: value)
                        }
                        .onAppear { TerminalFontCatalog.shared.refresh() }
                        .onTapGesture { workspace.terminal.requestFocus() }
                    MobileTerminalKeyboard(state: workspace.terminal) {
                        guard let text = UIPasteboard.general.string else { return }
                        workspace.insertTerminalText(text)
                    }
                }.opacity(showsJourney ? 0 : 1)
                    .allowsHitTesting(!showsJourney).accessibilityHidden(showsJourney)
                if showsJourney { connectionJourney.background(.background) }
            }
        } else if showsJourney {
            connectionJourney
        } else {
            MobileSFTPBrowser(
                session: workspace.sftpSession,
                connected: workspace.connected,
                bottomContentInset: editedFiles.isEmpty
                    ? 0 : (editRowHeight + 1) * Double(min(3, editedFiles.count)) + 24,
                open: open,
                openWith: openWith,
                canImportEditedCopy: { file in
                    guard
                        let edit = workspace.sftpEdits?.model.file(hostID: workspace.descriptor.hostID, path: file.path)
                    else { return false }
                    return !edit.isInvalidated && !edit.isPreparing && edit.transferID == nil
                },
                importEditedCopy: { file in
                    editedCopyTarget =
                        workspace.sftpEdits?.model.file(
                            hostID: workspace.descriptor.hostID, path: file.path)?.id
                    importingEditedCopy = editedCopyTarget != nil
                },
                download: { downloadTarget = $0 },
                copy: copyRemoteItem,
                paste: pasteRemoteItems,
                rename: { renaming = $0 },
                editPermissions: { editingPermissions = $0 },
                delete: { deleting = $0 }
            )
            .overlay(alignment: .bottom) {
                SFTPEditUploadOverlay(
                    files: editedFiles, transfers: workspace.transfers?.sftpTransfers ?? [],
                    connected: workspace.connected,
                    upload: { await workspace.uploadEdit($0, replacing: $1) },
                    resume: { workspace.transfers?.resume($0) },
                    open: presentPreview,
                    discard: { await workspace.sftpEdits?.discard($0) }
                )
                .padding(12)
            }
        }
    }

    private func presentPreview(_ url: URL) {
        exportedEditURL = nil
        previewURL = url
    }

    private func open(_ file: RemoteFile) {
        if file.isDirectory {
            Task { await workspace.sftpSession.openDirectory(file.path) }
        } else {
            _ = workspace.preview(file) { url in
                Task { @MainActor in presentPreview(url) }
            }
        }
    }

    private func openWith(_ file: RemoteFile) {
        guard !file.isDirectory, workspace.connected, let request = openWithPresenter.begin() else { return }
        // preview prepares the same managed edit copy used by Quick Look and the upload overlay.
        if !workspace.preview(
            file,
            completion: { [openWithPresenter] url in
                openWithPresenter.downloaded(url, request: request)
            })
        {
            openWithPresenter.invalidate()
        }
    }

    private func reopenHistory(_ entry: SFTPHistoryEntry) {
        switch entry.kind {
        case .directory:
            Task { await workspace.sftpSession.openDirectory(entry.path) }
        case .file:
            Task {
                _ = await workspace.reopenHistoryFile(at: entry.path) { url in
                    Task { @MainActor in presentPreview(url) }
                }
            }
        }
    }

    private var uploadConflictTitle: String {
        workspace.transferConflictCount == 1
            ? String(localized: "1 item already exists")
            : String(localized: "\(workspace.transferConflictCount) items already exist")
    }

    private var uploadDropPresentation: DropTargetPresentation {
        if let problem = workspace.uploadTargetProblem {
            return DropTargetPresentation(
                title: String(localized: "Can't Upload Here"),
                detail: problem,
                systemImage: "exclamationmark.triangle.fill",
                tone: .unavailable
            )
        }
        let hostName = library.host(workspace.descriptor.hostID)?.name ?? workspace.descriptor.title
        return DropTargetPresentation(
            title: String(localized: "Upload to \(hostName)"),
            detail: workspace.uploadDestination
                ?? String(localized: "The upload destination is unavailable."),
            systemImage: "arrow.up.doc.fill"
        )
    }

    private func receiveUpload(_ urls: [URL]) -> Bool {
        if workspace.descriptor.kind == .ssh,
            !pro.require(.terminalFileUpload)
        {
            return false
        }
        return workspace.prepareUpload(urls)
    }

    private func receiveUploadProviders(_ providers: [NSItemProvider]) -> Bool {
        guard MobileDropPayloadLoader.acceptsUpload(providers) else { return false }
        uploadDropTask?.cancel()
        let destination = workspace.uploadDestination
        uploadDropTask = Task {
            let payload = await MobileDropPayloadLoader.load(
                providers,
                kinds: [.files],
                fileMode: .staged
            )
            guard !Task.isCancelled, workspace.uploadDestination == destination else {
                if let stagedRoot = payload.stagedRoot { try? FileManager.default.removeItem(at: stagedRoot) }
                return
            }
            if !payload.fileURLs.isEmpty {
                let accepted = receiveUpload(payload.fileURLs)
                if !accepted, let stagedRoot = payload.stagedRoot {
                    try? FileManager.default.removeItem(at: stagedRoot)
                }
            }
            if let error = payload.failures.first {
                workspace.operationError = error
            }
        }
        return true
    }

    private func cancelDropLoading() {
        uploadDropTask?.cancel()
        uploadDropTask = nil
    }

    private func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        workspace.enqueuePendingTransfer(policy)
        uploadConflictPresented = false
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            sortButton("Name", field: .name, symbol: "textformat")
            sortButton("Date", field: .modified, symbol: "calendar")
            sortButton("Size", field: .size, symbol: "externaldrive")
            sortButton("Kind", field: .kind, symbol: "doc")
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text("Sort By")
                    Text(sortFieldTitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.up.arrow.down.square")
            }
        }
    }

    private func sortButton(
        _ title: LocalizedStringKey, field: RemoteFileSortField, symbol: String
    ) -> some View {
        Button {
            workspace.sftpSession.sort(by: field)
        } label: {
            Label(
                title,
                systemImage: workspace.sftpSession.sortField == field
                    ? (workspace.sftpSession.sortDirection == .ascending ? "chevron.up" : "chevron.down")
                    : symbol
            )
        }
    }

    private var sortFieldTitle: String {
        switch workspace.sftpSession.sortField {
        case .name: String(localized: "Name")
        case .modified: String(localized: "Date")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        }
    }

    private func copyRemoteItem(_ file: RemoteFile) {
        guard let transfers = workspace.transfers,
            let source = workspace.remoteCopySource(for: file),
            let data = try? JSONEncoder().encode(transfers.registerRemoteCopySource(source))
        else { return }
        UIPasteboard.general.items = [
            [
                UTType.termindSFTPItems.identifier: data,
                UTType.plainText.identifier: file.name,
            ]
        ]
    }

    private func pasteRemoteItems() {
        guard
            let data = UIPasteboard.general.data(
                forPasteboardType: UTType.termindSFTPItems.identifier
            ), let payload = try? JSONDecoder().decode(SFTPRemoteItemsPayload.self, from: data),
            workspace.transfers?.remoteCopySource(for: payload) != nil
        else {
            workspace.operationError = String(localized: "The copied SFTP items are invalid.")
            return
        }
        workspace.prepareRemoteCopy(payload)
    }

    private var presentedOperationError: String? {
        workspace.operationError ?? workspace.sftpSession.operationError
    }

    private var operationAlertTitle: String {
        workspace.descriptor.kind == .ssh
            ? String(localized: "Upload Failed")
            : String(localized: "SFTP Error")
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { presentedOperationError != nil },
            set: {
                if !$0 {
                    workspace.operationError = nil
                    workspace.sftpSession.operationError = nil
                }
            }
        )
    }

    private var deletingPresented: Binding<Bool> {
        Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )
    }

    private func workspaceTitleMenuLabel(for candidate: MobileWorkspace) -> some View {
        let symbol = candidate.id == workspace.id ? "checkmark" : candidate.descriptor.kind.symbol
        return Label(candidate.descriptor.title, systemImage: symbol)
    }

    @ViewBuilder
    private var sameDirectoryMenuAction: some View {
        if let launch = workspace.sameDirectoryLaunch {
            switch launch.kind {
            case .ssh:
                Button("Open with SSH", systemImage: "terminal") { openSameDirectory(launch) }
            case .sftp:
                Button("Open with SFTP", systemImage: "folder") { openSameDirectory(launch) }
            }
        }
    }

    private var showsJourney: Bool {
        workspace.journey.isPresented || workspace.authenticationRequired || workspace.hostKeyPrompt != nil
    }

    private var isSFTP: Bool { workspace.descriptor.kind == .sftp }

    private var showsCommandGeneratorOverlay: Bool {
        workspace.descriptor.kind == .ssh && workspace.commandGeneratorState != .idle
    }

    private var connectionJourney: some View {
        MobileConnectionJourneyView(
            journey: workspace.journey, library: library,
            authenticationPrompt: workspace.authenticationPrompt, hostKey: workspace.hostKeyPrompt,
            reconnectState: workspace.reconnectState,
            submit: { identity, username, password, passphrase, key, save in
                workspace.submitAuthentication(
                    identityID: identity, username: username, password: password,
                    passphrase: passphrase, keyID: key, save: save)
            }, accept: { workspace.trustHostKey(remember: $0) }, retry: { workspace.connect() },
            retryReconnectNow: { workspace.retryReconnectNow() },
            stopReconnecting: { workspace.stopReconnecting() }, cancel: { closeWorkspace(workspace.id) })
    }
}

private struct MobileCommandGeneratorOverlay: View {
    let state: CommandGeneratorState

    var body: some View {
        MobileTransientOverlay {
            symbol
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        switch state {
        case .readingDraft, .generating:
            ProgressView().controlSize(.small)
        case .inserted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch state {
        case .idle: ""
        case .readingDraft, .generating: String(localized: "Generating Command")
        case .inserted: String(localized: "Command Inserted")
        case .failed: String(localized: "Couldn't generate command")
        }
    }

    private var detail: String? {
        switch state {
        case .idle: nil
        case .readingDraft, .generating: String(localized: "This May Take a Moment")
        case .inserted: String(localized: "Press Return to Run")
        case .failed(let message): message
        }
    }
}

private struct MobileUploadNoticeOverlay: View {
    let notice: WorkspaceUploadNotice

    var body: some View {
        MobileTransientOverlay {
            symbol
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.headline)
                Text(notice.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var symbol: some View {
        switch notice {
        case .preparing:
            ProgressView().controlSize(.small)
        case .queued, .rejected:
            Image(systemName: notice.symbol ?? "")
                .foregroundStyle(notice.isRejected ? .orange : .green)
        }
    }
}

private struct MobileTransientOverlay<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct MobileWorkspaceSearchModifier: ViewModifier {
    @Bindable var workspace: MobileWorkspace
    @State private var queryRevision: UInt64 = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        switch workspace.descriptor.kind {
        case .ssh:
            searchable(content)
        case .sftp:
            content
                .mobileToolbarSearch(
                    text: Binding(
                        get: { workspace.sftpSession.query },
                        set: { workspace.sftpSession.query = $0 }
                    ),
                    prompt: Text("Search")
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func searchable(_ content: Content) -> some View {
        content
            .mobileToolbarSearch(
                text: query,
                isPresented: presentation,
                prompt: Text("Find")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { workspace.find.presentAndNavigate(.previous) }
    }

    private var query: Binding<String> {
        Binding(
            get: { workspace.find.query },
            set: { query in
                queryRevision &+= 1
                let revision = queryRevision
                guard query.isEmpty else {
                    workspace.find.updateQuery(query)
                    return
                }

                // SwiftUI clears the text binding when its native Close button
                // dismisses search. Defer an empty value for one turn so a
                // genuine clear is still sent to Ghostty while dismissal keeps
                // the retained query for the next presentation.
                DispatchQueue.main.async {
                    guard revision == queryRevision, workspace.find.isPresented else { return }
                    workspace.find.updateQuery("")
                }
            }
        )
    }

    private var presentation: Binding<Bool> {
        Binding(
            get: { workspace.find.isPresented },
            set: { presented in
                if presented {
                    queryRevision &+= 1
                    workspace.find.present()
                } else if workspace.find.isPresented {
                    workspace.find.dismiss()
                }
            }
        )
    }
}
