import Foundation

nonisolated struct ScratchListTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_list", present: present)
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_list",
        "List the private scratch workspace and report its quota usage.",
        properties: [
            "path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "recursive": Self.boolean(),
        ], required: [], target: .local, safety: .locallyReadOnly, concurrency: .parallel,
        presentation: .init(
            symbol: "folder", activity: .semanticArgument(key: "path", fallback: .scratchWorkspace),
            output: .json, actionKind: .list
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let entries = try await workspace.list(
            arguments.optionalString("path"),
            recursive: arguments.optionalBool("recursive") ?? false
        )
        let usage = try await workspace.usage()
        return Self.result(invocation, .object([
            "entries": .array(entries.map { entry in .object([
                "path": .string(entry.path), "kind": .string(entry.kind.rawValue),
                "bytes": .number(Double(entry.bytes)),
                "modified_at": entry.modifiedAt.map { .string($0.ISO8601Format()) } ?? .null,
            ]) }),
            "total_bytes": .number(Double(usage.bytes)),
            "byte_quota": .number(Double(usage.byteQuota)),
            "entry_count": .number(Double(usage.entries)),
            "entry_quota": .number(Double(usage.entryQuota)),
        ]))
    }
}

nonisolated struct ScratchReadTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_read", present: present)
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_read", "Read a bounded window of a UTF-8 scratch file.",
        properties: [
            "path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "offset": Self.integer(min: 1, max: 10_000_000),
            "limit": Self.integer(min: 1, max: 100_000),
        ], required: ["path"], target: .local, safety: .locallyReadOnly,
        concurrency: .parallel,
        presentation: .init(
            symbol: "doc.text", activity: .semanticArgument(key: "path", fallback: .scratchFile),
            output: .field("content"), actionKind: .read
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let text = try await workspace.read(
            arguments.string("path"), offset: arguments.optionalInt("offset"),
            limit: arguments.optionalInt("limit")
        )
        return Self.result(invocation, .object([
            "path": .string(text.path), "content": .string(text.content),
            "bytes": .number(Double(text.bytes)), "total_lines": .number(Double(text.totalLines)),
            "offset": .number(Double(text.offset)),
            "returned_lines": .number(Double(text.returnedLines)),
            "truncated": .bool(text.isTruncated), "line_ending": .string(text.lineEnding.rawValue),
        ]), truncated: text.isTruncated)
    }
}

nonisolated struct ScratchSearchTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_search", present: present)
    private static let contentBytes = 128 * 1_024
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_search", "Search UTF-8 scratch files with bounded matching-line previews.",
        properties: [
            "query": Self.string(max: AgentScratchWorkspace.Limits.searchQueryCharacters),
            "path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "regex": Self.boolean(), "case_sensitive": Self.boolean(),
            "limit": Self.integer(min: 1, max: AgentScratchWorkspace.Limits.searchResults),
        ], required: ["query"], target: .local, safety: .locallyReadOnly,
        concurrency: .parallel,
        presentation: .init(
            symbol: "magnifyingglass",
            activity: .semanticArgument(key: "query", fallback: .scratchWorkspace),
            output: .json, actionKind: .search
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let outcome = try await workspace.search(
            arguments.string("query"), path: arguments.optionalString("path"),
            regex: arguments.optionalBool("regex") ?? false,
            caseSensitive: arguments.optionalBool("case_sensitive"),
            limit: arguments.optionalInt("limit") ?? 20
        )
        var returned = outcome.matches
        var truncated = outcome.isTruncated
        var payload = Self.payload(outcome, matches: returned, truncated: truncated)
        while payload.encodedString.utf8.count > Self.contentBytes, !returned.isEmpty {
            returned.removeLast()
            truncated = true
            payload = Self.payload(outcome, matches: returned, truncated: truncated)
        }
        return Self.result(invocation, payload, truncated: truncated)
    }

    private static func payload(
        _ outcome: ScratchSearchOutcome, matches: [ScratchSearchMatch], truncated: Bool
    ) -> AgentJSONValue { .object([
        "matches": .array(matches.map { match in .object([
            "path": .string(match.path), "line": .number(Double(match.line)),
            "text": .string(match.text), "text_truncated": .bool(match.textTruncated),
        ]) }),
        "matching_lines": .number(Double(outcome.matchingLines)),
        "returned_matches": .number(Double(matches.count)),
        "searched_files": .number(Double(outcome.searchedFiles)),
        "skipped_binary_files": .number(Double(outcome.skippedBinaryFiles)),
        "case_sensitive": .bool(outcome.caseSensitive), "truncated": .bool(truncated),
    ]) }
}

