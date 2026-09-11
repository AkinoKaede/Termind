import Observation
import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

struct MobileWorkspaceToolbar: ToolbarContent {
    let hasWorkspaces: Bool
    let closeAll: () -> Void
    let connect: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Connect", systemImage: "network", action: connect)
                .labelStyle(.iconOnly)
            Menu {
                Button("Close All Workspaces", systemImage: "rectangle.stack.badge.minus", role: .destructive) {
                    closeAll()
                }
                .disabled(!hasWorkspaces)
            } label: {
                MobileOverflowMenuLabel("More")
            }
        }
    }
}

struct MobileConnectionPicker: View {
    @State private var model: MobileConnectionPickerModel
    let cancel: () -> Void

    init(
        library: HostLibraryModel,
        connect: @escaping (Host.ID, MobileWorkspaceDescriptor.Kind) -> Void,
        cancel: @escaping () -> Void
    ) {
        _model = State(initialValue: MobileConnectionPickerModel(library: library, connect: connect))
        self.cancel = cancel
    }

    var body: some View {
        List {
            Section {
                Picker("Connection Protocol", selection: $model.kind) {
                    Text("SSH").tag(MobileWorkspaceDescriptor.Kind.ssh)
                    Text("SFTP").tag(MobileWorkspaceDescriptor.Kind.sftp)
                }
                .pickerStyle(.segmented)
            }

            if model.isLibraryEmpty {
                ContentUnavailableView(
                    "No Hosts", systemImage: "server.rack",
                    description: Text("Add a host to connect to it.")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if model.hosts.isEmpty {
                ContentUnavailableView.search(text: model.query)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Section("Hosts") {
                    ForEach(model.hosts) { host in
                        Button {
                            model.select(host)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                    Text(model.loginAddress(for: host))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            } icon: {
                                Image(systemName: "server.rack")
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $model.query, prompt: "Search hosts")
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
            }
        }
    }
}

@MainActor
@Observable
final class MobileConnectionPickerModel {
    var kind = MobileWorkspaceDescriptor.Kind.ssh
    var query = ""

    private let library: HostLibraryModel
    private let connect: (Host.ID, MobileWorkspaceDescriptor.Kind) -> Void

    init(
        library: HostLibraryModel,
        connect: @escaping (Host.ID, MobileWorkspaceDescriptor.Kind) -> Void
    ) {
        self.library = library
        self.connect = connect
    }

    var isLibraryEmpty: Bool { library.hosts.isEmpty }

    var hosts: [Host] { library.searchHosts(query) }

    func loginAddress(for host: Host) -> String { library.loginAddress(for: host) }

    func select(_ host: Host) { connect(host.id, kind) }
}
