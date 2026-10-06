import SwiftUI
import TermindPresentation

/// Window-local key equivalents that stay out of the menu bar.
struct MobileWorkspaceNumberShortcuts: View {
    let scene: MobileSceneModel

    var body: some View {
        ZStack {
            ForEach(1...8, id: \.self) { index in
                Button(AppStrings.Workspace.numberedWorkspace(index).swiftUIKey) {
                    scene.selectWorkspace(at: index - 1)
                }
                .keyboardShortcut(MobileShortcut.workspace(index))
                .disabled(scene.workspaceCount < index)
            }
            Button(AppStrings.Workspace.lastWorkspace.swiftUIKey) { scene.selectLastWorkspace() }
                .keyboardShortcut(MobileShortcut.workspace(9))
                .disabled(!scene.hasWorkspaces)
        }
        .hidden()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
