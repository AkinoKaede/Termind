import GhosttyTerminal
import QuickLook
import SwiftUI
import TermindApplication
import TermindDomain
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
    let commandGenerator: any CommandGenerating
    @Bindable var workspace: MobileWorkspace
    let workspaces: [MobileWorkspaceDescriptor]
    var unreadWorkspaceIDs: Set<UUID> = []
    let selectWorkspace: (UUID) -> Void
    let renameWorkspace: (MobileWorkspaceDescriptor) -> Void
    let canCloseMultipleWorkspaces: Bool
    let openSameDirectory: (MobileWorkspaceDirectoryLaunch) -> Void
    let closeWorkspace: (UUID) -> Void
    let closeOtherWorkspaces: (UUID) -> Void
    @State private var terminalSheet: TerminalSheet?
    @State private var importing = false
    @State private var importingTerminalFiles = false
    @State private var importingTerminalPhotos = false
    @State private var terminalUploadTarget: TerminalUploadTarget?

    private struct TerminalUploadTarget {
        let workspaceID: UUID
        let generation: UUID
        let destination: String
    }
    @State private var directoryName = ""
    @State private var creatingDirectory = false
    @State private var renaming: RemoteFile?
    @State private var editingPermissions: RemoteFile?
    @State private var showingTransfers = false
    @State private var uploadDropTargeted = false
    @State private var workspaceIsVisible = false
    @State private var uploadDropTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileToolbarLayout) private var toolbarLayout
    @TerminalFontSettings private var font
    @State private var downloadImport = MobileFileImportState<RemoteFile>()
    @State private var preview = MobileSFTPPreviewState()
    @State private var openWithPresenter = MobileSFTPOpenWithPresenter()
    @State private var editedCopyImport = MobileFileImportState<UUID>()
    @ScaledMetric private var editRowHeight = 76.0

    private var resolvedFont: TerminalFontPreferences {
        font.resolvingFamily(in: TerminalFontCatalog.shared.families)
    }

    private var editedFiles: [SFTPEditedFile] {
        workspace.sftpEdits?.model.modifiedFiles(for: workspace.descriptor.hostID) ?? []
    }

    var body: some View {
        workspaceAlerts
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
                    receive: { receiveUploadProviders($0) }
                )
                .id(workspace.id)
            }
            .onAppear {
                workspaceIsVisible = true
                bindTerminalUploadMenu()
            }
            .onDisappear {
                openWithPresenter.isEnabled = false
                workspaceIsVisible = false
                workspace.configureTerminalUpload(files: nil)
                terminalUploadTarget = nil
                uploadDropTargeted = false
                cancelDropLoading()
            }
            .onChange(of: workspace.id) { _, _ in
                openWithPresenter.invalidate()
                terminalUploadTarget = nil
                bindTerminalUploadMenu()
                uploadDropTargeted = false
                cancelDropLoading()
            }
            .onChange(of: workspace.uploadDestination) { _, _ in cancelDropLoading() }
            .onChange(of: workspace.uploadConnectionGeneration) { _, _ in cancelDropLoading() }
            .onChange(of: workspace.pendingExternalPreviewURL, initial: true) { _, url in
                guard url != nil, let preview = workspace.consumePendingExternalPreviewURL() else { return }
                presentPreview(preview)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { openWithPresenter.isEnabled = false }
                if phase == .active { TerminalFontCatalog.shared.refresh() }
            }
    }

    private var workspaceChrome: some View {
        MobileRegionReader { regions in
            MobilePaneLayout(frames: [regions.continuous]) {
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
                    .overlay {
                        if uploadDropTargeted { DropTargetOverlay(presentation: uploadDropPresentation) }
                    }
                    .clipped()
                    .opacity(MobileContentRegions.isUsable(regions.continuous) ? 1 : 0)
                    .allowsHitTesting(MobileContentRegions.isUsable(regions.continuous))
                    .accessibilityHidden(!MobileContentRegions.isUsable(regions.continuous))
            }
        }
        .background {
            if workspace.descriptor.kind != .sftp, !showsJourney {
                TerminalBackground(state: workspace.terminal)
                    .ignoresSafeArea(.container)
            }
        }
        .navigationTitle(workspace.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(toolbarLayout.showsWorkspaceTabs ? .visible : .hidden, for: .tabBar)
        .toolbar(removing: toolbarLayout.usesIconSwitcher ? .title : nil)
        .toolbar {
            if toolbarLayout.usesIconSwitcher {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        workspaceSwitchActions
                    } label: {
                        MobileNotificationMenuLabel(
                            title: String(localized: AppStrings.Navigation.workspaces), symbol: "rectangle.stack",
                            hasUnread: !unreadWorkspaceIDs.isEmpty, isToolbar: true)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue(workspace.descriptor.title)
                }
                .mobileProminentAction()
            } else {
                ToolbarTitleMenu { workspaceSwitchActions }
            }
        }
        .modifier(MobileWorkspaceSearchModifier(workspace: workspace))
        .toolbar { workspaceToolbar }
    }

    private var workspaceSwitchActions: some View {
        ForEach(workspaces) { candidate in
            Button {
                guard candidate.id != workspace.id else { return }
                selectWorkspace(candidate.id)
            } label: {
                workspaceTitleMenuLabel(for: candidate)
            }
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if workspace.descriptor.kind == .ssh {
            MobileToolbarOverflow(placement: .topBarTrailing) {
                Button(AppStrings.Workspace.generateCommand.swiftUIKey, systemImage: "sparkles") {
                    workspace.generateCommand(using: commandGenerator)
                }
                Divider()
                Button(AppStrings.Navigation.snippets.swiftUIKey, systemImage: "curlybraces") {
                    terminalSheet = .snippets
                }
                Button(AppStrings.Common.history.swiftUIKey, systemImage: "clock") { terminalSheet = .commandHistory }
                Divider()
                Button(AppStrings.Workspace.nextMatch.swiftUIKey, systemImage: "chevron.down") {
                    workspace.find.presentAndNavigate(.previous)
                }
                Button(AppStrings.Workspace.previousMatch.swiftUIKey, systemImage: "chevron.up") {
                    workspace.find.presentAndNavigate(.next)
                }
                Divider()
                sameDirectoryMenuAction
                workspaceLifecycleActions
            }
        }
        if workspace.descriptor.kind == .telnet {
            MobileToolbarOverflow(placement: .topBarTrailing) {
                Button(AppStrings.Navigation.snippets.swiftUIKey, systemImage: "curlybraces") {
                    terminalSheet = .snippets
                }
                Divider()
                Button(AppStrings.Workspace.nextMatch.swiftUIKey, systemImage: "chevron.down") {
                    workspace.find.presentAndNavigate(.previous)
                }
                Button(AppStrings.Workspace.previousMatch.swiftUIKey, systemImage: "chevron.up") {
                    workspace.find.presentAndNavigate(.next)
                }
                Divider()
                workspaceLifecycleActions
            }
        }
        if isSFTP {
            MobileToolbarOverflow(placement: .topBarTrailing) {
                Button(AppStrings.Workspace.previousLocation.swiftUIKey, systemImage: "chevron.left") {
                    Task { await workspace.sftpChannel.goBack() }
                }
                .disabled(!workspace.connected || !workspace.sftpChannel.canGoBack)
                Button(AppStrings.Workspace.nextLocation.swiftUIKey, systemImage: "chevron.right") {
                    Task { await workspace.sftpChannel.goForward() }
                }
                .disabled(!workspace.connected || !workspace.sftpChannel.canGoForward)
                Divider()
                Button(AppStrings.SFTP.transfers.swiftUIKey, systemImage: "arrow.up.arrow.down") {
                    showingTransfers = true
                }
                Button(AppStrings.Common.history.swiftUIKey, systemImage: "clock") { terminalSheet = .sftpHistory }
                Divider()
                Button(AppStrings.SFTP.upload.swiftUIKey, systemImage: "square.and.arrow.up") { importing = true }
                    .disabled(!workspace.connected)
                Button(AppStrings.SFTP.newFolder.swiftUIKey, systemImage: "folder.badge.plus") {
                    creatingDirectory = true
                }
                .disabled(!workspace.connected)
                Button(AppStrings.Common.paste.swiftUIKey, systemImage: "doc.on.clipboard", action: pasteRemoteItems)
                    .disabled(!workspace.connected)
                sortMenu
                if workspace.sftpChannel.showsHiddenFiles {
                    Button(AppStrings.SFTP.hideHiddenFiles.swiftUIKey, systemImage: "eye.slash") {
                        workspace.sftpChannel.showsHiddenFiles = false
                    }
                } else {
                    Button(AppStrings.SFTP.showHiddenFiles.swiftUIKey, systemImage: "eye") {
                        workspace.sftpChannel.showsHiddenFiles = true
                    }
                }
                Button(AppStrings.Common.refresh.swiftUIKey, systemImage: "arrow.clockwise") {
                    Task { await workspace.sftpChannel.reload() }
                }
                .disabled(!workspace.connected || workspace.sftpChannel.isRefreshing)
                Divider()
                sameDirectoryMenuAction
                workspaceLifecycleActions
            }
        }
    }

    @ViewBuilder
    private var workspaceLifecycleActions: some View {
        MobileWorkspaceLifecycleMenuActions(
            canCloseMultipleWorkspaces: canCloseMultipleWorkspaces,
            rename: { renameWorkspace(workspace.descriptor) },
            close: { closeWorkspace(workspace.id) },
            closeOthers: { closeOtherWorkspaces(workspace.id) }
        )
    }

    private var workspaceSheets: some View {
        workspaceChrome
            .sheet(item: $terminalSheet) { sheet in
                switch sheet {
                case .snippets:
                    MobileTerminalSnippetsView(library: library, workspace: workspace)
                case .commandHistory:
                    MobileCommandHistoryView(library: library, workspace: workspace)
                case .sftpHistory:
                    MobileSFTPHistoryView(workspace: workspace, open: reopenHistory)
                }
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
                isPresented: $preview.isPreviewPresented,
                onDismiss: {
                    Task { await workspace.sftpEdits?.recheck() }
                    preview.previewDidDismiss()
                }
            ) {
                if let previewURL = preview.previewURL {
                    MobileSFTPEditPreview(
                        url: previewURL,
                        allowsEditing: workspace.sftpEdits?.model.files.contains { $0.localURL == previewURL } == true,
                        changed: { Task { await workspace.sftpEdits?.recheck() } },
                        export: { preview.stageExport($0) },
                        failed: { workspace.operationError = $0 },
                        dismiss: { preview.dismissPreview() }
                    )
                }
            }
            .sheet(isPresented: $preview.isExportPresented) {
                if let exportedEditURL = preview.exportedCopyURL {
                    VStack(spacing: 20) {
                        Text(AppStrings.Workspace.theEditedCopyUsesADifferentFormat).font(.headline)
                        Text(AppStrings.SFTP.editedCopyFormatExplanation)
                        ShareLink(item: exportedEditURL) {
                            Label(AppStrings.SFTP.keepLocalCopy.swiftUIKey, systemImage: "square.and.arrow.up")
                        }
                    }
                    .padding()
                    .mobileSheetPresentation(compact: true)
                }
            }
            .sheet(isPresented: $importingTerminalPhotos) {
                MobileTerminalPhotoPicker { providers in
                    importingTerminalPhotos = false
                    receiveTerminalUpload(providers)
                }
            }
            .fileImporter(
                isPresented: $importingTerminalFiles,
                allowedContentTypes: [.data, .folder], allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    receiveTerminalUploadFiles(urls)
                case .failure(let error):
                    terminalUploadTarget = nil
                    if (error as NSError).code != NSUserCancelledError {
                        workspace.reportUploadFailure(error.localizedDescription)
                    }
                }
            }
            .fileImporter(
                isPresented: $editedCopyImport.isPresented, allowedContentTypes: [.data], allowsMultipleSelection: false
            ) { result in
                let target = editedCopyImport.takeTarget()
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
                isPresented: $downloadImport.isPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                let target = downloadImport.takeTarget()
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
            .onDisappear {
                workspace.cancelPendingUpload()
                workspace.cancelCommandGeneration()
            }
            .confirmationDialog(
                uploadConflictTitle,
                isPresented: transferConflictPresented,
                titleVisibility: .visible
            ) {
                Button(AppStrings.SFTP.replace.swiftUIKey) { enqueuePendingUpload(.replace) }
                Button(AppStrings.SFTP.skipExisting.swiftUIKey) { enqueuePendingUpload(.skip) }
                Button(AppStrings.SFTP.keepBoth.swiftUIKey) { enqueuePendingUpload(.keepBoth) }
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { workspace.cancelPendingUpload() }
            } message: {
                Text(AppStrings.SFTP.applyToAllConflicts)
            }
            .alert(AppStrings.SFTP.newFolder, isPresented: $creatingDirectory) {
                TextField(AppStrings.Common.name.swiftUIKey, text: $directoryName.singleLineText, axis: .horizontal)
                    .singleLinePaste().lineLimit(1)
                Button(AppStrings.Common.create.swiftUIKey) {
                    Task {
                        await workspace.sftpChannel.createDirectory(directoryName)
                        directoryName = ""
                    }
                }
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
            }
    }

    private var workspaceAlerts: some View {
        workspaceDialogs
            .alert(
                operationAlertTitle,
                isPresented: operationErrorPresented
            ) {
                Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {
                    workspace.operationError = nil
                    workspace.sftpChannel.operationError = nil
                }
            } message: {
                Text(presentedOperationError ?? "")
            }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if workspace.descriptor.kind != .sftp {
            ZStack {
                VStack(spacing: 0) {
                    TerminalSurfaceView(context: workspace.terminal)
                        .modifier(
                            MobileTerminalInitialFocus(
                                terminal: workspace.terminal,
                                isReady: workspaceIsVisible && scenePhase == .active && workspace.connected
                                    && !showsJourney)
                        )
                        .id(workspace.id)
                        .onChange(of: workspace.terminalSettings.preferences, initial: true) { _, value in
                            workspace.terminal.applyPreferences(value, font: resolvedFont)
                        }
                        .onChange(of: resolvedFont) { _, value in
                            workspace.terminal.applyPreferences(workspace.terminalSettings.preferences, font: value)
                        }
                        .onAppear { TerminalFontCatalog.shared.refresh() }
                }.opacity(showsJourney ? 0 : 1)
                    .allowsHitTesting(!showsJourney).accessibilityHidden(showsJourney)
                if showsJourney { connectionJourney.background(.background) }
            }
        } else if showsJourney {
            connectionJourney
        } else {
            MobileSFTPBrowser(
                channel: workspace.sftpChannel,
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
                    if let id = workspace.sftpEdits?.model.file(
                        hostID: workspace.descriptor.hostID, path: file.path)?.id
                    {
                        editedCopyImport.present(for: id)
                    }
                },
                download: { downloadImport.present(for: $0) },
                copy: copyRemoteItem,
                paste: pasteRemoteItems,
                rename: { renaming = $0 },
                editPermissions: { editingPermissions = $0 },
                delete: { file in Task { await workspace.sftpChannel.delete(file) } }
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
        preview.present(url)
    }

    private func open(_ file: RemoteFile) {
        if file.isDirectory {
            Task { await workspace.sftpChannel.openDirectory(file.path) }
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
            Task { await workspace.sftpChannel.openDirectory(entry.path) }
        case .file:
            Task {
                _ = await workspace.reopenHistoryFile(at: entry.path) { url in
                    Task { @MainActor in presentPreview(url) }
                }
            }
        }
    }

    private var uploadConflictTitle: String {
        String(localized: AppStrings.SFTP.existingItemsMessage(count: workspace.transferConflictCount))
    }

    private var uploadDropPresentation: DropTargetPresentation {
        if let problem = workspace.uploadTargetProblem {
            return DropTargetPresentation(
                title: String(localized: AppStrings.SFTP.uploadUnavailable),
                detail: problem,
                systemImage: "exclamationmark.triangle.fill",
                tone: .unavailable
            )
        }
        let hostName = library.host(workspace.descriptor.hostID)?.name ?? workspace.descriptor.title
        return DropTargetPresentation(
            title: String(localized: AppStrings.Workspace.uploadTo(hostName)),
            detail: workspace.uploadDestination
                ?? String(localized: AppStrings.SFTP.theUploadDestinationIsUnavailable),
            systemImage: "arrow.up.doc.fill"
        )
    }

    private func bindTerminalUploadMenu() {
        workspace.configureTerminalUpload(
            files: { beginTerminalUpload(photos: false) },
            photos: { beginTerminalUpload(photos: true) })
    }

    private func beginTerminalUpload(photos: Bool) {
        guard workspaceIsVisible, workspace.uploadTargetProblem == nil,
            let destination = workspace.uploadDestination
        else { return }
        terminalUploadTarget = TerminalUploadTarget(
            workspaceID: workspace.id, generation: workspace.uploadConnectionGeneration,
            destination: destination)
        if photos { importingTerminalPhotos = true } else { importingTerminalFiles = true }
    }

    private var terminalUploadTargetIsCurrent: Bool {
        guard let target = terminalUploadTarget, workspaceIsVisible else { return false }
        return target.workspaceID == workspace.id
            && target.generation == workspace.uploadConnectionGeneration
            && target.destination == workspace.uploadDestination
    }

    private func receiveTerminalUploadFiles(_ urls: [URL]) {
        defer { terminalUploadTarget = nil }
        guard terminalUploadTargetIsCurrent else { return }
        // Keep the original security-scoped URLs, as in the SFTP file importer.
        _ = workspace.prepareUpload(urls, insertPaths: true)
    }

    private func receiveTerminalUpload(_ providers: [NSItemProvider]) {
        defer { terminalUploadTarget = nil }
        guard terminalUploadTargetIsCurrent else { return }
        _ = receiveUploadProviders(providers, insertPaths: true)
    }

    private func receiveUpload(_ urls: [URL]) -> Bool {
        workspace.prepareUpload(urls)
    }

    private func receiveUploadProviders(_ providers: [NSItemProvider], insertPaths: Bool = false) -> Bool {
        guard MobileDropPayloadLoader.acceptsUpload(providers) else { return false }
        uploadDropTask?.cancel()
        workspace.cancelPendingUpload()
        let targetWorkspace = workspace
        let generation = workspace.uploadConnectionGeneration
        let destination = workspace.uploadDestination
        uploadDropTask = Task {
            let payload = await MobileDropPayloadLoader.load(
                providers,
                kinds: [.files],
                fileMode: .staged
            )
            guard !Task.isCancelled, workspace.id == targetWorkspace.id,
                targetWorkspace.uploadConnectionGeneration == generation,
                targetWorkspace.uploadDestination == destination
            else {
                if let stagedRoot = payload.stagedRoot { try? FileManager.default.removeItem(at: stagedRoot) }
                return
            }
            if !payload.fileURLs.isEmpty {
                let accepted = targetWorkspace.prepareUpload(payload.fileURLs, insertPaths: insertPaths)
                if !accepted, let stagedRoot = payload.stagedRoot {
                    try? FileManager.default.removeItem(at: stagedRoot)
                }
            }
            if let error = payload.failures.first {
                targetWorkspace.reportUploadFailure(error)
            }
        }
        return true
    }

    private func cancelDropLoading() {
        uploadDropTask?.cancel()
        uploadDropTask = nil
    }

    private var transferConflictPresented: Binding<Bool> {
        let requestID = workspace.transferConflictID
        return Binding(
            get: { workspace.hasPendingTransferConflict },
            set: { presented in
                if !presented, let requestID { workspace.dismissTransferConflict(requestID) }
            })
    }

    private func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        workspace.enqueuePendingTransfer(policy)
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            sortButton(AppStrings.Common.name, field: .name, symbol: "textformat")
            sortButton(AppStrings.SFTP.modifiedDate, field: .modified, symbol: "calendar")
            sortButton(AppStrings.Common.size, field: .size, symbol: "externaldrive")
            sortButton(AppStrings.Common.kind, field: .kind, symbol: "doc")
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(AppStrings.Common.sortBy)
                    Text(sortFieldTitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.up.arrow.down.square")
            }
        }
    }

    private func sortButton(
        _ title: LocalizedStringResource, field: RemoteFileSortField, symbol: String
    ) -> some View {
        Button {
            workspace.sftpChannel.sort(by: field)
        } label: {
            Label(
                title,
                systemImage: workspace.sftpChannel.sortField == field
                    ? (workspace.sftpChannel.sortDirection == .ascending ? "chevron.up" : "chevron.down")
                    : symbol
            )
        }
    }

    private var sortFieldTitle: String {
        switch workspace.sftpChannel.sortField {
        case .name: String(localized: AppStrings.Common.name)
        case .modified: String(localized: AppStrings.SFTP.modifiedDate)
        case .size: String(localized: AppStrings.Common.size)
        case .kind: String(localized: AppStrings.Common.kind)
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
            workspace.operationError = String(localized: AppStrings.SFTP.theCopiedSftpItemsAreInvalid)
            return
        }
        workspace.prepareRemoteCopy(payload)
    }

    private var presentedOperationError: String? {
        workspace.operationError ?? workspace.sftpChannel.operationError
    }

    private var operationAlertTitle: String {
        workspace.descriptor.kind == .ssh
            ? String(localized: AppStrings.Workspace.uploadFailed)
            : String(localized: AppStrings.SFTP.sftpError)
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { presentedOperationError != nil },
            set: {
                if !$0 {
                    workspace.operationError = nil
                    workspace.sftpChannel.operationError = nil
                }
            }
        )
    }

    private func workspaceTitleMenuLabel(for candidate: MobileWorkspaceDescriptor) -> some View {
        MobileNotificationMenuLabel(
            title: candidate.title,
            symbol: candidate.id == workspace.id ? "checkmark" : candidate.kind.symbol,
            hasUnread: unreadWorkspaceIDs.contains(candidate.id))
    }

    @ViewBuilder
    private var sameDirectoryMenuAction: some View {
        if let launch = workspace.sameDirectoryLaunch {
            switch launch.kind {
            case .ssh:
                Button(AppStrings.Connections.openWithSsh.swiftUIKey, systemImage: "terminal") {
                    openSameDirectory(launch)
                }
            case .telnet:
                EmptyView()
            case .sftp:
                Button(AppStrings.SFTP.openWithSftp.swiftUIKey, systemImage: "folder") { openSameDirectory(launch) }
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
            stopReconnecting: { workspace.stopReconnecting() }, cancel: { closeWorkspace(workspace.id) },
            securityKeySigning: workspace.securityKeySigning,
            keyboardAuthentication: workspace.keyboardAuthentication)
    }
}

