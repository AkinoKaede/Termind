import AgentKit
import Foundation
import Testing

@testable import Termind

@Suite
struct AgentToolPresentationTests {
    @Test
    func userInputDetailShowsOneQuestionAndAnswerFieldPerLine() throws {
        let arguments: [String: AgentJSONValue] = [
            "questions": .array([
                .object([
                    "id": .string("storage"), "header": .string("Storage"),
                    "prompt": .string("Which format should we use?"),
                    "options": .array([
                        .object(["id": .string("jsonb"), "label": .string("JSONB")])
                    ]),
                ]),
                .object([
                    "id": .string("region"), "prompt": .string("Which region?")
                ]),
            ])
        ]
        var card = makeCard(
            name: "request_user_input", target: .user, arguments: arguments,
            presentation: RequestUserInputTool().descriptor.presentation
        )
        card.state = .completed
        card.result = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "answers": .array([
                    .object([
                        "question_id": .string("storage"), "answer": .string("With audit log"),
                        "selected_option_ids": .array([.string("jsonb")]),
                        "custom_text": .string("With audit log"),
                    ]),
                    .object([
                        "question_id": .string("region"), "answer": .null,
                        "selected_option_ids": .array([]), "custom_text": .null,
                    ]),
                ])
            ]).encodedString
        )

        let detail = try #require(AgentToolPresentation.detail(for: card))
        #expect(detail.items == [
            .field(.init(label: "Question", value: "Storage — Which format should we use?")),
            .field(.init(label: "Answer", value: "JSONB, With audit log")),
            .field(.init(label: "Question", value: "Which region?")),
            .field(.init(label: "Answer", value: "Skipped")),
        ])
        #expect(!String(describing: detail).contains("selected_option_ids"))
        #expect(!String(describing: detail).contains("jsonb"))
    }

    @Test
    func hostListingDetailPreservesGroupsAndHidesProtocolIdentifiers() throws {
        let productionID = "11111111-1111-1111-1111-111111111111"
        let childID = "22222222-2222-2222-2222-222222222222"
        let result = AgentJSONValue.object([
            "groups": .array([
                .object([
                    "id": .string(productionID), "name": .string("Production"),
                    "path": .string("Production"),
                    "children": .array([
                        .object([
                            "id": .string(childID), "name": .string("Edge"),
                            "path": .string("Production / Edge"), "children": .array([]),
                        ])
                    ]),
                ])
            ]),
            "hosts": .array([
                hostJSON(
                    id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name: "API Server",
                    address: "deploy@api.example.com", state: "connected",
                    tags: ["prod", "nginx"], groupID: productionID
                ),
                hostJSON(
                    id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", name: "Loose Box",
                    address: "root@10.0.0.2", state: "failed", tags: [],
                    groupID: "ffffffff-ffff-ffff-ffff-ffffffffffff"
                ),
                hostJSON(
                    id: "cccccccc-cccc-cccc-cccc-cccccccccccc", name: "Current Terminal",
                    address: "root@10.0.0.8", state: "reconnecting", tags: [],
                    temporary: true
                ),
            ]),
        ])
        var card = makeCard(name: "list_hosts", target: .host)
        card.state = .completed
        card.result = AgentToolResult(callID: "call", content: result.encodedString)

        let detail = try #require(AgentToolPresentation.detail(for: card))
        guard case .groupedList(let listing) = try #require(detail.items.first) else {
            Issue.record("Expected a grouped host listing")
            return
        }
        #expect(listing.summary == "3 hosts · 1 connected · 1 temporary")
        #expect(listing.sections.map(\.title) == [
            "Production · 1 host", "Production / Edge · 0 hosts",
            "Ungrouped · 1 host", "Temporary · 1 host",
        ])
        #expect(listing.sections[0].rows[0].title == "API Server")
        #expect(listing.sections[0].rows[0].subtitle == "deploy@api.example.com · Connected")
        #expect(listing.sections[0].rows[0].badges == ["prod", "nginx"])
        #expect(listing.sections[2].rows[0].subtitle == "root@10.0.0.2 · Failed")
        #expect(listing.sections[3].rows[0].subtitle == "root@10.0.0.8 · Reconnecting")
        let rendered = String(describing: detail)
        #expect(!rendered.contains(productionID))
        #expect(!rendered.contains("aaaaaaaa-aaaa"))
        #expect(!rendered.contains("group_id"))
        #expect(!rendered.contains("connection_state"))
    }

    @Test
    func hostListingBecomesScrollablePastTwelveHosts() throws {
        let hosts = (0..<13).map { index in
            hostJSON(
                id: UUID().uuidString, name: "Host \(index)",
                address: "host\(index).example.com", state: "disconnected", tags: []
            )
        }
        var card = makeCard(name: "list_hosts", target: .host)
        card.result = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "groups": .array([]), "hosts": .array(hosts),
            ]).encodedString
        )

        let detail = try #require(AgentToolPresentation.detail(for: card))
        guard case .groupedList(let listing) = try #require(detail.items.first) else {
            Issue.record("Expected a grouped host listing")
            return
        }
        #expect(listing.isScrollable)
        #expect(listing.sections[0].rows.count == 13)
    }

    @Test
    func builtInFallbackUsesFieldsWhileMCPKeepsJSON() throws {
        let payload = AgentJSONValue.object([
            "internal_flag": .bool(true), "count": .number(2),
        ]).encodedString
        var builtIn = makeCard(name: "future_tool", target: .local)
        builtIn.result = AgentToolResult(callID: "call", content: payload)
        let builtInDetail = try #require(AgentToolPresentation.detail(for: builtIn))
        #expect(builtInDetail.items == [
            .field(.init(label: "Count", value: "2")),
            .field(.init(label: "Internal Flag", value: "Yes")),
        ])
        #expect(!String(describing: builtInDetail).contains("{"))

        var mcp = makeCard(
            name: "remote_tool", target: .mcp,
            presentation: .init(
                symbol: "puzzlepiece.extension", activity: .label("remote tool"), output: .json
            )
        )
        mcp.result = AgentToolResult(callID: "call", content: payload)
        let mcpDetail = try #require(AgentToolPresentation.detail(for: mcp))
        guard case .text(let block) = try #require(mcpDetail.items.first) else {
            Issue.record("Expected MCP JSON text")
            return
        }
        #expect(block.text.contains("{"))
        #expect(block.text.contains("\"internal_flag\""))
    }

    @Test
    func unknownPresenterIDCannotSelectOrImpersonateBuiltInCode() throws {
        var card = makeCard(
            name: "fetch", target: .network,
            presentation: .init(
                symbol: "globe", activity: .label("URL"), output: .json,
                presenterID: "remote.fetch"
            )
        )
        card.result = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "url": .string("https://example.com"), "status": .number(200),
            ]).encodedString
        )

        let detail = try #require(AgentToolPresentation.detail(for: card))
        #expect(detail.items == [
            .field(.init(label: "Status", value: "200")),
            .field(.init(label: "Url", value: "https://example.com")),
        ])
    }

    @Test
    func everyBuiltInJSONToolProducesStructuredDetailWithoutJSONSyntax() throws {
        let file = AgentJSONValue.object([
            "path": .string("/tmp/a"), "name": .string("a"), "kind": .string("file"),
            "size": .number(4), "permissions": .string("644"), "modified_at": .null,
        ])
        let cases: [(String, AgentToolDescriptor.Target, [String: AgentJSONValue], AgentJSONValue)] = [
            ("list_hosts", .host, [:], .object(["groups": .array([]), "hosts": .array([])])),
            ("ssh_exec", .host, [:], .object([
                "status": .string("exited"), "stdout": .string("ok"),
                "stderr": .string(""), "exit_code": .number(0),
            ])),
            ("ssh_wait", .host, [:], .object([
                "status": .string("running"), "stdout": .string(""),
                "stderr": .string(""), "note": .string("Still running"),
            ])),
            ("terminal_suggest", .user, ["command": .string("pwd")], .object([
                "command": .string("pwd"), "requires_user_action": .bool(true),
            ])),
            ("sftp_list", .host, [:], .array([file])),
            ("sftp_stat", .host, [:], file),
            ("sftp_read", .host, [:], .object([
                "path": .string("/tmp/a"), "content": .string("text"), "bytes": .number(4),
            ])),
            ("sftp_write", .host, ["content": .string("text")], .object([
                "path": .string("/tmp/a"), "written": .bool(true),
            ])),
            ("sftp_mkdir", .host, [:], .object([
                "path": .string("/tmp/new"), "created": .bool(true),
            ])),
            ("sftp_move", .host, [:], .object([
                "source": .string("/tmp/a"), "destination": .string("/tmp/b"),
                "moved": .bool(true),
            ])),
            ("sftp_chmod", .host, [:], .object([
                "path": .string("/tmp/a"), "mode": .string("644"),
            ])),
            ("sftp_delete", .host, ["kind": .string("file")], .object([
                "path": .string("/tmp/a"), "deleted": .bool(true),
            ])),
            ("fetch", .network, ["method": .string("GET")], .object([
                "url": .string("https://example.com"), "status": .number(200),
                "headers": .object(["content-type": .string("text/plain")]),
                "body": .string("hello"),
            ])),
            ("web_search", .network, [:], .array([
                .object([
                    "title": .string("Example"), "url": .string("https://example.com"),
                    "snippet": .string("Snippet"), "published_at": .null,
                ])
            ])),
            ("request_user_input", .user, [
                "questions": .array([
                    .object(["id": .string("q"), "prompt": .string("Question?")])
                ])
            ], .object([
                "answers": .array([
                    .object(["question_id": .string("q"), "answer": .string("Answer")])
                ])
            ])),
            ("request_user_secret", .user, [
                "prompt": .string("Password"), "purpose": .string("Login"),
                "consumer_tool": .string("ssh_exec"),
            ], .object(["secret_handle": .string("hidden"), "single_use": .bool(true)])),
            ("scratch_list", .local, [:], .object([
                "entries": .array([]), "entry_count": .number(0),
                "entry_quota": .number(100), "total_bytes": .number(0),
                "byte_quota": .number(1000),
            ])),
            ("scratch_read", .local, [:], .object([
                "path": .string("a"), "content": .string("text"), "bytes": .number(4),
                "offset": .number(1), "returned_lines": .number(1),
                "total_lines": .number(1), "line_ending": .string("lf"),
            ])),
            ("scratch_write", .local, [:], .object([
                "path": .string("a"), "bytes": .number(4), "sha256": .string("abcd"),
                "created": .bool(true), "total_bytes": .number(4),
            ])),
            ("scratch_edit", .local, [:], .object([
                "path": .string("a"), "edits_applied": .number(1),
                "diff": .string("-old\n+new"), "bytes": .number(3),
                "line_ending": .string("lf"), "sha256": .string("abcd"),
                "total_bytes": .number(3),
            ])),
            ("scratch_diff", .local, [:], .object([
                "path_a": .string("a"), "path_b": .string("b"),
                "identical": .bool(true), "diff": .string(""),
                "line_ending_a": .string("lf"), "line_ending_b": .string("lf"),
            ])),
            ("scratch_delete", .local, [:], .object([
                "path": .string("a"), "kind": .string("file"), "deleted": .bool(true),
                "entry_count": .number(0), "total_bytes": .number(0),
            ])),
            ("scratch_pull", .host, [:], .object([
                "remote_path": .string("/tmp/a"), "scratch_path": .string("a"),
                "bytes": .number(4), "sha256": .string("abcd"),
                "is_utf8": .bool(true), "lines": .number(1), "total_bytes": .number(4),
            ])),
            ("scratch_push", .host, [:], .object([
                "scratch_path": .string("a"), "remote_path": .string("/tmp/a"),
                "bytes": .number(4), "sha256": .string("abcd"), "written": .bool(true),
            ])),
            ("present_plan", .user, [:], .object([
                "presented": .bool(true), "scratch_path": .string("plan.md"),
                "plan": .string("Plan"),
            ])),
            ("manage_tasks", .user, [:], .object([
                "tasks": .number(3), "completed": .number(1),
            ])),
        ]

        for (name, target, arguments, result) in cases {
            var card = makeCard(name: name, target: target, arguments: arguments)
            card.result = AgentToolResult(callID: "call", content: result.encodedString)
            let detail = try #require(AgentToolPresentation.detail(for: card), "Missing \(name)")
            let rendered = String(describing: detail)
            #expect(!rendered.contains("{"), "\(name) exposed JSON")
            #expect(!rendered.contains("}"), "\(name) exposed JSON")
        }
    }

    /// Separate from the table above, which builds cards without a presentation and
    /// so resolves through `legacyPresenter`. `scratch_fetch` has never shipped, so
    /// it deliberately has no legacy name and is reached only by presenter ID.
    @Test
    func scratchFetchDetailIsStructuredWithoutJSONSyntax() throws {
        var card = makeCard(
            name: "scratch_fetch", target: .network,
            arguments: ["url": .string("https://example.com/docs")],
            presentation: .init(
                symbol: "globe.badge.chevron.backward",
                activity: .semanticArgument(key: "url", fallback: .url),
                output: .json, presenterID: "builtin.scratch_fetch",
                actionKind: .fetch
            )
        )
        card.result = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "url": .string("https://example.com/docs"), "title": .string("Docs"),
                "format": .string("markdown"), "scratch_path": .string("docs.md"),
                "bytes": .number(4), "sha256": .string("abcd"), "lines": .number(1),
                "total_bytes": .number(4),
            ]).encodedString
        )

        let detail = try #require(AgentToolPresentation.detail(for: card))
        let rendered = String(describing: detail)
        #expect(!rendered.contains("{"))
        #expect(!rendered.contains("}"))
        #expect(rendered.contains("docs.md"))
        #expect(rendered.contains("Docs"))
    }

    @Test
    func scratchSearchDetailIsStructuredWithoutJSONSyntax() throws {
        var card = makeCard(
            name: "scratch_search", target: .local,
            arguments: ["query": .string("listen")],
            presentation: .init(
                symbol: "magnifyingglass",
                activity: .semanticArgument(key: "query", fallback: .scratchWorkspace),
                output: .json, presenterID: "builtin.scratch_search",
                actionKind: .search
            )
        )
        card.result = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object([
                "matches": .array([
                    .object([
                        "path": .string("nginx.conf"), "line": .number(12),
                        "text": .string("listen 443 ssl;"),
                        "text_truncated": .bool(false),
                    ]),
                ]),
                "matching_lines": .number(1), "returned_matches": .number(1),
                "searched_files": .number(2), "skipped_binary_files": .number(1),
                "case_sensitive": .bool(false), "truncated": .bool(false),
            ]).encodedString
        )

        let detail = try #require(AgentToolPresentation.detail(for: card))
        let rendered = String(describing: detail)
        #expect(rendered.contains("nginx.conf:12"))
        #expect(rendered.contains("listen 443 ssl;"))
        #expect(!rendered.contains("{"))
        #expect(!rendered.contains("}"))
    }

    @Test
    func batchIconFollowsLiveAndHomogeneousTools() {
        let terminal = AgentToolDescriptor.Presentation(
            symbol: "terminal", activity: .label("a command"),
            actionKind: .run
        )
        var first = makeCard(name: "ssh_exec", target: .host, presentation: terminal)
        var second = makeCard(name: "ssh_exec", target: .host, presentation: terminal)
        first.state = .running
        second.state = .proposed
        #expect(AgentToolPresentation.batchSymbol(for: [first, second]) == "terminal")
        #expect(AgentToolPresentation.batchTint(for: [first, second]) == .secondary)

        first.state = .completed
        second.state = .completed
        #expect(AgentToolPresentation.batchSymbol(for: [first, second]) == "terminal")
        #expect(AgentToolPresentation.batchTint(for: [first, second]) == .success)

        first.state = .failed
        second.state = .denied
        #expect(AgentToolPresentation.batchTint(for: [first, second]) == .failure)

        first.state = .completed
        second.state = .failed
        #expect(AgentToolPresentation.batchTint(for: [first, second]) == .warning)

        var question = makeCard(
            name: "request_user_input", target: .user,
            presentation: RequestUserInputTool().descriptor.presentation
        )
        question.state = .completed
        #expect(
            AgentToolPresentation.batchSymbol(for: [first, question])
                == "wrench.and.screwdriver"
        )
    }

    @Test
    func reasoningBatchTitleIsPlainSingleLineText() {
        let title = AgentToolPresentation.reasoningTitle(from: """
            **Checked both hosts.**

            - Compare the logs
            - Verify `sshd`
            """)

        #expect(title == "Checked both hosts. Compare the logs Verify sshd")
    }

    @Test
    func countedArrayActivityRoundTrips() throws {
        let activity = AgentToolDescriptor.Presentation.Activity.localizedArrayCount(
            key: "questions", unit: .question, fallback: "a question"
        )
        let data = try JSONEncoder().encode(activity)
        #expect(try JSONDecoder().decode(type(of: activity), from: data) == activity)
    }

    @Test
    func outputUnwrapsAndExtractsCommandStreams() {
        let result = AgentToolResult(
            callID: "call",
            content: "<untrusted-data>\n{\"stdout\":\"ok\\n\",\"stderr\":\"warning\"}\n</untrusted-data>",
            metadata: ["untrusted": .bool(true)]
        )

        #expect(
            AgentToolPresentation.output(
                from: result,
                presentation: .init(
                    symbol: "terminal", activity: .label("command"), output: .streams
                )
            )
                == "Standard output:\nok\n\nStandard error:\nwarning"
        )
    }

    @Test
    func duplicateSecurityReviewDenialIsShownOnlyOnce() {
        let reason = "The request was not explicitly authorized."
        let review = SecurityReviewDecision(
            verdict: .deny, risk: .high, userAuthorization: .insufficient,
            reason: reason
        )
        let duplicate = AgentToolResult(
            callID: "call", content: "  The request was not explicitly\nauthorized.  ",
            isError: true
        )
        let distinct = AgentToolResult(
            callID: "call", content: "The remote host refused the command.", isError: true
        )

        #expect(
            AgentToolPresentation.detailOutput(
                from: duplicate, presentation: nil, review: review
            ) == nil)
        #expect(
            AgentToolPresentation.detailOutput(
                from: distinct, presentation: nil, review: review
            ) == "The remote host refused the command.")
    }

    @Test
    func allowedReviewNeverHidesAResult() {
        let review = SecurityReviewDecision(
            verdict: .approve, risk: .low, userAuthorization: .sufficient,
            reason: "Completed with a warning."
        )
        let result = AgentToolResult(
            callID: "call", content: review.reason, isError: true
        )

        #expect(
            AgentToolPresentation.detailOutput(
                from: result, presentation: nil, review: review
            ) == review.reason)
    }

    @Test
    func longOutputPreviewStaysWithinTheRenderingBudgetAndKeepsFullCopy() {
        let full = (0..<180).map { "line \($0) " + String(repeating: "x", count: 80) }
            .joined(separator: "\n")

        let preview = AgentToolPresentation.preview(full)

        #expect(preview.isShortened)
        #expect(preview.full == full)
        #expect(preview.displayed.count <= AgentToolPresentation.displayCharacterLimit)
        #expect(
            preview.displayed.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                <= AgentToolPresentation.displayLineLimit
        )
        #expect(preview.displayed.hasPrefix("line 0"))
        #expect(preview.displayed.contains("characters omitted"))
        #expect(preview.displayed.hasSuffix(String(repeating: "x", count: 80)))
        #expect(preview.omittedCharacters > 0)
    }

    @Test
    func outputPreviewCountsUnicodeCharactersWithoutCorruptingEitherEnd() {
        let full = "开头🧭" + String(repeating: "中", count: 200) + "结尾✅"
        let preview = AgentToolPresentation.preview(full, characterLimit: 80, lineLimit: 120)

        #expect(preview.isShortened)
        #expect(preview.displayed.count <= 80)
        #expect(preview.displayed.hasPrefix("开头🧭"))
        #expect(preview.displayed.hasSuffix("结尾✅"))
        #expect(preview.full == full)
    }

    @Test
    func shortOutputIsNotProjectedOrMarkedAsShortened() {
        let full = "one\ntwo\nthree"
        let preview = AgentToolPresentation.preview(full)

        #expect(
            preview
                == .init(
                    displayed: full, full: full, isShortened: false, omittedCharacters: 0
                ))
    }

    @Test
    func presentationRoundTripsThroughExistingResultMetadata() {
        let presentation = AgentToolDescriptor.Presentation(
            symbol: "terminal",
            activity: .argument(key: "command", fallback: "the SSH command"),
            output: .streams,
            presenterID: "builtin.ssh_exec",
            groupsWithAdjacentTools: false,
            messages: ["running": "Connecting to {target}"]
        )
        var result = AgentToolResult(callID: "call", content: "done")
        result.toolPresentation = presentation

        #expect(result.toolPresentation == presentation)
        #expect(result.metadata[AgentToolResult.toolPresentationKey] != nil)
    }

    @Test
    func builtInDetailPresenterCatalogHasUniqueStableIDs() {
        // The composed registry, runtime plus Termind: a duplicate ID across the
        // two catalogs is exactly the collision that would make one app's card
        // draw with another's projection, and it is invisible in either catalog
        // alone.
        let runtime = AgentToolCatalog.builtInPresenters.map(\.id)
        let ids = TermindAgentTools.presenterRegistry.ids
        #expect(Set(ids).count == ids.count)
        #expect(Set(runtime).isSubset(of: Set(ids)))
        #expect(ids.allSatisfy { $0.hasPrefix("builtin.") })
        for id in ids {
            #expect(TermindAgentTools.presenter(id: id) != nil)
        }
    }

    @Test
    func restoredAndLegacyCardsUseTheSameToolOwnedDetailPresenter() throws {
        let payload = AgentJSONValue.array([
            .object([
                "title": .string("Example"), "url": .string("https://example.com"),
                "snippet": .string("A result"), "published_at": .null,
            ])
        ])
        let livePresentation = WebSearchTool.presenter.id
        var persisted = AgentToolResult(callID: "call", content: payload.encodedString)
        persisted.toolPresentation = .init(
            symbol: "magnifyingglass",
            activity: .semanticArgument(key: "query", fallback: .web), output: .json,
            presenterID: livePresentation, actionKind: .search
        )

        var restored = makeCard(
            name: "web_search", target: .network,
            arguments: ["query": .string("example")],
            presentation: persisted.toolPresentation
        )
        restored.result = persisted

        var legacy = makeCard(
            name: "web_search", target: .network,
            arguments: ["query": .string("example")]
        )
        legacy.result = persisted
        legacy.descriptor.presentation = nil

        #expect(
            AgentToolPresentation.detail(for: restored, locale: Locale(identifier: "en"))
                == AgentToolPresentation.detail(for: legacy, locale: Locale(identifier: "en"))
        )
    }

    @Test
    func semanticPresentationRoundTripsAndOldMetadataUsesSafeDefaults() throws {
        let semantic = AgentToolDescriptor.Presentation(
            symbol: "magnifyingglass",
            activity: .semanticArgument(key: "query", fallback: .web),
            output: .json, presenterID: "builtin.web_search",
            groupsWithAdjacentTools: false, actionKind: .search,
            phaseKinds: ["running": .sshConnecting]
        )
        let encoded = try JSONEncoder().encode(semantic)
        #expect(
            try JSONDecoder().decode(AgentToolDescriptor.Presentation.self, from: encoded)
                == semantic
        )

        let legacy = AgentToolDescriptor.Presentation(
            symbol: "terminal", activity: .argument(key: "command", fallback: "a command")
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["groupsWithAdjacentTools"] = nil
        object["actionKind"] = nil
        object["phaseKinds"] = nil
        object["presenterID"] = nil
        object["detailPresenterID"] = "builtin.web_search"
        let decoded = try JSONDecoder().decode(
            AgentToolDescriptor.Presentation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.groupsWithAdjacentTools)
        #expect(decoded.actionKind == nil)
        #expect(decoded.phaseKinds.isEmpty)
        #expect(decoded.presenterID == "builtin.web_search")
    }

    @Test
    func legacyCountedArrayActivityStillDecodes() throws {
        let activity = AgentToolDescriptor.Presentation.Activity.arrayCount(
            key: "questions", singular: "a question", plural: "questions",
            fallback: "a question"
        )
        let data = try JSONEncoder().encode(activity)
        #expect(try JSONDecoder().decode(type(of: activity), from: data) == activity)
    }

    private func makeCard(
        name: String, target: AgentToolDescriptor.Target,
        arguments: [String: AgentJSONValue] = [:],
        presentation: AgentToolDescriptor.Presentation? = nil
    ) -> AgentToolCard {
        AgentToolCard(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: "call", name: name, arguments: .object(arguments))
            ),
            descriptor: AgentToolDescriptor(
                name: name, summary: name,
                inputSchema: .object(["type": .string("object")]),
                target: target, safety: .locallyReadOnly, presentation: presentation
            )
        )
    }

    private func hostJSON(
        id: String, name: String, address: String, state: String, tags: [String],
        groupID: String? = nil, temporary: Bool = false
    ) -> AgentJSONValue {
        .object([
            "id": .string(id), "display_name": .string(name), "address": .string(address),
            "tags": .array(tags.map(AgentJSONValue.string)),
            "connection_state": .string(state), "temporary": .bool(temporary),
            "group_id": groupID.map(AgentJSONValue.string) ?? .null,
            "group_path": .null,
        ])
    }
}
