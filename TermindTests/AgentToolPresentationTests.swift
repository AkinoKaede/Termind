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
                == "Ran 2 SSH commands"
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
    func countedArrayActivityRoundTrips() throws {
        let activity = AgentToolDescriptor.Presentation.Activity.arrayCount(
            key: "questions", singular: "a question", plural: "questions",
            fallback: "a question"
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
            groupsWithAdjacentTools: false,
            messages: ["running": "Connecting to {target}"]
        )
        var result = AgentToolResult(callID: "call", content: "done")
        result.toolPresentation = presentation

        #expect(result.toolPresentation == presentation)
        #expect(result.metadata[AgentToolResult.toolPresentationKey] != nil)
    }

    @Test
    func olderPresentationMetadataDefaultsToParticipatingInBatches() throws {
        let presentation = AgentToolDescriptor.Presentation(
            symbol: "terminal", activity: .label("a command")
        )
        let encoded = try JSONEncoder().encode(presentation)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["groupsWithAdjacentTools"] = nil
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            AgentToolDescriptor.Presentation.self, from: legacy
        )
        #expect(decoded.groupsWithAdjacentTools)
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
}