nonisolated struct ScratchWriteTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_write", present: present)
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_write", "Create or overwrite a scratch file.",
        properties: [
            "path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "content": Self.string(max: 128 * 1_024),
        ], required: ["path", "content"], target: .local, safety: .locallyContained,
        concurrency: .parallel,
        presentation: .init(
            symbol: "square.and.pencil",
            activity: .semanticArgument(key: "path", fallback: .scratchFile),
            output: .json, actionKind: .write
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        guard let content = arguments.optionalString("content") else {
            throw AgentToolError.invalidArguments("content is required.")
        }
        let written = try await workspace.write(
            arguments.string("path"), data: Data(content.utf8)
        )
        return Self.result(invocation, .object([
            "path": .string(written.path), "bytes": .number(Double(written.bytes)),
            "sha256": .string(written.sha256), "created": .bool(written.didCreate),
            "total_bytes": .number(Double(written.usage.bytes)),
            "byte_quota": .number(Double(written.usage.byteQuota)),
        ]))
    }
}

nonisolated struct ScratchEditTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_edit", present: present)
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor {
        let replacement = Self.object(
            properties: [
                "old_text": Self.string(max: 128 * 1_024),
                "new_text": Self.string(max: 128 * 1_024),
            ], required: ["old_text", "new_text"]
        )
        return Self.descriptor(
            "scratch_edit", "Change a scratch file by exact text replacement.",
            properties: [
                "path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
                "edits": Self.array(items: replacement, max: AgentScratchWorkspace.Limits.edits),
            ], required: ["path", "edits"], target: .local, safety: .locallyContained,
            concurrency: .parallel,
            presentation: .init(
                symbol: "pencil", activity: .semanticArgument(key: "path", fallback: .scratchFile),
                output: .field("diff"), actionKind: .edit
            )
        )
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let outcome = try await workspace.apply(
            arguments.scratchEdits(), to: arguments.string("path")
        )
        return Self.result(invocation, .object([
            "path": .string(outcome.path), "edits_applied": .number(Double(outcome.editsApplied)),
            "first_changed_line": outcome.diff.firstChangedLine.map { .number(Double($0)) } ?? .null,
            "diff": .string(outcome.diff.text), "diff_truncated": .bool(outcome.diff.isTruncated),
            "bytes": .number(Double(outcome.bytes)), "sha256": .string(outcome.sha256),
            "line_ending": .string(outcome.lineEnding.rawValue),
            "total_bytes": .number(Double(outcome.usage.bytes)),
        ]), truncated: outcome.diff.isTruncated)
    }
}

nonisolated struct ScratchDiffTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_diff", present: present)
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_diff", "Compare two scratch files and return a unified diff.",
        properties: [
            "path_a": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "path_b": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "context": Self.integer(min: 0, max: 20),
        ], required: ["path_a", "path_b"], target: .local, safety: .locallyReadOnly,
        concurrency: .parallel,
        presentation: .init(
            symbol: "arrow.left.arrow.right",
            activity: .semanticArgument(key: "path_a", fallback: .scratchFiles),
            output: .field("diff"), actionKind: .compare
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let pathA = try arguments.string("path_a")
        let pathB = try arguments.string("path_b")
        let a = try await ScratchToolSupport.text(of: pathA, in: workspace)
        let b = try await ScratchToolSupport.text(of: pathB, in: workspace)
        let diff = try UnifiedDiff.between(
            LineEnding.normalizedToLF(a), LineEnding.normalizedToLF(b),
            fromPath: pathA, toPath: pathB,
            context: arguments.optionalInt("context") ?? UnifiedDiff.defaultContext
        )
        return Self.result(invocation, .object([
            "path_a": .string(pathA), "path_b": .string(pathB),
            "identical": .bool(diff.isIdentical && a == b), "diff": .string(diff.text),
            "truncated": .bool(diff.isTruncated),
            "line_ending_a": .string(LineEnding.detected(in: a).rawValue),
            "line_ending_b": .string(LineEnding.detected(in: b).rawValue),
        ]), truncated: diff.isTruncated)
    }
}

