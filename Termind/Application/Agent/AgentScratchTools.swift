import Foundation

/// The agent's own staging area, exposed as tools.
///
/// Six of these are `target: .local` and cannot leave `AgentScratchWorkspace`'s
/// scope directory — not to a host, not to the network, not to any other part of
/// the user's disk. That containment is what earns `.locallyContained` on the three
/// that write: they change something, but only storage the app owns.
///
/// `scratch_pull` and `scratch_push` are the exception and the reason the rest is
/// worth having. They move bytes between a host and the workspace *without the
/// bytes passing through the conversation*, which is what lifts `sftp_read`'s 128 KB
/// inline ceiling and stops an edit costing two copies of the file in tokens. They
/// are kept separate from `sftp_read` / `sftp_write` rather than folded in as
/// options: a tool that means two different things depending on which optional
/// argument is present is harder for a model to choose correctly and harder for a
/// reader to audit, and only one of the two directions needs approval.
///
/// Everything except `scratch_push` is `.parallel`. The workspace is an actor, so it
/// is already the per-path mutation queue Pi builds explicitly — a read and a write
/// of the same file in one batch serialize against each other there rather than by
/// taking the whole turn serial.
nonisolated enum AgentScratchTools: AgentToolSchemaBuilding {
    /// Connection and authentication services travel together. If either is
    /// absent no transfer tools are registered, rather than exposing a path
    /// that fails on first use or bypasses Agent credential interaction.
    static func make(
        workspace: AgentScratchWorkspace,
        connections: AgentConnectionPool? = nil,
        authentication: AgentSSHAuthenticationRegistry? = nil
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
        ] + transfers
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
            required: [], target: .local, safety: .locallyReadOnly, concurrency: .parallel
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
            required: ["path"], target: .local, safety: .locallyReadOnly, concurrency: .parallel
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
            concurrency: .parallel
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
            concurrency: .parallel
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
            concurrency: .parallel
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
            concurrency: .parallel
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
            safety: .locallyContained, concurrency: .parallel
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
            safety: .requiresAuthorization
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
