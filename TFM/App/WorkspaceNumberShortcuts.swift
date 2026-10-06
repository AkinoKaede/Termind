import SwiftUI
import TermindPresentation

/// Window-local key equivalents that stay out of the menu bar.
struct WorkspaceNumberShortcuts: View {
    let window: WindowModel

    var body: some View {
        ZStack {
            ForEach(1...8, id: \.self) { index in
                Button(AppStrings.Workspace.numberedWorkspace(index).swiftUIKey) {
                    window.select(index: index - 1)
                }
                .termindShortcut(AppShortcutKey.character(Character("\(index)")))
                .disabled(window.workspaces.count < index)
            }
            Button(AppStrings.Workspace.lastWorkspace.swiftUIKey) {
                window.select(index: window.workspaces.count - 1)
            }
            .termindShortcut("9")
            .disabled(window.workspaces.isEmpty)
        }
        .hidden()
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
