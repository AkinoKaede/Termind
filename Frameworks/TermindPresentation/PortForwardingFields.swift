import SwiftUI
import TermindDomain

public struct PortForwardingFields: View {
    @Binding private var rule: PortForwardingRule
    public init(rule: Binding<PortForwardingRule>) { _rule = rule }

    public var body: some View {
        Section("Port Forwarding") {
            TextField("Name", text: $rule.label.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                .textFieldStyle(
                    .automatic
                ).multilineTextAlignment(.leading)
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
