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
            messages: ["running": "Connecting to {target}"]
        )
        var result = AgentToolResult(callID: "call", content: "done")
        result.toolPresentation = presentation

        #expect(result.toolPresentation == presentation)
        #expect(result.metadata[AgentToolResult.toolPresentationKey] != nil)
    }

    @Test
    func builtInToolsKeepDistinctStableIcons() {
        #expect(AgentToolPresentation.symbol(for: makeCard(
            name: "ssh_exec", target: .host,
            presentation: .init(symbol: "terminal", activity: .label("command"))
        )) == "terminal")
        #expect(AgentToolPresentation.symbol(for: makeCard(name: "unknown", target: .local)) == "wrench.and.screwdriver")
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
}
