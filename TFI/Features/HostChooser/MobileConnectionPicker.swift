import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileWorkspaceToolbar: ToolbarContent {
    let hasWorkspaces: Bool
    let closeAll: () -> Void
    let connect: () -> Void
    let batchStartup: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(AppStrings.Common.connect.swiftUIKey, systemImage: "network", action: connect)
                .labelStyle(.iconOnly)
        }
        .mobileProminentAction()
        MobileToolbarOverflow {
            Button(AppStrings.Vault.batchStartup, systemImage: "wind", action: batchStartup)
            Divider()
            Button(AppStrings.Vault.closeAll.swiftUIKey, systemImage: "xmark", role: .destructive) {
                closeAll()
            }
            .disabled(!hasWorkspaces)
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
            title: AppStrings.Common.connect,
            emptyDescription: AppStrings.Vault.addAHostToConnectToIt,
            cancel: cancel,
            select: model.select,
            isEligible: { model.kind.kind(for: $0) != nil },
            header: {
                MobileConnectionProtocolPicker(selection: $model.kind)
            }
        )
    }
}

struct MobileConnectionProtocolPicker: View {
    @Binding var selection: MobileConnectionProtocol

    var body: some View {
        Section {
            Picker(AppStrings.Vault.connectionProtocol.swiftUIKey, selection: $selection) {
                Text(AppStrings.Vault.ssh).tag(MobileConnectionProtocol.ssh)
                Text(AppStrings.SFTP.sftp).tag(MobileConnectionProtocol.sftp)
            }
            .pickerStyle(.segmented)
        }
    }
}

struct MobileHostPickerRow<Accessory: View>: View {

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
            HostDistributionIcon(host: host)
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
}

extension MobileHostPickerRow where Accessory == EmptyView {
    init(host: Host, loginAddress: String) {
        self.init(host: host, loginAddress: loginAddress) { EmptyView() }
    }
}

struct MobileHostPicker<Header: View>: View {
    @State private var model: MobileHostPickerModel
    let title: LocalizedStringResource
    let emptyDescription: LocalizedStringResource
    let cancel: () -> Void
    let select: (Host) -> Void
    let isEligible: (Host) -> Bool
    let header: Header

    init(
        library: HostLibraryModel,
        title: LocalizedStringResource,
        emptyDescription: LocalizedStringResource,
        cancel: @escaping () -> Void,
        select: @escaping (Host) -> Void,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        @ViewBuilder header: () -> Header
    ) {
        _model = State(initialValue: MobileHostPickerModel(library: library))
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
                    AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack",
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
        .searchable(text: $model.query.singleLineText, prompt: AppStrings.Vault.searchHosts.swiftUIKey)
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var eligibleHosts: [Host] { model.hosts.filter(isEligible) }
}
