import SwiftUI
import TermindDomain

import struct TermindDomain.Host

public struct PortForwardingFields: View {
    @Binding private var rule: PortForwardingRule
    private let host: Host?

    public init(rule: Binding<PortForwardingRule>, host: Host?) {
        _rule = rule
        self.host = host
    }

    private var namePrompt: Text {
        guard let host else { return Text(verbatim: "") }
        let name = SavedName.resolve(host.name, default: host.defaultName)
        return Text(verbatim: rule.defaultName(hostName: name))
    }

    public var body: some View {
        Section("Port Forwarding") {
            TextField("Name", text: $rule.label.singleLineText, prompt: namePrompt, axis: .horizontal)
                .singleLinePaste().lineLimit(1)
                .textFieldStyle(
                    .automatic
                ).multilineTextAlignment(.leading)
            #if os(macOS)
                LabeledContent("Color") {
                    ColorTagPicker(selection: $rule.colorTag, layout: .compact)
                }
            #else
                VStack(alignment: .leading, spacing: 12) {
                    Text("Color")
                    ColorTagPicker(selection: $rule.colorTag, layout: .touch)
                }
            #endif
            PortForwardingDirectionPicker(kind: $rule.kind)
            Text(LocalizedStringKey(PortForwardingFieldPresentation.directionDescription(for: rule.kind)))
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Bind Address") {
                TextField("Bind Address", text: $rule.bindHost.singleLineText, axis: .horizontal).singleLinePaste()
                    .lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
            }
            let portLabel = LocalizedStringKey(PortForwardingFieldPresentation.portLabel(for: rule.kind))
            LabeledContent(portLabel) {
                TextField(portLabel, value: $rule.bindPort, format: .number.grouping(.never)).lineLimit(1)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }
            if PortForwardingFieldPresentation.showsDestination(for: rule.kind) {
                let destinationHostLabel = LocalizedStringKey("Destination Host (Port Forwarding)")
                LabeledContent(destinationHostLabel) {
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
}

nonisolated enum PortForwardingFieldPresentation {
    static func portLabel(for kind: PortForwardingRule.Kind) -> String {
        kind == .remote ? "Remote Port" : "Local Port"
    }

    static func directionDescription(for kind: PortForwardingRule.Kind) -> String {
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
        Picker("Direction", selection: $kind) {
            Text("Local").tag(PortForwardingRule.Kind.local).accessibilityLabel("Local Forward")
            Text("Remote").tag(PortForwardingRule.Kind.remote).accessibilityLabel("Remote Forward")
            Text("Dynamic").tag(PortForwardingRule.Kind.dynamic).accessibilityLabel("Dynamic SOCKS5 Proxy")
        }
        .labelsHidden().multilineTextAlignment(.trailing)
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }
}
