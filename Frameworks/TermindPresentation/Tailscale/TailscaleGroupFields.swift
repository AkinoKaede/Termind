import SwiftUI
import TermindApplication

/// Shared form behavior; the platform editor owns save, dismissal and cancellation.
public struct TailscaleGroupFields: View {
    @Bindable var editor: TailscaleGroupEditor
    let requireAccess: () -> Bool
    let copy: (String) -> Void

    public init(
        editor: TailscaleGroupEditor, requireAccess: @escaping () -> Bool, copy: @escaping (String) -> Void
    ) {
        self.editor = editor
        self.requireAccess = requireAccess
        self.copy = copy
    }

    public var body: some View {
        Section(AppStrings.Tailscale.title.swiftUIKey) {
            if !editor.model.runningGroups.contains(editor.draft.id) {
                Toggle(
                    AppStrings.Common.enabled.swiftUIKey,
                    isOn: Binding(
                        get: { editor.enabled },
                        set: { value in if !value || requireAccess() { editor.setEnabled(value) } })
                )
            }
            if editor.enabled {
                if editor.isConnected {
                    if let network = editor.network {
                        LabeledContent(AppStrings.Tailscale.network.swiftUIKey, value: network.dnsSuffix)
                    }
                    TailscaleExitNodeField(editor: editor)
                    TailscaleDeviceFields(editor: editor, copy: copy)
                } else {
                    TailscaleLoginFields(editor: editor, requireAccess: requireAccess)
                }
            }
            if let error = editor.model.error { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .disabled(editor.isSaving || editor.isLoggingOut)
        .onChange(of: editor.pending?.id) { _, _ in editor.receiveLogin() }
    }
}
