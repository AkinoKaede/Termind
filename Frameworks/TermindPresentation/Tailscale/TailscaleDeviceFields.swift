import SwiftUI
import TermindApplication

/// Hostname editing and information about this device's active Tailnet session.
public struct TailscaleDeviceFields: View {
    @Bindable private var editor: TailscaleGroupEditor
    private let copy: (String) -> Void

    public init(editor: TailscaleGroupEditor, copy: @escaping (String) -> Void) {
        self.editor = editor
        self.copy = copy
    }

    public var body: some View {
        Group {
            LabeledContent(AppStrings.Vault.hostname.swiftUIKey) {
                TextField(
                    AppStrings.Vault.hostname.swiftUIKey, text: $editor.hostname,
                    prompt: Text(verbatim: editor.model.defaultHostname)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
            }
            if let device = editor.device {
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
                Task { await editor.logout() }
            }.disabled(editor.isLoggingOut)
        }
    }

    private func copyable(_ label: LocalizedStringResource, value: String) -> some View {
        TailscaleCopyField(label: label, value: value, copy: copy)
    }
}
