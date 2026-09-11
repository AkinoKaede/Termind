import GhosttyTerminal
import SwiftUI
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure
import UniformTypeIdentifiers

struct MobileWorkspaceView: View {
    @Bindable var workspace: MobileWorkspace
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
                TerminalSurfaceView(context: workspace.terminal)
                    .id(workspace.id)
                    .onTapGesture { workspace.terminal.requestFocus() }
                MobileTerminalKeyboard(state: workspace.terminal)
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
            "Trust Host Key?",
            isPresented: Binding(
                get: { workspace.pendingHostKey != nil }, set: { if !$0 { workspace.pendingHostKey = nil } })
        ) {
            Button("Trust") { workspace.trustHostKey() }
            Button("Cancel", role: .cancel) { workspace.pendingHostKey = nil }
        } message: {
            Text(
                workspace.pendingHostKey.map {
                    "\($0.hostname):\($0.port)\n\($0.algorithm.rawValue)\n\($0.fingerprint)"
                } ?? "")
        }
        .sheet(isPresented: $workspace.authenticationRequired) {
            NavigationStack {
                Form {
                    TextField("Username", text: $workspace.username).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text(workspace.authenticationHostName).font(.headline)
                    SecureField("Password", text: $workspace.password)
                    SecureField("Passphrase", text: $workspace.passphrase)
                }
                .navigationTitle("Authentication")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            workspace.cancelAuthentication()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") {
                            workspace.submitAuthentication()
                        }
                    }
                }
            }.presentationDetents([.medium, .large])
                .onDisappear {
                    workspace.password = ""
                    workspace.passphrase = ""
                }
        }
        .alert(
            "Connection Error",
            isPresented: Binding(
                get: { workspace.error != nil && !workspace.authenticationRequired },
                set: { if !$0 { workspace.error = nil } })
        ) {
            Button("OK", role: .cancel) { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
    }
}
