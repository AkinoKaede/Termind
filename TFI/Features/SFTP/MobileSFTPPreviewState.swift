// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Export follows the preview's dismissal; it must never compete with the
/// preview for presentation or reopen after its own dismissal.
struct MobileSFTPPreviewState {
    private enum Phase {
        case preview(URL, exportedCopy: URL?)
        case dismissingPreview(URL, exportedCopy: URL?)
        case exportedCopy(URL)
    }

    private var phase: Phase?

    var previewURL: URL? {
        guard case .preview(let url, _) = phase else { return nil }
        return url
    }

    var exportedCopyURL: URL? {
        guard case .exportedCopy(let url) = phase else { return nil }
        return url
    }

    var isPreviewPresented: Bool {
        get { previewURL != nil }
        set { if !newValue { dismissPreview() } }
    }

    var isExportPresented: Bool {
        get { exportedCopyURL != nil }
        set {
            if !newValue, case .exportedCopy = phase { phase = nil }
        }
    }

    mutating func present(_ url: URL) {
        phase = .preview(url, exportedCopy: nil)
    }

    mutating func stageExport(_ url: URL) {
        switch phase {
        case .preview(let preview, _): phase = .preview(preview, exportedCopy: url)
        case .dismissingPreview(let preview, _): phase = .dismissingPreview(preview, exportedCopy: url)
        default: break
        }
    }

    mutating func dismissPreview() {
        guard case .preview(let url, let exportedCopy) = phase else { return }
        phase = .dismissingPreview(url, exportedCopy: exportedCopy)
    }

    mutating func previewDidDismiss() {
        guard case .dismissingPreview(_, let exportedCopy) = phase else { return }
        phase = exportedCopy.map(Phase.exportedCopy)
    }
}
