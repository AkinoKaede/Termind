import AgentKit
import Foundation
import SQLite3
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct HermesMemoryTests {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appending(path: "memory-test-\(UUID())") }

    private func messageIDs(in result: AgentJSONValue) throws -> [UUID] {
        let rows = try #require(result.objectValue?["messages"]?.arrayValue)
        return try rows.map { row in
            let text = try #require(row.objectValue?["message_id"]?.stringValue)
            return try #require(UUID(uuidString: text))
        }
    }

    private func memoryContents(in result: AgentJSONValue) throws -> [String] {
        let entries = try #require(result.objectValue?["entries"]?.arrayValue)
        return try entries.map { try #require($0.objectValue?["content"]?.stringValue) }
    }

    @Test func disabledMemoryDoesNotCreateFiles() async throws {
        let url = directory()
        let model = MemoryModel(storage: GRDBMemoryStore(directory: url))
        await model.refresh()
        #expect(await model.session(UUID()) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func memorySurvivesReopeningWithoutFrozenSnapshot() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        _ = try await store.applyMemory([.init(action: .add, target: .user, content: "Likes concise replies")])
        _ = try await store.applyMemory([
            .init(action: .replace, target: .user, content: "Likes detailed replies", oldText: "concise")
        ])
        try await store.close()
        let reopened = GRDBMemoryStore(directory: url)
        #expect(try await reopened.memoryState().text(.user) == "Likes detailed replies")
        #expect(try await reopened.searchMemories(.init(query: "detailed")).encodedString.contains("detailed"))
        #expect(try await !reopened.searchMemories(.init(query: "concise")).encodedString.contains("concise"))
        try await reopened.close()
    }

    @Test func v1SnapshotMigrationKeepsEntriesAndDropsFrozenCopies() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let path = url.appending(path: "memory.sqlite").path
        var raw: OpaquePointer?
        #expect(sqlite3_open(path, &raw) == SQLITE_OK)
        let legacy = AgentMemoryState(entries: [.init(target: .user, content: "Keep this preference")])
        let hex = try JSONEncoder().encode(legacy).map { String(format: "%02x", $0) }.joined()
        let sql = """
            CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES ('hermes-v1');
            CREATE TABLE memory_state (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL);
            INSERT INTO memory_state VALUES (1,X'\(hex)');
            CREATE TABLE snapshots (conversation_id TEXT PRIMARY KEY, content TEXT NOT NULL);
            INSERT INTO snapshots VALUES ('legacy','Frozen private copy');
            CREATE TABLE reviews (conversation_id TEXT PRIMARY KEY, message_id TEXT NOT NULL);
            CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, modified REAL NOT NULL);
            CREATE TABLE messages (id TEXT NOT NULL, session_id TEXT NOT NULL, position INTEGER NOT NULL,
                role TEXT NOT NULL, content TEXT NOT NULL, created REAL NOT NULL,
                PRIMARY KEY(session_id, id));
            CREATE VIRTUAL TABLE message_fts USING fts5(content, content='messages', content_rowid='rowid', tokenize='trigram');
            CREATE INDEX messages_session_position ON messages(session_id, position);
            """
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(raw) == SQLITE_OK)
        let store = GRDBMemoryStore(directory: url)
        #expect(try await store.memoryState().text(.user) == "Keep this preference")
        try await store.close()
        #expect(sqlite3_open(path, &raw) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(
            sqlite3_prepare_v2(
                raw, "SELECT count(*) FROM sqlite_master WHERE name='snapshots'", -1,
                &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int(statement, 0) == 0)
        sqlite3_finalize(statement)
        #expect(sqlite3_close(raw) == SQLITE_OK)
    }

    @Test func editingPreservesSeparateMemoryEntries() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let state = try await store.replaceTarget(.memory, text: "First fact\n§\nSecond fact")
        #expect(state.entries.count == 2)
        let updated = try await store.applyMemory([.init(action: .remove, target: .memory, oldText: "First")])
        #expect(updated.text(.memory) == "Second fact")
        try await store.close()
    }

    @Test func dateCommentsUseUTCAndNeverBecomeMemoryContent() throws {
        let created = Date(timeIntervalSince1970: 1_779_923_400)
        let referenced = Date(timeIntervalSince1970: 1_779_930_600)
        let entry = AgentMemoryEntry(target: .memory, content: "Keep this fact", createdAt: created)
        let state = AgentMemoryState(entries: [entry])
        let text = MemoryDateAnnotations.text(
            for: .memory, in: state, references: [entry.id: referenced])
        #expect(text == "Keep this fact <!-- created=2026-05-27, last=2026-05-28 -->")
        #expect(try MemoryDateAnnotations.content(from: text) == "Keep this fact")
        #expect(try MemoryDateAnnotations.content(from: "Keep this fact") == "Keep this fact")
        #expect(
            try MemoryDateAnnotations.content(from: "Remember <!-- ordinary comment -->")
                == "Remember <!-- ordinary comment -->")
        #expect(MemoryDateAnnotations.draftUsage(text).characters == "Keep this fact".count)
        #expect(MemoryDateAnnotations.document(state, references: [entry.id: referenced]).contains(text))
        #expect(throws: (any Error).self) {
            try MemoryDateAnnotations.content(from: "Keep this fact <!-- creatd=2026-05-27, last=2026-05-28 -->")
        }
        #expect(throws: (any Error).self) {
            try MemoryDateAnnotations.content(from: "Keep this fact <!-- created=2026-05-27, last=2026-05-28")
        }
    }

    @Test func searchTouchesOnlyReturnedEntriesWithoutInvalidatingReview() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let original = try await store.applyMemory([
            .init(action: .add, target: .memory, content: "Project Atlas uses pnpm"),
            .init(action: .add, target: .memory, content: "Project Borealis uses npm"),
        ])
        let atlas = try #require(original.entries.first { $0.content.contains("Atlas") })
        let borealis = try #require(original.entries.first { $0.content.contains("Borealis") })
        let model = MemoryModel(storage: store)
        await model.setEnabled(true)
        let session = try #require(await model.session(UUID()))
        let misses = try await session.access.searchMemories(.init(query: "nothing matches"))
        #expect(try memoryContents(in: misses).isEmpty)
        #expect(try await store.memoryReferenceDates().isEmpty)
        let result = try await session.access.searchMemories(.init(query: "Atlas"))
        #expect(try memoryContents(in: result) == ["Project Atlas uses pnpm"])
        #expect(model.referenceDates[atlas.id] != nil)
        #expect(model.referenceDates[borealis.id] == nil)
        let storedDates = try await store.memoryReferenceDates()
        #expect(storedDates.count == 1)
        #expect(storedDates[atlas.id] != nil)
        let reviewed = try await store.applyReview(
            [.init(action: .add, target: .user, content: "Prefers short answers")],
            expected: original, messageID: UUID(), conversationID: UUID(), reviewedActivityIDs: [])
        #expect(reviewed != nil)
        let reviewedDates = try await store.memoryReferenceDates()
        #expect(reviewedDates[atlas.id] != nil)
        try await store.close()
        let reopened = GRDBMemoryStore(directory: url)
        let reopenedDates = try await reopened.memoryReferenceDates()
        #expect(reopenedDates[atlas.id] != nil)
        #expect(reopenedDates[borealis.id] == nil)
        try await reopened.close()
    }

    @Test func editorIgnoresDateChangesAndPreservesMatchingEntryIdentities() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let original = try await store.applyMemory([
            .init(action: .add, target: .memory, content: "First fact"),
            .init(action: .add, target: .memory, content: "Second fact"),
        ])
        let first = original.entries[0]
        let second = original.entries[1]
        let reference = Date(timeIntervalSince1970: ceil(first.createdAt.timeIntervalSince1970) + 10)
        try await store.recordMemoryReferences([first.id], at: reference)
        let initialDates = try await store.memoryReferenceDates()
        #expect(initialDates.count == 1)
        #expect(initialDates[first.id] != nil)
        let edited = try await store.replaceTarget(
            .memory,
            text: "First fact revised\n§\nSecond fact <!-- created=1900-01-01, last=1900-01-01 -->")
        #expect(edited.entries.map(\.content) == ["First fact revised", "Second fact"])
        #expect(edited.entries.map(\.id) == [first.id, second.id])
        #expect(edited.entries[0].createdAt == first.createdAt)
        #expect(edited.entries[1].createdAt == second.createdAt)
        let editedDates = try await store.memoryReferenceDates()
        #expect(editedDates[first.id] == reference)
        await #expect(throws: (any Error).self) {
            try await store.replaceTarget(.memory, text: "First fact revised <!-- created=oops")
        }
        #expect(try await store.memoryState() == edited)
        let withoutComment = try await store.replaceTarget(.memory, text: "First fact revised")
        #expect(withoutComment.entries.map(\.id) == [first.id])
        let remainingDates = try await store.memoryReferenceDates()
        #expect(remainingDates[second.id] == nil)
        try await store.close()
    }

    @Test func ambiguousEditDoesNotAssignAnOldDateToANewEntry() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let original = try await store.applyMemory([
            .init(action: .add, target: .memory, content: "First fact"),
            .init(action: .add, target: .memory, content: "Second fact"),
        ])
        try await store.recordMemoryReferences([original.entries[0].id], at: .now)
        let updated = try await store.replaceTarget(.memory, text: "New fact")
        #expect(updated.entries.count == 1)
        #expect(!original.entries.map(\.id).contains(updated.entries[0].id))
        #expect(try await store.memoryReferenceDates().isEmpty)
        try await store.close()
    }

    @Test func staleBackgroundReviewCannotOverwriteForegroundChanges() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let state = try await store.memoryState()
        _ = try await store.applyMemory([.init(action: .add, target: .user, content: "New preference")])
        let id = UUID()
        let messageID = UUID()
        let result = try await store.applyReview(
            [.init(action: .add, target: .user, content: "Old assumption")], expected: state,
            messageID: messageID, conversationID: id, reviewedActivityIDs: [])
        #expect(result == nil)
        #expect(try await store.lastReviewedMessage(id) == nil)
        try await store.close()
    }

    @Test func activityThresholdsReviewOneShortWindowAndReplayIsDeduplicated() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let conversationID = UUID()
        var messages: [AgentTranscriptMessage] = []
        for index in 0..<10 {
            messages.append(.init(role: .user, text: "Request \(index)"))
            messages.append(.init(role: .assistant, text: "Done \(index)"))
        }
        let tools = (0..<14).map { _ in
            MemoryLearningEvent(id: UUID(), sourceMessageID: messages[1].id, kind: .tool)
        }
        let reviewer = CountingMemoryReviewModel()
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: messages.prefix(18).filter { $0.role == .user }.map(\.id),
            toolInvocations: tools, messages: Array(messages.prefix(18)), model: reviewer)
        #expect(await reviewer.count == 0)
        #expect(try await store.learningProgress(conversationID).turns == 9)
        #expect(try await store.learningProgress(conversationID).tools == 14)
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [messages[18].id], toolInvocations: [],
            messages: messages, model: reviewer)
        try await waitUntil {
            let count = await reviewer.count
            let turns = try? await store.learningProgress(conversationID).turns
            return count == 1 && turns == 0
        }
        #expect(await reviewer.count == 1)
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [messages[18].id], toolInvocations: tools,
            messages: messages, model: reviewer)
        #expect(try await store.learningProgress(conversationID).turns == 0)
        #expect(try await store.learningProgress(conversationID).tools == 0)
        #expect(await reviewer.count == 1)

        let moreTools = (0..<15).map { _ in
            MemoryLearningEvent(id: UUID(), sourceMessageID: messages[19].id, kind: .tool)
        }
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [], toolInvocations: Array(moreTools.prefix(14)),
            messages: messages, model: reviewer)
        #expect(await reviewer.count == 1)
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [], toolInvocations: [moreTools[14]],
            messages: messages, model: reviewer)
        try await waitUntil {
            let count = await reviewer.count
            let tools = try? await store.learningProgress(conversationID).tools
            return count == 2 && tools == 0
        }
        #expect(await reviewer.count == 2)
    }

    @Test func reviewPreservesActivityAddedWhileModelIsWorking() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let conversationID = UUID()
        let first = (0..<10).map { AgentTranscriptMessage(role: .user, text: "Question \($0)") }
        let reviewer = BlockingMemoryReviewModel()
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: first.map(\.id),
            toolInvocations: [], messages: first, model: reviewer)
        await reviewer.waitUntilEntered()
        let later = AgentTranscriptMessage(role: .user, text: "Later request")
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [later.id],
            toolInvocations: [], messages: first + [later], model: reviewer)
        await reviewer.release()
        try await waitUntil { (try? await store.learningProgress(conversationID).turns) == 1 }
        #expect(try await store.learningProgress(conversationID).turns == 1)
    }

    @Test func correctionCandidatesIncludeChineseAndEnglishCommandsButExcludeAcknowledgments() {
        #expect(MemoryModel.looksLikeCorrection("No, use yarn instead"))
        #expect(MemoryModel.looksLikeCorrection("不要 npm，用 yarn"))
        #expect(!MemoryModel.looksLikeCorrection("Actually looks great"))
        #expect(!MemoryModel.looksLikeCorrection("没关系，不是问题"))
    }

    @Test func consecutiveCorrectionsReplaceScopedMemoryAndDeduplicateMessages() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        _ = try await store.applyMemory([
            .init(action: .add, target: .memory, content: "For project A, use npm")
        ])
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let conversationID = UUID()
        let context = AgentTranscriptMessage(role: .user, text: "For project A, use npm")
        let first = AgentTranscriptMessage(
            role: .user, text: "No, use yarn instead for project A",
            authoredText: "No, use yarn instead for project A")
        let second = AgentTranscriptMessage(
            role: .user, text: "不要 yarn，用 pnpm，在项目 A",
            authoredText: "不要 yarn，用 pnpm，在项目 A")
        let reviewer = SequencedMemoryReviewModel(replies: [
            #"{"operations":[{"action":"replace","target":"memory","old_text":"npm","content":"For project A, use yarn"}]}"#,
            #"{"operations":[{"action":"replace","target":"memory","old_text":"yarn","content":"For project A, use pnpm"}]}"#,
        ])
        memory.considerCorrection(
            conversationID: conversationID, message: first,
            context: [context, first], model: reviewer)
        memory.considerCorrection(
            conversationID: conversationID, message: second,
            context: [context, first, second], model: reviewer)
        try await waitUntil { (try? await store.memoryState().text(.memory)) == "For project A, use pnpm" }
        #expect(try await store.correctionWasReviewed(first.id, conversationID: conversationID))
        #expect(try await store.correctionWasReviewed(second.id, conversationID: conversationID))
        memory.considerCorrection(
            conversationID: conversationID, message: first,
            context: [context, first], model: reviewer)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reviewer.count == 2)
    }

    @Test func failedOlderCorrectionCannotRetryAfterNewerCorrectionSucceeds() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        _ = try await store.applyMemory([
            .init(action: .add, target: .memory, content: "For project A, use npm")
        ])
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let conversationID = UUID()
        let first = AgentTranscriptMessage(
            role: .user, text: "No, use yarn instead", authoredText: "No, use yarn instead")
        let second = AgentTranscriptMessage(
            role: .user, text: "No, use pnpm instead", authoredText: "No, use pnpm instead")
        let reviewer = FailingFirstMemoryReviewModel()
        memory.considerCorrection(conversationID: conversationID, message: first, context: [first], model: reviewer)
        memory.considerCorrection(conversationID: conversationID, message: second, context: [second], model: reviewer)
        try await waitUntil { (try? await store.memoryState().text(.memory)) == "For project A, use pnpm" }
        #expect(await reviewer.count == 2)
        memory.considerCorrection(conversationID: conversationID, message: first, context: [first], model: reviewer)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await reviewer.count == 2)
        #expect(try await store.memoryState().text(.memory) == "For project A, use pnpm")
    }

    @Test func oldLearningTokenCannotWriteAfterDisableAndReenable() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let old = try #require(await memory.session(UUID()))
        let token = try #require(memory.learningToken(for: old.context))
        await memory.setEnabled(false)
        await memory.setEnabled(true)
        let message = AgentTranscriptMessage(role: .user, text: "Old run")
        let reviewer = CountingMemoryReviewModel()
        let conversationID = UUID()
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [message.id],
            toolInvocations: [], messages: [message], model: reviewer,
            sessionToken: token)
        #expect(try await store.learningProgress(conversationID).turns == 0)
        #expect(await reviewer.count == 0)
        #expect(memory.learningToken(for: old.context) == nil)
    }

    @Test func editingHistoryRevokesAnInFlightCorrection() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let history = InMemoryAgentRunRepository()
        let repository = MemoryIndexedAgentRepository(base: history, memory: memory)
        let conversationID = UUID()
        let message = AgentTranscriptMessage(
            role: .user, text: "No, use yarn instead",
            authoredText: "No, use yarn instead")
        try await repository.createConversation(
            .init(
                id: conversationID, messages: [message], lastRunState: .completed))
        let reviewer = BlockingMemoryReviewModel()
        memory.considerCorrection(
            conversationID: conversationID, message: message,
            context: [message], model: reviewer)
        await reviewer.waitUntilEntered()
        let replacement = AgentTranscriptMessage(role: .user, text: "Use npm for this one task")
        try await repository.truncateConversation(
            conversationID, fromUserMessageID: message.id,
            replacingWith: replacement)
        await reviewer.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await store.memoryState().entries.isEmpty)
        #expect(try await !store.correctionWasReviewed(message.id, conversationID: conversationID))
        let epoch = memory.learningEpoch(for: conversationID)
        memory.invalidateLearning(for: conversationID)
        #expect(memory.learningEpoch(for: conversationID) != epoch)
        let session = try #require(await memory.session(conversationID))
        let token = try #require(memory.learningToken(for: session.context))
        await memory.recordActivity(
            conversationID: conversationID, userMessageIDs: [message.id],
            toolInvocations: [], messages: [message], model: reviewer,
            sessionToken: token, historyEpoch: epoch)
        #expect(try await store.learningProgress(conversationID).turns == 0)
    }

    @Test func historyEditWhileLoadingProgressDoesNotRecordOrReviewOldMessages() async throws {
        let store = MemoryLifecycleStore(blocksLearningProgress: true)
        let memory = MemoryModel(storage: store)
        await memory.setEnabled(true)
        let conversationID = UUID()
        let messages = (0..<10).map { AgentTranscriptMessage(role: .user, text: "Question \($0)") }
        let reviewer = CountingMemoryReviewModel()
        let task = Task {
            await memory.recordActivity(
                conversationID: conversationID, userMessageIDs: messages.map(\.id),
                toolInvocations: [], messages: messages, model: reviewer)
        }
        await store.waitUntilLearningProgressEntered()
        memory.invalidateLearning(for: conversationID)
        await store.releaseLearningProgress()
        await task.value
        #expect(await store.learningProgress(conversationID).turns == 0)
        #expect(await reviewer.count == 0)
    }

    @Test func completedToolBatchIsCountedBeforeRunFinishes() {
        let conversation = ConversationModel()
        let runID = UUID()
        var counts: [Int] = []
        conversation.memoryToolBatchFinished = { tools, _ in counts.append(tools.count) }
        conversation.handle(.runStarted(.init(id: runID, state: .running, startedAt: .now)))
        for index in 0..<15 {
            let call = AgentToolCall(id: "call-\(index)", name: "example", arguments: .object([:]))
            let invocation = AgentToolInvocation(runID: runID, call: call)
            conversation.handle(.toolStarted(invocation))
            conversation.handle(.toolFinished(invocation, AgentToolResult(callID: call.id, content: "done")))
        }
        conversation.handle(.turnStarted(index: 1))
        #expect(counts == [15])
    }

    @Test func memoryToolsDoNotCountTowardLearningThreshold() {
        let conversation = ConversationModel()
        let runID = UUID()
        var batches: [[MemoryLearningEvent]] = []
        conversation.memoryToolBatchFinished = { tools, _ in batches.append(tools) }
        conversation.handle(.runStarted(.init(id: runID, state: .running, startedAt: .now)))
        for name in ["memory", "memory_search", "session_search", "example"] {
            let call = AgentToolCall(id: "call-\(name)", name: name, arguments: .object([:]))
            let invocation = AgentToolInvocation(runID: runID, call: call)
            conversation.handle(.toolStarted(invocation))
            conversation.handle(.toolFinished(invocation, AgentToolResult(callID: call.id, content: "done")))
        }
        conversation.handle(.turnStarted(index: 1))
        #expect(batches.count == 1)
        #expect(batches.first?.count == 1)
    }

    @Test func searchSupportsChineseAndRemovesDeletedHistory() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let conversation = StoredAgentConversation(
            id: UUID(),
            messages: [
                .init(role: .user, text: "部署服务器需要测试"), .init(role: .assistant, text: "Done"),
            ], lastRunState: .completed)
        try await store.replaceHistory([conversation])
        #expect(try await store.searchSessions(.init(query: "服务器")).encodedString.contains("部署"))
        #expect(try await store.searchSessions(.init(query: "部署")).encodedString.contains("服务器"))
        #expect(
            try await store.searchSessions(.init(conversationID: conversation.id, offset: 1)).encodedString.contains(
                "Done"))
        try await store.replaceHistory([])
        #expect(try await !store.searchSessions(.init(query: "服务器")).encodedString.contains("部署"))
        try await store.close()
    }

    @Test func sessionSearchFallsBackToPartialEnglishTermsAndIgnoresPunctuation() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let deploy = AgentTranscriptMessage(role: .user, text: "Deploy the staging server")
        let backup = AgentTranscriptMessage(role: .user, text: "Backup the database")
        try await store.replaceHistory([
            .init(id: UUID(), messages: [deploy], lastRunState: .completed),
            .init(id: UUID(), messages: [backup], lastRunState: .completed),
        ])

        let plain = try await store.searchSessions(.init(query: "deploy backup"))
        let punctuated = try await store.searchSessions(.init(query: "deploy, backup?"))
        #expect(try Set(messageIDs(in: plain)) == [deploy.id, backup.id])
        #expect(try Set(messageIDs(in: punctuated)) == [deploy.id, backup.id])
        #expect(try await messageIDs(in: store.searchSessions(.init(query: "quantum octopus"))).isEmpty)
        try await store.close()
    }

    @Test func sessionSearchFindsChineseQuestionsAndShortTermsWithinScope() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let matchingID = UUID()
        let unrelatedID = UUID()
        let matching = AgentTranscriptMessage(role: .user, text: "服务器部署失败，请检查端口")
        let unrelated = AgentTranscriptMessage(role: .user, text: "服务器监控正常")
        try await store.replaceHistory([
            .init(id: matchingID, messages: [matching], lastRunState: .completed),
            .init(id: unrelatedID, messages: [unrelated], lastRunState: .completed),
        ])

        #expect(try await messageIDs(in: store.searchSessions(.init(query: "服务器部署失败怎么办"))) == [matching.id])
        #expect(try await messageIDs(in: store.searchSessions(.init(query: "部署"))) == [matching.id])
        #expect(try await messageIDs(in: store.searchSessions(.init(query: "服务器怎么部署？"))) == [matching.id])
        #expect(try await messageIDs(in: store.searchSessions(.init(query: "部署", conversationID: unrelatedID))).isEmpty)
        #expect(
            try await messageIDs(in: store.searchSessions(.init(query: "部署", conversationID: matchingID))) == [
                matching.id
            ])
        #expect(try await messageIDs(in: store.searchSessions(.init(conversationID: matchingID))) == [matching.id])
        try await store.close()
    }

    @Test func sessionSearchKeepsStrictPagesAndRanksMoreRelevantShortTermMatches() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let strict = AgentTranscriptMessage(role: .user, text: "deploy backup")
        let partial = AgentTranscriptMessage(role: .user, text: "deploy only")
        let relevantChinese = AgentTranscriptMessage(role: .user, text: "服务器部署记录")
        let recentChinese = AgentTranscriptMessage(role: .user, text: "服务器状态正常")
        try await store.replaceHistory([
            .init(id: UUID(), messages: [strict], lastRunState: .completed, metadata: .init(updatedAt: old)),
            .init(id: UUID(), messages: [partial], lastRunState: .completed, metadata: .init(updatedAt: recent)),
            .init(id: UUID(), messages: [relevantChinese], lastRunState: .completed, metadata: .init(updatedAt: old)),
            .init(id: UUID(), messages: [recentChinese], lastRunState: .completed, metadata: .init(updatedAt: recent)),
        ])

        let first = try await store.searchSessions(.init(query: "deploy backup", limit: 1))
        #expect(try messageIDs(in: first) == [strict.id])
        #expect(first.objectValue?["next_offset"] == .null)
        #expect(
            try await messageIDs(in: store.searchSessions(.init(query: "deploy backup", offset: 1, limit: 1))).isEmpty)

        let chineseQuery = "服务器 故障 部署"
        let chineseFirst = try await store.searchSessions(.init(query: chineseQuery, limit: 1))
        let chineseSecond = try await store.searchSessions(.init(query: chineseQuery, offset: 1, limit: 1))
        #expect(try messageIDs(in: chineseFirst) == [relevantChinese.id])
        #expect(try messageIDs(in: chineseSecond) == [recentChinese.id])
        #expect(chineseFirst.objectValue?["next_offset"]?.integerValue == 1)
        #expect(
            try await messageIDs(in: store.searchSessions(.init(query: chineseQuery, limit: 1))) == [relevantChinese.id]
        )
        try await store.close()
    }

    @Test func sessionSearchUsesBM25BeforeConversationRecencyAndPreservesAccents() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let relevant = AgentTranscriptMessage(role: .user, text: "deploy backup deploy backup deploy backup")
        let recent = AgentTranscriptMessage(
            role: .user, text: "deploy backup with many unrelated words about weather music images and travel")
        let accented = AgentTranscriptMessage(role: .user, text: "Café deployment notes")
        try await store.replaceHistory([
            .init(
                id: UUID(), messages: [relevant], lastRunState: .completed,
                metadata: .init(updatedAt: Date(timeIntervalSince1970: 100))),
            .init(
                id: UUID(), messages: [recent], lastRunState: .completed,
                metadata: .init(updatedAt: Date(timeIntervalSince1970: 200))),
            .init(id: UUID(), messages: [accented], lastRunState: .completed),
        ])

        #expect(try await messageIDs(in: store.searchSessions(.init(query: "deploy backup"))).first == relevant.id)
        #expect(try await messageIDs(in: store.searchSessions(.init(query: "Café"))) == [accented.id])
        #expect(try await messageIDs(in: store.searchSessions(.init(query: "cafe"))).isEmpty)
        try await store.close()
    }

    @Test func sessionSearchMatchesUppercaseAccentsWithShortTermsThroughTool() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let matching = AgentTranscriptMessage(role: .user, text: "CAFÉ go live checklist")
        let plain = AgentTranscriptMessage(role: .user, text: "CAFE go live checklist")
        try await store.replaceHistory([
            .init(id: UUID(), messages: [matching], lastRunState: .completed),
            .init(id: UUID(), messages: [plain], lastRunState: .completed),
        ])

        let tool = SessionSearchTool(store: store)
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "accent-search", name: "session_search",
                arguments: .object(["query": .string("café go")])))
        let context = AgentToolExecutionContext(
            runID: invocation.runID, userIntent: "Find the café checklist", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:], authorize: { _ in .allow })
        let result = try await tool.execute(invocation, context: context)
        #expect(result.callID == invocation.call.id)
        #expect(result.content.contains(matching.id.uuidString))
        #expect(!result.content.contains(plain.id.uuidString))
        try await store.close()
    }

    @Test func defaultMemorySearchFindsStoredQuestionAndPartialMatches() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        _ = try await store.applyMemory([
            .init(action: .add, target: .memory, content: "服务器部署失败时检查防火墙"),
            .init(action: .add, target: .memory, content: "Project Atlas uses the staging server"),
            .init(action: .add, target: .user, content: "Backup jobs run every night"),
        ])

        let chinese = try await store.searchMemories(.init(query: "服务器部署失败怎么办"))
        let punctuated = try await store.searchMemories(.init(query: "Atlas, staging?"))
        let broad = try await store.searchMemories(.init(query: "Atlas backup"))
        #expect(try memoryContents(in: chinese).contains("服务器部署失败时检查防火墙"))
        #expect(try memoryContents(in: punctuated).contains("Project Atlas uses the staging server"))
        #expect(
            try Set(memoryContents(in: broad)) == [
                "Project Atlas uses the staging server", "Backup jobs run every night",
            ])

        let tool = MemorySearchTool(store: store)
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "memory-search", name: "memory_search",
                arguments: .object(["query": .string("Atlas backup"), "target": .string("memory")])))
        let context = AgentToolExecutionContext(
            runID: invocation.runID, userIntent: "Find saved project memory", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:], authorize: { _ in .allow })
        let result = try await tool.execute(invocation, context: context)
        #expect(result.callID == invocation.call.id)
        #expect(result.content.contains("Project Atlas uses the staging server"))
        #expect(!result.content.contains("Backup jobs run every night"))
        try await store.close()
    }

    @Test func destroyRevokesActiveAccessAndReenableCanBackfillOldHistory() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = GRDBMemoryStore(directory: url)
        let model = MemoryModel(storage: store)
        let history = InMemoryAgentRunRepository()
        let conversationID = UUID()
        await history.save(
            .init(
                conversationID: conversationID, state: .completed, permissionMode: .askForApproval,
                messages: [.init(role: .user, text: "Historical zebra fact")]))
        model.attachHistory(history)
        await model.setEnabled(true)
        let session = try #require(await model.session(conversationID))
        _ = try await session.access.applyMemory([.init(action: .add, target: .memory, content: "Temporary memory")])
        await model.destroy()
        #expect(!model.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: (any Error).self) {
            try await session.access.applyMemory([.init(action: .add, target: .memory, content: "Late write")])
        }
        #expect(session.context.transform(.init(systemPrompt: "Base", messages: [], tools: [])).systemPrompt == "Base")
        await model.destroy()
        await model.setEnabled(true)
        let fresh = try #require(await model.session(conversationID))
        #expect(try await fresh.access.memoryState().entries.isEmpty)
        #expect(try await fresh.access.searchSessions(.init(query: "zebra")).encodedString.contains("Historical"))
        await model.setEnabled(false)
    }

    @Test func suspendedMemoryDefersTerminalHistoryIndexUntilResume() async throws {
        let store = MemoryLifecycleStore()
        let model = MemoryModel(storage: store)
        let history = InMemoryAgentRunRepository()
        let repository = MemoryIndexedAgentRepository(base: history, memory: model)
        await model.setEnabled(true)
        await store.waitForHistoryReplacementCount(1)
        await waitForIndexingToFinish(model)

        model.suspend()
        let conversationID = UUID()
        try await repository.save(
            .init(
                conversationID: conversationID, state: .completed, permissionMode: .askForApproval,
                messages: [.init(role: .user, text: "Saved after suspension")]))

        #expect(!model.isIndexing)
        #expect(await store.historyReplacementCount == 1)

        model.resume()
        await store.waitForHistoryReplacementCount(2)
        await waitForIndexingToFinish(model)
        #expect(await store.lastHistory?.contains(where: { $0.id == conversationID }) == true)
    }

    @Test func suspendInvalidatesExistingMemoryAccessAcrossResume() async throws {
        let store = MemoryLifecycleStore()
        let model = MemoryModel(storage: store)
        await model.setEnabled(true)
        let conversationID = UUID()
        let original = try #require(await model.session(conversationID))

        model.suspend()
        #expect(await model.session(conversationID) == nil)
        model.resume()

        await #expect(throws: CancellationError.self) { try await original.access.memoryState() }
        let resumed = try #require(await model.session(conversationID))
        _ = try await resumed.access.memoryState()
    }

    @Test func resumeReconcilesACommittedWriteFromTheSuspendedGeneration() async throws {
        let store = MemoryLifecycleStore(blocksApply: true)
        let model = MemoryModel(storage: store)
        await model.setEnabled(true)
        let original = try #require(await model.session(UUID()))
        let write = Task {
            try await original.access.applyMemory([
                .init(action: .add, target: .memory, content: "Committed during suspension")
            ])
        }
        await store.waitUntilApplyEntered()

        model.suspend()
        model.resume()
        try await waitUntil { await store.memoryStateCallCount >= 2 }
        await store.releaseApply()

        await #expect(throws: CancellationError.self) { try await write.value }
        try await waitUntil {
            await store.memoryStateCallCount >= 3
                && model.state.text(.memory) == "Committed during suspension"
        }
        await #expect(throws: CancellationError.self) { try await original.access.memoryState() }
    }

    @Test func suspendPreventsStaleReviewFromApplyingAfterResume() async throws {
        let store = MemoryLifecycleStore()
        let model = MemoryModel(storage: store)
        await model.setEnabled(true)
        let reviewModel = BlockingMemoryReviewModel()
        let review = Task {
            await model.review(
                conversationID: UUID(), messages: [.init(role: .user, text: "Remember concise replies")],
                model: reviewModel, wait: true)
        }
        await reviewModel.waitUntilEntered()

        model.suspend()
        model.resume()
        await reviewModel.release()
        await review.value

        #expect(await store.reviewApplyCount == 0)
        #expect(model.state.entries.isEmpty)
    }

    @Test func skillPackagesPersistWithoutChangingLegacySkillRows() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let persistence = SkillPersistence(context: container.mainContext)
        let skill = AgentSkill(
            name: "example", summary: "Example", body: "Example",
            package: .init(frontmatter: "metadata:\n  owner: team", files: ["assets/raw": Data([0, 255])]))
        try persistence.save([skill])
        #expect(try persistence.load() == [skill])
        try persistence.save([])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentSkillPackage>()) == 0)
    }

    @Test func olderSyncPayloadCannotDiscardSupportingFiles() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let defaults = UserDefaults(suiteName: "skill-sync-\(UUID())")!
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        let skill = AgentSkill(
            name: "example", summary: "Example", body: "Original",
            package: .init(files: ["references/guide": Data("Keep".utf8)]))
        try store.saveSkills([skill])
        var legacy = skill
        legacy.package = nil
        legacy.body = "Edited on an old client"
        let payload = SettingsRecordPayload.skill(legacy, sortIndex: 0)
        let result = try store.applyRemote([
            SettingsEnvelope(
                key: payload.key,
                version: .init(modifiedAt: .now.addingTimeInterval(60), counter: 1, writerID: UUID()), payload: payload)
        ])
        #expect(result.snapshot.skills.first?.body == legacy.body)
        #expect(result.snapshot.skills.first?.package == skill.package)
        #expect(result.needsUpload.contains(payload.key))
    }

    @Test func skillImporterRejectsSymbolicLinks() throws {
        let url = directory()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appending(path: "original.md")
        try Data("---\nname: example\ndescription: Example\n---\nBody".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: url.appending(path: "SKILL.md"), withDestinationURL: file)
        #expect(throws: (any Error).self) { try SkillImporter.read(url) }
    }

    @Test func failedDestroyStaysDisabledAndStartupRetriesIt() async throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "destroy-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = GRDBMemoryStore(directory: url)
        let failing = FailingDestroyStore(base: base)
        let model = MemoryModel(storage: failing, defaults: defaults)
        await model.setEnabled(true)
        await model.destroy()
        #expect(!model.isEnabled)
        #expect(model.error != nil)
        #expect(defaults.bool(forKey: "hermesMemoryDestroyPending"))
        await model.setEnabled(true)
        #expect(!model.isEnabled)
        let restarted = MemoryModel(storage: base, defaults: defaults)
        for _ in 0..<200 where defaults.bool(forKey: "hermesMemoryDestroyPending") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!restarted.isEnabled)
        #expect(!defaults.bool(forKey: "hermesMemoryDestroyPending"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private actor MemoryLifecycleStore: MemoryPersisting {
    func prepareSession(_ conversationID: UUID) {}
    private var memory = AgentMemoryState()
    private var historyReplacements: [[StoredAgentConversation]] = []
    private let blocksApply: Bool
    private let blocksLearningProgress: Bool
    private var applyEntered = false
    private var applyReleased = false
    private var historyReplacementWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var applyEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var applyReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var learningProgressEntered = false
    private var learningProgressReleased = false
    private var learningProgressEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var learningProgressReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var reviewApplyCount = 0
    private(set) var memoryStateCallCount = 0
    private var progress = MemoryLearningProgress()

    var historyReplacementCount: Int { historyReplacements.count }
    var lastHistory: [StoredAgentConversation]? { historyReplacements.last }

    init(blocksApply: Bool = false, blocksLearningProgress: Bool = false) {
        self.blocksApply = blocksApply
        self.blocksLearningProgress = blocksLearningProgress
    }

    func waitUntilLearningProgressEntered() async {
        if learningProgressEntered { return }
        await withCheckedContinuation { learningProgressEntryWaiters.append($0) }
    }

    func releaseLearningProgress() {
        learningProgressReleased = true
        let waiters = learningProgressReleaseWaiters
        learningProgressReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForHistoryReplacementCount(_ count: Int) async {
        guard historyReplacements.count < count else { return }
        await withCheckedContinuation { historyReplacementWaiters[count, default: []].append($0) }
    }

    func waitUntilApplyEntered() async {
        if applyEntered { return }
        await withCheckedContinuation { applyEntryWaiters.append($0) }
    }

    func releaseApply() {
        applyReleased = true
        let waiters = applyReleaseWaiters
        applyReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func rebuildHistoryIndex() {}
    func memoryReferenceDates() -> [UUID: Date] { [:] }
    func recordMemoryReferences(_ ids: [UUID], at date: Date) {}
    func memoryState() -> AgentMemoryState {
        memoryStateCallCount += 1
        return memory
    }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState {
        if blocksApply {
            applyEntered = true
            let waiters = applyEntryWaiters
            applyEntryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !applyReleased {
                await withCheckedContinuation { applyReleaseWaiters.append($0) }
            }
        }
        memory = try memory.applying(operations)
        return memory
    }
    func replaceHistory(_ conversations: [StoredAgentConversation]) {
        historyReplacements.append(conversations)
        let readyCounts = historyReplacementWaiters.keys.filter { $0 <= historyReplacements.count }
        let waiters = readyCounts.flatMap { historyReplacementWaiters.removeValue(forKey: $0) ?? [] }
        for waiter in waiters { waiter.resume() }
    }
    func searchSessions(_ request: AgentSessionSearchRequest) -> AgentJSONValue { .array([]) }
    func lastReviewedMessage(_ id: UUID) -> UUID? { nil }
    func recordActivity(
        _ id: UUID, sourceMessageID: UUID, kind: MemoryActivityKind,
        conversationID: UUID
    ) -> MemoryLearningProgress {
        progress.events.append(.init(id: id, sourceMessageID: sourceMessageID, kind: kind))
        if kind == .turn { progress.turns += 1 } else { progress.tools += 1 }
        return progress
    }
    func learningProgress(_ id: UUID) async -> MemoryLearningProgress {
        if blocksLearningProgress {
            learningProgressEntered = true
            let waiters = learningProgressEntryWaiters
            learningProgressEntryWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !learningProgressReleased {
                await withCheckedContinuation { learningProgressReleaseWaiters.append($0) }
            }
        }
        return progress
    }
    func correctionWasReviewed(_ messageID: UUID, conversationID: UUID) -> Bool { false }
    func applyCorrection(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState,
        messageID: UUID, conversationID: UUID
    ) throws -> AgentMemoryState? {
        guard memory == expected else { return nil }
        if !operations.isEmpty { memory = try memory.applying(operations) }
        return memory
    }
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID,
        conversationID: UUID, reviewedActivityIDs: [UUID]
    ) throws -> AgentMemoryState? {
        reviewApplyCount += 1
        guard memory == expected else { return nil }
        if !operations.isEmpty { memory = try memory.applying(operations) }
        return memory
    }
    func replaceTarget(_ target: AgentMemoryTarget, text: String) -> AgentMemoryState { memory }
    func close() {}
    func destroy() { memory = .init() }
}

