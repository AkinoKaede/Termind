import AgentKit
import AgentKitScrubber
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
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
        let searched = try await workspace.search("anchor")
        #expect(searched.matches.map(\.path) == ["anchor.txt"])
        #expect(searched.searchedFiles == 1)
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

    // MARK: - Searching

    @Test
    func searchSupportsLiteralRegexAndSmartCaseMatching() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write(
            "a.txt", data: Data("Alpha alpha\nneedle twice needle\nserver_42\n".utf8)
        )
        _ = try await workspace.write(
            "b.txt", data: Data("alpha\nserver-x\n".utf8)
        )

        let insensitive = try await workspace.search("alpha")
        #expect(!insensitive.caseSensitive)
        #expect(insensitive.matchingLines == 2)
        #expect(insensitive.matches.map { "\($0.path):\($0.line)" } == ["a.txt:1", "b.txt:1"])

        let smartCase = try await workspace.search("Alpha")
        #expect(smartCase.caseSensitive)
        #expect(smartCase.matches.map(\.path) == ["a.txt"])

        let overridden = try await workspace.search("Alpha", caseSensitive: false)
        #expect(!overridden.caseSensitive)
        #expect(overridden.matchingLines == 2)

        let regex = try await workspace.search(#"server_[0-9]+"#, regex: true)
        #expect(regex.matches.map { "\($0.path):\($0.line)" } == ["a.txt:3"])

        // Search results are matching lines, not occurrences within those lines.
        let duplicate = try await workspace.search("needle")
        #expect(duplicate.matchingLines == 1)
        #expect(duplicate.matches.count == 1)
    }

    @Test
    func searchScopesAndOrdersFilesAndSkipsBinaryContent() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("z.txt", data: Data("hit at root\n".utf8))
        _ = try await workspace.write("dir/b.txt", data: Data("before\r\nhit b\r\n".utf8))
        _ = try await workspace.write("dir/a.txt", data: Data("hit a\n".utf8))
        _ = try await workspace.write(".hidden", data: Data("hidden hit\n".utf8))
        _ = try await workspace.write("dir/blob.bin", data: Data([0xFF, 0x00, 0x80]))

        let directory = try await workspace.search("hit", path: "dir")
        #expect(
            directory.matches.map { "\($0.path):\($0.line)" } == [
                "dir/a.txt:1", "dir/b.txt:2",
            ])
        #expect(directory.searchedFiles == 2)
        #expect(directory.skippedBinaryFiles == 1)

        let file = try await workspace.search("hit", path: "z.txt")
        #expect(file.matches.map(\.path) == ["z.txt"])
        #expect(file.searchedFiles == 1)

        let wholeWorkspace = try await workspace.search("hit")
        #expect(
            wholeWorkspace.matches.map(\.path) == [
                ".hidden", "dir/a.txt", "dir/b.txt", "z.txt",
            ])
        #expect(wholeWorkspace.searchedFiles == 4)
        #expect(wholeWorkspace.skippedBinaryFiles == 1)
    }

    @Test
    func searchBoundsResultsAndKeepsTheMatchVisibleInLongLines() async throws {
        let workspace = Fixture.workspace()
        let longLine =
            String(repeating: "x", count: 5_000)
            + "target" + String(repeating: "y", count: 5_000)
        _ = try await workspace.write(
            "long.txt", data: Data((longLine + "\ntarget two\ntarget three\n").utf8)
        )

        let outcome = try await workspace.search("target", limit: 1)
        #expect(outcome.matchingLines == 3)
        #expect(outcome.matches.count == 1)
        #expect(outcome.matches[0].text.contains("target"))
        #expect(outcome.matches[0].textTruncated)
        #expect(outcome.isTruncated)
    }

    @Test
    func searchRejectsInvalidPatternsPathsAndBounds() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("a.txt", data: Data("text\n".utf8))
        for query in ["", "two\nlines"] {
            await #expect(throws: (any Error).self) {
                try await workspace.search(query)
            }
        }
        await #expect(throws: (any Error).self) {
            try await workspace.search("[", regex: true)
        }
        await #expect(throws: (any Error).self) {
            try await workspace.search("text", path: "../outside")
        }
        await #expect(throws: (any Error).self) {
            try await workspace.search("text", path: "missing")
        }
        await #expect(throws: (any Error).self) {
            try await workspace.search("text", limit: 101)
        }
    }

    // MARK: - Editing

    @Test
    func everyEditMatchesTheOriginalRatherThanThePrecedingResult() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("c.conf", data: Data("alpha\nbeta\ngamma\n".utf8))

        let outcome = try await workspace.replace(
            [
                ScratchReplacement(oldText: "alpha", newText: "one"),
                ScratchReplacement(oldText: "gamma", newText: "three"),
            ],
            in: "c.conf"
        )
        #expect(outcome.replacementsApplied == 2)
        #expect(try await workspace.read("c.conf").content == "one\nbeta\nthree")
        #expect(outcome.diff.firstChangedLine == 1)
        #expect(outcome.diff.text.contains("-alpha"))
        #expect(outcome.diff.text.contains("+three"))

        // An old_text that exists only *after* the first edit lands is not matched:
        // the model never has to simulate its own changes to write the second one.
        _ = try await workspace.write("d.conf", data: Data("alpha\nbeta\n".utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [
                    ScratchReplacement(oldText: "alpha", newText: "one"),
                    ScratchReplacement(oldText: "one", newText: "uno"),
                ],
                in: "d.conf"
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
            try await workspace.replace(
                [ScratchReplacement(oldText: "listen 80;", newText: "listen 8080;")], in: "n.conf"
            )
        }
        #expect(try await workspace.data(at: "n.conf").sha256 == before)

        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [
                    ScratchReplacement(oldText: "server_name a;\nlisten", newText: "x"),
                    ScratchReplacement(oldText: "a;\nlisten 80;\n", newText: "y"),
                ],
                in: "n.conf"
            )
        }
        #expect(try await workspace.data(at: "n.conf").sha256 == before)

        // Extending old_text until it names one region is the documented fix, and
        // it works.
        let outcome = try await workspace.replace(
            [ScratchReplacement(oldText: "server_name a;\nlisten 80;", newText: "server_name a;\nlisten 8080;")],
            in: "n.conf"
        )
        #expect(outcome.replacementsApplied == 1)
        #expect(try await workspace.read("n.conf").content == "listen 80;\nserver_name a;\nlisten 8080;")
    }

    @Test
    func aNoOpEditIsReportedRatherThanSilentlySucceeding() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("f.txt", data: Data("same\n".utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [ScratchReplacement(oldText: "same", newText: "same")], in: "f.txt"
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
        let outcome = try await workspace.replace(
            [ScratchReplacement(oldText: "say \"hello\" - now", newText: "say goodbye")], in: "q.txt"
        )
        #expect(outcome.replacementsApplied == 1)
        #expect(try await workspace.read("q.txt").content == "say goodbye\nkeep")

        // A difference in an actual word is still a miss. The fallback forgives how
        // text was typed, not what it says.
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [ScratchReplacement(oldText: "say farewell", newText: "x")], in: "q.txt"
            )
        }
    }

    @Test
    func aWindowsFileKeepsItsLineEndingsAndBOM() async throws {
        let workspace = Fixture.workspace()
        let original = "\u{FEFF}alpha\r\nbeta\r\ngamma\r\n"
        _ = try await workspace.write("win.ini", data: Data(original.utf8))

        let outcome = try await workspace.replace(
            [ScratchReplacement(oldText: "beta", newText: "BETA")], in: "win.ini"
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

        let outcome = try await workspace.replace(
            [ScratchReplacement(oldText: "setting_200 = off", newText: "setting_200 = on")],
            in: "big.conf"
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
        let count = AgentScratchWorkspace.Limits.replacements + 1
        let body = (1...count).map { "v\($0)" }.joined(separator: "\n") + "\n"
        _ = try await workspace.write("many.txt", data: Data(body.utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                (1...count).map { ScratchReplacement(oldText: "v\($0)", newText: "w\($0)") },
                in: "many.txt"
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

    // MARK: - Approval policy

    @Test
    func approvedActionsSkipTheGateInEveryPermissionMode() async {
        for mode in AgentPermissionMode.allCases {
            let reviewer = CountingGuardianReviewer()
            let broker = AgentApprovalBroker(
                reviewer: reviewer,
                manualApproval: { _ in .deny("a person was asked") }
            )
            let allowed = await broker.authorize(
                Fixture.request(approvalPolicy: .approve), mode: mode
            )
            #expect(allowed == .allow, "\(mode) gated an approved action")
            #expect(await reviewer.count == 0, "\(mode) sent an approved action to review")
        }
    }

    @Test
    func askedRemoteWritesReachTheSelectedGate() async {
        let asked = CountingGuardianReviewer()
        let manual = AgentApprovalBroker(
            reviewer: asked, manualApproval: { _ in .deny("denied by the user") }
        )
        #expect(
            await manual.authorize(
                Fixture.request(approvalPolicy: .ask), mode: .askForApproval
            ) == .deny("denied by the user")
        )
        // Ask for approval asks the person, not the reviewer.
        #expect(await asked.count == 0)

        // Approve for me hands the same request to Guardian, which decides.
        let reviewed = CountingGuardianReviewer()
        let automatic = AgentApprovalBroker(
            reviewer: reviewed, manualApproval: { _ in .deny("nobody should be asked") }
        )
        #expect(
            await automatic.authorize(
                Fixture.request(approvalPolicy: .ask), mode: .approveForMe
            ) == .allow
        )
        #expect(await reviewed.count == 1)
    }

    // MARK: - Registry

    /// A card records the presenter ID it was written with, and older cards record
    /// only a tool name. `scratch_edit` became `scratch_replace`, so both routes
    /// still have to reach a projection — otherwise every transcript that predates
    /// the rename falls back to generic key/value fields.
    @Test
    func aCardWrittenAsScratchEditStillFindsItsProjection() throws {
        let byID = try #require(TermindAgentTools.presenter(id: "builtin.scratch_edit"))
        let byLegacyName = try #require(
            TermindAgentTools.legacyPresenter(forToolNamed: "scratch_edit")
        )
        #expect(byLegacyName.id == byID.id)
        #expect(TermindAgentTools.presenter(id: "builtin.scratch_replace") != nil)

        // And it draws the old payload, which has no `replacements_applied`.
        let items = byID.present(
            AgentToolDetailInput(
                result: .object([
                    "path": .string("app.conf"), "edits_applied": .number(2),
                    "diff": .string("@@ -1 +1 @@\n-a\n+b"), "bytes": .number(12),
                ]),
                arguments: ["path": .string("app.conf")], locale: Locale(identifier: "en")
            ))
        let showsPath = items.contains { item in
            guard case .field(let field) = item else { return false }
            return field.value == "app.conf"
        }
        let showsDiff = items.contains { item in
            guard case .text(let block) = item else { return false }
            return block.text.contains("+b")
        }
        #expect(showsPath)
        #expect(showsDiff)
    }

    @Test
    func theToolSetIsRegisteredWithoutShadowingABuiltIn() async throws {
        let workspace = Fixture.workspace()
        let local = Fixture.scratchTools(workspace: workspace)
        #expect(
            local.map(\.descriptor.name).sorted() == [
                "scratch_copy", "scratch_delete", "scratch_diff", "scratch_list", "scratch_move",
                "scratch_read", "scratch_replace", "scratch_search", "scratch_write",
            ])
        // Every purely local scratch tool is parallel and pre-approved.
        #expect(local.allSatisfy { $0.descriptor.concurrency == .parallel })
        #expect(local.allSatisfy { $0.descriptor.target == .local })
        #expect(local.allSatisfy { $0.descriptor.approvalPolicy == .approve })
        let search = try #require(local.first { $0.descriptor.name == "scratch_search" })
        let properties = search.descriptor.inputSchema.objectValue?["properties"]?.objectValue
        #expect(
            properties?.keys.sorted() == [
                "case_sensitive", "limit", "path", "query", "regex",
            ])
        #expect(search.descriptor.presentation?.actionKind == .search)

        // Transfer is absent until a connection pool is supplied, on the same terms
        // as `web_search`: a tool that cannot work is not offered.
        let withHosts = Fixture.scratchTools(
            workspace: workspace, connections: Fixture.pool(StubTransferSFTPClient()),
            authentication: Fixture.authentication()
        )
        let transfer = withHosts.filter { ["scratch_pull", "scratch_push"].contains($0.descriptor.name) }
        #expect(transfer.count == 2)
        #expect(transfer.allSatisfy { $0.descriptor.target == .host })
        #expect(
            transfer.first { $0.descriptor.name == "scratch_push" }?.descriptor.approvalPolicy
                == .ask
        )
        #expect(
            transfer.first { $0.descriptor.name == "scratch_pull" }?.descriptor.approvalPolicy
                == .approve
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

        // Absent without a client. When present, the write remains contained and
        // parallel, but the external network request requires approval.
        #expect(!local.contains { $0.descriptor.name == "scratch_fetch" })
        let withWeb = Fixture.scratchTools(workspace: workspace, web: Fixture.web())
        let fetch = try #require(withWeb.first { $0.descriptor.name == "scratch_fetch" })
        #expect(fetch.descriptor.target == .network)
        #expect(fetch.descriptor.approvalPolicy == .ask)
        #expect(fetch.descriptor.concurrency == .parallel)
    }

    /// `fetch` is a separate tool, not a new mode of `fetch`. The same promise
    /// `theSFTPToolsAreUnchanged` makes about `sftp_read` / `sftp_write`.
    @Test @MainActor
    func theFetchToolKeepsItsSchemaAndRequiresApproval() {
        let tools = Fixture.builtInTools(
            hosts: AgentHostResolver(store: HostLibraryModel()),
            connections: Fixture.pool(StubTransferSFTPClient())
        )
        let fetch = tools.first { $0.descriptor.name == "fetch" }?.descriptor
        let properties = fetch?.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        #expect(properties["scratch_path"] == nil)
        #expect(properties.keys.sorted() == ["format", "url"])
        #expect(fetch?.approvalPolicy == .ask)
        #expect(!tools.contains { $0.descriptor.name.hasPrefix("scratch_") })
    }

    /// The built-in SFTP tools were deliberately left alone: `scratch_pull` and
    /// `scratch_push` are separate tools, not new modes of existing ones.
    @Test @MainActor
    func theSFTPToolsAreUnchanged() {
        let tools = Fixture.builtInTools(
            hosts: AgentHostResolver(store: HostLibraryModel()),
            connections: Fixture.pool(StubTransferSFTPClient())
        )
        let names = tools.map(\.descriptor.name)
        #expect(!names.contains { $0.hasPrefix("scratch_") })
        for name in ["sftp_read", "sftp_write"] {
            let properties =
                tools.first { $0.descriptor.name == name }?
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

    @Test
    func searchToolBoundsItsEncodedTranscriptResult() async throws {
        let workspace = Fixture.workspace()
        let line = String(repeating: "\u{0001}", count: 1_100) + "target"
        let body = Array(repeating: line, count: 100).joined(separator: "\n")
        _ = try await workspace.write("large.txt", data: Data(body.utf8))
        let tool = try #require(
            Fixture.scratchTools(workspace: workspace)
                .first { $0.descriptor.name == "scratch_search" }
        )
        let result = try await tool.execute(
            Fixture.invocation(
                "scratch_search",
                [
                    "query": .string("target"), "limit": .number(100),
                ]), context: Fixture.context()
        )
        let payload = try #require(result.untrustedPayload)
        let object = try #require(
            try AgentJSONValue.decode(Data(payload.utf8)).objectValue
        )
        #expect(payload.utf8.count <= 128 * 1_024)
        #expect(result.isTruncated)
        #expect(object["matching_lines"]?.integerValue == 100)
        #expect((object["returned_matches"]?.integerValue ?? 100) < 100)
        #expect(object["truncated"]?.boolValue == true)
    }

    // MARK: - Transfer

    @Test
    func pullLandsTheFileWithoutPuttingItInTheResult() async throws {
        let workspace = Fixture.workspace()
        let body = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let client = StubTransferSFTPClient(files: ["/etc/app.conf": Data(body.utf8)])
        let tool = try #require(
            Fixture.scratchTools(
                workspace: workspace, connections: Fixture.pool(client),
                authentication: Fixture.authentication()
            )
            .first { $0.descriptor.name == "scratch_pull" }
        )

        let invocation = Fixture.invocation(
            "scratch_pull",
            [
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
            Fixture.scratchTools(
                workspace: Fixture.workspace(), connections: Fixture.pool(client),
                authentication: Fixture.authentication()
            ).first { $0.descriptor.name == "scratch_pull" }
        )
        for (remote, scratch) in [("relative/path", "ok.conf"), ("/etc/app.conf", "../out.conf")] {
            await #expect(throws: (any Error).self) {
                try await tool.preflight(
                    Fixture.invocation(
                        "scratch_pull",
                        [
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
            Fixture.scratchTools(
                workspace: workspace, connections: Fixture.pool(client),
                authentication: Fixture.authentication()
            )
            .first { $0.descriptor.name == "scratch_push" }
        )

        let invocation = Fixture.invocation(
            "scratch_push",
            [
                "host_id": .string(Fixture.hostID.uuidString),
                "scratch_path": .string("app.conf"), "remote_path": .string("/etc/app.conf"),
            ])
        let preflight = try await tool.preflight(invocation)
        let reasons = preflight.reasons.joined(separator: "\n")

        #expect(preflight.approvalPolicy == .ask)
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
            Fixture.scratchTools(
                workspace: workspace, connections: Fixture.pool(client),
                authentication: Fixture.authentication()
            )
            .first { $0.descriptor.name == "scratch_push" }
        )
        let invocation = Fixture.invocation(
            "scratch_push",
            [
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
        let tools = Fixture.scratchTools(
            workspace: workspace, connections: Fixture.pool(client),
            authentication: Fixture.authentication()
        )
        let pull = try #require(tools.first { $0.descriptor.name == "scratch_pull" })
        let push = try #require(tools.first { $0.descriptor.name == "scratch_push" })

        _ = try await pull.execute(
            Fixture.invocation(
                "scratch_pull",
                [
                    "host_id": .string(Fixture.hostID.uuidString),
                    "remote_path": .string("/opt/blob.bin"), "scratch_path": .string("blob.bin"),
                ]),
            context: Fixture.context()
        )
        let invocation = Fixture.invocation(
            "scratch_push",
            [
                "host_id": .string(Fixture.hostID.uuidString),
                "scratch_path": .string("blob.bin"), "remote_path": .string("/opt/copy.bin"),
            ])
        _ = try await push.execute(
            invocation,
            context: Fixture.context(preflight: try await push.preflight(invocation).executionMetadata)
        )
        #expect(await client.writes["/opt/copy.bin"] == binary)
    }

    // MARK: - Web

    @Test
    func fetchLandsThePageWithoutPuttingItInTheResult() async throws {
        let workspace = Fixture.workspace()
        let page = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tool = try #require(
            Fixture.scratchTools(workspace: workspace, web: Fixture.web(markdown: page))
                .first { $0.descriptor.name == "scratch_fetch" }
        )

        let result = try await tool.execute(
            Fixture.invocation(
                "scratch_fetch",
                [
                    "url": .string("https://example.com/docs"),
                    "scratch_path": .string("docs/page.md"),
                ]),
            context: Fixture.context()
        )

        #expect(!result.isError)
        #expect(!result.content.contains("line 1"))
        #expect(!result.content.contains("raw-marker"))
        #expect(result.content.contains("\"lines\":40"))
        #expect(result.content.contains("\"title\":\"Example\""))
        #expect(result.content.contains(AgentScratchWorkspace.digest(Data(page.utf8))))
        // The bytes are in the workspace, byte for byte.
        #expect(try await workspace.data(at: "docs/page.md").data == Data(page.utf8))
    }

    /// The reason the tool exists. `fetch` truncates at 256 KB because that is what
    /// crosses the context window; nothing does here, so the page arrives whole.
    @Test
    func fetchIsNotBoundedByTheInlineCeilingThatBoundsTheResultOfFetch() async throws {
        let workspace = Fixture.workspace()
        let oversized = String(repeating: "x", count: 256 * 1_024 + 100)
        let tool = try #require(
            Fixture.scratchTools(workspace: workspace, web: Fixture.web(markdown: oversized))
                .first { $0.descriptor.name == "scratch_fetch" }
        )

        let result = try await tool.execute(
            Fixture.invocation(
                "scratch_fetch",
                [
                    "url": .string("https://example.com/big"), "scratch_path": .string("big.md"),
                ]),
            context: Fixture.context()
        )

        #expect(!result.isTruncated)
        #expect(result.content.contains("\"bytes\":\(oversized.utf8.count)"))
        #expect(try await workspace.data(at: "big.md").bytes == oversized.utf8.count)
    }

    @Test
    func fetchWritesTheOriginalHTMLWhenAsked() async throws {
        let workspace = Fixture.workspace()
        let tool = try #require(
            Fixture.scratchTools(workspace: workspace, web: Fixture.web())
                .first { $0.descriptor.name == "scratch_fetch" }
        )

        let result = try await tool.execute(
            Fixture.invocation(
                "scratch_fetch",
                [
                    "url": .string("https://example.com/"), "scratch_path": .string("page.html"),
                    "format": .string("original"),
                ]),
            context: Fixture.context()
        )

        #expect(result.content.contains("\"format\":\"original\""))
        #expect(!result.content.contains("raw-marker"))
        let staged = try await workspace.data(at: "page.html")
        #expect(String(data: staged.data, encoding: .utf8)?.contains("raw-marker") == true)
    }

    @Test
    func fetchValidatesTheURLAndTheDestinationBeforeReachingTheNetwork() async throws {
        let loaded = Counter()
        let web = ScrubberWebClient(
            document: { url in
                await loaded.increment()
                return AgentWebDocument(
                    title: "Example", url: url, markdown: "# Example", original: "<html/>"
                )
            },
            search: { _, _ in [] }
        )
        let tool = try #require(
            Fixture.scratchTools(workspace: Fixture.workspace(), web: web)
                .first { $0.descriptor.name == "scratch_fetch" }
        )

        for arguments in [
            ["url": "file:///etc/passwd", "scratch_path": "leak.txt"],
            ["url": "https://user:pass@example.com/", "scratch_path": "creds.md"],
            ["url": "https://example.com/", "scratch_path": "../escape.md"],
            ["url": "https://example.com/", "scratch_path": "/etc/passwd"],
        ] {
            await #expect(throws: (any Error).self) {
                try await tool.preflight(
                    Fixture.invocation(
                        "scratch_fetch", arguments.mapValues(AgentJSONValue.string)
                    ))
            }
        }
        #expect(await loaded.count == 0)
    }

    /// An empty representation means extraction failed, not that the page is empty.
    @Test
    func fetchRefusesToStageAnEmptyExtraction() async throws {
        let workspace = Fixture.workspace()
        let tool = try #require(
            Fixture.scratchTools(workspace: workspace, web: Fixture.web(markdown: ""))
                .first { $0.descriptor.name == "scratch_fetch" }
        )

        await #expect(throws: (any Error).self) {
            try await tool.execute(
                Fixture.invocation(
                    "scratch_fetch",
                    [
                        "url": .string("https://example.com/js-only"),
                        "scratch_path": .string("empty.md"),
                    ]),
                context: Fixture.context()
            )
        }
        #expect(try await workspace.usage().entries == 0)
    }
}

