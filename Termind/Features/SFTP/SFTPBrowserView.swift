import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
    import AppKit
#endif

struct SFTPBrowserView: View {
    let sftpSession: SFTPSessionModel
    let externalFileDrop: LocalFileDropRequest?
    let isExternalFileDropTargeted: Bool
    let closePane: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var newFolderPresented = false
    @State private var newFolderName = ""
    @State private var renameTarget: RemoteFile?
    @State private var renameName = ""
    @State private var deleteTargets: [RemoteFile] = []
    @State private var conflictPresented = false
    @State private var isDropTargeted = false
    @State private var isRemoteDropTargeted = false
    @AppStorage("termind.sftp.table.columns")
    private var columnCustomization = TableColumnCustomization<RemoteFile>()

    private var host: Host? { app.hosts.host(sftpSession.hostID) }
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

    var body: some View {
        @Bindable var sftpSession = sftpSession
        ZStack {
            VStack(spacing: 0) {
                pathBar
                Divider()
                browserContent
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
                            passphrase: passphrase, keyID: keyID, save: save, using: app.hosts
                        )
                    },
                    continueHostKey: {
                        sftpSession.continueWithTemporaryHostKey($0, using: app.hosts)
                    },
                    trustHostKey: { sftpSession.trustAndConnect($0, using: app.hosts) },
                    denyHostKey: {
                        cancelConnection()
                    },
                    retry: { sftpSession.connect(using: app.hosts) },
                    cancel: cancelConnection
                )
                .zIndex(10)
            }
        }
        .contextMenu { browserLocationMenu }
        .background(.background)
        .onAppear {
            sftpSession.bindTransfers(to: app.sftpTransfers)
            if sftpSession.status == .disconnected {
                sftpSession.connect(using: app.hosts)
            } else {
                sftpSession.startAutomaticRefresh()
            }
        }
        .onChange(of: sftpSession.path) {
            guard window.selectedTab?.focusedPane.sftpSession === sftpSession else { return }
            window.selectedTab?.refreshConversationContext(in: app.hosts)
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
    }

    private func cancelConnection() {
        sftpSession.disconnect()
        closePane()
    }

    private var pathBar: some View {
        @Bindable var sftpSession = sftpSession
        return HStack(spacing: Metrics.Space.s) {
            Button {
                sftpSession.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!sftpSession.canGoBack)
            .help("Back")
            Button {
                sftpSession.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!sftpSession.canGoForward)
            .help("Forward")
            Button {
                sftpSession.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(!sftpSession.canGoUp)
            .help("Parent folder")

            TextField("Remote Path", text: $sftpSession.pathText)
                .onSubmit { sftpSession.commitPathText() }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())

            TermindSearchField(text: $sftpSession.query, prompt: "Filter", density: .compact)
                .frame(width: 180)

            Button {
                newFolderPresented = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(sftpSession.status != .connected)
            .help("New folder")
            Button {
                chooseUploadItems()
            } label: {
                Image(systemName: "arrow.up.doc")
            }
            .disabled(sftpSession.status != .connected)
            .help("Upload")
            Button {
                sftpSession.reloadNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(sftpSession.status != .connected || sftpSession.isLoading)
            .help("Refresh")
            if sftpSession.canCancelOperation {
                Button {
                    sftpSession.cancelOperation()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .foregroundStyle(.red)
                .help("Cancel operation")
            }

            if let host {
                StatusDot(status: sftpSession.status)
                    .help(host.name)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.s)
        .background(.bar)
    }

    @ViewBuilder
    private var browserContent: some View {
        Group {
            if sftpSession.status == .disconnected, !sftpSession.connectionJourney.isPresented {
                VStack(spacing: Metrics.Space.l) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Not connected").foregroundStyle(.secondary)
                    Button("Connect") { sftpSession.connect(using: app.hosts) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sftpSession.files.isEmpty, sftpSession.isLoading {
                centeredState("Loading", symbol: "arrow.triangle.2.circlepath", progress: true)
            } else if sftpSession.files.isEmpty, sftpSession.status == .connected {
                centeredState("This folder is empty", symbol: "folder", progress: false)
            } else {
                fileTable
            }
        }
        .onDrop(
            of: [.fileURL],
            delegate: FileURLDropTarget(
                isTargeted: $isDropTargeted,
                receive: receiveDroppedURLs
            )
        )
        .onDrop(
            of: [.termindSFTPItems], isTargeted: $isRemoteDropTargeted,
            perform: receiveRemoteItemProviders
        )
        .onCopyCommand { remoteCopyProviders(for: sftpSession.selectedFiles) }
        .onPasteCommand(of: [.termindSFTPItems]) { providers in
            _ = receiveRemoteItemProviders(providers)
        }
        .overlay {
            if isDropTargeted || isRemoteDropTargeted || isExternalFileDropTargeted {
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
            value: isDropTargeted || isRemoteDropTargeted || isExternalFileDropTargeted
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

    private var fileTable: some View {
        @Bindable var sftpSession = sftpSession
        return Table(
            sftpSession.filteredFiles,
            selection: $sftpSession.selection,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("Name") { file in
                nameCell(file) {
                    Label {
                        Text(file.name)
                    } icon: {
                        Image(systemName: file.kind.symbol)
                            .foregroundStyle(file.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .customizationID("name")
            TableColumn("Size") { file in
                menuCell(file) {
                    Text(file.isDirectory ? "—" : file.size.formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 70, ideal: 90)
            .customizationID("size")
            TableColumn("Modified") { file in
                menuCell(file) {
                    Text(file.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 160)
            .customizationID("modified")
            TableColumn("Permissions") { file in
                menuCell(file) {
                    Text(file.permissionDescription).monospaced().foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 110)
            .customizationID("permissions")
            TableColumn("UID") { file in
                menuCell(file) {
                    Text(file.ownerUID.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 55, ideal: 70)
            .customizationID("uid")
            .defaultVisibility(.hidden)
            TableColumn("GID") { file in
                menuCell(file) {
                    Text(file.ownerGID.formatted())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 55, ideal: 70)
            .customizationID("gid")
            .defaultVisibility(.hidden)
        }
        .onDrop(
            of: [.fileURL],
            delegate: FileURLDropTarget(
                isTargeted: $isDropTargeted,
                receive: receiveDroppedURLs
            )
        )
        .overlay(alignment: .bottomLeading) {
            if !sftpSession.hint.isEmpty {
                Text(sftpSession.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(Metrics.Space.m)
                    .allowsHitTesting(false)
            }
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
        }
        Button(targets.count == 1 ? "Delete" : "Delete \(targets.count) Items", role: .destructive) {
            deleteTargets = targets
        }
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
                NSWorkspace.shared.open(localURL)
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

    private func menuCell<Content: View>(
        _ file: RemoteFile, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .contextMenu { fileMenu(file) }
    }

    @ViewBuilder
    private func nameCell<Content: View>(
        _ file: RemoteFile, @ViewBuilder content: () -> Content
    ) -> some View {
        let cell = menuCell(file, content: content)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { primaryAction(file) }
            )
        cell.onDrag { remoteDragProvider(for: file) }
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
