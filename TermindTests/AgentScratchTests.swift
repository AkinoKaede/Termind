import Foundation
import Testing

@testable import Termind

@Suite
struct AgentScratchTests {

    // MARK: - Containment

    @Test
    func aPathThatCouldLeaveTheWorkspaceIsRefused() async throws {
        let workspace = Fixture.workspace()
        for path in [
            "../escape", "a/../../b", "/etc/passwd", "~/secrets", "",
            "a/\u{0}b", "line\nbreak", String(repeating: "x", count: 300),
            (1...9).map(String.init).joined(separator: "/"),
        ] {
            await #expect(throws: (any Error).self, "\(path) was allowed") {
                try await workspace.write(path, data: Data("x".utf8))
            }
        }
        // `.` and redundant separators are normalized away rather than refused —
        // they name a path inside the workspace perfectly well.
        _ = try await workspace.write("./a//b.txt", data: Data("ok".utf8))
        #expect(try await workspace.read("a/b.txt").content == "ok")
    }

    /// Containment alone would already stop an escape. The stricter rule is what
    /// keeps an alias *inside* the workspace from making two paths the same file,
    /// which would quietly break both the quota arithmetic and the atomicity
    /// `apply(_:to:)` claims.
    @Test
    func aSymlinkPlantedByHandIsRefusedRatherThanFollowed() async throws {
        let base = Fixture.base()
        let id = UUID()
        let workspace = AgentScratchWorkspace(conversationID: id, base: base)
        _ = try await workspace.write("anchor.txt", data: Data("anchor".utf8))

        let outside = base.appending(path: "outside.txt")
        try Data("outside".utf8).write(to: outside)
        let scope = base.appending(path: id.uuidString)
        try FileManager.default.createSymbolicLink(
            at: scope.appending(path: "link.txt"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: scope.appending(path: "inside.txt"),
            withDestinationURL: scope.appending(path: "anchor.txt")
        )

        await #expect(throws: (any Error).self) { try await workspace.read("link.txt") }
        await #expect(throws: (any Error).self) { try await workspace.read("inside.txt") }
        // And it is not reported as content either, so nothing can act on it.
        let listed = try await workspace.list(nil, recursive: true).map(\.path)
        #expect(listed == ["anchor.txt"])
    }

    @Test
    func twoConversationsCannotSeeEachOther() async throws {
        let base = Fixture.base()
        let first = AgentScratchWorkspace(conversationID: UUID(), base: base)
        let second = AgentScratchWorkspace(conversationID: UUID(), base: base)

        _ = try await first.write("notes.md", data: Data("first".utf8))
        #expect(try await second.list(nil, recursive: true).isEmpty)
        await #expect(throws: (any Error).self) { try await second.read("notes.md") }

        // And deleting one scope leaves the other alone.
        _ = try await second.write("notes.md", data: Data("second".utf8))
        try await first.removeScope()
        #expect(try await second.read("notes.md").content == "second")
    }

    // MARK: - Quota

    @Test
    func aWritePastTheEntryLimitFailsAndChangesNothing() async throws {
        let workspace = Fixture.workspace()
        for index in 0..<AgentScratchWorkspace.Limits.entries {
            _ = try await workspace.write("f\(index).txt", data: Data("x".utf8))
        }
        let before = try await workspace.usage()
        await #expect(throws: (any Error).self) {
            try await workspace.write("one-too-many.txt", data: Data("x".utf8))
        }
        #expect(try await workspace.usage() == before)
        #expect(before.entries == AgentScratchWorkspace.Limits.entries)

        // Overwriting an existing file adds no entry, so it is still allowed at the
        // ceiling — otherwise a full workspace could not even be corrected.
        _ = try await workspace.write("f0.txt", data: Data("replaced".utf8))
        #expect(try await workspace.read("f0.txt").content == "replaced")
    }

    @Test
    func aFilePastTheSizeLimitIsRefusedBeforeAnythingIsWritten() async throws {
        let workspace = Fixture.workspace()
        let tooBig = Data(repeating: 0x61, count: AgentScratchWorkspace.Limits.fileBytes + 1)
        await #expect(throws: (any Error).self) {
            try await workspace.write("big.bin", data: tooBig)
        }
        #expect(try await workspace.usage().bytes == 0)
        #expect(try await workspace.list(nil, recursive: true).isEmpty)
    }

    /// A quota an agent could evade by naming a file `.big` is not a quota.
    @Test
    func hiddenFilesCountAgainstTheQuotaAndAppearInListings() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write(".hidden", data: Data(repeating: 0x61, count: 100))
        let usage = try await workspace.usage()
        #expect(usage.bytes == 100)
        #expect(usage.entries == 1)
        #expect(try await workspace.list(nil, recursive: true).map(\.path) == [".hidden"])
    }

    // MARK: - Reading

    @Test
    func readReturnsABoundedWindowAndSaysWhenMoreRemains() async throws {
        let workspace = Fixture.workspace()
        let body = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        _ = try await workspace.write("log.txt", data: Data(body.utf8))

        let window = try await workspace.read("log.txt", offset: 10, limit: 3)
        #expect(window.content == "line 10\nline 11\nline 12")
        #expect(window.offset == 10)
        #expect(window.returnedLines == 3)
        #expect(window.totalLines == 100)
        #expect(window.isTruncated)

        let tail = try await workspace.read("log.txt", offset: 98)
        #expect(tail.returnedLines == 3)
        #expect(!tail.isTruncated)

        await #expect(throws: (any Error).self) {
            try await workspace.read("log.txt", offset: 500)
        }
    }

    @Test
    func aNonTextFileIsRefusedByReadButStillMovable() async throws {
        let workspace = Fixture.workspace()
        let binary = Data([0xFF, 0xFE, 0x00, 0x01, 0x80])
        _ = try await workspace.write("blob.bin", data: binary)
        await #expect(throws: (any Error).self) { try await workspace.read("blob.bin") }
        // `data(at:)` is what scratch_push uses, and it does not decode.
        #expect(try await workspace.data(at: "blob.bin").data == binary)
    }

    // MARK: - Editing

    @Test
    func everyEditMatchesTheOriginalRatherThanThePrecedingResult() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("c.conf", data: Data("alpha\nbeta\ngamma\n".utf8))

        let outcome = try await workspace.apply(
            [
                ScratchEdit(oldText: "alpha", newText: "one"),
                ScratchEdit(oldText: "gamma", newText: "three"),
            ],
            to: "c.conf"
        )
        #expect(outcome.editsApplied == 2)
        #expect(try await workspace.read("c.conf").content == "one\nbeta\nthree")
        #expect(outcome.diff.firstChangedLine == 1)
        #expect(outcome.diff.text.contains("-alpha"))
        #expect(outcome.diff.text.contains("+three"))

        // An old_text that exists only *after* the first edit lands is not matched:
        // the model never has to simulate its own changes to write the second one.
        _ = try await workspace.write("d.conf", data: Data("alpha\nbeta\n".utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.apply(
                [
                    ScratchEdit(oldText: "alpha", newText: "one"),
                    ScratchEdit(oldText: "one", newText: "uno"),
                ],
                to: "d.conf"
            )
        }
        #expect(try await workspace.read("d.conf").content == "alpha\nbeta")
    }

    @Test
    func anAmbiguousOrOverlappingEditChangesNothingAtAll() async throws {
        let workspace = Fixture.workspace()
        let body = "listen 80;\nserver_name a;\nlisten 80;\n"
        _ = try await workspace.write("n.conf", data: Data(body.utf8))
        let before = try await workspace.data(at: "n.conf").sha256

        await #expect(throws: (any Error).self) {
            try await workspace.apply(
                [ScratchEdit(oldText: "listen 80;", newText: "listen 8080;")], to: "n.conf"
            )
        }
        #expect(try await workspace.data(at: "n.conf").sha256 == before)

        await #expect(throws: (any Error).self) {
            try await workspace.apply(
                [
                    ScratchEdit(oldText: "server_name a;\nlisten", newText: "x"),
                    ScratchEdit(oldText: "a;\nlisten 80;\n", newText: "y"),
                ],
                to: "n.conf"
            )
        }
        #expect(try await workspace.data(at: "n.conf").sha256 == before)

        // Extending old_text until it names one region is the documented fix, and
        // it works.
        let outcome = try await workspace.apply(
            [ScratchEdit(oldText: "server_name a;\nlisten 80;", newText: "server_name a;\nlisten 8080;")],
            to: "n.conf"
        )
        #expect(outcome.editsApplied == 1)
        #expect(try await workspace.read("n.conf").content == "listen 80;\nserver_name a;\nlisten 8080;")
    }

    @Test
    func aNoOpEditIsReportedRatherThanSilentlySucceeding() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("f.txt", data: Data("same\n".utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.apply(
                [ScratchEdit(oldText: "same", newText: "same")], to: "f.txt"
            )
        }
    }

    /// Without the normalized retry, an edit fails whenever the model retypes a
    /// block with tidied punctuation — which is often.
    @Test
    func punctuationAndTrailingWhitespaceDoNotDefeatAMatch() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write(
            "q.txt", data: Data("say \u{201C}hello\u{201D} \u{2014} now   \nkeep\n".utf8)
        )
        let outcome = try await workspace.apply(
            [ScratchEdit(oldText: "say \"hello\" - now", newText: "say goodbye")], to: "q.txt"
        )
        #expect(outcome.editsApplied == 1)
        #expect(try await workspace.read("q.txt").content == "say goodbye\nkeep")

        // A difference in an actual word is still a miss. The fallback forgives how
        // text was typed, not what it says.
        await #expect(throws: (any Error).self) {
            try await workspace.apply(
                [ScratchEdit(oldText: "say farewell", newText: "x")], to: "q.txt"
            )
        }
    }

    @Test
    func aWindowsFileKeepsItsLineEndingsAndBOM() async throws {
        let workspace = Fixture.workspace()
        let original = "\u{FEFF}alpha\r\nbeta\r\ngamma\r\n"
        _ = try await workspace.write("win.ini", data: Data(original.utf8))

        let outcome = try await workspace.apply(
            [ScratchEdit(oldText: "beta", newText: "BETA")], to: "win.ini"
        )
        #expect(outcome.lineEnding == .crlf)
        // Asserted on the bytes, not on a decoded String. Decoding is what hides a
        // BOM — Foundation strips it — and reading the file back through
        // `String(data:encoding:)` here would report a pass whether or not those
        // three bytes survived.
        let updated = try await workspace.data(at: "win.ini").data
        #expect(updated.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(updated == Data("\u{FEFF}alpha\r\nBETA\r\ngamma\r\n".utf8))
        // Only the edited line differs; the diff is not "every line changed".
        #expect(outcome.diff.firstChangedLine == 2)
        #expect(outcome.diff.text.components(separatedBy: "\n-").count == 2)
    }

    @Test
    func editReportsADiffAndNeverTheNewFile() async throws {
        let workspace = Fixture.workspace()
        let body = (1...400).map { "setting_\($0) = off" }.joined(separator: "\n") + "\n"
        _ = try await workspace.write("big.conf", data: Data(body.utf8))

        let outcome = try await workspace.apply(
            [ScratchEdit(oldText: "setting_200 = off", newText: "setting_200 = on")],
            to: "big.conf"
        )
        #expect(outcome.diff.firstChangedLine == 200)
        #expect(outcome.diff.text.contains("+setting_200 = on"))
        // The whole point: what comes back is a fraction of what changed hands.
        #expect(outcome.diff.text.utf8.count < body.utf8.count / 10)
        #expect(!outcome.diff.text.contains("setting_1 = off"))
    }

    @Test
    func moreEditsThanTheLimitAreRefused() async throws {
        let workspace = Fixture.workspace()
        let count = AgentScratchWorkspace.Limits.edits + 1
        let body = (1...count).map { "v\($0)" }.joined(separator: "\n") + "\n"
        _ = try await workspace.write("many.txt", data: Data(body.utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.apply(
                (1...count).map { ScratchEdit(oldText: "v\($0)", newText: "w\($0)") },
                to: "many.txt"
            )
        }
    }

    // MARK: - Deleting

    @Test
    func deleteTakesOneFileOrOneEmptyDirectory() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("tree/leaf.txt", data: Data("x".utf8))

        // A directory with anything in it is refused, so there is no un-gated way to
        // destroy a subtree.
        await #expect(throws: (any Error).self) {
            try await workspace.delete("tree", kind: .directory)
        }
        // And the kind has to match what is actually there.
        await #expect(throws: (any Error).self) {
            try await workspace.delete("tree", kind: .file)
        }

        try await workspace.delete("tree/leaf.txt", kind: .file)
        try await workspace.delete("tree", kind: .directory)
        #expect(try await workspace.list(nil, recursive: true).isEmpty)
    }

    // MARK: - Concurrency

    /// The actor is the mutation queue Pi builds explicitly, which is what lets every
    /// scratch tool stay `.parallel` without a batch ever observing a torn file.
    @Test
    func concurrentWritesAndReadsNeverObserveATornFile() async throws {
        let workspace = Fixture.workspace()
        let short = String(repeating: "a", count: 4_096)
        let long = String(repeating: "b", count: 65_536)
        _ = try await workspace.write("race.txt", data: Data(short.utf8))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let body = index.isMultiple(of: 2) ? short : long
                    _ = try? await workspace.write("race.txt", data: Data(body.utf8))
                }
                group.addTask {
                    guard let file = try? await workspace.data(at: "race.txt"),
                        let text = String(data: file.data, encoding: .utf8)
                    else { return }
                    // Every observation is one of the two whole values, never a
                    // prefix of one or a splice of both.
                    #expect(text == short || text == long)
                }
            }
        }
    }

    // MARK: - Safety

    /// `.locallyContained` has to mean the same thing in every mode, or it is just
    /// `.requiresAuthorization` with extra steps.
    @Test
    func containedActionsSkipTheGateInEveryPermissionMode() async {
        for mode in ChatPermissionMode.allCases {
            let reviewer = CountingSecurityReviewer()
            let broker = AgentApprovalBroker(
                reviewer: reviewer,
                manualApproval: { _ in .deny("a person was asked") }
            )
            let allowed = await broker.authorize(
                Fixture.request(safety: .locallyContained), mode: mode
            )
            #expect(allowed == .allow, "\(mode) gated a contained action")
            #expect(await reviewer.count == 0, "\(mode) sent a contained action to review")
        }
    }

    /// The other half of the claim: adding a third case widened nothing. An action
    /// that needs authorization still reaches whichever gate the mode nominates.
    @Test
    func remoteWritesStillReachTheGate() async {
        let asked = CountingSecurityReviewer()
        let manual = AgentApprovalBroker(
            reviewer: asked, manualApproval: { _ in .deny("denied by the user") }
        )
        #expect(
            await manual.authorize(
                Fixture.request(safety: .requiresAuthorization), mode: .askForApproval
            ) == .deny("denied by the user")
        )
        // Ask for approval asks the person, not the reviewer.
        #expect(await asked.count == 0)

        // Approve for me hands the same request to Security Review, which decides.
        let reviewed = CountingSecurityReviewer()
        let automatic = AgentApprovalBroker(
            reviewer: reviewed, manualApproval: { _ in .deny("nobody should be asked") }
        )
        #expect(
            await automatic.authorize(
                Fixture.request(safety: .requiresAuthorization), mode: .approveForMe
            ) == .allow
        )
        #expect(await reviewed.count == 1)
    }

    @Test
    func autoAllowIsAPropertyOfTheCaseAndNotOfTheCallSite() {
        #expect(AgentToolDescriptor.Safety.locallyReadOnly.isAutoAllowed)
        #expect(AgentToolDescriptor.Safety.locallyContained.isAutoAllowed)
        #expect(!AgentToolDescriptor.Safety.requiresAuthorization.isAutoAllowed)
    }

    // MARK: - Registry

    @Test
    func theToolSetIsRegisteredWithoutShadowingABuiltIn() async throws {
        let workspace = Fixture.workspace()
        let local = AgentScratchTools.make(workspace: workspace)
        #expect(local.map(\.descriptor.name).sorted() == [
            "scratch_delete", "scratch_diff", "scratch_edit",
            "scratch_list", "scratch_read", "scratch_write",
        ])
        // Every purely local tool is parallel, and only the three that change
        // something claim to.
        #expect(local.allSatisfy { $0.descriptor.concurrency == .parallel })
        #expect(local.allSatisfy { $0.descriptor.target == .local })
        #expect(
            local.filter { $0.descriptor.safety == .locallyContained }
                .map(\.descriptor.name).sorted()
                == ["scratch_delete", "scratch_edit", "scratch_write"]
        )
        #expect(!local.contains { $0.descriptor.safety == .requiresAuthorization })

        // Transfer is absent until a connection pool is supplied, on the same terms
        // as `web_search`: a tool that cannot work is not offered.
        let withHosts = AgentScratchTools.make(
            workspace: workspace, connections: Fixture.pool(StubTransferSFTPClient())
        )
        let transfer = withHosts.filter { ["scratch_pull", "scratch_push"].contains($0.descriptor.name) }
        #expect(transfer.count == 2)
        #expect(transfer.allSatisfy { $0.descriptor.target == .host })
        #expect(
            transfer.first { $0.descriptor.name == "scratch_push" }?.descriptor.safety
                == .requiresAuthorization
        )
        #expect(
            transfer.first { $0.descriptor.name == "scratch_pull" }?.descriptor.safety
                == .locallyContained
        )
        // A pull is a remote read landing in contained storage and may overlap
        // anything; a push changes a host and takes its turn serial.
        #expect(
            transfer.first { $0.descriptor.name == "scratch_pull" }?.descriptor.concurrency
                == .parallel
        )
        #expect(
            transfer.first { $0.descriptor.name == "scratch_push" }?.descriptor.concurrency
                == .sequential
        )
    }

    /// The built-in SFTP tools were deliberately left alone: `scratch_pull` and
    /// `scratch_push` are separate tools, not new modes of existing ones.
    @Test @MainActor
    func theSFTPToolsAreUnchanged() {
        let tools = AgentBuiltInTools.make(
            hosts: AgentHostResolver(store: HostStore()),
            connections: Fixture.pool(StubTransferSFTPClient())
        )
        let names = tools.map(\.descriptor.name)
        #expect(!names.contains { $0.hasPrefix("scratch_") })
        for name in ["sftp_read", "sftp_write"] {
            let properties = tools.first { $0.descriptor.name == name }?
                .descriptor.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(properties["to_scratch"] == nil)
            #expect(properties["from_scratch"] == nil)
        }
        #expect(
            tools.first { $0.descriptor.name == "sftp_write" }?.descriptor.inputSchema
                .objectValue?["required"]?.arrayValue?.compactMap(\.stringValue).sorted()
                == ["content", "host_id", "path"]
        )
    }

    // MARK: - Transfer

    @Test
    func pullLandsTheFileWithoutPuttingItInTheResult() async throws {
        let workspace = Fixture.workspace()
        let body = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let client = StubTransferSFTPClient(files: ["/etc/app.conf": Data(body.utf8)])
        let tool = try #require(
            AgentScratchTools.make(workspace: workspace, connections: Fixture.pool(client))
                .first { $0.descriptor.name == "scratch_pull" }
        )

        let invocation = Fixture.invocation("scratch_pull", [
            "host_id": .string(Fixture.hostID.uuidString),
            "remote_path": .string("/etc/app.conf"), "scratch_path": .string("app.conf"),
        ])
        let result = try await tool.execute(invocation, context: Fixture.context())

        #expect(!result.isError)
        #expect(!result.content.contains("line 1"))
        #expect(result.content.contains("\"lines\":50"))
        #expect(result.content.contains(AgentScratchWorkspace.digest(Data(body.utf8))))
        // The bytes are in the workspace, byte for byte.
        #expect(try await workspace.data(at: "app.conf").data == Data(body.utf8))
    }

    @Test
    func pullValidatesBothPathsBeforeTouchingTheHost() async throws {
        let client = StubTransferSFTPClient(files: ["/etc/app.conf": Data("x".utf8)])
        let tool = try #require(
            AgentScratchTools.make(
                workspace: Fixture.workspace(), connections: Fixture.pool(client)
            ).first { $0.descriptor.name == "scratch_pull" }
        )
        for (remote, scratch) in [("relative/path", "ok.conf"), ("/etc/app.conf", "../out.conf")] {
            await #expect(throws: (any Error).self) {
                try await tool.preflight(Fixture.invocation("scratch_pull", [
                    "host_id": .string(Fixture.hostID.uuidString),
                    "remote_path": .string(remote), "scratch_path": .string(scratch),
                ]))
            }
        }
        #expect(await client.reads.isEmpty)
    }

    /// The regression this guards: `scratch_push` would otherwise turn an approval
    /// that showed the bytes into one that showed a filename, and the reviewer —
    /// human or model — would be agreeing to something neither had seen.
    @Test
    func pushPutsRealEvidenceInFrontOfTheApprover() async throws {
        let workspace = Fixture.workspace()
        let body = "user = admin\npassword = hunter2\nport = 8080\n"
        _ = try await workspace.write("app.conf", data: Data(body.utf8))
        let client = StubTransferSFTPClient()
        let tool = try #require(
            AgentScratchTools.make(workspace: workspace, connections: Fixture.pool(client))
                .first { $0.descriptor.name == "scratch_push" }
        )

        let invocation = Fixture.invocation("scratch_push", [
            "host_id": .string(Fixture.hostID.uuidString),
            "scratch_path": .string("app.conf"), "remote_path": .string("/etc/app.conf"),
        ])
        let preflight = try await tool.preflight(invocation)
        let reasons = preflight.reasons.joined(separator: "\n")

        #expect(preflight.safety == .requiresAuthorization)
        #expect(preflight.invocation.targetHostID == Fixture.hostID)
        #expect(reasons.contains("app.conf"))
        #expect(reasons.contains("\(body.utf8.count) bytes"))
        #expect(reasons.contains("3 lines"))
        #expect(reasons.contains(AgentScratchWorkspace.digest(Data(body.utf8)).prefix(16)))
        #expect(reasons.contains("user = admin"))
        // The head is a preview shown to a person, so it goes through the same
        // redaction the arguments do.
        #expect(!reasons.contains("hunter2"))
        #expect(reasons.contains("[REDACTED]"))
        // The digest binding is execution-only: not an argument, not replayed to
        // the model, not persisted.
        #expect(preflight.executionMetadata["scratch_sha256"]?.stringValue != nil)
        #expect(preflight.invocation.call.arguments.objectValue?["scratch_sha256"] == nil)
    }

    @Test
    func pushWritesTheApprovedBytesAndRefusesAnySubstitute() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("app.conf", data: Data("approved\n".utf8))
        let client = StubTransferSFTPClient()
        let tool = try #require(
            AgentScratchTools.make(workspace: workspace, connections: Fixture.pool(client))
                .first { $0.descriptor.name == "scratch_push" }
        )
        let invocation = Fixture.invocation("scratch_push", [
            "host_id": .string(Fixture.hostID.uuidString),
            "scratch_path": .string("app.conf"), "remote_path": .string("/etc/app.conf"),
        ])
        let approved = try await tool.preflight(invocation).executionMetadata

        let result = try await tool.execute(
            invocation, context: Fixture.context(preflight: approved)
        )
        #expect(!result.isError)
        #expect(await client.writes["/etc/app.conf"] == Data("approved\n".utf8))

        // Approval suspends the turn. Whatever comes back from the workspace after
        // it is only the same file if nothing rewrote it in between.
        _ = try await workspace.write("app.conf", data: Data("swapped\n".utf8))
        await #expect(throws: (any Error).self) {
            try await tool.execute(invocation, context: Fixture.context(preflight: approved))
        }
        #expect(await client.writes["/etc/app.conf"] == Data("approved\n".utf8))
    }

    @Test
    func nonTextFilesSurviveTheRoundTripIntact() async throws {
        let workspace = Fixture.workspace()
        let binary = Data((0...255).map { UInt8($0) })
        let client = StubTransferSFTPClient(files: ["/opt/blob.bin": binary])
        let tools = AgentScratchTools.make(
            workspace: workspace, connections: Fixture.pool(client)
        )
        let pull = try #require(tools.first { $0.descriptor.name == "scratch_pull" })
        let push = try #require(tools.first { $0.descriptor.name == "scratch_push" })

        _ = try await pull.execute(
            Fixture.invocation("scratch_pull", [
                "host_id": .string(Fixture.hostID.uuidString),
                "remote_path": .string("/opt/blob.bin"), "scratch_path": .string("blob.bin"),
            ]),
            context: Fixture.context()
        )
        let invocation = Fixture.invocation("scratch_push", [
            "host_id": .string(Fixture.hostID.uuidString),
            "scratch_path": .string("blob.bin"), "remote_path": .string("/opt/copy.bin"),
        ])
        _ = try await push.execute(
            invocation,
            context: Fixture.context(preflight: try await push.preflight(invocation).executionMetadata)
        )
        #expect(await client.writes["/opt/copy.bin"] == binary)
    }
}

