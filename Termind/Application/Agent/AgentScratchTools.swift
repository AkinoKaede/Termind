import Foundation

/// The agent's own staging area, exposed as tools.
///
/// Six of these are `target: .local` and cannot leave `AgentScratchWorkspace`'s
/// scope directory — not to a host, not to the network, not to any other part of
/// the user's disk. That containment is what earns `.locallyContained` on the three
/// that write: they change something, but only storage the app owns.
///
/// The three that reach outside — `scratch_pull`, `scratch_push` and
/// `scratch_fetch` — are the exception and the reason the rest is worth having.
/// They move bytes between a host or the web and the workspace *without the bytes
/// passing through the conversation*, which is what lifts `sftp_read`'s and
/// `fetch`'s inline ceilings and stops an edit costing two copies of the file in
/// tokens. They are kept separate from `sftp_read` / `sftp_write` / `fetch` rather
/// than folded in as options: a tool that means two different things depending on
/// which optional argument is present is harder for a model to choose correctly and
/// harder for a reader to audit, and only one of the three needs approval.
///
/// Everything except `scratch_push` is `.parallel`. The workspace is an actor, so it
/// is already the per-path mutation queue Pi builds explicitly — a read and a write
/// of the same file in one batch serialize against each other there rather than by
/// taking the whole turn serial.
nonisolated enum AgentScratchTools: AgentToolSchemaBuilding {
    /// Connection and authentication services travel together. If either is
    /// absent no host transfer tools are registered, rather than exposing a path
    /// that fails on first use or bypasses Agent credential interaction. `web`
    /// governs `scratch_fetch` on the same terms.
    static func make(
        workspace: AgentScratchWorkspace,
        connections: AgentConnectionPool? = nil,
        authentication: AgentSSHAuthenticationRegistry? = nil,
        web: ScrubberWebClient? = nil
    ) -> [AnyAgentTool] {
        let transfers: [AnyAgentTool]
        if let connections, let authentication {
            transfers = [
                pull(workspace, connections, authentication),
                push(workspace, connections, authentication),
            ]
        } else {
            transfers = []
        }
        return [
            list(workspace), read(workspace), write(workspace),
            edit(workspace), diff(workspace), delete(workspace),
        ] + transfers + (web.map { [fetch(workspace, $0)] } ?? [])
    }

    private static let pathBytes = AgentScratchWorkspace.Limits.pathBytes
    private static let contentBytes = 128 * 1_024

    private static func list(_ workspace: AgentScratchWorkspace) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "scratch_list",
            """
            List the scratch workspace: a private staging directory that persists across \
            the turns of this conversation and is not visible to the user. Also reports how \
            much of the workspace quota is spent.
            """,
            properties: ["path": string(max: pathBytes), "recursive": boolean()],
            required: [], target: .local, safety: .locallyReadOnly, concurrency: .parallel,
            presentation: .init(
                symbol: "folder",
                activity: .semanticArgument(key: "path", fallback: .scratchWorkspace),
                output: .json,
                detailPresenterID: "builtin.scratch_list",
                actionKind: .list
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let entries = try await workspace.list(
                arguments.optionalString("path"),
                recursive: arguments.optionalBool("recursive") ?? false
            )
            let usage = try await workspace.usage()
            return result(invocation, .object([
                "entries": .array(entries.map { entry in
                    .object([
                        "path": .string(entry.path), "kind": .string(entry.kind.rawValue),
                        "bytes": .number(Double(entry.bytes)),
                        "modified_at": entry.modifiedAt.map { .string($0.ISO8601Format()) } ?? .null,
                    ])
                }),
                "total_bytes": .number(Double(usage.bytes)),
                "byte_quota": .number(Double(usage.byteQuota)),
                "entry_count": .number(Double(usage.entries)),
                "entry_quota": .number(Double(usage.entryQuota)),
            ]))
        }
    }

    private static func read(_ workspace: AgentScratchWorkspace) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "scratch_read",
            """
            Read a UTF-8 file from the scratch workspace. Output is bounded; use offset and \
            limit to walk a large file a window at a time. To change a file, prefer \
            scratch_edit — reading a file whole in order to write it back whole costs two \
            copies of it.
            """,
            properties: [
                "path": string(max: pathBytes),
                "offset": integer(min: 1, max: 10_000_000),
                "limit": integer(min: 1, max: 100_000),
            ],
            required: ["path"], target: .local, safety: .locallyReadOnly, concurrency: .parallel,
            presentation: .init(
                symbol: "doc.text", activity: .semanticArgument(key: "path", fallback: .scratchFile),
                output: .field("content"),
                detailPresenterID: "builtin.scratch_read",
                actionKind: .read
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let text = try await workspace.read(
                arguments.string("path"),
                offset: arguments.optionalInt("offset"), limit: arguments.optionalInt("limit")
            )
            return result(invocation, .object([
                "path": .string(text.path), "content": .string(text.content),
                "bytes": .number(Double(text.bytes)),
                "total_lines": .number(Double(text.totalLines)),
                "offset": .number(Double(text.offset)),
                "returned_lines": .number(Double(text.returnedLines)),
                "truncated": .bool(text.isTruncated),
                "line_ending": .string(text.lineEnding.rawValue),
            ]), truncated: text.isTruncated)
        }
    }

    private static func write(_ workspace: AgentScratchWorkspace) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "scratch_write",
            """
            Create or overwrite a scratch file, creating parent directories as needed. For a \
            file that already exists, scratch_edit is almost always the better tool: it \
            spends tokens only on what changes. Large files should arrive through \
            scratch_pull rather than being typed out here.
            """,
            properties: ["path": string(max: pathBytes), "content": string(max: contentBytes)],
            required: ["path", "content"], target: .local, safety: .locallyContained,
            concurrency: .parallel,
            presentation: .init(
                symbol: "square.and.pencil",
                activity: .semanticArgument(key: "path", fallback: .scratchFile), output: .json,
                detailPresenterID: "builtin.scratch_write",
                actionKind: .write
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            // Not `string("content")`: writing an empty file is a legitimate request
            // and that accessor rejects empty strings.
            guard let content = arguments.optionalString("content") else {
                throw AgentToolError.invalidArguments("content is required.")
            }
            let written = try await workspace.write(
                arguments.string("path"), data: Data(content.utf8)
            )
            return result(invocation, .object([
                "path": .string(written.path), "bytes": .number(Double(written.bytes)),
                "sha256": .string(written.sha256), "created": .bool(written.didCreate),
                "total_bytes": .number(Double(written.usage.bytes)),
                "byte_quota": .number(Double(written.usage.byteQuota)),
            ]))
        }
    }

    private static func edit(_ workspace: AgentScratchWorkspace) -> AnyAgentTool {
        let replacement = object(
            properties: [
                "old_text": string(max: contentBytes), "new_text": string(max: contentBytes),
            ],
            required: ["old_text", "new_text"]
        )
        return AnyAgentTool(descriptor: descriptor(
            "scratch_edit",
            """
            Change a scratch file by exact text replacement, and get back a unified diff of \
            what changed rather than the new file. This is how to modify a file of any size \
            without paying for a copy of it in either direction. Every old_text is matched \
            against the file as it is now, not against the result of the preceding edit, so \
            do not chain them mentally. Each must appear exactly once and the regions must \
            not overlap — include surrounding lines until old_text is unique, and merge two \
            changes that touch the same block into one edit. An ambiguous or overlapping \
            call changes nothing at all. Use an empty new_text to delete a region.
            """,
            properties: [
                "path": string(max: pathBytes),
                "edits": array(items: replacement, max: AgentScratchWorkspace.Limits.edits),
            ],
            required: ["path", "edits"], target: .local, safety: .locallyContained,
            concurrency: .parallel,
            presentation: .init(
                symbol: "pencil", activity: .semanticArgument(key: "path", fallback: .scratchFile),
                output: .field("diff"),
                detailPresenterID: "builtin.scratch_edit",
                actionKind: .edit
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let outcome = try await workspace.apply(
                arguments.scratchEdits(), to: arguments.string("path")
            )
            return result(invocation, .object([
                "path": .string(outcome.path),
                "edits_applied": .number(Double(outcome.editsApplied)),
                "first_changed_line": outcome.diff.firstChangedLine
                    .map { .number(Double($0)) } ?? .null,
                "diff": .string(outcome.diff.text),
                "diff_truncated": .bool(outcome.diff.isTruncated),
                "bytes": .number(Double(outcome.bytes)), "sha256": .string(outcome.sha256),
                "line_ending": .string(outcome.lineEnding.rawValue),
                "total_bytes": .number(Double(outcome.usage.bytes)),
            ]), truncated: outcome.diff.isTruncated)
        }
    }

    private static func diff(_ workspace: AgentScratchWorkspace) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "scratch_diff",
            """
            Compare two scratch files and return a unified diff. Use it to check what a \
            change actually amounts to before sending it anywhere — for example against the \
            untouched copy sftp_read left in the workspace. Line endings are compared \
            separately and reported, so a CRLF file and an LF file do not read as every line \
            having changed.
            """,
            properties: [
                "path_a": string(max: pathBytes), "path_b": string(max: pathBytes),
                "context": integer(min: 0, max: 20),
            ],
            required: ["path_a", "path_b"], target: .local, safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: .init(
                symbol: "arrow.left.arrow.right",
                activity: .semanticArgument(key: "path_a", fallback: .scratchFiles),
                output: .field("diff"), detailPresenterID: "builtin.scratch_diff",
                actionKind: .compare
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let pathA = try arguments.string("path_a")
            let pathB = try arguments.string("path_b")
            let a = try await text(of: pathA, in: workspace)
            let b = try await text(of: pathB, in: workspace)
            let diff = try UnifiedDiff.between(
                LineEnding.normalizedToLF(a), LineEnding.normalizedToLF(b),
                fromPath: pathA, toPath: pathB,
                context: arguments.optionalInt("context") ?? UnifiedDiff.defaultContext
            )
            return result(invocation, .object([
                "path_a": .string(pathA), "path_b": .string(pathB),
                "identical": .bool(diff.isIdentical && a == b),
                "diff": .string(diff.text), "truncated": .bool(diff.isTruncated),
                "line_ending_a": .string(LineEnding.detected(in: a).rawValue),
                "line_ending_b": .string(LineEnding.detected(in: b).rawValue),
            ]), truncated: diff.isTruncated)
        }
    }

    private static func delete(_ workspace: AgentScratchWorkspace) -> AnyAgentTool {
        AnyAgentTool(descriptor: descriptor(
            "scratch_delete",
            """
            Delete one scratch file, or one empty scratch directory, to stay under the \
            workspace quota. Nothing outside the workspace can be reached, and a directory \
            with anything in it is refused — delete its entries first.
            """,
            properties: [
                "path": string(max: pathBytes), "kind": enumeration(["file", "directory"]),
            ],
            required: ["path", "kind"], target: .local, safety: .locallyContained,
            concurrency: .parallel,
            presentation: .init(
                symbol: "trash", activity: .semanticArgument(key: "path", fallback: .scratchEntry),
                output: .json,
                detailPresenterID: "builtin.scratch_delete",
                actionKind: .delete
            )
        )) { invocation, _ in
            let arguments = try Arguments(invocation)
            let path = try arguments.string("path")
            let kind = ScratchEntryKind(rawValue: try arguments.string("kind")) ?? .file
            try await workspace.delete(path, kind: kind)
            let usage = try await workspace.usage()
            return result(invocation, .object([
                "path": .string(path), "kind": .string(kind.rawValue), "deleted": .bool(true),
                "total_bytes": .number(Double(usage.bytes)),
                "entry_count": .number(Double(usage.entries)),
            ]))
        }
    }

    // MARK: - Transfer

    /// Host → workspace.
    ///
    /// `.locallyContained`, which is exactly the sum of its two halves: reading a
    /// remote file is what `sftp_read` already does un-gated, and the landing site is
    /// storage the app owns. Nothing on the host changes, and nothing outside the
    /// container is touched.
    private static func pull(
        _ workspace: AgentScratchWorkspace, _ pool: AgentConnectionPool,
        _ authentication: AgentSSHAuthenticationRegistry
    ) -> AnyAgentTool {
        let tool = descriptor(
            "scratch_pull",
            """
            Copy a remote file into the scratch workspace. Returns its size and digest \
            only — the contents do not enter this conversation, there is no UTF-8 \
            requirement, and the size limit is far above what sftp_read can return \
            inline. This is the first step of changing a remote file: pull it, \
            scratch_edit it, then scratch_push it back.
            """,
            properties: [
                "host_id": string(), "remote_path": string(max: 4_096),
                "scratch_path": string(max: pathBytes),
            ],
            required: ["host_id", "remote_path", "scratch_path"], target: .host,
            safety: .locallyContained, concurrency: .parallel,
            presentation: .init(
                symbol: "arrow.down.doc",
                activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
                output: .json, detailPresenterID: "builtin.scratch_pull", actionKind: .pull,
                includesTarget: true
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                var checked = invocation
                let arguments = try Arguments(invocation)
                checked.targetHostID = try arguments.uuid("host_id")
                _ = try AgentBuiltInTools.normalizeRemotePath(arguments.string("remote_path"))
                // Proven here so a malformed destination costs nothing, rather than a
                // round trip to the host followed by a local failure.
                _ = try AgentScratchWorkspace.normalize(arguments.string("scratch_path"))
                return AgentToolPreflight(invocation: checked, safety: .locallyContained)
            },
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let remote = try AgentBuiltInTools.normalizeRemotePath(
                    arguments.string("remote_path")
                )
                let hostID = try arguments.uuid("host_id")
                let data = try await AgentBuiltInTools.withAuthenticatedSFTP(
                    hostID: hostID, invocation: invocation, context: context,
                    authentication: authentication, pool: pool
                ) { client in
                    try await client.readFile(
                        at: remote, maximumBytes: AgentScratchWorkspace.Limits.fileBytes
                    )
                }
                let written = try await workspace.write(
                    arguments.string("scratch_path"), data: data
                )
                let text = String(data: data, encoding: .utf8)
                    .map(LineEnding.normalizedToLF)
                return result(invocation, .object([
                    "remote_path": .string(remote), "scratch_path": .string(written.path),
                    "bytes": .number(Double(written.bytes)), "sha256": .string(written.sha256),
                    "is_utf8": .bool(text != nil),
                    "lines": text.map { .number(Double(UnifiedDiff.split($0).lines.count)) } ?? .null,
                    "total_bytes": .number(Double(written.usage.bytes)),
                ]))
            }
        )
    }

    /// Workspace → host. The one tool here that changes something the user owns, so
    /// the only one behind the approval gate.
    private static func push(
        _ workspace: AgentScratchWorkspace, _ pool: AgentConnectionPool,
        _ authentication: AgentSSHAuthenticationRegistry
    ) -> AnyAgentTool {
        let tool = descriptor(
            "scratch_push",
            """
            Copy a scratch file to a remote path, atomically. No size limit beyond the \
            workspace quota, no copy of the file sent through this conversation, and no \
            UTF-8 requirement. The user is asked to approve this step; show them what \
            changed with scratch_diff first if it is not obvious.
            """,
            properties: [
                "host_id": string(), "scratch_path": string(max: pathBytes),
                "remote_path": string(max: 4_096), "overwrite": boolean(),
            ],
            required: ["host_id", "scratch_path", "remote_path"], target: .host,
            safety: .requiresAuthorization,
            presentation: .init(
                symbol: "arrow.up.doc",
                activity: .semanticArgument(key: "remote_path", fallback: .remoteFile),
                output: .json, detailPresenterID: "builtin.scratch_push", actionKind: .push,
                includesTarget: true
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                var checked = invocation
                let arguments = try Arguments(invocation)
                checked.targetHostID = try arguments.uuid("host_id")
                _ = try AgentBuiltInTools.normalizeRemotePath(arguments.string("remote_path"))
                let staged = try arguments.string("scratch_path")
                let file = try await workspace.data(at: staged)
                return AgentToolPreflight(
                    invocation: checked,
                    safety: .requiresAuthorization,
                    reasons: evidence(path: staged, file: file),
                    // Binds the approval to these exact bytes. Not an argument and
                    // not persisted — see `AgentToolPreflight.executionMetadata`.
                    executionMetadata: ["scratch_sha256": .string(file.sha256)]
                )
            },
            execute: { invocation, context in
                let arguments = try Arguments(invocation)
                let remote = try AgentBuiltInTools.normalizeRemotePath(
                    arguments.string("remote_path")
                )
                let staged = try arguments.string("scratch_path")
                let file = try await workspace.data(at: staged)
                // Approval suspends the turn, and what comes back from the workspace
                // afterwards is only the same file if nothing rewrote it in between.
                // Cheap to check, and the alternative is writing bytes to a host that
                // nobody approved.
                if let approved = context.preflightMetadata["scratch_sha256"]?.stringValue,
                    approved != file.sha256
                {
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
                        file.data, at: remote,
                        overwrite: arguments.optionalBool("overwrite") ?? false
                    )
                }
                return result(invocation, .object([
                    "scratch_path": .string(staged), "remote_path": .string(remote),
                    "bytes": .number(Double(file.bytes)), "sha256": .string(file.sha256),
                    "written": .bool(true),
                ]))
            }
        )
    }

    /// Network → workspace.
    ///
    /// `.locallyContained`, which is the sum of its two halves on exactly the terms
    /// `scratch_pull` argues: reading a page — public or private-network — is what
    /// `fetch` already does un-gated and never escalates for, and the landing site is
    /// storage the app owns. So it stays available while planning, which is right:
    /// staging the documentation you are planning against is planning.
    ///
    /// The point of it is the ceiling. `fetch` bounds what it returns at 256 KB
    /// because that is what crosses the context window; here nothing does, so the
    /// bound becomes the workspace's own 8 MB per-file limit and a page far larger
    /// than `fetch` can show lands whole, to be read a window at a time.
    private static func fetch(
        _ workspace: AgentScratchWorkspace, _ web: ScrubberWebClient
    ) -> AnyAgentTool {
        let tool = descriptor(
            "scratch_fetch",
            """
            Read an HTTP(S) webpage, including private-network pages, straight into the \
            scratch workspace. Returns its title, size and digest only — the page does not \
            enter this conversation, and there is no inline size ceiling, so a page far \
            larger than fetch can return lands whole. Prefer fetch to read a page once; \
            prefer this when the page is large, when you will refer back to it, or when it \
            is going to a host. Markdown by default, or the original HTML when format is \
            original.
            """,
            properties: [
                "url": string(max: 8_192),
                "scratch_path": string(max: pathBytes),
                "format": enumeration(["markdown", "original"]),
            ],
            required: ["url", "scratch_path"], target: .network,
            safety: .locallyContained, concurrency: .parallel,
            presentation: .init(
                symbol: "globe.badge.chevron.backward",
                activity: .semanticArgument(key: "url", fallback: .url),
                output: .json, detailPresenterID: "builtin.scratch_fetch",
                actionKind: .fetch
            )
        )
        return AnyAgentTool(
            descriptor: tool,
            preflight: { invocation in
                let arguments = try Arguments(invocation)
                _ = try ScrubberWebClient.validatedURL(arguments.string("url"))
                // Proven here so a malformed destination costs nothing, rather than a
                // page fetched over the network and then dropped on the floor.
                _ = try AgentScratchWorkspace.normalize(arguments.string("scratch_path"))
                return AgentToolPreflight(invocation: invocation, safety: .locallyContained)
            },
            execute: { invocation, _ in
                let arguments = try Arguments(invocation)
                let document = try await web.document(for: arguments.string("url"))
                let format = arguments.optionalString("format") ?? "markdown"
                let selected = format == "original" ? document.original : document.markdown
                // An empty representation means extraction failed, not that the page is
                // empty. Saying so beats spending one of the workspace's entries on a
                // zero-byte file the model will then try to read.
                guard !selected.isEmpty else { throw ScrubberWebError.emptyDocument }
                let written = try await workspace.write(
                    arguments.string("scratch_path"), data: Data(selected.utf8)
                )
                return result(invocation, .object([
                    "url": .string(document.url.absoluteString),
                    "title": .string(document.title),
                    "format": .string(format),
                    "scratch_path": .string(written.path),
                    "bytes": .number(Double(written.bytes)),
                    "sha256": .string(written.sha256),
                    "lines": .number(Double(
                        UnifiedDiff.split(LineEnding.normalizedToLF(selected)).lines.count
                    )),
                    "total_bytes": .number(Double(written.usage.bytes)),
                ]))
            }
        )
    }

    /// What the approval card and Security Review see in place of the content.
    ///
    /// Without this, `scratch_push` would be an approval that showed a filename where
    /// `sftp_write` showed the bytes — the reviewer, human or model, agreeing to
    /// something neither had seen. A digest, a size and a bounded head is not the
    /// whole file, but it is evidence rather than a name.
    private static func evidence(path: String, file: ScratchFile) -> [String] {
        var reasons = ["The content comes from the scratch workspace: \(path)"]
        guard let text = String(data: file.data, encoding: .utf8) else {
            reasons.append(
                "\(file.bytes) bytes of non-text data, sha256 \(file.sha256.prefix(16))…"
            )
            return reasons
        }
        // Normalized first, so a CRLF file's preview does not carry a stray carriage
        // return at the end of every line of the card.
        let lines = UnifiedDiff.split(LineEnding.normalizedToLF(text)).lines
        reasons.append(
            "\(file.bytes) bytes, \(lines.count) lines, sha256 \(file.sha256.prefix(16))…"
        )
        reasons.append(
            "First lines: "
                + AgentSensitiveDataRedactor.visibleText(
                    lines.prefix(20).joined(separator: "\n"), maximumCharacters: 600
                )
        )
        return reasons
    }

    private static func text(
        of path: String, in workspace: AgentScratchWorkspace
    ) async throws -> String {
        let file = try await workspace.data(at: path)
        guard let text = String(data: file.data, encoding: .utf8) else {
            throw AgentToolError.scratchNotText(path)
        }
        return text
    }
}

