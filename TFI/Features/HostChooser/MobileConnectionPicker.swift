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
        ToolbarItem(placement: .primaryAction) {
            Button("Connect", systemImage: "network", action: connect)
                .labelStyle(.iconOnly)
        }
        .mobileProminentAction()
        MobileToolbarOverflow {
            Button("Close All Workspaces", systemImage: "xmark") {
                closeAll()
            }
            .disabled(!hasWorkspaces)
            Divider()
            Button("Clear History", systemImage: "trash", role: .destructive, action: clearHistory)
                .disabled(!hasHistory)
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
            select: model.select,
            isEligible: { host in model.kind != .sftp || host.sshEnabled },
            header: {
                Section {
                    Picker("Connection Protocol", selection: $model.kind) {
                        Text("SSH").tag(ConnectionHistoryEntry.Kind.ssh)
                        Text("SFTP").tag(ConnectionHistoryEntry.Kind.sftp)
                    }
                    .pickerStyle(.segmented)
                }
            }
        )
    }
}

struct MobileHostPickerRow<Accessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let host: Host
    let loginAddress: String
    @ViewBuilder let accessory: Accessory

    init(host: Host, loginAddress: String, @ViewBuilder accessory: () -> Accessory) {
        self.host = host
        self.loginAddress = loginAddress
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            HostSystemIcon(asset: distributionEntry?.asset, size: 36)
                .tint(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).foregroundStyle(.primary).lineLimit(1)
                Text(loginAddress)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private var distributionEntry: LinuxDistributionIconEntry? {
        LinuxDistributionIconCatalog.entry(for: host.detectedDistribution)
    }

    private var tint: Color {
        host.colorTag.color
            ?? distributionEntry.flatMap {
                LinuxDistributionBrandColor.color(hex: $0.hex, colorScheme: colorScheme)
            }
            ?? .accentColor
    }
}

extension MobileHostPickerRow where Accessory == EmptyView {
    init(host: Host, loginAddress: String) {
        self.init(host: host, loginAddress: loginAddress) { EmptyView() }
    }
}

struct MobileHostPicker<Header: View>: View {
    @State private var model: MobileHostPickerModel
    let title: LocalizedStringKey
    let emptyDescription: LocalizedStringKey
    let cancel: () -> Void
    let select: (Host) -> Void
    let isEligible: (Host) -> Bool
    let header: Header

    init(
        library: HostLibraryModel,
        useCase: HostUseCase? = nil,
        title: LocalizedStringKey,
        emptyDescription: LocalizedStringKey,
        cancel: @escaping () -> Void,
        select: @escaping (Host) -> Void,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        @ViewBuilder header: () -> Header
    ) {
        _model = State(initialValue: MobileHostPickerModel(library: library, useCase: useCase))
        self.title = title
        self.emptyDescription = emptyDescription
        self.cancel = cancel
        self.select = select
        self.isEligible = isEligible
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
            } else if eligibleHosts.isEmpty {
                ContentUnavailableView.search(text: model.query)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(eligibleHosts) { host in
                        Button {
                            select(host)
                        } label: {
                            MobileHostPickerRow(
                                host: host,
                                loginAddress: model.loginAddress(for: host))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $model.query.singleLineText, prompt: "Search hosts")
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var eligibleHosts: [Host] { model.hosts.filter(isEligible) }
}

extension MobileHostPicker where Header == EmptyView {
    init(
        library: HostLibraryModel,
        useCase: HostUseCase? = nil,
        title: LocalizedStringKey,
        emptyDescription: LocalizedStringKey,
        cancel: @escaping () -> Void,
        select: @escaping (Host) -> Void,
        isEligible: @escaping (Host) -> Bool = { _ in true }
    ) {
        self.init(
            library: library,
            useCase: useCase,
            title: title,
            emptyDescription: emptyDescription,
            cancel: cancel,
            select: select,
            isEligible: isEligible,
            header: { EmptyView() })
    }
}