// MARK: - Fixtures

private enum Fixture {
    static let hostID = UUID(uuidString: "F0000000-0000-0000-0000-00000000000F")!

    static func base() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "termind-scratch-tests/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func workspace() -> AgentScratchWorkspace {
        AgentScratchWorkspace(conversationID: UUID(), base: base())
    }

    static func pool(_ client: StubTransferSFTPClient) -> AgentConnectionPool {
        AgentConnectionPool(
            configuration: { hostID in
                SSHConnectionConfiguration(
                    hostID: hostID, host: "host.example", port: 22, username: "root",
                    credentials: [], expectedHostKeys: [], proxy: nil, jumps: []
                )
            },
            routeFingerprint: { _ in "fingerprint" },
            openExec: { _ in throw AgentToolError.invalidHost },
            openSFTP: { _ in client },
            sweepInterval: nil
        )
    }

    static func invocation(
        _ name: String, _ arguments: [String: AgentJSONValue]
    ) -> AgentToolInvocation {
        AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "call-1", name: name, arguments: .object(arguments))
        )
    }

    static func context(
        preflight: [String: AgentJSONValue] = [:]
    ) -> AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: UUID(), userIntent: "update the config", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(),
            preflightMetadata: preflight, authorize: { _ in .allow }
        )
    }

    static func request(safety: AgentToolDescriptor.Safety) -> AgentApprovalRequest {
        AgentApprovalRequest(
            invocation: invocation("t", [:]),
            descriptor: AgentToolDescriptor(
                name: "t", summary: "t",
                inputSchema: .object(["type": .string("object")]),
                target: .local, safety: safety
            ),
            userIntent: "do the thing"
        )
    }
}

private actor CountingSecurityReviewer: SecurityReviewing {
    private(set) var count = 0

    func review(_ request: AgentApprovalRequest) async throws -> SecurityReviewDecision {
        count += 1
        return SecurityReviewDecision(
            verdict: .approve, risk: .low, userAuthorization: .sufficient, reason: "fine"
        )
    }
}

private actor StubTransferSFTPClient: SFTPClientProtocol {
    private(set) var files: [String: Data]
    private(set) var writes: [String: Data] = [:]
    private(set) var reads: [String] = []

    init(files: [String: Data] = [:]) { self.files = files }

    func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        reads.append(path)
        guard let data = files[path] else { throw AgentToolError.notFound }
        guard data.count <= maximumBytes else {
            throw SFTPError.operation("\(path) exceeds \(maximumBytes) bytes.")
        }
        return data
    }

    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        guard overwrite || writes[path] == nil else {
            throw SFTPError.operation("\(path) already exists.")
        }
        writes[path] = data
    }

    func connect(
        using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/root" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}