nonisolated struct ScratchDeleteTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_delete", present: present)
    let workspace: AgentScratchWorkspace

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_delete", "Delete one scratch file or empty directory.",
        properties: [
            "path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "kind": Self.enumeration(["file", "directory"]),
        ], required: ["path", "kind"], target: .local, safety: .locallyContained,
        concurrency: .parallel,
        presentation: .init(
            symbol: "trash", activity: .semanticArgument(key: "path", fallback: .scratchEntry),
            output: .json, actionKind: .delete
        )
    ) }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let path = try arguments.string("path")
        let kind = ScratchEntryKind(rawValue: try arguments.string("kind")) ?? .file
        try await workspace.delete(path, kind: kind)
        let usage = try await workspace.usage()
        return Self.result(invocation, .object([
            "path": .string(path), "kind": .string(kind.rawValue), "deleted": .bool(true),
            "total_bytes": .number(Double(usage.bytes)),
            "entry_count": .number(Double(usage.entries)),
        ]))
    }
}

nonisolated extension ScratchListTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            let entries = object["entries"]?.arrayValue ?? []
            let entryCount = object["entry_count"]?.integerValue ?? entries.count
            let entryQuota = object["entry_quota"]?.integerValue
            let totalBytes = object["total_bytes"]?.integerValue ?? 0
            let byteQuota = object["byte_quota"]?.integerValue
            var summary = entryQuota.map { "\(entryCount) / \($0) entries" }
                ?? String(localized: "\(entryCount) entries", locale: input.locale)
            if let byteQuota {
                summary += " · \(F.byteCount(totalBytes)) / \(F.byteCount(byteQuota))"
            } else {
                summary += " · \(F.byteCount(totalBytes))"
            }
            let rows = entries.compactMap { entry -> AgentToolDetail.ListRow? in
                guard let fields = entry.objectValue else { return nil }
                let path = fields["path"]?.stringValue
                    ?? F.localized("Unnamed entry", locale: input.locale)
                let kind = fields["kind"]?.stringValue ?? ""
                var subtitle = F.kindLabel(kind, locale: input.locale)
                if let bytes = fields["bytes"]?.integerValue { subtitle += " · \(F.byteCount(bytes))" }
                return .init(
                    title: path, subtitle: subtitle,
                    detail: fields["modified_at"]?.stringValue.map(F.displayDate),
                    symbol: kind == "directory" ? "folder" : "doc"
                )
            }
            return [
                .message(summary, .secondary),
                .list(.init(
                    title: nil, rows: rows,
                    emptyMessage: F.localized("Workspace is empty", locale: input.locale)
                )),
            ]
            }
        }
}

nonisolated extension ScratchReadTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
            let content = object["content"]?.stringValue ?? ""
            items.append(content.isEmpty
                ? .message(F.localized("Empty file", locale: input.locale), .secondary)
                : F.text("Content", content, locale: input.locale))
            if let offset = object["offset"]?.integerValue,
                let returned = object["returned_lines"]?.integerValue,
                let total = object["total_lines"]?.integerValue
            {
                let end = returned == 0 ? offset : offset + returned - 1
                items.append(F.field("Lines", "\(offset)–\(end) of \(total)", locale: input.locale))
            }
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            F.appendField(
                &items, "Line endings", object["line_ending"]?.stringValue?.uppercased(),
                locale: input.locale
            )
            return items
            }
        }
}

nonisolated extension ScratchSearchTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            let matching = object["matching_lines"]?.integerValue ?? 0
            let returned = object["returned_matches"]?.integerValue ?? 0
            let searched = object["searched_files"]?.integerValue ?? 0
            let skipped = object["skipped_binary_files"]?.integerValue ?? 0
            var items: [AgentToolDetail.Item] = [
                .message(
                    String(
                        localized: "\(matching) matching lines in \(searched) files",
                        locale: input.locale
                    ),
                    matching == 0 ? .secondary : .success
                )
            ]
            let rows = (object["matches"]?.arrayValue ?? []).compactMap {
                match -> AgentToolDetail.ListRow? in
                guard let fields = match.objectValue,
                    let path = fields["path"]?.stringValue,
                    let line = fields["line"]?.integerValue
                else { return nil }
                return .init(
                    title: "\(path):\(line)", subtitle: fields["text"]?.stringValue,
                    badges: fields["text_truncated"]?.boolValue == true
                        ? [F.localized("Truncated", locale: input.locale)] : [],
                    symbol: "doc.text"
                )
            }
            items.append(.list(.init(
                title: nil, rows: rows,
                emptyMessage: F.localized("No matches", locale: input.locale)
            )))
            if object["truncated"]?.boolValue == true {
                items.append(.message(
                    String(
                        localized: "Showing \(returned) of \(matching) matching lines",
                        locale: input.locale
                    ),
                    .warning
                ))
            }
            if skipped > 0 {
                items.append(.message(
                    String(localized: "Skipped \(skipped) binary files", locale: input.locale),
                    .secondary
                ))
            }
            items.append(F.field(
                "Case sensitive",
                F.localized(
                    object["case_sensitive"]?.boolValue == true ? "Yes" : "No",
                    locale: input.locale
                ),
                locale: input.locale
            ))
            return items
            }
        }
}

