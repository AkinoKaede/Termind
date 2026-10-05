import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import TermindRemoteInfrastructure

@Suite
struct AgentToolPresentationTests {
    @Test
    func approvalUsesTheRegisteredToolArgumentProjectionWithoutRedactingIt() throws {
        let hostID = UUID()
        let command = "sudo deploy --token=visible-to-the-user"
        let request = AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: "approval",
                    name: "ssh_exec",
                    arguments: .object([
                        "host_id": .string(hostID.uuidString),
                        "command": .string(command),
                        "stdin": .string("password=hunter2"),
                        "secret_handle": .string("one-shot-handle"),
                        "stdin_purpose": .string("sudo password"),
                    ])
                ),
                targetHostID: hostID
            ),
            descriptor: AgentToolDescriptor(
                name: "ssh_exec", summary: "Execute over SSH",
                inputSchema: .object([:]), target: .host,
                approvalPolicy: .ask,
                presentation: .init(
                    symbol: "terminal",
                    activity: .semanticArgument(key: "command", fallback: .sshCommand),
                    actionKind: .run
                )
            ),
            userIntent: "Deploy"
        )

        let presentation = AgentToolPresentation.approval(
            for: request,
            presenter: SSHExecTool.presenter,
            hostName: "Production",
            locale: Locale(identifier: "en")
        )

        #expect(!presentation.title.contains(command))
        #expect(!presentation.title.contains(hostID.uuidString))
        #expect(
            presentation.detail.items == [
                .text(.init(title: "Command", text: command, style: .monospaced)),
                .text(.init(title: "Input", text: "password=hunter2", style: .monospaced)),
                .field(.init(label: "Secret handle", value: "one-shot-handle", isMonospaced: true)),
                .field(.init(label: "Purpose", value: "sudo password")),
            ]
        )
    }

    @Test
    func approvalFallsBackToGenericFieldsForAnUnregisteredTool() {
        let request = AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(
                    id: "approval", name: "remote_tool",
                    arguments: .object(["password": .string("hunter2")])
                )
            ),
            descriptor: AgentToolDescriptor(
                name: "remote_tool", summary: "Remote tool",
                inputSchema: .object([:]), target: .mcp,
                approvalPolicy: .ask
            ),
            userIntent: "Run it"
        )

        let presentation = AgentToolPresentation.approval(
            for: request, locale: Locale(identifier: "en")
        )
        #expect(!presentation.title.contains("hunter2"))
        #expect(
            presentation.detail.items == [
                .field(.init(label: "Password", value: "hunter2"))
            ]
        )
    }

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
                    "id": .string("region"), "prompt": .string("Which region?"),
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

        let detail = try #require(
            AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)))
        #expect(
            detail.items == [
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

        let detail = try #require(
            AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)))
        guard case .groupedList(let listing) = try #require(detail.items.first) else {
            Issue.record("Expected a grouped host listing")
            return
        }
        #expect(
            listing.sections.map { $0.rows.map(\.title) } == [
                ["API Server"], [], ["Loose Box"], ["Current Terminal"],
            ])
        #expect(listing.sections[0].rows[0].badges == ["prod", "nginx"])
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

        let detail = try #require(
            AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)))
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
        let builtInDetail = try #require(
            AgentToolPresentation.detail(for: builtIn, presenter: TermindAgentTools.presenter(for: builtIn.descriptor)))
        #expect(
            builtInDetail.items == [
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
        let mcpDetail = try #require(
            AgentToolPresentation.detail(for: mcp, presenter: TermindAgentTools.presenter(for: mcp.descriptor)))
        guard case .text(let block) = try #require(mcpDetail.items.first) else {
            Issue.record("Expected MCP JSON text")
            return
        }
        #expect(block.text.contains("{"))
        #expect(block.text.contains("\"internal_flag\""))
    }

    @Test
    func everyChatCollaborationToolUsesCompactDetails() {
        for name in [
            "list_models", "create_new_chat", "list_chats", "read_chat",
            "send_to_chat", "wait_chats",
        ] {
            let card = makeCard(name: name, target: .local)
            #expect(
                AgentToolPresentation.usesCompactDetails(for: card.descriptor),
                Comment(rawValue: "\(name) should use bounded compact details"))
        }
    }

    @Test
    func missingChatApprovalPresenterNeverFallsBackToPromptOrMessageFields() {
        for (name, arguments, secret) in [
            (
                "create_new_chat",
                ["prompt": AgentJSONValue.string("private create body")],
                "private create body"
            ),
            (
                "send_to_chat",
                [
                    "chat_id": AgentJSONValue.string(UUID().uuidString),
                    "message": AgentJSONValue.string("private send body"),
                ],
                "private send body"
            ),
        ] {
            let card = makeCard(name: name, target: .local, arguments: arguments)
            let request = AgentApprovalRequest(
                invocation: card.invocation, descriptor: card.descriptor,
                userIntent: "Collaborate")

            let approval = AgentToolPresentation.approval(
                for: request, presenter: nil, locale: Locale(identifier: "en"))
            let rendered = AgentToolDetailPreview(approval.detail).fullText
            #expect(!rendered.contains(secret))
            #expect(approval.detail.items.isEmpty)
        }
    }

    @Test
    func chatFallbacksNeverExposeMalformedErrorOrUnprojectedBodies() throws {
        let privateBody = "private routed body"
        let validPayload = AgentJSONValue.object([
            "chat_id": .string(UUID().uuidString),
            "title": .string("Target"),
            "status": .string("delivered"),
            "message": .string(privateBody),
        ]).encodedString
        let cases: [(String, AgentToolResult, AgentToolDetailPresenter?)] = [
            (
                "malformed",
                AgentToolResult(callID: "call", content: privateBody),
                TermindAgentTools.presenter(id: "builtin.send_to_chat")
            ),
            (
                "error",
                AgentToolResult(callID: "call", content: privateBody, isError: true),
                TermindAgentTools.presenter(id: "builtin.send_to_chat")
            ),
            (
                "missing presenter",
                AgentToolResult(callID: "call", content: validPayload),
                nil
            ),
        ]

        for (label, result, presenter) in cases {
            var card = makeCard(
                name: "send_to_chat", target: .local,
                presentation: .init(
                    symbol: "paperplane", activity: .semanticLabel(.chat),
                    output: .json, presenterID: "builtin.send_to_chat",
                    actionKind: .send))
            card.result = result
            if result.isError { card.state = .failed }
            let detail = try #require(
                AgentToolPresentation.detail(
                    for: card, presenter: presenter,
                    locale: Locale(identifier: "en")),
                Comment(rawValue: label))
            let rendered = AgentToolDetailPreview(detail).fullText
            #expect(!rendered.contains(privateBody), Comment(rawValue: label))
            #expect(!rendered.contains("\"message\""), Comment(rawValue: label))
            #expect(rendered == "Chat details unavailable", Comment(rawValue: label))
        }
    }

    @Test
    func chatCompactPreviewAndFullCopyContainOnlyProjectedBoundedFields() throws {
        let secret = "body-that-must-never-render"
        let creatorSecrets = (0..<12).map { "creator-that-must-never-render-\($0)" }
        let creatorIDs = (0..<12).map { _ in UUID().uuidString }
        let chats = (0..<12).map { index in
            AgentJSONValue.object([
                "chat_id": .string(UUID().uuidString),
                "title": .string("Chat \(index)"),
                "status": .string("completed"),
                "message": .string("\(secret)-\(index)"),
                "creator": .object([
                    "kind": .string("agent"),
                    "chat_id": .string(creatorIDs[index]),
                    "title": .string(creatorSecrets[index]),
                ]),
            ])
        }
        var card = makeCard(
            name: "list_chats", target: .local,
            presentation: .init(
                symbol: "bubble.left.and.bubble.right",
                activity: .semanticLabel(.chats), output: .json,
                presenterID: "builtin.list_chats", actionKind: .list))
        card.result = AgentToolResult(
            callID: "call",
            content: AgentJSONValue.object(["chats": .array(chats)]).encodedString)

        let detail = try #require(
            AgentToolPresentation.detail(
                for: card,
                presenter: TermindAgentTools.presenter(id: "builtin.list_chats"),
                locale: Locale(identifier: "en")))
        let preview = AgentToolDetailPreview(detail)

        #expect(preview.isShortened)
        #expect(preview.fullText.contains("Chat 11"))
        #expect(!preview.fullText.contains(secret))
        #expect(creatorSecrets.allSatisfy { !preview.fullText.contains($0) })
        #expect(creatorIDs.allSatisfy { !preview.fullText.contains($0) })
        let displayed = AgentToolDetailPreview(
            AgentToolDetail(items: preview.items)
        ).fullText
        #expect(!displayed.contains(secret))
        #expect(creatorSecrets.allSatisfy { !displayed.contains($0) })
        #expect(creatorIDs.allSatisfy { !displayed.contains($0) })
        guard case .list(let list) = try #require(preview.items.first) else {
            Issue.record("Expected compact chat list")
            return
        }
        #expect(list.rows.count == AgentToolDetailPreview.rowLimit)
        #expect(displayed.count <= AgentToolDetailPreview.characterLimit + 20)
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

        let detail = try #require(
            AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)))
        #expect(
            detail.items == [
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
            (
                "ssh_exec", .host, [:],
                .object([
                    "status": .string("exited"), "stdout": .string("ok"),
                    "stderr": .string(""), "exit_code": .number(0),
                ])
            ),
            (
                "ssh_wait", .host, [:],
                .object([
                    "status": .string("running"), "stdout": .string(""),
                    "stderr": .string(""), "note": .string("Still running"),
                ])
            ),
            (
                "terminal_suggest", .user, ["command": .string("pwd")],
                .object([
                    "command": .string("pwd"), "requires_user_action": .bool(true),
                ])
            ),
            ("sftp_list", .host, [:], .array([file])),
            ("sftp_stat", .host, [:], file),
            (
                "sftp_read", .host, [:],
                .object([
                    "path": .string("/tmp/a"), "content": .string("text"), "bytes": .number(4),
                ])
            ),
            (
                "sftp_write", .host, ["content": .string("text")],
                .object([
                    "path": .string("/tmp/a"), "written": .bool(true),
                ])
            ),
            (
                "sftp_mkdir", .host, [:],
                .object([
                    "path": .string("/tmp/new"), "created": .bool(true),
                ])
            ),
            (
                "sftp_move", .host, [:],
                .object([
                    "source": .string("/tmp/a"), "destination": .string("/tmp/b"),
                    "moved": .bool(true),
                ])
            ),
            (
                "sftp_chmod", .host, [:],
                .object([
                    "path": .string("/tmp/a"), "mode": .string("644"),
                ])
            ),
            (
                "sftp_delete", .host, ["kind": .string("file")],
                .object([
                    "path": .string("/tmp/a"), "deleted": .bool(true),
                ])
            ),
            (
                "fetch", .network, ["method": .string("GET")],
                .object([
                    "url": .string("https://example.com"), "status": .number(200),
                    "headers": .object(["content-type": .string("text/plain")]),
                    "body": .string("hello"),
                ])
            ),
            (
                "web_search", .network, [:],
                .array([
                    .object([
                        "title": .string("Example"), "url": .string("https://example.com"),
                        "snippet": .string("Snippet"), "published_at": .null,
                    ])
                ])
            ),
            (
                "request_user_input", .user,
                [
                    "questions": .array([
                        .object(["id": .string("q"), "prompt": .string("Question?")])
                    ])
                ],
                .object([
                    "answers": .array([
                        .object(["question_id": .string("q"), "answer": .string("Answer")])
                    ])
                ])
            ),
            (
                "request_user_secret", .user,
                [
                    "prompt": .string("Password"), "purpose": .string("Login"),
                    "consumer_tool": .string("ssh_exec"),
                ], .object(["secret_handle": .string("hidden"), "single_use": .bool(true)])
            ),
            (
                "scratch_list", .local, [:],
                .object([
                    "entries": .array([]), "entry_count": .number(0),
                    "entry_quota": .number(100), "total_bytes": .number(0),
                    "byte_quota": .number(1000),
                ])
            ),
            (
                "scratch_read", .local, [:],
                .object([
                    "path": .string("a"), "content": .string("text"), "bytes": .number(4),
                    "offset": .number(1), "returned_lines": .number(1),
                    "total_lines": .number(1), "line_ending": .string("lf"),
                ])
            ),
            (
                "scratch_write", .local, [:],
                .object([
                    "path": .string("a"), "bytes": .number(4), "sha256": .string("abcd"),
                    "created": .bool(true), "total_bytes": .number(4),
                ])
            ),
            (
                "scratch_edit", .local, [:],
                .object([
                    "path": .string("a"), "edits_applied": .number(1),
                    "diff": .string("-old\n+new"), "bytes": .number(3),
                    "line_ending": .string("lf"), "sha256": .string("abcd"),
                    "total_bytes": .number(3),
                ])
            ),
            (
                "scratch_diff", .local, [:],
                .object([
                    "path_a": .string("a"), "path_b": .string("b"),
                    "identical": .bool(true), "diff": .string(""),
                    "line_ending_a": .string("lf"), "line_ending_b": .string("lf"),
                ])
            ),
            (
                "scratch_delete", .local, [:],
                .object([
                    "path": .string("a"), "kind": .string("file"), "deleted": .bool(true),
                    "entry_count": .number(0), "total_bytes": .number(0),
                ])
            ),
            (
                "scratch_pull", .host, [:],
                .object([
                    "remote_path": .string("/tmp/a"), "scratch_path": .string("a"),
                    "bytes": .number(4), "sha256": .string("abcd"),
                    "is_utf8": .bool(true), "lines": .number(1), "total_bytes": .number(4),
                ])
            ),
            (
                "scratch_push", .host, [:],
                .object([
                    "scratch_path": .string("a"), "remote_path": .string("/tmp/a"),
                    "bytes": .number(4), "sha256": .string("abcd"), "written": .bool(true),
                ])
            ),
            (
                "present_plan", .user, [:],
                .object([
                    "presented": .bool(true), "scratch_path": .string("plan.md"),
                    "plan": .string("Plan"),
                ])
            ),
            (
                "manage_tasks", .user, [:],
                .object([
                    "tasks": .number(3), "completed": .number(1),
                ])
            ),
        ]

        for (name, target, arguments, result) in cases {
            var card = makeCard(name: name, target: target, arguments: arguments)
            card.result = AgentToolResult(callID: "call", content: result.encodedString)
            let detail = try #require(
                AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)),
                "Missing \(name)")
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

        let detail = try #require(
            AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)))
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
                    ])
                ]),
                "matching_lines": .number(1), "returned_matches": .number(1),
                "searched_files": .number(2), "skipped_binary_files": .number(1),
                "case_sensitive": .bool(false), "truncated": .bool(false),
            ]).encodedString
        )

        let detail = try #require(
            AgentToolPresentation.detail(for: card, presenter: TermindAgentTools.presenter(for: card.descriptor)))
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
        let title = AgentToolPresentation.reasoningTitle(
            from: """
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
    func duplicateGuardianDenialIsShownOnlyOnce() {
        let reason = "The request was not explicitly authorized."
        let review = GuardianDecision(
            verdict: .deny, risk: .high, userAuthorization: .low,
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
        let review = GuardianDecision(
            verdict: .approve, risk: .low, userAuthorization: .high,
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

        #expect(preview.displayed == full)
        #expect(preview.full == full)
        #expect(!preview.isShortened)
        #expect(preview.omittedCharacters == 0)
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
            AgentToolPresentation.detail(
                for: restored, presenter: TermindAgentTools.presenter(for: restored.descriptor),
                locale: Locale(identifier: "en"))
                == AgentToolPresentation.detail(
                    for: legacy, presenter: TermindAgentTools.presenter(for: legacy.descriptor),
                    locale: Locale(identifier: "en"))
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
    func sshCommandSummaryUsesLocaleAppropriatePunctuationAcrossCommandPhases() {
        let command = "printf hello\nworld"
        let current = AgentToolDescriptor.Presentation(
            symbol: "terminal",
            activity: .semanticArgument(key: "command", fallback: .sshCommand),
            output: .streams, actionKind: .run,
            phaseKinds: [
                "proposed": .sshPreparingCommand,
                "waitingForApproval": .sshWaitingForCommand,
                "running": .sshConnecting,
                "command": .sshRunningCommand,
                "completed": .sshCompletedCommand,
                "denied": .sshDeniedCommand,
                "failed": .sshFailedCommand,
                "interrupted": .sshInterruptedCommand,
            ]
        )
        let legacy = AgentToolDescriptor.Presentation(
            symbol: "terminal",
            activity: .argument(key: "command", fallback: "the SSH command"),
            output: .streams, actionKind: .run
        )
        let states: [(AgentToolCard.State, String?)] = [
            (.proposed, nil), (.reviewing, nil), (.waitingForApproval, nil),
            (.running, "command"), (.completed, nil), (.denied, nil),
            (.failed, nil), (.interrupted, nil),
        ]
        let locales: [(String, String?, String?)] = [
            ("en", nil, nil),
            ("zh-Hans", "“", "”"),
            ("zh-Hant", "「", "」"),
        ]

        for presentation in [current, legacy] {
            for (identifier, openingQuote, closingQuote) in locales {
                for hostName in [String?.none, "Production"] {
                    for (state, phase) in states {
                        var card = makeCard(
                            name: "ssh_exec", target: .host,
                            arguments: ["command": .string(command)],
                            presentation: presentation
                        )
                        card.state = state
                        if let phase {
                            card.result = AgentToolResult(
                                callID: "call", content: "",
                                metadata: ["presentation_phase": .string(phase)]
                            )
                        }

                        let title = AgentToolPresentation.summary(
                            for: card, hostName: hostName,
                            locale: Locale(identifier: identifier)
                        )
                        let normalizedCommand = "printf hello world"
                        #expect(title.contains(normalizedCommand))
                        #expect(!title.contains("\n"))
                        if let openingQuote, let closingQuote {
                            #expect(title.contains("\(openingQuote)\(normalizedCommand)\(closingQuote)"))
                        } else {
                            #expect(!title.contains("“\(normalizedCommand)”"))
                            #expect(!title.contains("「\(normalizedCommand)」"))
                        }
                    }
                }
            }
        }

        var example = makeCard(
            name: "ssh_exec", target: .host,
            arguments: ["command": .string(command)], presentation: current
        )
        example.state = .running
        example.result = AgentToolResult(
            callID: "call", content: "",
            metadata: ["presentation_phase": .string("command")]
        )
        #expect(
            AgentToolPresentation.summary(
                for: example, hostName: "Production", locale: Locale(identifier: "en")
            ) == "Running printf hello world on Production"
        )
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

    @Test
    func batchesDescribeTheObjectsOfEachActionForCurrentAndHistoricalTools() {
        let cases:
            [(
                String, AgentToolDescriptor.Presentation.ActivityKind,
                AgentToolDescriptor.Presentation.ActionKind, String
            )] = [
                ("ssh_exec", .sshCommand, .run, "Ran 2 commands"),
                ("terminal_suggest", .command, .suggest, "Provided 2 suggestions"),
                ("scratch_push", .remoteFile, .push, "Pushed 2 files"),
                ("scratch_pull", .remoteFile, .pull, "Pulled 2 files"),
                ("sftp_read", .remoteFile, .read, "Read 2 files"),
                ("sftp_write", .remoteFile, .write, "Wrote 2 files"),
                ("sftp_copy", .remoteFile, .copy, "Copied 2 files"),
                ("sftp_move", .remoteFile, .move, "Moved 2 files"),
                ("sftp_delete", .remoteFile, .delete, "Deleted 2 files"),
                ("sftp_stat", .remoteFile, .inspect, "Inspected 2 files"),
                ("sftp_chmod", .remoteFile, .changePermissions, "Changed permissions for 2 files"),
                // Persisted semantic descriptors used remoteFile for directories.
                ("sftp_list", .remoteFile, .list, "Listed 2 directories"),
                ("sftp_mkdir", .remoteFile, .create, "Created 2 directories"),
                ("scratch_read", .scratchFile, .read, "Read 2 scratch files"),
                ("scratch_write", .scratchFile, .write, "Wrote 2 scratch files"),
                ("scratch_edit", .scratchFile, .edit, "Edited 2 scratch files"),
                ("scratch_copy", .scratchEntry, .copy, "Copied 2 scratch items"),
                ("scratch_move", .scratchEntry, .move, "Moved 2 scratch items"),
                ("scratch_delete", .scratchEntry, .delete, "Deleted 2 scratch items"),
                ("scratch_diff", .scratchFiles, .compare, "Compared scratch files (2 times)"),
                ("scratch_list", .scratchWorkspace, .list, "Listed the scratch workspace (2 times)"),
                ("scratch_search", .scratchWorkspace, .search, "Searched the scratch workspace (2 times)"),
                ("fetch", .url, .fetch, "Fetched 2 URLs"),
                ("scratch_fetch", .url, .fetch, "Fetched 2 URLs"),
                ("web_search", .web, .search, "Searched the web (2 times)"),
                ("list_hosts", .hosts, .list, "Listed hosts (2 times)"),
                ("get_metrics", .metrics, .read, "Read host metrics (2 times)"),
                ("ssh_wait", .remoteCommand, .wait, "Waited for the remote command (2 times)"),
                ("present_plan", .plan, .present, "Presented 2 plans"),
                ("manage_tasks", .taskList, .update, "Updated the task list 2 times"),
                ("request_user_secret", .secret, .request, "Requested 2 secrets"),
            ]
        for (name, kind, action, expected) in cases {
            let current = AgentToolDescriptor.Presentation(
                symbol: "wrench", activity: .semanticArgument(key: "path", fallback: kind), actionKind: action)
            let legacy = AgentToolDescriptor.Presentation(
                symbol: "wrench", activity: .argument(key: "path", fallback: "legacy activity"))
            for presentation in [current, legacy, nil] {
                var card = makeCard(
                    name: name, target: name == "terminal_suggest" ? .user : .host, presentation: presentation)
                card.state = .completed
                #expect(
                    AgentToolPresentation.batchSummary(for: [card, card], locale: Locale(identifier: "en")) == expected,
                    "\(name): \(String(describing: presentation))")
                for language in ["zh-Hans", "zh-Hant"] {
                    let title = AgentToolPresentation.batchSummary(
                        for: [card, card], locale: Locale(identifier: language))
                    #expect(!title.contains("tool calls"))
                    #expect(!title.contains("工具调用"))
                    #expect(!title.contains("工具呼叫"))
                    #expect(!title.contains("legacy activity"))
                }
            }
        }
    }

    @Test
    func executionAndSuggestionUseDifferentVerbsInAllSupportedLanguages() {
        let english = Locale(identifier: "en")
        for activity: AgentToolDescriptor.Presentation.Activity in [
            .semanticArgument(key: "command", fallback: .sshCommand),
            .argument(key: "command", fallback: "the SSH command"),
        ] {
            var command = makeCard(
                name: "ssh_exec", target: .host, arguments: ["command": .string("pwd")],
                presentation: .init(symbol: "terminal", activity: activity, actionKind: .run))
            command.state = .completed
            #expect(AgentToolPresentation.batchSummary(for: [command], locale: english) == "Ran a command")
            #expect(AgentToolPresentation.summary(for: command, locale: english) == "Ran pwd")
        }
        let legacy = AgentToolDescriptor.Presentation(
            symbol: "terminal", activity: .semanticArgument(key: "command", fallback: .command), actionKind: .suggest)
        for presentation in [TerminalSuggestTool().descriptor.presentation, legacy, nil] {
            var suggestion = makeCard(
                name: "terminal_suggest", target: .user, arguments: ["command": .string("pwd")],
                presentation: presentation)
            suggestion.state = .completed
            #expect(AgentToolPresentation.summary(for: suggestion, locale: english) == "Provided a suggestion")
            #expect(AgentToolPresentation.batchSummary(for: [suggestion], locale: english) == "Provided a suggestion")
            for (language, expected) in [("zh-Hans", "已提供2条建议"), ("zh-Hant", "已提供2條建議")] {
                #expect(
                    AgentToolPresentation.batchSummary(
                        for: [suggestion, suggestion], locale: Locale(identifier: language))
                        == expected)
            }
        }
    }

    @Test
    func fileBatchesPreserveEveryLifecycleStateAndMixedOutcomes() {
        var card = makeCard(
            name: "sftp_write", target: .host, presentation: SFTPWriteTool.presentation)
        let english = Locale(identifier: "en")
        let states: [(AgentToolCard.State, String)] = [
            (.proposed, "Preparing to write 2 files"), (.reviewing, "Preparing to write 2 files"),
            (.waitingForApproval, "Waiting to write 2 files"), (.waitingForUser, "Waiting to write 2 files"),
            (.running, "Writing 2 files"), (.completed, "Wrote 2 files"),
            (.denied, "Did not write 2 files"), (.failed, "Failed to write 2 files"),
            (.interrupted, "Interrupted while writing 2 files"),
        ]
        for (state, expected) in states {
            card.state = state
            #expect(AgentToolPresentation.batchSummary(for: [card, card], locale: english) == expected)
        }
        card.state = .completed
        var failed = card
        failed.state = .failed
        #expect(
            AgentToolPresentation.batchSummary(for: [card, card, failed], locale: english)
                == "Wrote 2 files, failed to write a file")
        for (language, expected) in [("zh-Hans", "已写入2个文件，写入文件失败"), ("zh-Hant", "已寫入2個檔案，寫入檔案失敗")] {
            #expect(
                AgentToolPresentation.batchSummary(for: [card, card, failed], locale: Locale(identifier: language))
                    == expected)
        }
    }

    @Test
    func batchesCountArrayElementsAndKeepUnknownToolObjects() {
        for activity: AgentToolDescriptor.Presentation.Activity in [
            .semanticArrayCount(key: "questions", unit: .question, fallback: .question),
            .arrayCount(key: "questions", singular: "a question", plural: "questions", fallback: "a question"),
        ] {
            var card = makeCard(
                name: "request_user_input", target: .user,
                arguments: ["questions": .array([.object([:]), .object([:])])],
                presentation: .init(symbol: "questionmark", activity: activity, actionKind: .ask))
            card.state = .completed
            #expect(
                AgentToolPresentation.batchSummary(for: [card, card], locale: Locale(identifier: "en"))
                    == "Asked 4 questions")
        }
        var custom = makeCard(
            name: "scratch_push", target: .mcp,
            presentation: .init(symbol: "wrench", activity: .label("artifacts"), actionKind: .push))
        custom.state = .completed
        #expect(
            AgentToolPresentation.batchSummary(for: [custom, custom], locale: Locale(identifier: "en"))
                == "Pushed artifacts (2 times)")
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
                target: target, approvalPolicy: .approve, presentation: presentation
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
@Suite
@MainActor
struct AgentKnowledgeSearchPresentationTests {
    private let store = PresentationMemoryAccess()

    @Test func memoryToolUsesMemoryInSummariesApprovalsAndBatches() {
        let descriptor = MemoryTool(store: store).descriptor
        let arguments: [String: AgentJSONValue] = [
            "operations": .array([
                .object(["action": .string("add"), "target": .string("memory"), "content": .string("Remember")])
            ])
        ]
        var memory = card(descriptor, arguments: arguments)
        memory.state = .completed
        #expect(AgentToolPresentation.summary(for: memory, locale: Locale(identifier: "en")) == "Updated memory")
        #expect(
            AgentToolPresentation.batchSummary(for: [memory, memory], locale: Locale(identifier: "en"))
                == "Updated memory (2 times)")
        #expect(AgentToolPresentation.summary(for: memory, locale: Locale(identifier: "zh-Hans")) == "已更新记忆")
        #expect(AgentToolPresentation.summary(for: memory, locale: Locale(identifier: "zh-Hant")) == "已更新記憶")

        let request = AgentApprovalRequest(
            invocation: memory.invocation, descriptor: descriptor, userIntent: "Remember")
        #expect(
            AgentToolPresentation.approval(for: request, locale: Locale(identifier: "en")).title
                == "Update memory")
        #expect(
            AgentToolPresentation.approval(for: request, locale: Locale(identifier: "zh-Hans")).title
                == "更新记忆")

        var fallback = card(
            .init(
                name: "other_memory_tool", summary: "Other memory tool", inputSchema: .object([:]),
                target: .local, approvalPolicy: .approve,
                presentation: .init(symbol: "brain", activity: .semanticLabel(.memory), actionKind: .read)))
        fallback.state = .completed
        #expect(AgentToolPresentation.summary(for: fallback, locale: Locale(identifier: "en")) == "Read memory")
    }

    @Test func searchedQueryAndScopeAppearInSingleToolBatchHeaders() {
        let memory = MemorySearchTool(store: store).descriptor
        let chats = SessionSearchTool(store: store).descriptor
        let cases: [(AgentToolDescriptor, [String: AgentJSONValue], String, String, String)] = [
            (memory, ["query": .string("deploy backup")], "memory", "记忆", "記憶"),
            (chats, ["query": .string("deploy backup")], "chats", "聊天", "聊天"),
            (
                memory, ["query": .string("deploy backup"), "target": .string("user")],
                "user profile", "用户资料", "使用者資料"
            ),
        ]
        for (descriptor, arguments, englishScope, simplifiedScope, traditionalScope) in cases {
            var card = card(descriptor, arguments: arguments)
            card.state = .running
            #expect(
                AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "en"))
                    == "Searching deploy backup in \(englishScope)")
            #expect(
                AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "zh-Hans"))
                    == "正在\(simplifiedScope)中搜索“deploy backup”")
            #expect(
                AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "zh-Hant"))
                    == "正在\(traditionalScope)中搜尋“deploy backup”")

            card.state = .completed
            #expect(
                AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "en"))
                    == "Searched deploy backup in \(englishScope)")
            #expect(
                AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "zh-Hans"))
                    == "已在\(simplifiedScope)中搜索“deploy backup”")
            #expect(
                AgentToolPresentation.batchSummary(for: [card], locale: Locale(identifier: "zh-Hant"))
                    == "已在\(traditionalScope)中搜尋“deploy backup”")
        }

        var failed = card(memory, arguments: ["query": .string("deploy backup")])
        failed.state = .failed
        #expect(
            AgentToolPresentation.batchSummary(for: [failed], locale: Locale(identifier: "en"))
                == "Failed to search deploy backup")
    }

    @Test func longQueriesKeepTheScopeSuffixAndQuerylessChatsStillBrowse() {
        let longQuery = String(repeating: "deployment ", count: 20)
        for (descriptor, suffix) in [
            (MemorySearchTool(store: store).descriptor, " in memory"),
            (SessionSearchTool(store: store).descriptor, " in chats"),
        ] {
            var search = card(descriptor, arguments: ["query": .string(longQuery)])
            search.state = .completed
            let summary = AgentToolPresentation.batchSummary(for: [search], locale: Locale(identifier: "en"))
            #expect(summary.count <= 80)
            #expect(summary.contains("…"))
            #expect(summary.hasSuffix(suffix))
        }

        var browse = card(SessionSearchTool(store: store).descriptor)
        browse.state = .completed
        #expect(
            AgentToolPresentation.batchSummary(for: [browse], locale: Locale(identifier: "en"))
                == "Listed saved conversations")
    }

    private func card(
        _ descriptor: AgentToolDescriptor, arguments: [String: AgentJSONValue] = [:]
    ) -> AgentToolCard {
        AgentToolCard(
            invocation: .init(
                runID: UUID(), call: .init(id: "search", name: descriptor.name, arguments: .object(arguments))),
            descriptor: descriptor)
    }
}

private struct PresentationMemoryAccess: AgentMemoryAccessing {
    func memoryState() async throws -> AgentMemoryState { .init() }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState { .init() }
    func searchSessions(_ request: AgentSessionSearchRequest) async throws -> AgentJSONValue { .array([]) }
}
