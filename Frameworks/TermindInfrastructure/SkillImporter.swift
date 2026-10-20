// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Darwin
import Foundation

/// Reading a skill off disk, kept out of the view so the parsing decisions are
/// testable without a panel.
public enum SkillImporter {
    public struct Outcome {
        public var document: AgentSkillDocument
        public var origin: String
        public var warnings: [String] = []
    }

    public static func read(_ url: URL) throws -> Outcome {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AgentSkillImportError.notReadable }
        let isDirectory = values.isDirectory == true
        let file = isDirectory ? url.appending(path: "SKILL.md") : url
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw AgentSkillImportError.noSkillFile
        }

        let data = try readBounded(file, root: isDirectory ? url : nil, limit: AgentSkill.maximumBodyBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentSkillImportError.notReadable
        }

        // The folder name is the skill name for anything written against the
        // standard, where the directory *is* the identifier.
        let source = isDirectory ? url : url.deletingPathExtension()
        var document = try AgentSkillDocument.parse(
            text, fallbackName: source.lastPathComponent
        )
        if isDirectory {
            let root = url.standardizedFileURL
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
                throw AgentSkillImportError.notReadable
            }
            for case let resource as URL in enumerator {
                let values = try resource.resourceValues(forKeys: Set(keys))
                guard values.isSymbolicLink != true else { throw AgentSkillImportError.notReadable }
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { throw AgentSkillImportError.notReadable }
                let path = String(resource.standardizedFileURL.path.dropFirst(root.path.count + 1))
                if path == "SKILL.md" { continue }
                try AgentSkillPackage.validatePath(path)
                document.package.files[path] = try readBounded(
                    resource, root: root, limit: AgentSkillPackage.maximumFileBytes)
                try document.package.validate()
            }
        }
        return Outcome(document: document, origin: file.lastPathComponent, warnings: [])
    }

    public static func readResource(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try readBounded(url, root: nil, limit: AgentSkillPackage.maximumFileBytes)
    }

    private static func readBounded(_ url: URL, root: URL?, limit: Int) throws -> Data {
        var descriptor: Int32
        if let root {
            let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            try AgentSkillPackage.validatePath(path)
            descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw AgentSkillImportError.notReadable }
            let parts = path.components(separatedBy: "/")
            for (index, part) in parts.enumerated() {
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index == parts.count - 1 ? 0 : O_DIRECTORY)
                let next = openat(descriptor, part, flags)
                close(descriptor)
                guard next >= 0 else { throw AgentSkillImportError.notReadable }
                descriptor = next
            }
        } else {
            descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw AgentSkillImportError.notReadable }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentSkillImportError.notReadable
        }
        guard info.st_size <= limit else { throw AgentSkillImportError.tooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AgentSkillImportError.tooLarge }
        return data
    }
}
