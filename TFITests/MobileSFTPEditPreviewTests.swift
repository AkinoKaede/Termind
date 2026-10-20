// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import QuickLook
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileSFTPEditPreviewTests {
    @Test func previewEnablesSystemEditingAndReceivesInPlaceChanges() {
        let url = URL(filePath: "/tmp/document.pdf")
        var changes = 0
        let preview = MobileSFTPEditPreview(
            url: url, allowsEditing: true, changed: { changes += 1 }, export: { _ in }, failed: { _ in }, dismiss: {})
        let delegate = preview.makeCoordinator()
        let controller = QLPreviewController()
        #expect(delegate.previewController(controller, editingModeFor: url as NSURL) == .updateContents)
        delegate.previewController(controller, didUpdateContentsOf: url as NSURL)
        #expect(changes == 1)
        delegate.parent = MobileSFTPEditPreview(
            url: url, allowsEditing: false, changed: {}, export: { _ in }, failed: { _ in }, dismiss: {})
        #expect(delegate.previewController(controller, editingModeFor: url as NSURL) == .disabled)
    }

    @Test func editedCopiesAreOwnedBeforeCallbackReturnsAndDifferentFormatsAreExported() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appending(path: "original.pdf")
        let sameType = directory.appending(path: "edited.pdf")
        let differentType = directory.appending(path: "edited.png")
        try Data([1]).write(to: original)
        try Data([2]).write(to: sameType)
        try Data([3]).write(to: differentType)
        var changes = 0
        var exported: URL?
        let delegate = MobileSFTPEditPreview(
            url: original, allowsEditing: true, changed: { changes += 1 },
            export: { exported = $0 }, failed: { Issue.record("\($0)") }, dismiss: {}
        ).makeCoordinator()
        let controller = QLPreviewController()
        delegate.previewController(controller, didSaveEditedCopyOf: original as NSURL, at: sameType)
        try FileManager.default.removeItem(at: sameType)
        #expect(try Data(contentsOf: original) == Data([2]))
        #expect(changes == 1)
        delegate.previewController(controller, didSaveEditedCopyOf: original as NSURL, at: differentType)
        try FileManager.default.removeItem(at: differentType)
        #expect(try Data(contentsOf: original) == Data([2]))
        #expect(try Data(contentsOf: #require(exported)) == Data([3]))
        #expect(changes == 1)
    }

}
