import CryptoKit
import Foundation

// MARK: - Values

nonisolated enum ScratchEntryKind: String, Hashable, Sendable, Codable {
    case file, directory
}

nonisolated struct ScratchEntry: Hashable, Sendable {
    var path: String
    var kind: ScratchEntryKind
    var bytes: Int
    var modifiedAt: Date?
}

/// How much of the workspace is spent. Returned with every write so the agent can
/// stay under the ceiling deliberately rather than discover it by failing.
nonisolated struct ScratchUsage: Hashable, Sendable {
    var bytes: Int
    var entries: Int
    var byteQuota: Int
    var entryQuota: Int
}

nonisolated struct ScratchFile: Hashable, Sendable {
    var path: String
    var data: Data
    var sha256: String

    var bytes: Int { data.count }
}

/// A bounded window of a text file, in lines.
nonisolated struct ScratchText: Hashable, Sendable {
    var path: String
    var content: String
    var bytes: Int
    /// Lines in the whole file, not in this window.
    var totalLines: Int
    /// 1-based, and the first line this window contains.
    var offset: Int
    var returnedLines: Int
    var isTruncated: Bool
    var lineEnding: LineEnding
}

nonisolated struct ScratchSearchMatch: Hashable, Sendable {
    var path: String
    /// 1-based, matching `scratch_read`, diffs and editors.
    var line: Int
    var text: String
    var textTruncated: Bool
}

nonisolated struct ScratchSearchOutcome: Hashable, Sendable {
    var matches: [ScratchSearchMatch]
    /// Matching lines in the whole search, including those past `limit`.
    var matchingLines: Int
    var searchedFiles: Int
    var skippedBinaryFiles: Int
    var caseSensitive: Bool
    var isTruncated: Bool
}

/// One exact-text replacement, matched against the file as it was before any edit in
/// the same call was applied.
nonisolated struct ScratchEdit: Hashable, Sendable {
    var oldText: String
    var newText: String
}

nonisolated struct ScratchWriteOutcome: Hashable, Sendable {
    var path: String
    var bytes: Int
    var sha256: String
    var didCreate: Bool
    var usage: ScratchUsage
}

nonisolated struct ScratchEditOutcome: Hashable, Sendable {
    var path: String
    var editsApplied: Int
    var diff: UnifiedDiff
    var bytes: Int
    var sha256: String
    var lineEnding: LineEnding
    var usage: ScratchUsage
}

// MARK: - Workspace

