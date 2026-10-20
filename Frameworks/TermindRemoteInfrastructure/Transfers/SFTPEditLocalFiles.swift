// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation
import TermindApplication

/// Streams arbitrary regular files; never decodes content or filters filename extensions.
public actor SFTPEditLocalFiles {
    public struct Snapshot: Sendable {
        public let url: URL
        public let digest: String
        public let size: Int64
    }

    private struct Signature: Equatable {
        let size: UInt64
        let modified: Date?
        let inode: UInt64
    }

    private var cache: [URL: (Signature, String)] = [:]
    public init() {}

    public func digest(_ url: URL, force: Bool = true) throws -> String {
        let before = try signature(url)
        if !force, let cached = cache[url], cached.0 == before { return cached.1 }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard try signature(url) == before else { throw SFTPEditFailure.localChanged }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        cache[url] = (before, digest)
        return digest
    }

    public func snapshot(_ url: URL) throws -> Snapshot {
        let original = try digest(url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindEditUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let copied = try digest(copy)
            guard copied == original, try digest(url) == original else { throw SFTPEditFailure.localChanged }
            return Snapshot(url: copy, digest: copied, size: Int64(try signature(copy).size))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func removeSnapshot(_ snapshot: Snapshot) {
        cache[snapshot.url] = nil
        try? FileManager.default.removeItem(at: snapshot.url.deletingLastPathComponent())
    }

    public func forget(_ url: URL) { cache[url] = nil }

    private func signature(_ url: URL) throws -> Signature {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else { throw SFTPEditFailure.unsupported }
        return Signature(
            size: (values[.size] as? NSNumber)?.uint64Value ?? 0,
            modified: values[.modificationDate] as? Date,
            inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}
