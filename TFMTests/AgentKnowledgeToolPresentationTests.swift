import AgentKit
import Foundation
import TermindApplication
import TermindPresentation
import Testing

@Suite struct AgentKnowledgeToolPresentationTests {
    private let english = Locale(identifier: "en")

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func oldMemoryMetadataIsRepairedInEveryState(_ language: String) {
        let locale = Locale(identifier: language)
        for state: AgentToolCard.State in [
            .proposed, .waitingForApproval, .waitingForUser, .reviewing, .running,
            .completed, .failed, .denied, .interrupted,
        ] {
            var value = card(
                "memory",
                arguments: [
                    "operations": .array([
                        .object([
                            "action": .string("add"), "target": .string("user"), "content": .string("private-body"),
                        ])
                    ])
                ])
            value.state = state
            let title = AgentToolPresentation.summary(for: value, locale: locale)
            #expect(!title.contains("skill"))
            #expect(!title.contains("技能"))
            #expect(!title.contains("private-body"))
            #expect(title.contains(language == "en" ? "memory" : language == "zh-Hans" ? "记忆" : "記憶"))
        }
        var value = card("memory", arguments: ["operations": .array([])])
        value.state = .completed
        if language == "en" {
            #expect(AgentToolPresentation.summary(for: value, locale: locale) == "Read persistent memory")
        }
    }

    @Test func eachKnowledgeModeHasTheCorrectActionAndTarget() {
        let cases: [(String, [String: AgentJSONValue], String)] = [
            ("skills_list", [:], "Listed skills"),
            ("skill_read_file", ["name": .string("guide")], "Read guide / SKILL.md"),
            ("skill_read_file", ["name": .string("guide"), "path": .string(".")], "Listed guide"),
            ("skill_install", ["name": .string("guide")], "Installed guide"),
            (
                "skill_manage",
                ["operations": .array([.object(["action": .string("delete"), "name": .string("guide")])])],
                "Updated guide"
            ),
            ("memory", ["operations": .array([.object(["action": .string("add")])])], "Updated persistent memory"),
            ("session_search", [:], "Listed saved conversations"),
            ("session_search", ["query": .string("deploy")], "Searched deploy"),
            ("session_search", ["conversation_id": .string("hidden-id")], "Read saved conversations"),
        ]
        for (name, args, expected) in cases {
            let value = card(name, arguments: args)
            #expect(AgentToolPresentation.summary(for: value, locale: english) == expected)
        }
    }

    @Test func mixedMemoryReadAndWriteBatchesKeepTheirActionsAndFailuresSeparate() {
        let read = card("memory", arguments: ["operations": .array([])])
        var write = card("memory", arguments: ["operations": .array([.object(["action": .string("add")])])])
        write.state = .failed
        let title = AgentToolPresentation.batchSummary(for: [read, read, write], locale: english)
        #expect(title.contains("Read persistent memory"))
        #expect(title.contains("2 tool calls"))
        #expect(title.contains("failed to update persistent memory"))
        #expect(!title.contains("skill"))
    }

    @Test func unknownPresenterOrRemoteIdentityCannotSelectKnowledgePolicy() {
        var value = card("memory")
        value.descriptor.presentation?.presenterID = "remote.memory"
        #expect(!AgentToolPresentation.usesCompactDetails(for: value.descriptor))
        value.descriptor.presentation?.presenterID = "builtin.memory"
        value.descriptor.target = .mcp
        #expect(!AgentToolPresentation.usesCompactDetails(for: value.descriptor))
    }

    @Test func approvalKeepsBodyOutOfItsTitleAndProjectsTheCompleteArguments() {
        let body = String(repeating: "approval-only-content\n", count: 1_000)
        let value = card(
            "skill_manage",
            arguments: [
                "operations": .array([
                    .object([
                        "action": .string("create"), "name": .string("example"), "content": .string(body),
                    ])
                ])
            ])
        let request = AgentApprovalRequest(
            invocation: value.invocation, descriptor: value.descriptor, userIntent: "Create")
        let approval = AgentToolPresentation.approval(
            for: request, presenter: SkillManageTool.presenter, locale: english)
        #expect(approval.title == "Update skills")
        #expect(approval.detail.items.contains(.text(.init(title: "Content", text: body, style: .monospaced))))
    }