nonisolated extension ScratchWriteTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
            let result = object["created"]?.boolValue == true
                ? F.localized("Created", locale: input.locale)
                : F.localized("Overwritten", locale: input.locale)
            items.append(F.field("Result", result, locale: input.locale))
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Workspace usage", object["total_bytes"], locale: input.locale)
            return items
            }
        }
}

nonisolated extension ScratchEditTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
            if let count = object["edits_applied"]?.integerValue {
                items.append(F.field(
                    "Changes", String(localized: "\(count) edits applied", locale: input.locale),
                    locale: input.locale
                ))
            }
            if let diff = object["diff"]?.stringValue, !diff.isEmpty {
                items.append(F.text("Diff", diff, locale: input.locale))
            }
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            F.appendField(
                &items, "Line endings", object["line_ending"]?.stringValue?.uppercased(),
                locale: input.locale
            )
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Workspace usage", object["total_bytes"], locale: input.locale)
            return items
            }
        }
}

nonisolated extension ScratchDiffTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "From", object["path_a"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendField(&items, "To", object["path_b"]?.stringValue, locale: input.locale, monospaced: true)
            let diff = object["diff"]?.stringValue ?? ""
            let a = object["line_ending_a"]?.stringValue?.uppercased()
            let b = object["line_ending_b"]?.stringValue?.uppercased()
            if !diff.isEmpty {
                items.append(F.text("Diff", diff, locale: input.locale))
            } else if object["identical"]?.boolValue == true {
                items.append(.message(F.localized("Files are identical", locale: input.locale), .success))
            } else if let a, let b, a != b {
                items.append(.message(
                    String(
                        localized: "Text is identical; line endings differ: \(a) → \(b)",
                        locale: input.locale
                    ),
                    .warning
                ))
            } else {
                items.append(.message(F.localized("No differences", locale: input.locale), .secondary))
            }
            return items
            }
        }
}

nonisolated extension ScratchDeleteTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "Path", object["path"]?.stringValue, locale: input.locale, monospaced: true)
            items.append(F.field("Result", F.localized("Deleted", locale: input.locale), locale: input.locale))
            F.appendField(
                &items, "Kind", object["kind"]?.stringValue.map {
                    F.kindLabel($0, locale: input.locale)
                }, locale: input.locale
            )
            let count = object["entry_count"]?.integerValue
            let bytes = object["total_bytes"]?.integerValue
            if count != nil || bytes != nil {
                let parts = [
                    count.map { String(localized: "\($0) entries", locale: input.locale) },
                    bytes.map(F.byteCount),
                ].compactMap { $0 }
                items.append(F.field("Workspace", parts.joined(separator: " · "), locale: input.locale))
            }
            return items
            }
        }
}

nonisolated enum ScratchToolSupport {
    static func text(of path: String, in workspace: AgentScratchWorkspace) async throws -> String {
        let file = try await workspace.data(at: path)
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw AgentToolError.scratchNotText(path)
        }
        return text
    }
}

