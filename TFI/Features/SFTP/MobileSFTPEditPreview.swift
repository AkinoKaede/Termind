// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct MobileSFTPEditPreview: UIViewControllerRepresentable {
    let url: URL
    let allowsEditing: Bool
    let changed: () -> Void
    let export: (URL) -> Void
    let failed: (String) -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in dismiss() })
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.parent = self
    }

    /// No editable-type allowlist: Quick Look decides whether to offer editing tools.
    /// A new format must not silently replace a remote file with a different representation.
    static func canReplaceOriginal(_ original: URL, with edited: URL) -> Bool {
        let originalType = UTType(filenameExtension: original.pathExtension)
        let editedType = UTType(filenameExtension: edited.pathExtension)
        if let originalType, let editedType { return originalType == editedType }
        return original.pathExtension.lowercased() == edited.pathExtension.lowercased()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var parent: MobileSFTPEditPreview
        init(_ parent: MobileSFTPEditPreview) { self.parent = parent }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            parent.url as NSURL
        }

        func previewController(
            _ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            parent.allowsEditing ? .updateContents : .disabled
        }

        func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: any QLPreviewItem) {
            parent.changed()
        }

        func previewController(
            _ controller: QLPreviewController, didSaveEditedCopyOf previewItem: any QLPreviewItem,
            at modifiedContentsURL: URL
        ) {
            do {
                // The callback's URL is temporary; take ownership before returning to Quick Look.
                let directory = parent.url.deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let copy = directory.appendingPathComponent(modifiedContentsURL.lastPathComponent)
                try FileManager.default.copyItem(at: modifiedContentsURL, to: copy)
                if MobileSFTPEditPreview.canReplaceOriginal(parent.url, with: copy) {
                    _ = try FileManager.default.replaceItemAt(parent.url, withItemAt: copy)
                    try? FileManager.default.removeItem(at: directory)
                    parent.changed()
                } else {
                    parent.export(copy)
                }
            } catch { parent.failed(error.localizedDescription) }
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            parent.changed()
            parent.dismiss()
        }
    }
}