// MARK: - Tool-owned transcript details

nonisolated extension AgentScratchTools {
    static let listDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_list", present: presentListDetail
    )
    static let readDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_read", present: presentReadDetail
    )
    static let writeDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_write", present: presentWriteDetail
    )
    static let editDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_edit", present: presentEditDetail
    )
    static let diffDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_diff", present: presentDiffDetail
    )
    static let deleteDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_delete", present: presentDeleteDetail
    )
    static let pullDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_pull", present: presentPullDetail
    )
    static let pushDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_push", present: presentPushDetail
    )
    static let fetchDetailPresenter = AgentToolDetailPresenter(
        id: "builtin.scratch_fetch", present: presentFetchDetail
    )

    private static func presentListDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentReadDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentWriteDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentEditDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentDiffDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentDeleteDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentPullDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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

    private static func presentPushDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
        var items: [AgentToolDetail.Item] = []
        F.appendField(&items, "Scratch path", object["scratch_path"]?.stringValue, locale: input.locale, monospaced: true)
        F.appendField(&items, "Remote path", object["remote_path"]?.stringValue, locale: input.locale, monospaced: true)
        F.appendBytes(&items, "Size", object["bytes"], locale: input.locale)
        F.appendField(&items, "SHA-256", object["sha256"]?.stringValue, locale: input.locale, monospaced: true)
        items.append(F.field("Result", F.localized("Written", locale: input.locale), locale: input.locale))
        return items
    }

    /// The page's identity and where it landed, since its content is deliberately
    /// not in the result. `presentPullDetail` with a URL in place of a host path.
    private static func presentFetchDetail(
        _ input: AgentToolDetailInput
    ) -> [AgentToolDetail.Item] {
        typealias F = AgentToolDetailFormatting
        guard let object = input.result.objectValue else {
            return F.genericItems(input.result, locale: input.locale)
        }
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
