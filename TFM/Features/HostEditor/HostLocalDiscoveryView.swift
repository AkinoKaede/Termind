// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct HostLocalDiscoveryView: View {
    let model: LocalDiscoveryModel
    let back: () -> Void
    let select: (DiscoveredLocalHost) -> Void

    var body: some View {
        VaultDetailScaffold(
            title: AppStrings.LocalNetwork.discovery, symbol: "dot.radiowaves.left.and.right", close: back,
            closeLabel: AppStrings.Common.back, closeSymbol: "chevron.backward"
        ) {
            LocalDiscoveryView(model: model, select: select)
        } footer: {
            HStack {
                Spacer()
                Button(AppStrings.Common.cancel.swiftUIKey) {
                    model.cancel()
                    back()
                }
                Button(AppStrings.LocalNetwork.rescan.swiftUIKey) { model.scan() }
            }
            .padding(Metrics.Space.l)
            .termindGlassBar()
        }
    }
}
