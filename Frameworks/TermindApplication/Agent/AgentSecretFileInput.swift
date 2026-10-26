// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated public enum AgentSecretFileInput {
    public static let maximumBytes = 1_048_576

    /// Called only after a user selects a file in the native secret prompt.
    public static func read(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        return try decode(bytes)
    }

    public static func decode(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
            let text = String(data: bytes, encoding: .utf8), !text.contains("\0")
        else { throw CocoaError(.fileReadCorruptFile) }
        return text
    }
}