nonisolated struct ScratchPullTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_pull", present: present)
    let workspace: AgentScratchWorkspace
    let pool: AgentConnectionPool
    let authentication: AgentSSHAuthenticationRegistry

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_pull", "Copy a remote file into the scratch workspace without returning its contents.",
        properties: [
            "host_id": Self.string(), "remote_path": Self.string(max: 4_096),
            "scratch_path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
        ], required: ["host_id", "remote_path", "scratch_path"], target: .host,
        safety: .locallyContained, concurrency: .parallel,
        presentation: .init(
            symbol: "arrow.down.doc",
            activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
            output: .json, actionKind: .pull
        )
    ) }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var checked = invocation
        let arguments = try Arguments(invocation)
        checked.targetHostID = try arguments.uuid("host_id")
        _ = try AgentBuiltInTools.normalizeRemotePath(arguments.string("remote_path"))
        _ = try AgentScratchWorkspace.normalize(arguments.string("scratch_path"))
        return AgentToolPreflight(invocation: checked, safety: .locallyContained)
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let remote = try AgentBuiltInTools.normalizeRemotePath(arguments.string("remote_path"))
        let hostID = try arguments.uuid("host_id")
        let data = try await AgentBuiltInTools.withAuthenticatedSFTP(
            hostID: hostID, invocation: invocation, context: context,
            authentication: authentication, pool: pool
        ) { client in
            try await client.readFile(at: remote, maximumBytes: AgentScratchWorkspace.Limits.fileBytes)
        }
        let written = try await workspace.write(arguments.string("scratch_path"), data: data)
        let text = String(data: data, encoding: .utf8).map(LineEnding.normalizedToLF)
        return Self.result(invocation, .object([
            "remote_path": .string(remote), "scratch_path": .string(written.path),
            "bytes": .number(Double(written.bytes)), "sha256": .string(written.sha256),
            "is_utf8": .bool(text != nil),
            "lines": text.map { .number(Double(UnifiedDiff.split($0).lines.count)) } ?? .null,
            "total_bytes": .number(Double(written.usage.bytes)),
        ]))
    }
}

nonisolated struct ScratchPushTool: AgentToolDefinition, AgentToolSchemaBuilding {
    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_push", present: present)
    let workspace: AgentScratchWorkspace
    let pool: AgentConnectionPool
    let authentication: AgentSSHAuthenticationRegistry

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_push", "Copy a scratch file atomically to a remote path.",
        properties: [
            "host_id": Self.string(),
            "scratch_path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "remote_path": Self.string(max: 4_096), "overwrite": Self.boolean(),
        ], required: ["host_id", "scratch_path", "remote_path"], target: .host,
        safety: .requiresAuthorization,
        presentation: .init(
            symbol: "arrow.up.doc",
            activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
            output: .json, actionKind: .push
        )
    ) }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var checked = invocation
        let arguments = try Arguments(invocation)
        checked.targetHostID = try arguments.uuid("host_id")
        _ = try AgentBuiltInTools.normalizeRemotePath(arguments.string("remote_path"))
        let staged = try arguments.string("scratch_path")
        let file = try await workspace.data(at: staged)
        return AgentToolPreflight(
            invocation: checked, safety: .requiresAuthorization,
            reasons: Self.evidence(path: staged, file: file),
            executionMetadata: ["scratch_sha256": .string(file.sha256)]
        )
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let remote = try AgentBuiltInTools.normalizeRemotePath(arguments.string("remote_path"))
        let staged = try arguments.string("scratch_path")
        let file = try await workspace.data(at: staged)
        if let approved = context.preflightMetadata["scratch_sha256"]?.stringValue,
           approved != file.sha256 {
            throw AgentToolError.invalidArguments(
                "\(staged) changed after this push was approved. Nothing was written."
            )
        }
        let hostID = try arguments.uuid("host_id")
        try await AgentBuiltInTools.withAuthenticatedSFTP(
            hostID: hostID, invocation: invocation, context: context,
            authentication: authentication, pool: pool
        ) { client in
            try await client.writeFile(
                file.data, at: remote, overwrite: arguments.optionalBool("overwrite") ?? false
            )
        }
        return Self.result(invocation, .object([
            "scratch_path": .string(staged), "remote_path": .string(remote),
            "bytes": .number(Double(file.bytes)), "sha256": .string(file.sha256),
            "written": .bool(true),
        ]))
    }

    private static func evidence(path: String, file: ScratchFile) -> [String] {
        var reasons = ["The content comes from the scratch workspace: \(path)"]
        guard let text = String(data: file.data, encoding: .utf8) else {
            reasons.append("\(file.bytes) bytes of non-text data, sha256 \(file.sha256.prefix(16))…")
            return reasons
        }
        let lines = UnifiedDiff.split(LineEnding.normalizedToLF(text)).lines
        reasons.append("\(file.bytes) bytes, \(lines.count) lines, sha256 \(file.sha256.prefix(16))…")
        reasons.append("First lines: " + AgentSensitiveDataRedactor.visibleText(
            lines.prefix(20).joined(separator: "\n"), maximumCharacters: 600
        ))
        return reasons
    }
}

