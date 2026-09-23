import Foundation
import SwiftUI
import TermindPresentation

struct MobileWorkspaceRenameView: View {
    let originalTitle: String
    let save: (String) -> Void
    @State private var title: String

    init(descriptor: MobileWorkspaceDescriptor, save: @escaping (String) -> Void) {
        originalTitle = descriptor.title
        self.save = save
        _title = State(initialValue: descriptor.title)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: TermindCopy.Common.rename),
            isDirty: normalizedTitle != originalTitle,
            canSave: !normalizedTitle.isEmpty && normalizedTitle != originalTitle,
            compact: true,
            save: { save(normalizedTitle) },
            content: {
                TextField(
                    TermindCopy.Workspace.workspaceName.swiftUIKey, text: $title.singleLineText, axis: .horizontal
                ).singleLinePaste().lineLimit(
                    1)
            }
        )
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