private actor BlockingMemoryReviewModel: AgentModelCompleting {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return [
            .textDelta(#"{"operations":[{"action":"add","target":"user","content":"Likes concise replies"}]}"#),
            .finished(.completed),
        ]
    }
}

private actor CountingMemoryReviewModel: AgentModelCompleting {
    private(set) var count = 0
    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        count += 1
        return [.textDelta(#"{"operations":[]}"#), .finished(.completed)]
    }
}

private actor SequencedMemoryReviewModel: AgentModelCompleting {
    private var replies: [String]
    private(set) var count = 0
    init(replies: [String]) { self.replies = replies }
    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        count += 1
        guard !replies.isEmpty else { throw CancellationError() }
        return [.textDelta(replies.removeFirst()), .finished(.completed)]
    }
}

private actor FailingFirstMemoryReviewModel: AgentModelCompleting {
    private(set) var count = 0
    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        count += 1
        if count == 1 { throw MemoryReviewTestFailure() }
        let result =
            count == 2
            ? #"{"operations":[{"action":"replace","target":"memory","old_text":"npm","content":"For project A, use pnpm"}]}"#
            : #"{"operations":[{"action":"replace","target":"memory","old_text":"pnpm","content":"For project A, use yarn"}]}"#
        return [.textDelta(result), .finished(.completed)]
    }
}

