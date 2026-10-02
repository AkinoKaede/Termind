import SwiftUI
import TermindApplication

/// Hostname editing and information about this device's active Tailnet session.
public struct TailscaleDeviceFields: View {
    private let model: TailscaleModel
    private let groupID: UUID
    @Binding private var hostname: String
    private let copy: (String) -> Void
    @State private var isLoggingOut = false

    public init(model: TailscaleModel, groupID: UUID, hostname: Binding<String>, copy: @escaping (String) -> Void) {
        self.model = model
        self.groupID = groupID
        self.copy = copy
        _hostname = hostname
    }

    public var body: some View {
        Group {
            LabeledContent(AppStrings.Vault.hostname.swiftUIKey) {
                TextField(
                    AppStrings.Vault.hostname.swiftUIKey, text: $hostname,
                    prompt: Text(verbatim: model.defaultHostname)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
            }
            if let device = model.devices[groupID] {
                copyable(AppStrings.Tailscale.magicDNS, value: device.dnsName)
                ForEach(device.addresses, id: \.self) { address in
                    copyable(
                        address.contains(":") ? AppStrings.Tailscale.ipv6 : AppStrings.Tailscale.ipv4, value: address)
                }
                LabeledContent(AppStrings.Tailscale.keyExpiry.swiftUIKey) {
                    if let expiry = device.keyExpiry {
                        Text(expiry, format: .dateTime)
                    } else {
                        Text(AppStrings.Settings.disabled)
                    }
                }
                LabeledContent(AppStrings.Tailscale.operatingSystem.swiftUIKey, value: device.operatingSystem)
            }
            Button(AppStrings.Tailscale.logout.swiftUIKey, role: .destructive) {
                isLoggingOut = true
                Task {
                    await model.logout(groupID: groupID)
                    isLoggingOut = false
                }
            }.disabled(isLoggingOut)
        }
    }

    private func copyable(_ label: LocalizedStringResource, value: String) -> some View {
        TailscaleCopyField(label: label, value: value, copy: copy)
    }
}
