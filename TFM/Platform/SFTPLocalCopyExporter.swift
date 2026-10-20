// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import TermindPresentation

@MainActor
enum SFTPLocalCopyExporter {
    static func present(for source: URL, failed: @escaping (any Error) -> Void) {
        let panel = NSSavePanel()
        panel.title = String(localized: AppStrings.SFTP.keepLocalCopy)
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try copy(from: source, to: destination)
                    }.value
                } catch { failed(error) }
            }
        }
    }

    /// Prepare the complete copy before replacing a user-selected existing file.
    nonisolated static func copy(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(
            readingItemAt: source, options: [], writingItemAt: destination, options: .forReplacing,
            error: &coordinationError
        ) { readingURL, writingURL in
            do {
                let files = FileManager.default
                let directory = try files.url(
                    for: .itemReplacementDirectory, in: .userDomainMask,
                    appropriateFor: writingURL, create: true)
                defer { try? files.removeItem(at: directory) }
                let prepared = directory.appendingPathComponent(source.lastPathComponent)
                try files.copyItem(at: readingURL, to: prepared)
                if files.fileExists(atPath: writingURL.path) {
                    _ = try files.replaceItemAt(writingURL, withItemAt: prepared)
                } else {
                    try files.moveItem(at: prepared, to: writingURL)
                }
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