struct MobileWorkspaceLifecycleMenuActions: View {
    let canCloseMultipleWorkspaces: Bool
    let rename: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    var hasUnread: Bool? = nil
    var toggleRead: () -> Void = {}

    var body: some View {
        Button(AppStrings.Common.rename.swiftUIKey, systemImage: "pencil", action: rename)
        if let hasUnread {
            Button(
                hasUnread ? AppStrings.Notifications.markRead : AppStrings.Notifications.markUnread,
                systemImage: hasUnread ? "circle" : "circle.fill", action: toggleRead)
        }
        Button(AppStrings.Common.close.swiftUIKey, systemImage: "xmark", role: .destructive, action: close)
        if canCloseMultipleWorkspaces {
            Divider()
            Button(
                AppStrings.Workspace.closeOthers.swiftUIKey, systemImage: "xmark", role: .destructive,
                action: closeOthers)
        }
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
        case .readingDraft, .generating: String(localized: AppStrings.Workspace.generatingCommand)
        case .inserted: String(localized: AppStrings.Workspace.commandInserted)
        case .failed: String(localized: AppStrings.Workspace.commandGenerationFailed)
        }
    }

    private var detail: String? {
        switch state {
        case .idle: nil
        case .readingDraft, .generating: String(localized: AppStrings.Workspace.thisMayTakeAMoment)
        case .inserted: String(localized: AppStrings.Workspace.pressReturnToRun)
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
                    .font(notice.isRejected ? .caption : .caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(notice.isRejected ? .tail : .middle)
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