private struct MemoryReviewTestFailure: Error {}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(10), _ condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw MemoryLifecycleTestTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func waitForIndexingToFinish(_ model: MemoryModel) async {
    while model.isIndexing { await Task.yield() }
}

private struct MemoryLifecycleTestTimeout: Error {}

private struct FailingDestroyStore: MemoryPersisting {
    let base: GRDBMemoryStore
    func prepareSession(_ conversationID: UUID) async throws { try await base.prepareSession(conversationID) }
    func rebuildHistoryIndex() async throws { try await base.rebuildHistoryIndex() }
    func memoryState() async throws -> AgentMemoryState { try await base.memoryState() }
    func memoryReferenceDates() async throws -> [UUID: Date] { try await base.memoryReferenceDates() }
    func recordMemoryReferences(_ ids: [UUID], at date: Date) async throws {
        try await base.recordMemoryReferences(ids, at: date)
    }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState {
        try await base.applyMemory(operations)
    }
    func replaceHistory(_ conversations: [StoredAgentConversation]) async throws {
        try await base.replaceHistory(conversations)
    }
    func searchSessions(_ request: AgentSessionSearchRequest) async throws -> AgentJSONValue {
        try await base.searchSessions(request)
    }
    func lastReviewedMessage(_ id: UUID) async throws -> UUID? { try await base.lastReviewedMessage(id) }
    func recordActivity(
        _ id: UUID, sourceMessageID: UUID, kind: MemoryActivityKind,
        conversationID: UUID
    ) async throws -> MemoryLearningProgress {
        try await base.recordActivity(
            id, sourceMessageID: sourceMessageID, kind: kind,
            conversationID: conversationID)
    }
    func learningProgress(_ id: UUID) async throws -> MemoryLearningProgress { try await base.learningProgress(id) }
    func correctionWasReviewed(_ messageID: UUID, conversationID: UUID) async throws -> Bool {
        try await base.correctionWasReviewed(messageID, conversationID: conversationID)
    }
    func applyCorrection(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState,
        messageID: UUID, conversationID: UUID
    ) async throws -> AgentMemoryState? {
        try await base.applyCorrection(
            operations, expected: expected, messageID: messageID,
            conversationID: conversationID)
    }
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID,
        conversationID: UUID, reviewedActivityIDs: [UUID]
    ) async throws -> AgentMemoryState? {
        try await base.applyReview(
            operations, expected: expected, messageID: messageID,
            conversationID: conversationID, reviewedActivityIDs: reviewedActivityIDs)
    }
    func replaceTarget(_ target: AgentMemoryTarget, text: String) async throws -> AgentMemoryState {
        try await base.replaceTarget(target, text: text)
    }
    func close() async throws { try await base.close() }
    func destroy() async throws { throw CocoaError(.fileWriteNoPermission) }
}
