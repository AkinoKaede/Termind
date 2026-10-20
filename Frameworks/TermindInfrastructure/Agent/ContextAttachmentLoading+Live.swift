// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication

extension ContextAttachmentLoading {
    public static let live = Self(
        file: { try await ContextAttachmentImporter.importFile(at: $0) },
        image: { try await ContextAttachmentImporter.importImage(data: $0, label: $1) })
}
