import SwiftUI
import TermindPresentation

struct MobileWorkspaceSearchModifier: ViewModifier {
    @Bindable var workspace: MobileWorkspace

    @ViewBuilder
    func body(content: Content) -> some View {
        switch workspace.descriptor.kind {
        case .ssh, .telnet:
            content.mobileToolbarSearch(
                text: Binding(get: { workspace.find.query }, set: { workspace.find.updateQuery($0) }),
                isPresented: Binding(
                    get: { workspace.find.isPresented },
                    set: { presented in
                        if presented {
                            workspace.find.present()
                        } else {
                            workspace.find.dismiss(restoringFocus: false)
                        }
                    }),
                prompt: AppStrings.Workspace.find,
                onSubmit: { workspace.find.navigate(.previous) })
        case .sftp:
            content.mobileToolbarSearch(
                text: Bindable(workspace.sftpChannel).projectedValue.query,
                prompt: AppStrings.Common.search)
        }
    }
}
