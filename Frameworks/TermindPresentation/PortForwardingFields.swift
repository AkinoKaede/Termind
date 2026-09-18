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
        guard !name.isEmpty else { return Text(verbatim: "") }
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
            Text(directionDescription).font(.caption).foregroundStyle(.secondary)
            LabeledContent("Bind Address") {
                TextField("Bind Address", text: $rule.bindHost.singleLineText, axis: .horizontal).singleLinePaste()
                    .lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
            }
            LabeledContent("Bind Port") {
                TextField("Bind Port", value: $rule.bindPort, format: .number.grouping(.never)).lineLimit(1)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }
            if rule.kind != .dynamic {
                LabeledContent("Target Host") {
                    TextField(
                        "Target Host",
                        text: Binding(get: { rule.targetHost ?? "localhost" }, set: { rule.targetHost = $0 })
                            .singleLineText, axis: .horizontal
                    ).singleLinePaste().lineLimit(1).labelsHidden().multilineTextAlignment(.trailing)
                }
                LabeledContent("Target Port") {
                    TextField(
                        "Target Port", value: Binding(get: { rule.targetPort ?? 80 }, set: { rule.targetPort = $0 }),
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
    private var directionDescription: String {
        switch rule.kind {
        case .local: String(localized: "This Device → SSH Host → Target")
        case .remote: String(localized: "SSH Host → This Device → Target")
        case .dynamic: String(localized: "SOCKS5 on This Device → SSH Host → Requested Target")
        }
    }

}

public struct PortForwardingDirectionPicker: View {
    @Binding private var kind: PortForwardingRule.Kind
    public init(kind: Binding<PortForwardingRule.Kind>) { _kind = kind }
    public var body: some View {
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
