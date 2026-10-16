import SwiftUI
import TermindDomain

import struct TermindDomain.Host

public struct HostTransportSection: View {
    @Binding private var host: Host

    public init(host: Binding<Host>) { _host = host }

    public var body: some View {
        Section(AppStrings.Transports.section.swiftUIKey) {
            Picker(
                AppStrings.Transports.defaultTransport.swiftUIKey, selection: $host.terminalTransports.defaultTransport
            ) {
                ForEach(host.terminalTransports.available(isTailscaleManaged: host.isTailscaleManaged)) { transport in
                    Label {
                        Text(verbatim: transport.displayName)
                    } icon: {
                        Image(systemName: transport.symbol)
                    }.tag(transport)
                }
            }
            Toggle(isOn: $host.terminalTransports.moshEnabled) {
                Text(verbatim: "Mosh")
            }
            .disabled(host.isTailscaleManaged)
            if host.terminalTransports.moshEnabled && !host.isTailscaleManaged {
                LabeledContent(AppStrings.Transports.portRange.swiftUIKey) {
                    TextField(
                        AppStrings.Transports.portRange.swiftUIKey,
                        text: $host.terminalTransports.moshUDPPortRange,
                        prompt: Text(verbatim: "60001-60999").italic()
                    )
                    .labelsHidden().multilineTextAlignment(.trailing)
                }
            }
            Toggle(isOn: $host.terminalTransports.eternalTerminalEnabled) {
                Text(verbatim: "Eternal Terminal")
            }
            if host.terminalTransports.eternalTerminalEnabled {
                LabeledContent(AppStrings.Common.port.swiftUIKey) {
                    TextField(
                        AppStrings.Common.port.swiftUIKey,
                        value: $host.terminalTransports.eternalTerminalPort,
                        format: .number.grouping(.never)
                    )
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                }
            }
        }
        .onChange(of: host.terminalTransports.moshEnabled) { normalizeDefault() }
        .onChange(of: host.terminalTransports.eternalTerminalEnabled) { normalizeDefault() }
        .onAppear { normalizeDefault() }
    }

    private func normalizeDefault() {
        host.terminalTransports.normalizeDefault(isTailscaleManaged: host.isTailscaleManaged)
    }
}
