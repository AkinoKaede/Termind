import SwiftUI
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileVaultView: View {
    let app: MobileAppModel
    let open: (UUID, MobileWorkspaceDescriptor.Kind) -> Void
    @State private var query = ""
    @State private var editingHost: Host?
    @State private var deletingHost: Host?
    @State private var groupName = ""
    @State private var addingGroup = false
    @State private var importingSSH = false

    var body: some View {
        List {
            Section {
                NavigationLink("Keychain") { MobileCredentialsView(app: app) }
                NavigationLink("Snippets") { MobileSnippetsView(app: app) }
                NavigationLink("Known Hosts") { MobileKnownHostsView(app: app) }
                NavigationLink("Port Forwarding") { MobileForwardingsView(app: app) }
                NavigationLink("Transfers") { MobileTransfersView(transfers: app.transfers) }
            }
            if app.library.hosts.isEmpty {
                ContentUnavailableView(
                    "No Hosts", systemImage: "server.rack",
                    description: Text("Add a host to connect with SSH or SFTP."))
            }
            ForEach(app.library.groups) { group in
                Section(group.name) {
                    ForEach(app.library.searchHosts(query).filter { $0.groupID == group.id }) { row($0) }
                }
            }
            Section("Hosts") {
                ForEach(app.library.searchHosts(query).filter { $0.groupID == nil }) { row($0) }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Vault")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Host", systemImage: "server.rack") { editingHost = Host(name: "", host: "") }
                    Button("New Group", systemImage: "folder.badge.plus") { addingGroup = true }
                    Button("Import SSH Files", systemImage: "square.and.arrow.down") { importingSSH = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $importingSSH) { MobileSSHImportScreen(app: app) }
        .sheet(item: $editingHost) { MobileHostEditor(library: app.library, host: $0) }
        .sheet(isPresented: $addingGroup) {
            MobileEditorSheet(
                title: String(localized: "New Group"), isDirty: !groupName.isEmpty,
                canSave: !groupName.isEmpty, compact: true,
                save: {
                    app.library.upsert(HostGroup(name: groupName))
                    if let error = app.library.storageError { throw MobileEditorError.message(error) }
                    groupName = ""
                }
            ) { TextField("Name", text: $groupName) }
        }
        .confirmationDialog(
            "Delete Host?", isPresented: Binding(get: { deletingHost != nil }, set: { if !$0 { deletingHost = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let host = deletingHost { app.deleteHost(host.id) }
                deletingHost = nil
            }
        } message: {
            Text("Open connections and references to this host will be removed.")
        }
    }

    private func row(_ host: Host) -> some View {
        Menu {
            Button("SSH", systemImage: "terminal") { open(host.id, .ssh) }
            Button("SFTP", systemImage: "folder") { open(host.id, .sftp) }
            Button("Edit", systemImage: "pencil") { editingHost = host }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingHost = host }
        } label: {
            HStack {
                HostSystemIcon(asset: LinuxDistributionIconCatalog.entry(for: host.detectedDistribution)?.asset)
                VStack(alignment: .leading) {
                    Text(host.name).foregroundStyle(.primary)
                    Text(app.library.loginAddress(for: host)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
        }
    }
}
