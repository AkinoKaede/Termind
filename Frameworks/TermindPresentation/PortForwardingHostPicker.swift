import SwiftUI
import TermindDomain

import struct TermindDomain.Host

public struct PortForwardingHostPicker: View {
    @Binding private var rule: PortForwardingRule
    private let hosts: [Host]

    public init(rule: Binding<PortForwardingRule>, hosts: [Host]) {
        _rule = rule
        self.hosts = hosts
    }

    public var body: some View {
        Section("Host") {
            Picker("Host", selection: selection) {
                Text("Select Host").tag(UUID?.none)
                ForEach(hosts) { host in
                    Text(PortForwardingHostPickerPresentation.title(for: host)).tag(Optional(host.id))
                }
            }
            if hosts.isEmpty {
                Text("Add a host before creating a forwarding rule.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { hosts.contains { $0.id == rule.hostID } ? rule.hostID : nil },
            set: { rule.hostID = $0 ?? UUID() })
    }
}

nonisolated enum PortForwardingHostPickerPresentation {
    static func title(for host: Host) -> String { host.name }
}
