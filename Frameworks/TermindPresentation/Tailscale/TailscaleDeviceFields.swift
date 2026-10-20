// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication

/// Separate address and metadata sections for this device's active Tailnet session.
public struct TailscaleDeviceFields: View {
    @Bindable private var editor: TailscaleGroupEditor
    private let copy: (String) -> Void

    public init(editor: TailscaleGroupEditor, copy: @escaping (String) -> Void) {
        self.editor = editor
        self.copy = copy
    }

    public var body: some View {
        if let device = editor.device {
            if !device.dnsName.isEmpty || !device.addresses.isEmpty {
                Section {
                    copyable(AppStrings.Tailscale.magicDNS, value: device.dnsName)
                    ForEach(device.addresses, id: \.self) { address in
                        copyable(
                            address.contains(":") ? AppStrings.Tailscale.ipv6 : AppStrings.Tailscale.ipv4,
                            value: address)
                    }
                }
            }
            Section {
                TailscaleFormRow(label: AppStrings.Tailscale.keyExpiry, symbol: "key") {
                    if let expiry = device.keyExpiry {
                        Text(expiry, format: .dateTime)
                    } else {
                        Text(AppStrings.Settings.disabled)
                    }
                }
                if !device.operatingSystem.isEmpty {
                    TailscaleFormRow(label: AppStrings.Tailscale.operatingSystem, symbol: "desktopcomputer") {
                        Text(verbatim: device.operatingSystem)
                    }
                }
            }
        }
    }

    private func copyable(_ label: LocalizedStringResource, value: String) -> some View {
        TailscaleCopyField(label: label, value: value, copy: copy)
    }
}
