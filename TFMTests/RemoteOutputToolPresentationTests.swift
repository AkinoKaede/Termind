import AgentKit
import AppKit
import Foundation
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite @MainActor
struct RemoteOutputToolPresentationTests {
    @Test(arguments: ["ssh_exec_run", "ssh_exec_output", "sftp_read"], [380.0, 720.0])
    func longOutputExpandsCompletelyWithoutCopyControls(_ name: String, _ width: Double) throws {
        let output = (0..<180).map { "line \($0): " + String(repeating: "output ", count: 8) }.joined(separator: "\n")
        let value = card(name, output: output)
        let presenter = try #require(TermindAgentTools.presenter(for: value.descriptor))
        for language in [AppLanguage.english, .simplifiedChinese] {
            let detail = try #require(
                AgentToolPresentation.detail(for: value, presenter: presenter, locale: language.locale))
            let preview = AgentToolDetailPreview(detail)
            #expect(preview.isShortened)
            #expect(preview.fullText.contains(output))
            #expect(preview.fullItems == detail.items)
            if name != "sftp_read" {
                #expect(preview.fullText.contains("stderr-last-line"))
            }

            let state = TranscriptPresentationState()
            state.disclosures.followDefault(true, for: .tool(value.id))
            let row = TranscriptNativeRow.make(for: .tool)
            func configure() {
                row.configure(
                    entry: .init(id: value.id, content: .tool(value)), proposedWidth: width,
                    configuration: .init(
                        isCompact: true, showsTerminalActions: false, isConversationStreaming: false,
                        locale: language.locale, reduceMotion: true, colorScheme: .light),
                    actions: .init(), presentation: state, markdownCache: TranscriptMarkdownCache(limit: 4),
                    measurement: false, invalidate: { _, _ in })
            }
            func button(_ identifier: String) throws -> NSButton {
                try #require(
                    descendants(row).first { $0.identifier?.rawValue == identifier } as? NSButton)
            }
            func expectOnlyExpansionControl() throws {
                let body = try #require(
                    descendants(row).first { $0.identifier?.rawValue == "AssistantTool.CompactDetails" })
                let buttons = descendants(body).compactMap { $0 as? NSButton }
                #expect(buttons.map { $0.identifier?.rawValue } == ["AssistantTool.More"])
            }
            configure()
            let compactHeight = row.measuredHeight(for: width)
            #expect(!descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue == output })
            try expectOnlyExpansionControl()
            try button("AssistantTool.More").performClick(nil)
            configure()
            #expect(state.disclosures.isExpanded(.toolDetail(value.id)))
            #expect(row.measuredHeight(for: width) > compactHeight)
            #expect(descendants(row).compactMap { $0 as? NSTextField }.contains { $0.stringValue == output })
            try expectOnlyExpansionControl()
            try button("AssistantTool.More").performClick(nil)
            configure()
            #expect(!state.disclosures.isExpanded(.toolDetail(value.id)))
            #expect(abs(row.measuredHeight(for: width) - compactHeight) < 0.5)
        }
    }

    @Test
    func displayFoldingNeverCreatesAMarkerAndActualMarkersAreReusedVerbatim() throws {
        var value = card("ssh_exec_output", output: String(repeating: "line\n", count: 100))
        let presenter = try #require(TermindAgentTools.presenter(for: value.descriptor))
        let detail = try #require(
            AgentToolPresentation.detail(for: value, presenter: presenter, locale: Locale(identifier: "zh-Hans")))
        #expect(AgentToolDetailPreview(detail).isShortened)
        #expect(AgentToolPresentation.truncationNotice(for: value) == nil)
        value.result?.isTruncated = true
        #expect(AgentToolPresentation.truncationNotice(for: value) == nil)
        let marker = AgentTruncateMarker.render(
            ranges: [10...20], totalLines: 20,
            capture: .init(path: "chat/outputs/ssh-exec-output-test.txt", bytes: 100, lines: 20))
        value.result?.truncateMarker = marker
        #expect(AgentToolPresentation.truncationNotice(for: value) == marker)
    }

    private func card(_ name: String, output: String) -> AgentToolCard {
        let result: AgentJSONValue =
            name == "sftp_read"
            ? .object(["path": .string("/tmp/output.log"), "content": .string(output)])
            : .object([
                "handle": .string(UUID().uuidString), "status": .string("exited"), "exit_code": .number(0),
                "stdout": .string(output), "stderr": .string("stderr-last-line"), "stdin_closed": .bool(true),
            ])
        return AgentToolCard(
            invocation: .init(
                runID: UUID(),
                call: .init(
                    id: "call", name: name,
                    arguments: .object(
                        name == "ssh_exec_run" ? ["command": .string("cat /tmp/output.log")] : [:]))),
            descriptor: .init(
                name: name, summary: name, inputSchema: .object([:]), target: .host, approvalPolicy: .ask,
                presentation: .init(
                    symbol: "terminal", activity: .semanticLabel(.commandOutput), presenterID: "builtin.\(name)",
                    actionKind: .read)),
            state: .completed,
            result: .init(callID: "call", content: result.encodedString))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
