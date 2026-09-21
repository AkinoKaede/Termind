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
        Section {
            VaultNameField(text: $host.name, prompt: Text(verbatim: host.defaultName))
            groupField
            tagsField
            VaultColorField(selection: $host.colorTag)
        }
    }
}

/// The same connection form inside a desktop work column or a mobile sheet.
public struct HostConnectionFields: View {
    @Binding private var host: Host
    @Binding private var connectionProtocol: HostTerminalProtocol

    public init(host: Binding<Host>, protocol connectionProtocol: Binding<HostTerminalProtocol>) {
        _host = host
        _connectionProtocol = connectionProtocol
    }

    public init(host: Binding<Host>) {
        _host = host
        _connectionProtocol = .constant(.ssh)
    }

    public var body: some View {
        Section("Connection") {
            LabeledContent("Host") {
                TextField(
                    "Host", text: $host.host.singleLineText, prompt: Text("IP address or hostname"), axis: .horizontal
                ).singleLinePaste().lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    #endif
            }
            Picker("Protocol", selection: $connectionProtocol) {
                ForEach(HostTerminalProtocol.allCases) { connectionProtocol in
                    Text(connectionProtocol.displayName).tag(connectionProtocol)
                }
            }
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            Toggle("Enabled", isOn: enabled)
            LabeledContent("Port") {
                TextField("Port", value: port, format: .number.grouping(.never)).lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
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
