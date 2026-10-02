import SwiftUI
import TermindApplication

public struct TailscaleExitNodeField: View {
    let model: TailscaleModel
    let groupID: UUID
    @Binding var selection: String

    public init(model: TailscaleModel, groupID: UUID, selection: Binding<String>) {
        self.model = model
        self.groupID = groupID
        _selection = selection
    }

    public var body: some View {
        let candidates = model.exitNodeCandidates(groupID: groupID)
        Picker(AppStrings.Tailscale.exitNode.swiftUIKey, selection: $selection) {
            Text(AppStrings.Settings.disabled).tag("")
            ForEach(candidates, id: \.stableID) { peer in
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(peer.online ? .green : .secondary)
                    Text(verbatim: peer.name)
                    if !peer.online { Text(AppStrings.Tailscale.offline).foregroundStyle(.secondary) }
                }.tag(peer.stableID)
            }
            if !selection.isEmpty, !candidates.contains(where: { $0.stableID == selection }) {
                Text(AppStrings.Tailscale.selectedExitNodeUnavailable).tag(selection)
            }
        }
        if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
    }
}
