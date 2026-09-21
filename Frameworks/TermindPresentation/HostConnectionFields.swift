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

    public init(host: Binding<Host>) { _host = host }

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
            LabeledContent("Port") {
                TextField("Port", value: $host.port, format: .number.grouping(.never)).lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }
        }
    }
}
