import Foundation
import Testing

@testable import Termind

@Suite
struct AgentToolPresentationTests {
    @Test
    func summariesFollowStateAndNameTheHost() {
        var card = makeCard(
            name: "ssh_exec", target: .host,
            arguments: ["command": .string("ls -la")],
            presentation: .init(
                symbol: "terminal",
                activity: .argument(key: "command", fallback: "the SSH command"),
                output: .streams,
                messages: [
                    "proposed": "Preparing to run “{activity}” on {target}",
                    "running": "Connecting to {target}",
                    "command": "Running “{activity}” on {target}",
                    "completed": "Ran “{activity}” on {target}",
                ]
            )
        )
        card.state = .running
        #expect(
            AgentToolPresentation.summary(for: card, hostName: "production")
                == "Connecting to production"
        )

        card.result = AgentToolResult(
            callID: "call", content: "",
            metadata: ["presentation_phase": .string("command")]
        )
        #expect(
            AgentToolPresentation.summary(for: card, hostName: "production")
                == "Running “ls -la” on production"
        )

        card.state = .reviewing
        #expect(
            AgentToolPresentation.summary(for: card, hostName: "production")
                == "Preparing to run “ls -la” on production"
        )

        card.state = .completed
        #expect(
            AgentToolPresentation.summary(for: card, hostName: "production")
                == "Ran “ls -la” on production"
        )
        #expect(
            AgentToolPresentation.batchSummary(for: [card, card])
                == "Ran 2 tool calls"
        )
        for state in [
            AgentToolCard.State.denied, .failed, .interrupted,
        ] {
            card.state = state
            let summary = AgentToolPresentation.batchSummary(for: [card, card])
            #expect(!summary.contains("“"))
            #expect(!summary.contains("”"))
            #expect(!summary.contains("\""))
        }
    }

    @Test
    func mcpSummaryUsesOriginalToolAndServerNames() {
        var card = makeCard(
            name: "mcp__12345678__find_records", target: .mcp,
            presentation: .init(
                symbol: "puzzlepiece.extension", activity: .label("find-records"), output: .json,
                action: .init(infinitive: "run", progressive: "Running", past: "Ran")
            )
        )
        card.state = .failed
        card.result = AgentToolResult(
            callID: "call", content: "failed", isError: true,
            metadata: ["mcp_tool": .string("find-records")]
        )

        #expect(
            AgentToolPresentation.summary(for: card)
                == "Failed to run find-records"
        )
        #expect(AgentToolPresentation.symbol(for: card) == "puzzlepiece.extension")
    }

    @Test
    func toolOwnedActionsProduceNaturalStateGrammar() {
        var sftp = makeCard(
            name: "sftp_read", target: .host,
            arguments: ["path": .string("/etc/nginx.conf")],
            presentation: .init(
                symbol: "doc.text", activity: .argument(key: "path", fallback: "a remote file"),
                action: .init(infinitive: "read", progressive: "Reading", past: "Read"),
                includesTarget: true
            )
        )
        sftp.state = .running
        #expect(
            AgentToolPresentation.summary(for: sftp, hostName: "production")
                == "Reading /etc/nginx.conf on production"
        )
        #expect(
            AgentToolPresentation.summary(for: sftp)
                == "Reading /etc/nginx.conf"
        )

        var scratch = makeCard(
            name: "scratch_edit", target: .local,
            arguments: ["path": .string("notes/config")],
            presentation: .init(
                symbol: "pencil", activity: .argument(key: "path", fallback: "a scratch file"),
                action: .init(infinitive: "edit", progressive: "Editing", past: "Edited")
            )
        )
        scratch.state = .running
        #expect(AgentToolPresentation.summary(for: scratch) == "Editing notes/config")

        var fetch = makeCard(
            name: "fetch", target: .network,
            arguments: ["url": .string("https://example.com")],
            presentation: .init(
                symbol: "globe", activity: .argument(key: "url", fallback: "a URL"),
                action: .init(infinitive: "fetch", progressive: "Fetching", past: "Fetched")
            )
        )
        fetch.state = .running
        #expect(AgentToolPresentation.summary(for: fetch) == "Fetching https://example.com")

        var mcp = makeCard(
            name: "mcp__airtable__find_records", target: .mcp,
            presentation: .init(
                symbol: "puzzlepiece.extension", activity: .label("find-records"),
                action: .init(infinitive: "run", progressive: "Running", past: "Ran")
            )
        )
        mcp.state = .running
        #expect(
            AgentToolPresentation.summary(for: mcp)
                == "Running find-records"
        )
    }

    @Test
    func semanticActionsLocalizeEveryLifecycleWithoutChangingArguments() {
        let zh = Locale(identifier: "zh-Hans")
        let actions: [(AgentToolDescriptor.Presentation.ActionKind, String)] = [
            (.ask, "询问"), (.compare, "比较"), (.create, "创建"), (.delete, "删除"),
            (.edit, "编辑"), (.fetch, "获取"), (.inspect, "检查"), (.list, "列出"),
            (.move, "移动"), (.present, "提交"), (.pull, "拉取"), (.push, "推送"),
            (.read, "读取"), (.request, "请求"), (.run, "运行"), (.search, "搜索"),
            (.suggest, "生成建议"), (.update, "更新"), (.wait, "等待"), (.write, "写入"),
            (.changePermissions, "更改权限"), (.use, "使用"),
        ]

        for (kind, verb) in actions {
            var card = makeCard(
                name: "semantic_\(kind.rawValue)", target: .local,
                arguments: ["value": .string("Target 42")],
                presentation: .init(
                    symbol: "wrench", activity: .semanticArgument(key: "value", fallback: .command),
                    actionKind: kind
                )
            )
            let expected: [(AgentToolCard.State, String)] = [
                (.proposed, "正在准备\(verb)“Target 42”"),
                (.waitingForApproval, "等待\(verb)“Target 42”"),
                (.running, "正在\(verb)“Target 42”"),
                (.completed, "已\(verb)“Target 42”"),
                (.denied, "未\(verb)“Target 42”"),
                (.failed, "\(verb)“Target 42”失败"),
                (.interrupted, "\(verb)“Target 42”已中断"),
            ]
            for (state, title) in expected {
                card.state = state
                #expect(AgentToolPresentation.summary(for: card, locale: zh) == title)
            }
        }
    }

    @Test
    func localizedSearchBatchSSHAndMCPKeepUserAndRemoteTextVerbatim() {
        let zh = Locale(identifier: "zh-Hans")
        var search = makeCard(
            name: "web_search", target: .network,
            arguments: ["query": .string("Swift 6 concurrency")],
            presentation: .init(
                symbol: "magnifyingglass",
                activity: .semanticArgument(key: "query", fallback: .web),
                actionKind: .search
            )
        )
        search.state = .completed
        #expect(
            AgentToolPresentation.summary(for: search, locale: zh)
                == "已搜索“Swift 6 concurrency”"
        )

        var fetch = makeCard(
            name: "fetch", target: .network,
            presentation: .init(
                symbol: "globe", activity: .semanticArgument(key: "url", fallback: .url),
                actionKind: .fetch
            )
        )
        fetch.state = .failed
        #expect(
            AgentToolPresentation.batchSummary(for: [search, fetch], locale: zh)
                == "已搜索“Swift 6 concurrency”，获取URL失败"
        )

        var ssh = makeCard(
            name: "ssh_exec", target: .host,
            arguments: ["command": .string("printf 'hello world'")],
            presentation: AgentBuiltInTools.terminalSuggest().descriptor.presentation
        )
        ssh.state = .completed
        #expect(
            AgentToolPresentation.summary(for: ssh, hostName: "production-1", locale: zh)
                == "已在production-1上运行“printf 'hello world'”"
        )

        var mcp = makeCard(
            name: "mcp__airtable__find_records", target: .mcp,
            presentation: .init(
                symbol: "puzzlepiece.extension", activity: .label("airtable.find_records"),
                actionKind: .run
            )
        )
        mcp.state = .running
        #expect(
            AgentToolPresentation.summary(for: mcp, locale: zh)
                == "正在运行airtable.find_records"
        )
        mcp.state = .failed
        #expect(
            AgentToolPresentation.batchSummary(for: [mcp, mcp], locale: zh)
                == "2次运行失败"
        )
        mcp.state = .interrupted
        #expect(
            AgentToolPresentation.batchSummary(for: [mcp, mcp], locale: zh)
                == "2次运行已中断"
        )
    }

    @Test
    func appOwnedActivitiesAreUnquotedAndLegacySearchUsesItsQuery() {
        let zh = Locale(identifier: "zh-Hans")

        var hosts = makeCard(name: "list_hosts", target: .host)
        hosts.state = .completed
        #expect(AgentToolPresentation.summary(for: hosts, locale: zh) == "已列出主机")

        var restoredSearch = makeCard(
            name: "web_search", target: .network,
            arguments: ["query": .string("Swift concurrency")]
        )
        restoredSearch.state = .completed
        #expect(
            AgentToolPresentation.summary(for: restoredSearch, locale: zh)
                == "已搜索“Swift concurrency”"
        )

        var restoredSearchWithoutQuery = makeCard(name: "web_search", target: .network)
        restoredSearchWithoutQuery.state = .completed
        #expect(
            AgentToolPresentation.summary(for: restoredSearchWithoutQuery, locale: zh)
                == "已搜索"
        )
        #expect(
            AgentToolPresentation.batchSummary(for: [restoredSearchWithoutQuery], locale: zh)
                == "已搜索"
        )
        #expect(
            AgentToolPresentation.batchSummary(
                for: [restoredSearchWithoutQuery, restoredSearchWithoutQuery], locale: zh
            ) == "已搜索2次"
        )
    }

    @Test
    func userInputSummaryCountsQuestionsAndUsesAskGrammar() {
        let descriptor = AgentBuiltInTools.requestUserInput().descriptor
        #expect(descriptor.presentation?.symbol == "questionmark.circle")

        for count in 1...3 {
            let arguments: [String: AgentJSONValue] = [
                "questions": .array(
                    (0..<count).map { index in
                        .object([
                            "id": .string("q\(index)"), "prompt": .string("Question?")
                        ])
                    })
            ]
            var card = makeCard(
                name: "request_user_input", target: .user, arguments: arguments,
                presentation: descriptor.presentation
            )
            let activity = count == 1 ? "a question" : "\(count) questions"

            card.state = .running
            #expect(AgentToolPresentation.summary(for: card) == "Asking \(activity)")
            card.state = .completed
            #expect(AgentToolPresentation.summary(for: card) == "Asked \(activity)")
        }

        var lifecycle = makeCard(
            name: "request_user_input", target: .user,
            arguments: ["questions": .array([.object([:])])],
            presentation: descriptor.presentation
        )
        #expect(AgentToolPresentation.summary(for: lifecycle) == "Preparing to ask a question")
        lifecycle.state = .failed
        #expect(AgentToolPresentation.summary(for: lifecycle) == "Failed to ask a question")
        lifecycle.state = .interrupted
        #expect(
            AgentToolPresentation.summary(for: lifecycle)
                == "Interrupted while asking a question"
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
                    "id": .string("region"), "prompt": .string("Which region?")
                ]),
            ])
        ]
        var card = makeCard(
            name: "request_user_input", target: .user, arguments: arguments,
            presentation: AgentBuiltInTools.requestUserInput().descriptor.presentation
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
                detailPresenterID: "remote.fetch"
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
                output: .json, detailPresenterID: "builtin.scratch_fetch",
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
                output: .json, detailPresenterID: "builtin.scratch_search",
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
    func finishedBatchSummaryCountsRepeatedActivitiesAndPreservesFailures() {
        let questionPresentation = AgentBuiltInTools.requestUserInput().descriptor.presentation
        var firstQuestion = makeCard(
            name: "request_user_input", target: .user,
            arguments: ["questions": .array([.object([:])])],
            presentation: questionPresentation
        )
        var secondQuestion = firstQuestion
        let commandPresentation = AgentToolDescriptor.Presentation(
            symbol: "terminal", activity: .argument(key: "command", fallback: "a command"),
            action: .init(infinitive: "run", progressive: "Running", past: "Ran")
        )
        var command = makeCard(
            name: "ssh_exec", target: .host,
            arguments: ["command": .string("uptime")],
            presentation: commandPresentation
        )
        firstQuestion.state = .completed
        secondQuestion.state = .completed
        command.state = .completed

        #expect(
            AgentToolPresentation.batchSummary(for: [firstQuestion, secondQuestion, command])
                == "Asked 2 questions, ran a command"
        )

        command.state = .failed
        #expect(
            AgentToolPresentation.batchSummary(for: [firstQuestion, secondQuestion, command])
                == "Asked 2 questions, failed to run a command"
        )
    }

    @Test
    func batchIconFollowsLiveAndHomogeneousTools() {
        let terminal = AgentToolDescriptor.Presentation(
            symbol: "terminal", activity: .label("a command"),
            action: .init(infinitive: "run", progressive: "Running", past: "Ran")
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
            presentation: AgentBuiltInTools.requestUserInput().descriptor.presentation
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
    func reasoningBatchSamplingIsStableAtThirtyPercent() throws {
        let included = try #require(UUID(
            uuidString: "00000000-0000-4000-8000-000000000001"
        ))
        let excluded = try #require(UUID(
            uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff"
        ))

        #expect(AgentToolPresentation.showsReasoning(forBatchID: included))
        #expect(AgentToolPresentation.showsReasoning(forBatchID: included))
        #expect(!AgentToolPresentation.showsReasoning(forBatchID: excluded))
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
    func interruptedResultsAreExplicitlyMarked() {
        let result = AgentToolResult(
            callID: "call", content: "stopped", isError: true,
            metadata: ["interrupted": .bool(true)]
        )
        #expect(result.isInterrupted)
    }

    @Test
    func presentationRoundTripsThroughExistingResultMetadata() {
        let presentation = AgentToolDescriptor.Presentation(
            symbol: "terminal",
            activity: .argument(key: "command", fallback: "the SSH command"),
            output: .streams,
            detailPresenterID: "builtin.ssh_exec",
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
        let ids = AgentBuiltInToolDetailPresenters.ids
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("builtin.") })
        for id in ids {
            #expect(AgentBuiltInToolDetailPresenters.presenter(id: id) != nil)
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
        let livePresentation = AgentBuiltInTools.webSearchDetailPresenter.id
        var persisted = AgentToolResult(callID: "call", content: payload.encodedString)
        persisted.toolPresentation = .init(
            symbol: "magnifyingglass",
            activity: .semanticArgument(key: "query", fallback: .web), output: .json,
            detailPresenterID: livePresentation, actionKind: .search
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
            output: .json, detailPresenterID: "builtin.web_search",
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
        object["detailPresenterID"] = nil
        let decoded = try JSONDecoder().decode(
            AgentToolDescriptor.Presentation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.groupsWithAdjacentTools)
        #expect(decoded.actionKind == nil)
        #expect(decoded.phaseKinds.isEmpty)
        #expect(decoded.detailPresenterID == nil)
    }

    @Test
    func legacyCountedArrayActivityStillDecodesAndLocalizesKnownQuestions() throws {
        let activity = AgentToolDescriptor.Presentation.Activity.arrayCount(
            key: "questions", singular: "a question", plural: "questions",
            fallback: "a question"
        )
        let data = try JSONEncoder().encode(activity)
        #expect(try JSONDecoder().decode(type(of: activity), from: data) == activity)

        var card = makeCard(
            name: "request_user_input", target: .user,
            arguments: ["questions": .array([.object([:]), .object([:])])],
            presentation: .init(
                symbol: "questionmark.circle", activity: activity,
                action: .init(infinitive: "ask", progressive: "Asking", past: "Asked")
            )
        )
        card.state = .completed
        #expect(
            AgentToolPresentation.summary(
                for: card, locale: Locale(identifier: "zh-Hans")
            ) == "已询问2个问题"
        )
    }

    @Test
    func builtInToolsKeepDistinctStableIcons() {
        #expect(
            AgentToolPresentation.symbol(
                for: makeCard(
                    name: "ssh_exec", target: .host,
                    presentation: .init(symbol: "terminal", activity: .label("command"))
                )) == "terminal")
        #expect(
            AgentToolPresentation.symbol(for: makeCard(name: "unknown", target: .local)) == "wrench.and.screwdriver")
    }

    @Test
    func securityReviewKeepsTheToolIcon() {
        var card = makeCard(
            name: "ssh_exec", target: .host,
            presentation: .init(symbol: "terminal", activity: .label("command"))
        )
        card.state = .reviewing
        #expect(AgentToolPresentation.symbol(for: card) == "terminal")

        card.state = .running
        #expect(AgentToolPresentation.symbol(for: card) == "terminal")
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
