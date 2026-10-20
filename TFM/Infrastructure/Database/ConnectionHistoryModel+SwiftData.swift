// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftData
import TermindApplication
import TermindPersistence

extension ConnectionHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataConnectionHistoryRepository(context: modelContext))
    }
}
