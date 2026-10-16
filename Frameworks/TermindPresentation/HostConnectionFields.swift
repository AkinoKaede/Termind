import SwiftUI
import TermindDomain

import struct TermindDomain.Host

/// The same host metadata form inside a desktop work column or a mobile sheet.
public struct HostOrganizationSection<GroupField: View, TagsField: View>: View {
    @Binding private var host: Host
    private let groupField: GroupField
    private let tagsField: TagsField

    public init(
        host: Binding<Host>,
        @ViewBuilder groupField: () -> GroupField,
        @ViewBuilder tagsField: () -> TagsField
    ) {
        _host = host
        self.groupField = groupField()
        self.tagsField = tagsField()
    }

    public var body: some View {
        Section(AppStrings.Vault.host.swiftUIKey) {
            VaultNameField(text: $host.name, prompt: Text(verbatim: host.defaultName))
                .disabled(host.isTailscaleManaged)
            groupField.disabled(host.isTailscaleManaged)
            HostIconPicker(selection: $host.iconOverrideID)
            tagsField
            VaultColorField(selection: $host.colorTag)
        }
    }
}

/// Selects the protocol profile being edited.
public struct HostProtocolProfileControls: View {
    @Binding private var connectionProtocol: HostTerminalProtocol

    public init(protocol connectionProtocol: Binding<HostTerminalProtocol>) {
        _connectionProtocol = connectionProtocol
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Protocol Profile", selection: $connectionProtocol) {
                ForEach([HostTerminalProtocol.ssh, .telnet]) { connectionProtocol in
                    Text(connectionProtocol.displayName).tag(connectionProtocol)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The protocol-specific connection form inside a desktop work column or a mobile sheet.
public struct HostConnectionFields: View {
    @Binding private var host: Host
    private let connectionProtocol: HostTerminalProtocol

    public init(host: Binding<Host>, protocol connectionProtocol: HostTerminalProtocol) {
        _host = host
        self.connectionProtocol = connectionProtocol
    }

    public init(host: Binding<Host>) {
        _host = host
        connectionProtocol = .ssh
    }

    public var body: some View {
        Section(AppStrings.Settings.connection.swiftUIKey) {
            LabeledContent(AppStrings.Vault.host.swiftUIKey) {
                TextField(
                    AppStrings.Vault.host.swiftUIKey, text: $host.host.singleLineText,
                    prompt: Text("IP address or hostname"), axis: .horizontal
                ).singleLinePaste().lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    #endif
            }
            Toggle(AppStrings.Common.enabled.swiftUIKey, isOn: enabled)
                .toggleStyle(.switch)
            if host.isEnabled(connectionProtocol) {
                LabeledContent(AppStrings.Common.port.swiftUIKey) {
                    TextField(AppStrings.Common.port.swiftUIKey, value: port, format: .number.grouping(.never))
                        .lineLimit(1)
                        .labelsHidden().multilineTextAlignment(.trailing)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                }
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { connectionProtocol == .ssh ? host.sshEnabled : host.telnetEnabled },
            set: {
                if connectionProtocol == .ssh { host.sshEnabled = $0 } else { host.telnetEnabled = $0 }
            })
    }

    private var port: Binding<Int> {
        Binding(
            get: { connectionProtocol == .ssh ? host.sshPort : host.telnetPort },
            set: {
                if connectionProtocol == .ssh { host.sshPort = $0 } else { host.telnetPort = $0 }
            })
    }
}
