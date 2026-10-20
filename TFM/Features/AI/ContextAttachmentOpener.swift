// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import Foundation
import TermindPresentation
import UniformTypeIdentifiers

nonisolated enum ContextAttachmentOpener {
    private static let directoryName = "Termind-Context-Previews"

    static var previewDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Preview files are snapshots and can contain sensitive context. They are
    /// kept only long enough for the receiving app to read them, then removed
    /// the next time Termind launches.
    static func cleanPreviousSession() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    static func materialize(_ attachment: AgentContextAttachment) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(
            at: previewDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = safeFilename(for: attachment)
        let folder = previewDirectory.appendingPathComponent(
            attachment.id.uuidString, isDirectory: true
        )
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        if !manager.fileExists(atPath: destination.path) {
            try attachment.data.write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return destination
    }

    @MainActor
    static func open(_ attachment: AgentContextAttachment) async throws {
        let url = try await Task.detached(priority: .userInitiated) {
            try materialize(attachment)
        }.value
        guard NSWorkspace.shared.open(url) else {
            throw OpenError.noDefaultApplication
        }
    }

    @MainActor
    static func open(_ image: AgentImageAttachment) async throws {
        let type = UTType(mimeType: image.mimeType) ?? .image
        let attachment = AgentContextAttachment(
            id: image.id, kind: .file, label: image.label,
            contentTypeIdentifier: type.identifier,
            suggestedFilename: image.label, data: image.data
        )
        try await open(attachment)
    }

    static func safeFilename(for attachment: AgentContextAttachment) -> String {
        var name = (attachment.suggestedFilename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? "-" : String($0)
        }.joined()
        name = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Attachment" }
        if (name as NSString).pathExtension.isEmpty,
            let ext = UTType(attachment.contentTypeIdentifier)?.preferredFilenameExtension
        {
            name += ".\(ext)"
        }
        let ext = (name as NSString).pathExtension
        guard name.count > 180, !ext.isEmpty else { return String(name.prefix(180)) }
        let suffix = ".\(ext)"
        let stemLimit = max(1, 180 - suffix.count)
        let stem = (name as NSString).deletingPathExtension
        return String(stem.prefix(stemLimit)) + suffix
    }

    enum OpenError: LocalizedError {
        case noDefaultApplication

        var errorDescription: String? {
            switch self {
            case .noDefaultApplication:
                String(localized: AppStrings.Assistant.noApplicationIsAvailableToOpenThisAttachment)
            }
        }
    }
}
