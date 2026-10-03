import SwiftUI
import TermindApplication

public struct TailscaleExitNodeField: View {
    @Bindable var editor: TailscaleGroupEditor

    public init(editor: TailscaleGroupEditor) { self.editor = editor }

    public var body: some View {
        let candidates = editor.candidates
        Picker(AppStrings.Tailscale.exitNode.swiftUIKey, selection: $editor.exitNodeID) {
            Text(AppStrings.Settings.disabled).tag("")
            ForEach(candidates, id: \.stableID) { peer in
                HStack {
                    Image(systemName: "circle.fill").foregroundStyle(peer.online ? .green : .secondary)
                    Text(verbatim: peer.name)
                    if !peer.online { Text(AppStrings.Tailscale.offline).foregroundStyle(.secondary) }
                }.tag(peer.stableID)
            }
            if !editor.exitNodeID.isEmpty, !candidates.contains(where: { $0.stableID == editor.exitNodeID }) {
                Text(AppStrings.Tailscale.selectedExitNodeUnavailable).tag(editor.exitNodeID)
            }
        }
    }
}
