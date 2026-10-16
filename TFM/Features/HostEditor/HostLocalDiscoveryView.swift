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
            title: AppStrings.LocalNetwork.discovery, symbol: "network", close: back,
            closeLabel: AppStrings.Common.back, closeSymbol: "chevron.backward"
        ) {
            LocalDiscoveryView(model: model, select: select)
        } footer: {
            HStack {
                Spacer()
                Button(AppStrings.LocalNetwork.rescan.swiftUIKey) { model.scan() }
            }
            .padding(Metrics.Space.l)
            .termindGlassBar()
        }
    }
}
