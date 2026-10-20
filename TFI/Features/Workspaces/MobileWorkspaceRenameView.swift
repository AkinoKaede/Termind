// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
            title: String(localized: AppStrings.Common.rename),
            isDirty: normalizedTitle != originalTitle,
            canSave: !normalizedTitle.isEmpty && normalizedTitle != originalTitle,
            compact: true,
            save: { save(normalizedTitle) },
            content: {
                TextField(
                    AppStrings.Workspace.workspaceName.swiftUIKey, text: $title.singleLineText, axis: .horizontal
                ).singleLinePaste().lineLimit(
                    1)
            }
        )
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