/// A per-conversation staging directory inside the app's own container.
///
/// It exists so bytes can move between a host and the model's attention without
/// passing *through* the model: `sftp_read` can land a file here and `sftp_write`
/// can take one from here, so the ordinary "pull a config, change three lines, push
/// it back" job stops costing two full copies of the file in tokens.
///
/// An `actor`, and that is load-bearing rather than incidental. Pi serializes file
/// mutations through an explicit per-path queue (`file-mutation-queue.ts`); here the
/// actor already serializes every operation against every other, so `apply(_:to:)`
/// is atomic across its read and its write for free. That is what lets every scratch
/// tool stay `.parallel` — a batch containing one of them does not have to drag its
/// whole turn serial to be safe.
///
/// Nothing outside the scope directory is reachable. Paths are relative, `..` is
/// refused outright rather than resolved, and the built URL is proven to still be
/// inside the scope after symlink resolution.
actor AgentScratchWorkspace {
    nonisolated enum Limits {
        static let fileBytes = 8 * 1_024 * 1_024
        static let totalBytes = 64 * 1_024 * 1_024
        static let entries = 512
        static let pathBytes = 1_024
        static let componentBytes = 255
        static let depth = 8
        /// What `scratch_read` will put in front of the model at once, matching
        /// `sftp_read`'s inline ceiling. A *file* may be far larger; reading it whole
        /// is what the offset/limit window and `scratch_push` are for.
        static let inlineReadBytes = 128 * 1_024
        static let searchQueryCharacters = 4_096
        static let searchLineBytes = 1_024
        static let searchResults = 100
        static let edits = 32
    }

    private let conversationID: UUID
    private let base: URL?
    private var scope: URL?

    /// `base` is injectable for tests only; in the app it resolves to Application
    /// Support inside the sandbox container.
    init(conversationID: UUID, base: URL? = nil) {
        self.conversationID = conversationID
        self.base = base
    }

    /// Application Support rather than Caches deliberately: the system may evict a
    /// Caches directory mid-run, and a staging area that can vanish between two tool
    /// calls is worse than no staging area.
    static func defaultBase() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appending(path: "Termind", directoryHint: .isDirectory)
        .appending(path: "Scratch", directoryHint: .isDirectory)
    }

    static func copyScope(from sourceID: UUID, to destinationID: UUID) throws {
        let base = try defaultBase()
        let source = base.appending(path: sourceID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            return
        }
        let destination = base.appending(
            path: destinationID.uuidString, directoryHint: .isDirectory
        )
        guard !FileManager.default.fileExists(
            atPath: destination.path(percentEncoded: false)
        ) else { return }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    // MARK: Reading

    func usage() throws -> ScratchUsage { try measure(in: try root()) }

    func list(_ path: String?, recursive: Bool) throws -> [ScratchEntry] {
        let root = try root()
        let directory = try path.map { try resolve($0, in: root) } ?? root
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw AgentToolError.scratchNotFound(path ?? ".")
        }
        var entries: [ScratchEntry] = []
        try walk(directory, root: root, recursive: recursive) { entries.append($0) }
        return entries.sorted { $0.path < $1.path }
    }

    /// A bounded window, in lines, of a UTF-8 file.
    ///
    /// `offset` is 1-based to match how the file will be talked about everywhere
    /// else — a diff hunk, an error message, an editor.
    func read(
        _ path: String, offset: Int? = nil, limit: Int? = nil,
        maximumBytes: Int = Limits.inlineReadBytes
    ) throws -> ScratchText {
        let file = try data(at: path)
        guard let raw = String(data: file.data, encoding: .utf8) else {
            throw AgentToolError.scratchNotText(path)
        }
        let ending = LineEnding.detected(in: raw)
        let (lines, _) = UnifiedDiff.split(LineEnding.normalizedToLF(raw))

        let start = max(1, offset ?? 1)
        guard start <= max(lines.count, 1) else {
            throw AgentToolError.invalidArguments(
                "offset \(start) is past the end of \(path), which has \(lines.count) lines."
            )
        }
        let end = limit.map { min(lines.count, start - 1 + max(0, $0)) } ?? lines.count
        let window = start - 1 < end ? Array(lines[(start - 1)..<end]) : []

        var content = window.joined(separator: "\n")
        var isTruncated = false
        if content.utf8.count > maximumBytes {
            content = String(decoding: content.utf8.prefix(maximumBytes), as: UTF8.self)
            isTruncated = true
        }
        return ScratchText(
            path: path, content: content, bytes: file.bytes, totalLines: lines.count,
            offset: start, returnedLines: window.count,
            isTruncated: isTruncated || end < lines.count, lineEnding: ending
        )
    }

    /// The whole file, undecoded. What `scratch_push` uses, and the reason
    /// a scratch file does not have to be text at all.
    func data(at path: String) throws -> ScratchFile {
        let url = try resolve(path, in: try root())
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else { throw AgentToolError.scratchNotFound(path) }
        let data = try Data(contentsOf: url)
        return ScratchFile(path: path, data: data, sha256: Self.digest(data))
    }

    /// Search UTF-8 files one line at a time without putting whole files into the
    /// transcript. A directory scope is always recursive; `nil` means the workspace
    /// root. Non-text files are counted and skipped rather than making a mixed tree
    /// impossible to search.
    func search(
        _ query: String, path: String? = nil, regex: Bool = false,
        caseSensitive requestedCaseSensitivity: Bool? = nil, limit: Int = 20
    ) throws -> ScratchSearchOutcome {
        guard !query.isEmpty else {
            throw AgentToolError.invalidArguments("query is required.")
        }
        guard query.count <= Limits.searchQueryCharacters else {
            throw AgentToolError.invalidArguments(
                "query is past the limit of \(Limits.searchQueryCharacters) characters."
            )
        }
        guard !query.contains("\n"), !query.contains("\r") else {
            throw AgentToolError.invalidArguments(
                "query must fit on one line; scratch_search does not match across lines."
            )
        }
        guard (1...Limits.searchResults).contains(limit) else {
            throw AgentToolError.invalidArguments(
                "limit must be between 1 and \(Limits.searchResults)."
            )
        }

        let caseSensitive = requestedCaseSensitivity ?? query.unicodeScalars.contains {
            CharacterSet.uppercaseLetters.contains($0)
        }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(
                pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]
            )
        } catch {
            throw AgentToolError.invalidArguments("query is not a valid regular expression.")
        }

        let root = try root()
        let files = try searchFiles(at: path, in: root)
        var matches: [ScratchSearchMatch] = []
        var matchingLines = 0
        var searchedFiles = 0
        var skippedBinaryFiles = 0
        var previewWasTruncated = false

        for filePath in files {
            let file = try data(at: filePath)
            guard let raw = String(data: file.data, encoding: .utf8) else {
                skippedBinaryFiles += 1
                continue
            }
            searchedFiles += 1
            let normalized = LineEnding.normalizedToLF(raw)
            let (lines, _) = UnifiedDiff.split(normalized)
            for (index, line) in lines.enumerated() {
                let wholeLine = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let first = expression.firstMatch(
                    in: line, range: wholeLine
                ), let range = Range(first.range, in: line) else { continue }
                matchingLines += 1
                guard matches.count < limit else { continue }
                let preview = Self.searchPreview(
                    of: line, around: range, maximumBytes: Limits.searchLineBytes
                )
                previewWasTruncated = previewWasTruncated || preview.truncated
                matches.append(ScratchSearchMatch(
                    path: filePath, line: index + 1, text: preview.text,
                    textTruncated: preview.truncated
                ))
            }
        }
        return ScratchSearchOutcome(
            matches: matches, matchingLines: matchingLines,
            searchedFiles: searchedFiles, skippedBinaryFiles: skippedBinaryFiles,
            caseSensitive: caseSensitive,
            isTruncated: previewWasTruncated || matchingLines > matches.count
        )
    }

    // MARK: Writing

    @discardableResult
    func write(_ path: String, data: Data) throws -> ScratchWriteOutcome {
        let root = try root()
        let url = try resolve(path, in: root)
        let existing = Self.size(of: url)
        try checkQuota(in: root, adding: data.count, replacing: existing)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return ScratchWriteOutcome(
            path: path, bytes: data.count, sha256: Self.digest(data),
            didCreate: existing == nil, usage: try measure(in: root)
        )
    }

    /// Exact-text replacement, following Pi's `edit` tool.
    ///
    /// Every `oldText` is matched against the file as it was *before* this call, not
    /// against the result of the preceding edit — so the model never has to simulate
    /// its own changes to write the second one. Matches must be unique and must not
    /// overlap; anything ambiguous fails the whole call rather than applying part of
    /// it, because a half-applied edit is the one outcome nobody can reason about.
    func apply(_ edits: [ScratchEdit], to path: String) throws -> ScratchEditOutcome {
        guard !edits.isEmpty else {
            throw AgentToolError.invalidArguments("edits must contain at least one replacement.")
        }
        guard edits.count <= Limits.edits else {
            throw AgentToolError.invalidArguments(
                "edits contains \(edits.count) replacements, past the limit of \(Limits.edits)."
            )
        }
        let file = try data(at: path)
        guard let raw = String(data: file.data, encoding: .utf8) else {
            throw AgentToolError.scratchNotText(path)
        }

        let ending = LineEnding.detected(in: raw)
        // Read from the bytes, not from `raw`: Foundation strips a UTF-8 BOM while
        // decoding, so by the time the file is a String the only evidence it ever
        // had one is gone — and writing the String back drops those three bytes
        // from a file nobody asked to change that way.
        let bom = file.data.starts(with: [0xEF, 0xBB, 0xBF]) ? "\u{FEFF}" : ""
        let original = LineEnding.normalizedToLF(raw)

        var located: [(range: Range<String.Index>, replacement: String)] = []
        for edit in edits {
            let needle = LineEnding.normalizedToLF(edit.oldText)
            guard !needle.isEmpty else {
                throw AgentToolError.invalidArguments("old_text must not be empty.")
            }
            located.append((
                try Self.locate(needle, in: original, path: path),
                LineEnding.normalizedToLF(edit.newText)
            ))
        }
        located.sort { $0.range.lowerBound < $1.range.lowerBound }
        for (previous, next) in zip(located, located.dropFirst())
        where next.range.lowerBound < previous.range.upperBound {
            throw AgentToolError.invalidArguments(
                """
                Two edits of \(path) match overlapping regions. Merge changes that touch \
                the same block into one edit.
                """
            )
        }

        var updated = ""
        var cursor = original.startIndex
        for (range, replacement) in located {
            updated += original[cursor..<range.lowerBound]
            updated += replacement
            cursor = range.upperBound
        }
        updated += original[cursor...]

        guard updated != original else {
            throw AgentToolError.invalidArguments("The edits of \(path) produced no change.")
        }
        let diff = try UnifiedDiff.between(original, updated, fromPath: path, toPath: path)
        let encoded = Data((bom + ending.restore(updated)).utf8)
        let written = try write(path, data: encoded)
        return ScratchEditOutcome(
            path: path, editsApplied: located.count, diff: diff, bytes: written.bytes,
            sha256: written.sha256, lineEnding: ending, usage: written.usage
        )
    }

    func delete(_ path: String, kind: ScratchEntryKind) throws {
        let url = try resolve(path, in: try root())
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else {
            throw AgentToolError.scratchNotFound(path)
        }
        let isDirectory = values.isDirectory == true
        guard isDirectory == (kind == .directory) else {
            throw AgentToolError.invalidArguments(
                "\(path) is a \(isDirectory ? "directory" : "file"), not a \(kind.rawValue)."
            )
        }
        if isDirectory {
            let children = try FileManager.default.contentsOfDirectory(
                atPath: url.path(percentEncoded: false)
            )
            // Only empty directories, matching `sftp_delete`. A recursive delete is
            // the one scratch action that can destroy work the user wanted kept, and
            // "it is contained" is too thin a reason to let it through un-gated.
            guard children.isEmpty else {
                throw AgentToolError.invalidArguments(
                    "\(path) is not empty. Delete its \(children.count) entries first."
                )
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Called when the conversation this workspace belongs to is deleted.
    func removeScope() throws {
        guard let scope = try? root() else { return }
        self.scope = nil
        guard FileManager.default.fileExists(atPath: scope.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: scope)
    }

    // MARK: - Containment

    private func root() throws -> URL {
        if let scope { return scope }
        let base = try self.base ?? Self.defaultBase()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Working data, and often a copy of somebody's production config. It has no
        // business in a Time Machine snapshot.
        var backupExcluded = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? backupExcluded.setResourceValues(values)

        let scope = base.appending(path: conversationID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        self.scope = scope
        return scope
    }

    /// Normalizes a model-supplied path and proves the result is inside the scope.
    ///
    /// `..` is rejected rather than popped — the inverse of `normalizeRemotePath`,
    /// which resolves it. A relative path with `..` in it is never something the
    /// agent needed to write, so refusing is both safe and a clearer error than
    /// silently rewriting what was asked for.
    private func resolve(_ raw: String, in root: URL) throws -> URL {
        let relative = try Self.normalize(raw)
        let url = root.appending(path: relative, directoryHint: .notDirectory)
        try Self.assertNoSymlink(in: url, below: root)

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        guard resolved.hasPrefix(resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/")
        else { throw AgentToolError.scratchPathEscapes }
        return url
    }

    static func normalize(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= Limits.pathBytes else {
            throw AgentToolError.scratchPathEscapes
        }
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~"),
            !raw.contains("\0"), !raw.contains("\r"), !raw.contains("\n")
        else { throw AgentToolError.scratchPathEscapes }

        var components: [String] = []
        for component in raw.split(separator: "/") {
            if component == "." { continue }
            guard component != ".." else { throw AgentToolError.scratchPathEscapes }
            guard component.utf8.count <= Limits.componentBytes else {
                throw AgentToolError.scratchPathEscapes
            }
            components.append(String(component))
        }
        guard !components.isEmpty, components.count <= Limits.depth else {
            throw AgentToolError.scratchPathEscapes
        }
        return components.joined(separator: "/")
    }

    /// Refuses to traverse or write through a symlink, even one pointing back inside
    /// the scope.
    ///
    /// Containment alone would already stop an escape. This is the stricter rule
    /// because an alias *inside* the workspace makes two paths the same file, which
    /// quietly breaks both the quota arithmetic and the atomicity `apply(_:to:)`
    /// claims.
    private static func assertNoSymlink(in url: URL, below root: URL) throws {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        let components = url.standardizedFileURL.pathComponents
        guard components.count > rootDepth else { return }
        var candidate = root
        for component in components[rootDepth...] {
            candidate = candidate.appending(path: component, directoryHint: .notDirectory)
            guard let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                return  // Does not exist yet, so nothing below it can either.
            }
            if values.isSymbolicLink == true { throw AgentToolError.scratchPathEscapes }
        }
    }

    // MARK: - Quota

    private func checkQuota(in root: URL, adding bytes: Int, replacing existing: Int?) throws {
        guard bytes <= Limits.fileBytes else {
            throw AgentToolError.scratchQuotaExceeded(
                "\(bytes) bytes is past the \(Limits.fileBytes)-byte limit for one scratch file."
            )
        }
        let usage = try measure(in: root)
        let projected = usage.bytes - (existing ?? 0) + bytes
        guard projected <= Limits.totalBytes else {
            throw AgentToolError.scratchQuotaExceeded(
                """
                The scratch workspace would reach \(projected) of \(Limits.totalBytes) bytes. \
                Delete what is no longer needed.
                """
            )
        }
        guard existing != nil || usage.entries < Limits.entries else {
            throw AgentToolError.scratchQuotaExceeded(
                "The scratch workspace already holds its limit of \(Limits.entries) files."
            )
        }
    }

    private func measure(in root: URL) throws -> ScratchUsage {
        var bytes = 0
        var entries = 0
        try walk(root, root: root, recursive: true) { entry in
            guard entry.kind == .file else { return }
            bytes += entry.bytes
            entries += 1
        }
        return ScratchUsage(
            bytes: bytes, entries: entries,
            byteQuota: Limits.totalBytes, entryQuota: Limits.entries
        )
    }

    // MARK: - Enumeration

    private func walk(
        _ directory: URL, root: URL, recursive: Bool, into visit: (ScratchEntry) -> Void
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        // Hidden files are *not* skipped. A quota the agent can evade by naming a
        // file `.big` is not a quota, and a listing that omits what it wrote is a
        // listing it cannot clean up from.
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            // Anything that is neither a regular file nor a directory — a symlink, a
            // socket — is not something this workspace put there and not something
            // it will report.
            guard isDirectory || values?.isRegularFile == true else { continue }
            visit(ScratchEntry(
                path: Self.relative(child, to: root),
                kind: isDirectory ? .directory : .file,
                bytes: isDirectory ? 0 : (values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate
            ))
            if isDirectory, recursive {
                try walk(child, root: root, recursive: true, into: visit)
            }
        }
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let rootDepth = root.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
    }

    private static func size(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else { return nil }
        return values.fileSize ?? 0
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func searchFiles(at path: String?, in root: URL) throws -> [String] {
        guard let path else {
            var entries: [ScratchEntry] = []
            try walk(root, root: root, recursive: true) { entries.append($0) }
            return entries.filter { $0.kind == .file }.map(\.path).sorted()
        }
        let url = try resolve(path, in: root)
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { throw AgentToolError.scratchNotFound(path) }
        if values.isRegularFile == true { return [Self.relative(url, to: root)] }
        guard values.isDirectory == true else { throw AgentToolError.scratchNotFound(path) }
        var entries: [ScratchEntry] = []
        try walk(url, root: root, recursive: true) { entries.append($0) }
        return entries.filter { $0.kind == .file }.map(\.path).sorted()
    }

    /// Keep the first match visible in a bounded UTF-8 window. The byte boundaries
    /// are advanced to scalar boundaries so clipping never introduces replacement
    /// characters into a valid text file.
    private static func searchPreview(
        of line: String, around match: Range<String.Index>, maximumBytes: Int
    ) -> (text: String, truncated: Bool) {
        let bytes = Array(line.utf8)
        guard bytes.count > maximumBytes else { return (line, false) }
        let matchOffset = line[..<match.lowerBound].utf8.count
        var start = max(0, min(bytes.count - maximumBytes, matchOffset - maximumBytes / 2))
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        var end = min(bytes.count, start + maximumBytes)
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        let body = String(decoding: bytes[start..<end], as: UTF8.self)
        return ((start > 0 ? "…" : "") + body + (end < bytes.count ? "…" : ""), true)
    }

    // MARK: - Matching

    /// Finds the one region `needle` names, or explains why it named none or several.
    ///
    /// Exact first. The fallback is line-aligned rather than character-aligned: a
    /// window of lines whose normalized forms equal the normalized needle's. That
    /// covers the failure this fallback exists for — a model retyping a block with
    /// tidied quotes, dashes or trailing whitespace — without the index-mapping a
    /// character-level fuzzy match would need to translate a position in normalized
    /// text back into the original.
    private static func locate(
        _ needle: String, in haystack: String, path: String
    ) throws -> Range<String.Index> {
        let exact = ranges(of: needle, in: haystack)
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 {
            throw AgentToolError.invalidArguments(
                """
                old_text occurs \(exact.count) times in \(path). Extend it with surrounding \
                lines until it names exactly one region.
                """
            )
        }

        let (lines, _) = UnifiedDiff.split(haystack)
        let (needleLines, needleEndsWithNewline) = UnifiedDiff.split(needle)
        guard !needleLines.isEmpty, needleLines.count <= lines.count else {
            throw noMatch(path)
        }
        let normalizedLines = lines.map(normalizedForMatch)
        let normalizedNeedle = needleLines.map(normalizedForMatch)
        var matches: [Int] = []
        for start in 0...(lines.count - needleLines.count)
        where Array(normalizedLines[start..<(start + needleLines.count)]) == normalizedNeedle {
            matches.append(start)
        }
        guard matches.count == 1, let start = matches.first else {
            throw matches.isEmpty
                ? noMatch(path)
                : AgentToolError.invalidArguments(
                    """
                    old_text matches \(matches.count) regions of \(path) once punctuation and \
                    trailing whitespace are ignored. Extend it until it names exactly one.
                    """
                )
        }
        return lineRange(
            start..<(start + needleLines.count), in: haystack, lines: lines,
            includingTrailingNewline: needleEndsWithNewline
        )
    }

    private static func noMatch(_ path: String) -> AgentToolError {
        .invalidArguments(
            """
            old_text does not appear in \(path). Read the file and copy the region exactly as \
            it is now.
            """
        )
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchFrom = haystack.startIndex
        // Two is all any caller needs to know: one is a match, more than one is
        // ambiguous. Stopping there keeps a one-character `old_text` against a large
        // file from collecting a range per occurrence.
        while found.count < 2,
            let range = haystack.range(of: needle, range: searchFrom..<haystack.endIndex)
        {
            found.append(range)
            searchFrom = range.lowerBound < range.upperBound
                ? range.upperBound : haystack.index(after: range.lowerBound)
            guard searchFrom < haystack.endIndex else { break }
        }
        return found
    }

    /// Pi's `normalizeForFuzzyMatch`: the differences a model introduces by retyping
    /// a block rather than copying it.
    private static func normalizedForMatch(_ line: String) -> String {
        var output = line.precomposedStringWithCompatibilityMapping
        for (characters, replacement) in [
            ("\u{2018}\u{2019}\u{201A}\u{201B}", "'"),
            ("\u{201C}\u{201D}\u{201E}\u{201F}", "\""),
            ("\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\u{2212}", "-"),
            ("\u{00A0}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}"
                + "\u{200A}\u{202F}\u{205F}\u{3000}", " "),
        ] {
            for character in characters {
                output = output.replacingOccurrences(of: String(character), with: replacement)
            }
        }
        while output.hasSuffix(" ") || output.hasSuffix("\t") { output.removeLast() }
        return output
    }

    /// The character range covering a window of whole lines.
    ///
    /// `includingTrailingNewline` mirrors whether the needle itself ended with one.
    /// Getting this wrong is not cosmetic: consuming a newline the needle did not
    /// have would splice the replacement onto the following line, and leaving one
    /// the needle did have would double it.
    private static func lineRange(
        _ window: Range<Int>, in haystack: String, lines all: [String],
        includingTrailingNewline: Bool
    ) -> Range<String.Index> {
        let lower = startIndex(ofLine: window.lowerBound, in: haystack, lines: all)
        var upper = startIndex(ofLine: window.upperBound, in: haystack, lines: all)
        if !includingTrailingNewline, upper > lower,
            haystack[haystack.index(before: upper)] == "\n"
        {
            upper = haystack.index(before: upper)
        }
        return lower..<upper
    }

    private static func startIndex(
        ofLine line: Int, in haystack: String, lines all: [String]
    ) -> String.Index {
        var index = haystack.startIndex
        for existing in all[..<min(line, all.count)] {
            index = haystack.index(index, offsetBy: existing.count)
            if index < haystack.endIndex { index = haystack.index(after: index) }
        }
        return index
    }
}