nonisolated struct ScratchFetchTool: AgentToolDefinition, AgentToolSchemaBuilding {

    static let presenter = AgentToolDetailPresenter(id: "builtin.scratch_fetch", present: present)
    let workspace: AgentScratchWorkspace
    let web: ScrubberWebClient

    var descriptor: AgentToolDescriptor { Self.descriptor(
        "scratch_fetch", "Read an HTTP(S) webpage directly into the scratch workspace.",
        properties: [
            "url": Self.string(max: 8_192),
            "scratch_path": Self.string(max: AgentScratchWorkspace.Limits.pathBytes),
            "format": Self.enumeration(["markdown", "original"]),
        ], required: ["url", "scratch_path"], target: .network,
        safety: .locallyContained, concurrency: .parallel,
        presentation: .init(
            symbol: "globe.badge.chevron.backward",
            activity: .semanticArgument(key: "url", fallback: .url),
            output: .json, actionKind: .fetch
        )
    ) }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let arguments = try Arguments(invocation)
        _ = try ScrubberWebClient.validatedURL(arguments.string("url"))
        _ = try AgentScratchWorkspace.normalize(arguments.string("scratch_path"))
        return AgentToolPreflight(invocation: invocation, safety: .locallyContained)
    }

    func execute(_ invocation: AgentToolInvocation, context: AgentToolExecutionContext) async throws
        -> AgentToolResult {
        let arguments = try Arguments(invocation)
        let document = try await web.document(for: arguments.string("url"))
        let format = arguments.optionalString("format") ?? "markdown"
        let selected = format == "original" ? document.original : document.markdown
        guard !selected.isEmpty else { throw ScrubberWebError.emptyDocument }
        let written = try await workspace.write(
            arguments.string("scratch_path"), data: Data(selected.utf8)
        )
        return Self.result(invocation, .object([
            "url": .string(document.url.absoluteString), "title": .string(document.title),
            "format": .string(format), "scratch_path": .string(written.path),
            "bytes": .number(Double(written.bytes)), "sha256": .string(written.sha256),
            "lines": .number(Double(UnifiedDiff.split(LineEnding.normalizedToLF(selected)).lines.count)),
            "total_bytes": .number(Double(written.usage.bytes)),
        ]))
    }
}
nonisolated extension ScratchPullTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "Remote path", object["remote_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendField(&items, "Scratch path", object["scratch_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            items.append(F.field(
                "Content type",
                object["is_utf8"]?.boolValue == true
                    ? F.localized("UTF-8 text", locale: input.locale)
                    : F.localized("Binary", locale: input.locale),
                locale: input.locale
            ))
            if let lines = object["lines"]?.integerValue {
                items.append(F.field("Lines", String(lines), locale: input.locale))
            }
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Workspace usage", object["total_bytes"], locale: input.locale)
            return items
            }
        }
}

nonisolated extension ScratchPushTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            F.appendField(&items, "Scratch path", object["scratch_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendField(&items, "Remote path", object["remote_path"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            items.append(F.field("Result", F.localized("Written", locale: input.locale), locale: input.locale))
            return items
            }
        }
}

nonisolated extension ScratchFetchTool {
    static func present(
            _ input: AgentToolDetailInput
        ) -> [AgentToolDetail.Item] {
            typealias F = AgentToolDetailFormatting
            return F.objectItems(input) { object in
            var items: [AgentToolDetail.Item] = []
            if let title = F.nonempty(object["title"]?.stringValue) {
                items.append(F.field("Title", title, locale: input.locale))
            }
            if let url = F.nonempty(object["url"]?.stringValue) {
                items.append(.field(.init(
                    label: F.localized("URL", locale: input.locale), value: url,
                    isMonospaced: true, url: url
                )))
            }
            F.appendField(&items, "Scratch path", object["scratch_path"]?.stringValue, locale: input.locale, monospaced: true)
            items.append(F.field(
                "Content type",
                object["format"]?.stringValue == "original"
                    ? F.localized("Original HTML", locale: input.locale)
                    : F.localized("Markdown", locale: input.locale),
                locale: input.locale
            ))
            F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
            if let lines = object["lines"]?.integerValue {
                items.append(F.field("Lines", String(lines), locale: input.locale))
            }
            F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
            F.appendBytes(&items, "Workspace usage", object["total_bytes"], locale: input.locale)
            return items
            }
        }
}
