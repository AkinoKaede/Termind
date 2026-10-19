import SwiftUI
import TermindDomain

import struct TermindDomain.Host

public struct PortForwardingFields: View {
    @Binding private var rule: PortForwardingRule
    private let hosts: [Host]

    public init(rule: Binding<PortForwardingRule>, hosts: [Host]) {
        _rule = rule
        self.hosts = hosts
    }

    private var namePrompt: Text {
        guard let host = selectedHost else { return Text(verbatim: "") }
        let name = SavedName.resolve(host.name, default: host.defaultName)
        return Text(verbatim: rule.defaultName(hostName: name))
    }

    public var body: some View {
        Section {
            VaultNameField(text: $rule.label, prompt: namePrompt)
            VaultColorField(selection: $rule.colorTag)
        }
        Section(AppStrings.Navigation.portForwarding.swiftUIKey) {
            Picker(AppStrings.Vault.host.swiftUIKey, selection: hostSelection) {
                Text("Select Host").tag(UUID?.none)
                ForEach(hosts) { host in
                    Text(PortForwardingFieldPresentation.hostTitle(for: host)).tag(Optional(host.id))
                }
            }
            if hosts.isEmpty {
                Text("Add a host before creating a forwarding rule.").font(.caption).foregroundStyle(.secondary)
            }
            PortForwardingDirectionPicker(kind: $rule.kind)
            Text(PortForwardingFieldPresentation.directionDescription(for: rule.kind))
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Bind Address") {
                TextField("Bind Address", text: $rule.bindHost.singleLineText, axis: .horizontal).singleLinePaste()
                    .lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
            }
            let portLabel = PortForwardingFieldPresentation.portLabel(for: rule.kind)
            LabeledContent(portLabel.swiftUIKey) {
                TextField(portLabel, value: $rule.bindPort, format: .number.grouping(.never)).lineLimit(1)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }
            if PortForwardingFieldPresentation.showsDestination(for: rule.kind) {
                let destinationHostLabel = LocalizedStringResource("Destination Host (Port Forwarding)")
                LabeledContent(destinationHostLabel.swiftUIKey) {
                    TextField(
                        destinationHostLabel,
                        text: Binding(get: { rule.targetHost ?? "localhost" }, set: { rule.targetHost = $0 })
                            .singleLineText, axis: .horizontal
                    ).singleLinePaste().lineLimit(1).labelsHidden().multilineTextAlignment(.trailing)
                }
                LabeledContent("Destination Port") {
                    TextField(
                        "Destination Port",
                        value: Binding(get: { rule.targetPort ?? 80 }, set: { rule.targetPort = $0 }),
                        format: .number.grouping(.never)
                    ).lineLimit(1).labelsHidden().multilineTextAlignment(.trailing)
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                }
            }
        }
        #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #endif
    }

    private var selectedHost: Host? { hosts.first { $0.id == rule.hostID } }

    private var hostSelection: Binding<UUID?> {
        Binding(
            get: { selectedHost?.id },
            set: { rule.hostID = $0 ?? UUID() }
        )
    }
}

private nonisolated enum PortForwardingFieldPresentation {
    static func hostTitle(for host: Host) -> String { host.name }

    static func portLabel(for kind: PortForwardingRule.Kind) -> LocalizedStringResource {
        kind == .remote ? "Remote Port" : "Local Port"
    }

    static func directionDescription(for kind: PortForwardingRule.Kind) -> LocalizedStringResource {
        #if os(macOS)
            switch kind {
            case .local: "This Mac → SSH Host → Destination"
            case .remote: "SSH Host → This Mac → Destination"
            case .dynamic: "SOCKS5 on This Mac → SSH Host → Requested Destination"
            }
        #else
            switch kind {
            case .local: "This Device → SSH Host → Destination"
            case .remote: "SSH Host → This Device → Destination"
            case .dynamic: "SOCKS5 on This Device → SSH Host → Requested Destination"
            }
        #endif
    }

    static func showsDestination(for kind: PortForwardingRule.Kind) -> Bool { kind != .dynamic }
}

private struct PortForwardingDirectionPicker: View {
    @Binding var kind: PortForwardingRule.Kind
    var body: some View {
        Picker(AppStrings.Forwarding.direction.swiftUIKey, selection: $kind) {
            Text("Local").tag(PortForwardingRule.Kind.local).accessibilityLabel("Local Forward")
            Text("Remote").tag(PortForwardingRule.Kind.remote).accessibilityLabel("Remote Forward")
            Text("Dynamic").tag(PortForwardingRule.Kind.dynamic).accessibilityLabel("Dynamic SOCKS5 Proxy")
        }
        .labelsHidden().multilineTextAlignment(.trailing)
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }
}
