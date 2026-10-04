import SwiftUI
import TermindApplication

public struct TailscaleExitNodeField: View {
    @Bindable var editor: TailscaleGroupEditor

    public init(editor: TailscaleGroupEditor) { self.editor = editor }

    // Recheck live candidates when the menu commits, including while a menu is already open.
    var selection: Binding<String> {
        Binding(
            get: { editor.exitNodeID },
            set: { value in
                guard !editor.isSaving,
                    value.isEmpty || editor.candidates.contains(where: { $0.stableID == value && $0.online })
                else { return }
                editor.exitNodeID = value
            })
    }

    public var body: some View {
        let candidates = editor.candidates
        Picker(AppStrings.Tailscale.exitNode.swiftUIKey, selection: selection) {
            Text(AppStrings.Settings.disabled).tag("")
            ForEach(candidates, id: \.stableID) { peer in
                HStack {
                    Text(verbatim: peer.name)
                    if !peer.online { Text(AppStrings.Tailscale.offline) }
                }.tag(peer.stableID).disabled(!peer.online)
            }
            if !editor.exitNodeID.isEmpty, !candidates.contains(where: { $0.stableID == editor.exitNodeID }) {
                Text(AppStrings.Tailscale.selectedExitNodeUnavailable).tag(editor.exitNodeID).disabled(true)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("tailscale.exitNode")
    }
}
