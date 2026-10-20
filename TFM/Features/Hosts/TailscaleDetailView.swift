// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct TailscaleDetailView: View {
    let hostID: Host.ID
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        VaultDetailScaffold(
            title: AppStrings.Tailscale.title, symbol: "point.3.connected.trianglepath.dotted",
            close: window.closeVaultWork, showsHeaderClose: false
        ) {
            if let host = app.hostLibrary.host(hostID) {
                TailscalePeerForm(model: app.tailscale, host: host) { _ = copyToPasteboard($0) }
            } else {
                Text(AppStrings.Tailscale.unavailable)
            }
        } footer: {
            HStack {
                Spacer()
                Button(AppStrings.Common.close.swiftUIKey, action: window.closeVaultWork)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("tailscale.close")
            }
            .padding(Metrics.Space.l)
        }
        .termindInputAwareFocusEffect()
    }
}
