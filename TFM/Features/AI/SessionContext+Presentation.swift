// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import TermindDomain

extension SessionContext {
    /// The pinned pills. They carry no `×`: the user's control over this is
    /// which pane has focus, not a per-turn checkbox.
    var chips: [ContextChip] {
        var chips: [ContextChip] = []
        if let hostName {
            chips.append(ContextChip(kind: .host, label: hostName, content: hostName))
        }
        if let workingDirectory, showsWorkingDirectoryChip {
            chips.append(
                ContextChip(
                    kind: .directory,
                    label: workingDirectoryDisplayLabel ?? workingDirectory,
                    content: workingDirectory
                ))
        }
        return chips
    }

}
