// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

public struct HostWakeOnLANSection: View {
    @Binding private var preferences: WakeOnLANPreferences
    private let fetchMAC: (() -> Void)?
    @State private var invalidAddress = false

    public init(
        preferences: Binding<WakeOnLANPreferences>,
        fetchMAC: (() -> Void)?
    ) {
        _preferences = preferences
        self.fetchMAC = fetchMAC
    }

    public var body: some View {
        Section {
            TextField(
                AppStrings.LocalNetwork.macAddress.swiftUIKey, text: $preferences.macAddress,
                prompt: Text(verbatim: "00:1A:2B:3C:4D:5E")
            )
            #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
            #endif
            if let fetchMAC {
                Button(
                    AppStrings.LocalNetwork.fetchMAC.swiftUIKey, systemImage: "rectangle.connected.to.line.below",
                    action: fetchMAC)
            }
            Toggle(
                AppStrings.LocalNetwork.autoWake.swiftUIKey,
                isOn: WakeOnLANSettingsAccess(
                    invalidAddress: { invalidAddress = true }
                ).automatic($preferences))
            if !preferences.isValid {
                Text(AppStrings.LocalNetwork.invalidMACAddress)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(AppStrings.LocalNetwork.wakeOnLAN)
        }
        .alert(AppStrings.LocalNetwork.macAddress, isPresented: $invalidAddress) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.LocalNetwork.invalidMAC)
        }
    }
}
