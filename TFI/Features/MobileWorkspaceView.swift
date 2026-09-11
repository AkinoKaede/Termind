import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure
import UniformTypeIdentifiers

struct MobileWorkspaceView: View {
    let library: HostLibraryModel
    @Bindable var workspace: MobileWorkspace
    @State private var showingHistory = false
    @FocusState private var findFocused: Bool
    @State private var importing = false
    @State private var directoryName = ""
    @State private var creatingDirectory = false
    @State private var deleting: RemoteFile?
    @State private var renaming: RemoteFile?
    @State private var editingPermissions: RemoteFile?
    @State private var showingTransfers = false

    var body: some View {
        VStack(spacing: 0) {
            if workspace.descriptor.kind == .ssh {
                ZStack {
                    VStack(spacing: 0) {
                        if workspace.isFindPresented { findBar }
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
                    Button("Parent Directory", systemImage: "arrow.up") {
                        Task { await workspace.openDirectory(RemotePath.parent(of: workspace.path)) }
                    }
                    ForEach(workspace.files) { file in
                        Menu {
                            if file.isDirectory {
                                Button("Open", systemImage: "folder") {
                                    Task { await workspace.openDirectory(file.path) }
                                }
                            } else {
                                Button("Download", systemImage: "square.and.arrow.down") {
                                    workspace.download(file)
                                    showingTransfers = true
                                }
                            }
                            Button("Rename", systemImage: "pencil") { renaming = file }
                            Button("Edit Permissions", systemImage: "lock.shield") { editingPermissions = file }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = file }
                        } label: {
                            Label(file.name, systemImage: file.kind.symbol)
                        }
                        .disabled(!workspace.connected)
                        .swipeActions { Button("Delete", role: .destructive) { deleting = file } }
                    }
                }
                .refreshable { await workspace.openDirectory(workspace.path) }
            }
            HStack {
                Circle().fill(workspace.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(workspace.status).font(.caption)
                Spacer()
                if workspace.busy { ProgressView().controlSize(.small) }
                Button(workspace.connected ? String(localized: "Disconnect") : String(localized: "Connect")) {
                    if workspace.connected { workspace.disconnect() } else { workspace.connect() }
                }.disabled(workspace.busy)
            }.padding(12).background(.bar)
        }
        .navigationTitle(workspace.descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if workspace.descriptor.kind == .ssh {
                Button("Find", systemImage: "magnifyingglass") {
                    workspace.presentFind()
                    findFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("History", systemImage: "clock") { showingHistory = true }
                Menu {
                    Button("Next Match") {
                        workspace.navigateFind(previous: false)
                        findFocused = true
                    }
                    .keyboardShortcut("g", modifiers: .command)
                    Button("Previous Match") {
                        workspace.navigateFind(previous: true)
                        findFocused = true
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            if workspace.descriptor.kind == .sftp {
                Button("Transfers", systemImage: "arrow.up.arrow.down") { showingTransfers = true }
                Menu {
                    Button("Upload", systemImage: "square.and.arrow.up") { importing = true }
                    Button("New Folder", systemImage: "folder.badge.plus") { creatingDirectory = true }
                } label: {
                    Image(systemName: "plus")
                }.disabled(!workspace.connected)
            }
        }
        .sheet(isPresented: $showingHistory) { MobileCommandHistoryView(workspace: workspace) }
        .sheet(item: $renaming) { MobileRemoteFileEditor(workspace: workspace, file: $0, mode: .rename) }
        .sheet(item: $editingPermissions) { MobileRemoteFileEditor(workspace: workspace, file: $0, mode: .permissions) }
        .sheet(isPresented: $showingTransfers) {
            NavigationStack {
                if let transfers = workspace.transfers { MobileTransfersView(transfers: transfers) }
            }.presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                Task {
                    await workspace.upload(url)
                    showingTransfers = true
                }
            case .failure(let error): workspace.error = error.localizedDescription
            }
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
            "Connection Error",
            isPresented: Binding(
                get: { workspace.error != nil && !workspace.authenticationRequired && !workspace.journey.isPresented },
                set: { if !$0 { workspace.error = nil } })
        ) {
            Button("OK", role: .cancel) { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
    }
    private var showsJourney: Bool {
        workspace.journey.isPresented || workspace.authenticationRequired || workspace.pendingHostKey != nil
    }

    private var connectionJourney: some View {
        MobileConnectionJourneyView(
            journey: workspace.journey, library: library,
            authenticationPrompt: workspace.authenticationPrompt, hostKey: workspace.hostKeyPrompt,
            submit: { identity, username, password, passphrase, key, save in
                workspace.submitAuthentication(
                    identityID: identity, username: username, password: password,
                    passphrase: passphrase, keyID: key, save: save)
            }, accept: { workspace.trustHostKey(remember: $0) }, retry: { workspace.connect() },
            cancel: { workspace.disconnect() })
    }

    private var findBar: some View {
        HStack {
            TextField("Find", text: Binding(get: { workspace.findQuery }, set: { workspace.updateFindQuery($0) }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($findFocused)
                .onSubmit { workspace.navigateFind(previous: true) }
            Button("Previous Match", systemImage: "chevron.up") { workspace.navigateFind(previous: true) }
            Button("Next Match", systemImage: "chevron.down") { workspace.navigateFind(previous: false) }
            Button("Close", systemImage: "xmark") { workspace.dismissFind() }.keyboardShortcut(.escape, modifiers: [])
        }.labelStyle(.iconOnly).padding(8).background(.bar)
            .onAppear { findFocused = true }
    }

}