/// Counts calls from a `@Sendable` closure without a data race.
private actor Counter {
    private(set) var count = 0
    func increment() { count += 1 }
}

// MARK: - Fixtures

private enum Fixture {
    static func scratchTools(
        workspace: AgentScratchWorkspace,
        connections: AgentConnectionPool? = nil,
        authentication: AgentSSHAuthenticationRegistry? = nil,
        web: ScrubberWebClient? = nil
    ) -> [AnyAgentTool] {
        var tools = [
            AnyAgentTool(ScratchListTool(workspace: workspace)),
            AnyAgentTool(ScratchReadTool(workspace: workspace)),
            AnyAgentTool(ScratchSearchTool(workspace: workspace)),
            AnyAgentTool(ScratchWriteTool(workspace: workspace)),
            AnyAgentTool(ScratchReplaceTool(workspace: workspace)),
            AnyAgentTool(ScratchCopyTool(workspace: workspace)),
            AnyAgentTool(ScratchMoveTool(workspace: workspace)),
            AnyAgentTool(ScratchDiffTool(workspace: workspace)),
            AnyAgentTool(ScratchDeleteTool(workspace: workspace)),
        ]
        if let connections, let authentication {
            tools += [
                AnyAgentTool(
                    ScratchPullTool(
                        workspace: workspace, pool: connections, authentication: authentication
                    )),
                AnyAgentTool(
                    ScratchPushTool(
                        workspace: workspace, pool: connections, authentication: authentication
                    )),
            ]
        }
        if let web { tools.append(AnyAgentTool(ScratchFetchTool(workspace: workspace, web: web))) }
        return tools
    }

