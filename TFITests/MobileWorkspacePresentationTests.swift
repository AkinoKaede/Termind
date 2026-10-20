// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileWorkspacePresentationTests {
    @Test(arguments: [false, true])
    func importerRetainsItsTargetRegardlessOfDismissalCallbackOrder(_ dismissalFirst: Bool) {
        var importer = MobileFileImportState<UUID>()
        let target = UUID()
        importer.present(for: target)
        if dismissalFirst { importer.isPresented = false }
        #expect(importer.takeTarget() == target)
        importer.isPresented = false
        #expect(!importer.isPresented)
        #expect(importer.takeTarget() == nil)
    }

    @Test func reopeningAnImporterReplacesTheCancelledRequest() {
        var importer = MobileFileImportState<UUID>()
        importer.present(for: UUID())
        importer.isPresented = false
        let replacement = UUID()
        importer.present(for: replacement)
        #expect(importer.isPresented)
        #expect(importer.takeTarget() == replacement)
    }

    @Test(arguments: [false, true])
    func exportedCopyWaitsForPreviewDismissalAndDoesNotReopen(_ exportDuringDismissal: Bool) {
        var preview = MobileSFTPPreviewState()
        let source = URL(fileURLWithPath: "/tmp/source.txt")
        let export = URL(fileURLWithPath: "/tmp/export.pdf")
        preview.present(source)
        if !exportDuringDismissal { preview.stageExport(export) }
        #expect(preview.isPreviewPresented)
        #expect(!preview.isExportPresented)
        preview.isPreviewPresented = false
        if exportDuringDismissal { preview.stageExport(export) }
        #expect(!preview.isExportPresented)
        preview.previewDidDismiss()
        #expect(preview.exportedCopyURL == export)
        #expect(!preview.isPreviewPresented)
        preview.isExportPresented = false
        preview.previewDidDismiss()
        #expect(!preview.isExportPresented)
    }

    @Test func aNewPreviewDiscardsAPreviousPendingExport() {
        var preview = MobileSFTPPreviewState()
        preview.present(URL(fileURLWithPath: "/tmp/first.txt"))
        preview.stageExport(URL(fileURLWithPath: "/tmp/export.pdf"))
        preview.dismissPreview()
        let next = URL(fileURLWithPath: "/tmp/next.txt")
        preview.present(next)
        preview.previewDidDismiss()
        #expect(preview.previewURL == next)
        #expect(!preview.isExportPresented)
        preview.dismissPreview()
        preview.previewDidDismiss()
        #expect(!preview.isPreviewPresented && !preview.isExportPresented)
    }
}
