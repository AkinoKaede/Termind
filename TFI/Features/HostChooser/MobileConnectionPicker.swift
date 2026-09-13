import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileWorkspaceToolbar: ToolbarContent {
    let hasWorkspaces: Bool
    let hasHistory: Bool
    let closeAll: () -> Void
    let clearHistory: () -> Void
    let connect: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Connect", systemImage: "network", action: connect)
                .labelStyle(.iconOnly)
            Menu {
                Button("Clear History", systemImage: "trash", role: .destructive, action: clearHistory)
                    .disabled(!hasHistory)
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
    let library: HostLibraryModel
    let cancel: () -> Void

    init(
        library: HostLibraryModel,
        connect: @escaping (Host.ID, ConnectionHistoryEntry.Kind) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.library = library
        _model = State(initialValue: MobileConnectionPickerModel(connect: connect))
        self.cancel = cancel
    }

    var body: some View {
        MobileHostPicker(
            library: library,
            title: "Connect",
            emptyDescription: "Add a host to connect to it.",
            cancel: cancel,
            select: model.select
        ) {
            Section {
                Picker("Connection Protocol", selection: $model.kind) {
                    Text("SSH").tag(ConnectionHistoryEntry.Kind.ssh)
                    Text("SFTP").tag(ConnectionHistoryEntry.Kind.sftp)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct MobileHostPicker<Header: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var model: MobileHostPickerModel
    let title: LocalizedStringKey
    let emptyDescription: LocalizedStringKey
    let cancel: () -> Void
    let select: (Host) -> Void
    let header: Header

    init(
        library: HostLibraryModel,
        title: LocalizedStringKey,
        emptyDescription: LocalizedStringKey,
        cancel: @escaping () -> Void,
        select: @escaping (Host) -> Void,
        @ViewBuilder header: () -> Header
    ) {
        _model = State(initialValue: MobileHostPickerModel(library: library))
        self.title = title
        self.emptyDescription = emptyDescription
        self.cancel = cancel
        self.select = select
        self.header = header()
    }

    var body: some View {
        List {
            header

            if model.isLibraryEmpty {
                ContentUnavailableView(
                    "No Hosts", systemImage: "server.rack",
                    description: Text(emptyDescription)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if model.hosts.isEmpty {
                ContentUnavailableView.search(text: model.query)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(model.hosts) { host in
                        Button {
                            select(host)
                        } label: {
                            HStack(spacing: 12) {
                                HostSystemIcon(asset: distributionEntry(for: host)?.asset, size: 32)
                                    .tint(tint(for: host))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name).foregroundStyle(.primary).lineLimit(1)
                                    Text(model.loginAddress(for: host))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $model.query, prompt: "Search hosts")
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
            }
        }
    }

    private func distributionEntry(for host: Host) -> LinuxDistributionIconEntry? {
        LinuxDistributionIconCatalog.entry(for: host.detectedDistribution)
    }

    private func tint(for host: Host) -> Color {
        host.colorTag.color
            ?? distributionEntry(for: host).flatMap {
                LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme)
            }
            ?? .accentColor
    }
}

extension MobileHostPicker where Header == EmptyView {
    init(
        library: HostLibraryModel,
        title: LocalizedStringKey,
        emptyDescription: LocalizedStringKey,
        cancel: @escaping () -> Void,
        select: @escaping (Host) -> Void
    ) {
        self.init(
            library: library,
            title: title,
            emptyDescription: emptyDescription,
            cancel: cancel,
            select: select,
            header: { EmptyView() })
    }
}
