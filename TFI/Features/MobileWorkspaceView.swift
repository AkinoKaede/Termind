import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure
import UIKit
import UniformTypeIdentifiers

struct MobileWorkspaceView: View {
    let library: HostLibraryModel
    let pro: ProAccessController
    let commandGenerator: any CommandGenerating
    @Bindable var workspace: MobileWorkspace
    let workspaces: [MobileWorkspace]
    let selectWorkspace: (UUID) -> Void
    let closeWorkspace: (UUID) -> Void
    @State private var showingHistory = false
    @State private var importing = false
    @State private var directoryName = ""
    @State private var creatingDirectory = false
    @State private var deleting: RemoteFile?
    @State private var renaming: RemoteFile?
    @State private var editingPermissions: RemoteFile?
    @State private var showingTransfers = false
    @State private var uploadConflictPresented = false
    @State private var uploadDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if workspace.descriptor.kind == .ssh {
                ZStack {
                    VStack(spacing: 0) {
                        TerminalSurfaceView(context: workspace.terminal)
                            .id(workspace.id)
                            .onChange(of: workspace.terminalSettings.preferences, initial: true) { _, value in
                                workspace.terminal.applyPreferences(value)
                            }
                            .onTapGesture { workspace.terminal.requestFocus() }
                        MobileTerminalKeyboard(state: workspace.terminal)
                    }.opacity(showsJourney ? 0 : 1)
                        .allowsHitTesting(!showsJourney).accessibilityHidden(showsJourney)
                    if showsJourney { connectionJourney.background(.background) }
                }
            } else if showsJourney {
                connectionJourney
            } else {
                List {
                    ForEach(workspace.files) { file in
                        Button {
                            open(file)
                        } label: {
                            Label(file.name, systemImage: file.kind.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(!workspace.connected)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renaming = file }
                            Button("Edit Permissions", systemImage: "lock.shield") { editingPermissions = file }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }
                        }
                        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { deleting = file } }
                    }
                }
                .refreshable { await workspace.openDirectory(workspace.path) }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if workspace.descriptor.kind == .ssh,
                    workspace.commandGeneratorState != .idle
                {
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
            if uploadDropTargeted {
                MobileUploadDropOverlay(
                    title: uploadDropTitle,
                    detail: uploadDropDetail,
                    available: workspace.uploadTargetProblem == nil
                )
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            receiveUpload(urls)
        } isTargeted: { targeted in
            uploadDropTargeted = targeted
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
                    Label(
                        candidate.descriptor.title,
                        systemImage: candidate.id == workspace.id ? "checkmark" : candidate.descriptor.kind.symbol
                    )
                }
            }
        }
        .modifier(MobileTerminalSearchModifier(workspace: workspace))
        .toolbar {
            if workspace.descriptor.kind == .ssh {
                Button("History", systemImage: "clock") { showingHistory = true }
                    .labelStyle(.iconOnly)
                Menu {
                    Button("Close", systemImage: "xmark", role: .destructive) {
                        closeWorkspace(workspace.id)
                    }
                    Divider()
                    Button("Generate Command", systemImage: "sparkles") {
                        workspace.generateCommand(using: commandGenerator)
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    Divider()
                    Button("Next Match", systemImage: "chevron.down") {
                        workspace.navigateFind(previous: false)
                    }
                    .keyboardShortcut("g", modifiers: .command)
                    Button("Previous Match", systemImage: "chevron.up") {
                        workspace.navigateFind(previous: true)
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
            if workspace.descriptor.kind == .sftp {
                Menu {
                    Button("Close", systemImage: "xmark", role: .destructive) {
                        closeWorkspace(workspace.id)
                    }
                    Divider()
                    Button("Transfers", systemImage: "arrow.up.arrow.down") { showingTransfers = true }
                    Divider()
                    Button("Parent Directory", systemImage: "arrow.up") {
                        Task { await workspace.openDirectory(RemotePath.parent(of: workspace.path)) }
                    }
                    .disabled(!workspace.connected)
                    Divider()
                    Button("Upload", systemImage: "square.and.arrow.up") { importing = true }
                        .disabled(!workspace.connected)
                    Button("New Folder", systemImage: "folder.badge.plus") { creatingDirectory = true }
                        .disabled(!workspace.connected)
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
        }
        .sheet(isPresented: $showingHistory) { MobileCommandHistoryView(workspace: workspace) }
        .sheet(item: $renaming) { MobileRemoteFileEditor(workspace: workspace, file: $0, mode: .rename) }
        .sheet(item: $editingPermissions) { MobileRemoteFileEditor(workspace: workspace, file: $0, mode: .permissions) }
        .sheet(isPresented: $showingTransfers) {
            NavigationStack {
                if let transfers = workspace.transfers { MobileTransfersView(transfers: transfers) }
            }.mobileSheetPresentation(compact: true)
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
        .onChange(of: workspace.uploadConflictCount) { _, count in
            uploadConflictPresented = count > 0
        }
        .onChange(of: uploadConflictPresented) { wasPresented, isPresented in
            if wasPresented, !isPresented, workspace.hasPendingUploadConflict {
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
            TextField("Name", text: $directoryName)
            Button("Create") {
                Task {
                    await workspace.createDirectory(directoryName)
                    directoryName = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete File?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = deleting { Task { await workspace.delete(file) } }
                deleting = nil
            }
        }
        .alert(
            workspace.descriptor.kind == .ssh
                ? String(localized: "Upload Failed")
                : String(localized: "SFTP Error"),
            isPresented: Binding(
                get: { workspace.operationError != nil },
                set: { if !$0 { workspace.operationError = nil } })
        ) {
            Button("OK", role: .cancel) { workspace.operationError = nil }
        } message: {
            Text(workspace.operationError ?? "")
        }
    }

    private func open(_ file: RemoteFile) {
        if file.isDirectory {
            Task { await workspace.openDirectory(file.path) }
        } else {
            workspace.download(file)
            showingTransfers = true
        }
    }

    private var uploadConflictTitle: String {
        workspace.uploadConflictCount == 1
            ? String(localized: "1 item already exists")
            : String(localized: "\(workspace.uploadConflictCount) items already exist")
    }

    private var uploadDropTitle: String {
        if workspace.uploadTargetProblem != nil {
            return String(localized: "Can't Upload Here")
        }
        let hostName = library.host(workspace.descriptor.hostID)?.name ?? workspace.descriptor.title
        return String(localized: "Upload to \(hostName)")
    }

    private var uploadDropDetail: String {
        workspace.uploadTargetProblem
            ?? workspace.uploadDestination
            ?? String(localized: "The upload destination is unavailable.")
    }

    private func receiveUpload(_ urls: [URL]) -> Bool {
        if workspace.descriptor.kind == .ssh,
            !pro.require(.terminalFileUpload)
        {
            return false
        }
        return workspace.prepareUpload(urls)
    }

    private func enqueuePendingUpload(_ policy: TransferConflictPolicy) {
        workspace.enqueuePendingUpload(policy)
        uploadConflictPresented = false
    }

    private var showsJourney: Bool {
        workspace.journey.isPresented || workspace.authenticationRequired || workspace.pendingHostKey != nil
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
    let notice: MobileUploadNotice

    var body: some View {
        MobileTransientOverlay {
            symbol
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
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
        case .queued:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .rejected:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch notice {
        case .preparing: String(localized: "Preparing upload…")
        case .queued(let count, _):
            count == 1
                ? String(localized: "Added 1 item to Transfers")
                : String(localized: "Added \(count) items to Transfers")
        case .rejected: String(localized: "Can't upload here")
        }
    }

    private var detail: String {
        switch notice {
        case .preparing(let path), .queued(_, let path): path
        case .rejected(let reason): reason
        }
    }
}

private struct MobileUploadDropOverlay: View {
    let title: String
    let detail: String
    let available: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: available ? "arrow.up.doc.fill" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(available ? Color.accentColor : .orange)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
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

private struct MobileTerminalSearchModifier: ViewModifier {
    @Bindable var workspace: MobileWorkspace
    @State private var queryRevision: UInt64 = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if workspace.descriptor.kind == .ssh {
            searchable(content)
        } else {
            content
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
            .onSubmit(of: .search) { workspace.navigateFind(previous: true) }
    }

    private var query: Binding<String> {
        Binding(
            get: { workspace.findQuery },
            set: { query in
                queryRevision &+= 1
                let revision = queryRevision
                guard query.isEmpty else {
                    workspace.updateFindQuery(query)
                    return
                }

                // SwiftUI clears the text binding when its native Close button
                // dismisses search. Defer an empty value for one turn so a
                // genuine clear is still sent to Ghostty while dismissal keeps
                // the retained query for the next presentation.
                DispatchQueue.main.async {
                    guard revision == queryRevision, workspace.isFindPresented else { return }
                    workspace.updateFindQuery("")
                }
            }
        )
    }

    private var presentation: Binding<Bool> {
        Binding(
            get: { workspace.isFindPresented },
            set: { presented in
                if presented {
                    queryRevision &+= 1
                    workspace.presentFind()
                } else if workspace.isFindPresented {
                    workspace.dismissFind()
                }
            }
        )
    }
}