    @MainActor
    static func builtInTools(
        hosts: AgentHostResolver, connections: AgentConnectionPool
    ) -> [AnyAgentTool] {
        // A fetcher but no workspace: the point of every caller is that the
        // scratch tools are absent while `fetch` is not.
        AgentToolCatalog.registry(
            builtIn: .init(web: web()),
            additional: TermindAgentTools.tools(
                in: .init(
                    hosts: hosts, metrics: TestMetricsReader(), connections: connections
                ))
        ).registeredTools
    }

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
            openConnection: { _ in StubTransferSSHConnection(client: client) },
            openSFTP: { _ in client },
            sweepInterval: nil
        )
    }

    static func web(markdown: String = "# Example") -> ScrubberWebClient {
        ScrubberWebClient(
            document: { url in
                AgentWebDocument(
                    title: "Example", url: url, markdown: markdown,
                    original: "<html><body>raw-marker</body></html>"
                )
            },
            search: { _, _ in [] }
        )
    }

    @MainActor
    static func authentication() -> AgentSSHAuthenticationRegistry {
        AgentSSHAuthenticationRegistry(
            resolver: AgentHostResolver(store: HostLibraryModel())
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

    static func request(
        approvalPolicy: AgentToolDescriptor.ApprovalPolicy
    ) -> AgentApprovalRequest {
        AgentApprovalRequest(
            invocation: invocation("t", [:]),
            descriptor: AgentToolDescriptor(
                name: "t", summary: "t",
                inputSchema: .object(["type": .string("object")]),
                target: .local, approvalPolicy: approvalPolicy
            ),
            userIntent: "do the thing"
        )
    }
}

private actor CountingGuardianReviewer: GuardianReviewing {
    private(set) var count = 0

    func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision {
        count += 1
        return GuardianDecision(
            verdict: .approve, risk: .low, userAuthorization: .high, reason: "fine"
        )
    }
}

private actor StubTransferSSHConnection: SSHConnectionProtocol {
    let client: StubTransferSFTPClient

    init(client: StubTransferSFTPClient) { self.client = client }

    func connect(using configuration: SSHConnectionConfiguration) async throws {}
    func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?, timeout: TimeInterval,
        outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        throw AgentToolError.invalidArguments("Unexpected exec in scratch transfer test")
    }
    func openSFTPChannel() async throws -> any SFTPChannelProtocol { client }
    func disconnect() async {}
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
