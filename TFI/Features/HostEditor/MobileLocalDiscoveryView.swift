import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileLocalDiscoveryView: View {
    @State var model: LocalDiscoveryModel
    let select: (DiscoveredLocalHost) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LocalDiscoveryView(model: model) {
                select($0)
                dismiss()
            }
            .navigationTitle(AppStrings.LocalNetwork.discovery.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.cancel.swiftUIKey) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(AppStrings.LocalNetwork.rescan.swiftUIKey) { model.scan() }
                }
            }
        }
    }
}
