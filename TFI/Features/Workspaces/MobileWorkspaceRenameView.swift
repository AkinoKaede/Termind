import Foundation
import SwiftUI

struct MobileWorkspaceRenameView: View {
    let originalTitle: String
    let save: (String) -> Void
    @State private var title: String

    init(workspace: MobileWorkspace, save: @escaping (String) -> Void) {
        originalTitle = workspace.descriptor.title
        self.save = save
        _title = State(initialValue: workspace.descriptor.title)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Rename"),
            isDirty: normalizedTitle != originalTitle,
            canSave: !normalizedTitle.isEmpty && normalizedTitle != originalTitle,
            compact: true,
            save: { save(normalizedTitle) },
            content: { TextField("Workspace Name", text: $title) }
        )
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
