// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import UniformTypeIdentifiers

/// Reads a dropped reference before a provider's temporary file is released.
public nonisolated enum ReferenceDropLoader {
    public static func load(_ provider: NSItemProvider) async throws -> String {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: NSURL.self) { value, error in
                    do {
                        guard let url = value as? URL, url.isFileURL else {
                            throw error ?? CocoaError(.fileReadUnknown)
                        }
                        continuation.resume(returning: try read(url))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let fileTypes = provider.registeredTypeIdentifiers(fileOptions: .openInPlace)
        let named = provider.suggestedName?.isEmpty == false
        if let type = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0), type.conforms(to: .data), !type.conforms(to: .url) else { return false }
            return !type.conforms(to: .text) || named || fileTypes.contains($0)
        }) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                        continuation.resume(returning: try read(url))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { value, error in
                guard let text = value as? String else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                guard text.utf8.count <= 1024 * 1024 else {
                    continuation.resume(throwing: CocoaError(.fileReadTooLarge))
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