    @Test func failedKnowledgeResultsCannotDrawSuccessMessages() throws {
        var value = card("skill_install")
        value.state = .failed
        value.result = AgentToolResult(callID: "call", content: "{\"saved\":true}", isError: true)
        let detail = try #require(
            AgentToolPresentation.detail(for: value, presenter: SkillInstallTool.presenter, locale: english))
        #expect(
            !detail.items.contains {
                if case .message(_, .success) = $0 { return true }
                return false
            })
    }

    @Test func titleLimitsDoNotChangeOriginalArguments() {
        let query = "开始\n" + String(repeating: "🧭", count: 160)
        let value = card("session_search", arguments: ["query": .string(query)])
        let title = AgentToolPresentation.summary(for: value, locale: english)
        #expect(title.count <= 80)
        #expect(!title.contains("\n"))
        #expect(title.hasSuffix("…"))
        #expect(value.invocation.call.arguments.objectValue?["query"]?.stringValue == query)
    }

    @Test func wholeCardPreviewSharesItsBudgetAndPreservesFullCopy() {
        let text = String(repeating: "中🧭", count: 900)
        let detail = AgentToolDetail(
            items: (0..<32).map { .text(.init(title: "Block \($0)", text: text, style: .plain)) })
        let preview = AgentToolDetailPreview(detail)
        #expect(preview.isShortened)
        #expect(preview.fullItems == detail.items)
        let rendered = AgentToolDetailPreview(AgentToolDetail(items: preview.items)).fullText
        // Separators are formatting, not source text; all source strings share the 600-character budget.
        #expect(rendered.count <= 610)
        #expect(preview.fullText.contains("Block 31"))
        #expect(preview.fullText.hasSuffix(text))
    }

    @Test func listsShareFiveRowsAcrossSectionsAndShortDetailsRemainUnchanged() {
        let rows = (0..<4).map { AgentToolDetail.ListRow(title: "Skill \($0)") }
        let detail = AgentToolDetail(items: [
            .list(.init(title: "First", rows: rows)), .list(.init(title: "Second", rows: rows)),
        ])
        let preview = AgentToolDetailPreview(detail)
        let count = preview.items.reduce(0) { count, item in
            if case .list(let list) = item { return count + list.rows.count }
            return count
        }
        #expect(count == 5)
        #expect(preview.isShortened)
        let short = AgentToolDetail(items: [.list(.init(rows: [.init(title: "One")], emptyMessage: "None"))])
        #expect(!AgentToolDetailPreview(short).isShortened)
    }

    @Test @MainActor func detailExpansionIsIndependentAndSurvivesReconfiguration() {
        let state = AssistantTranscriptPresentationState()
        let id = UUID()
        state.toggleDisclosure(.toolDetail(id))
        let revision = state.layoutRevision(for: [id])
        state.followDefault(false, for: .tool(id))
        state.prune(validTimelineIDs: [id])
        #expect(state.isExpanded(.toolDetail(id)))
        #expect(!state.isExpanded(.tool(id)))
        #expect(state.layoutRevision(for: [id]) >= revision)
        state.prune(validTimelineIDs: [])
        #expect(!state.isExpanded(.toolDetail(id)))
    }

    private func card(_ name: String, arguments: [String: AgentJSONValue] = [:]) -> AgentToolCard {
        AgentToolCard(
            invocation: .init(runID: UUID(), call: .init(id: "call", name: name, arguments: .object(arguments))),
            descriptor: .init(
                name: name, summary: name, inputSchema: .object([:]), target: .local,
                approvalPolicy: .ask,
                presentation: .init(
                    symbol: "brain", activity: .semanticArgument(key: "target", fallback: .skill),
                    presenterID: "builtin.\(name)", actionKind: .write)), state: .completed)
    }
}
