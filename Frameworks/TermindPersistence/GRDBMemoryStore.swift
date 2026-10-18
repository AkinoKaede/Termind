import AgentKit
import Foundation
import GRDB
import TermindApplication

/// A single actor owns the connection and every file in its dedicated directory.
/// Opening is lazy: constructing a disabled feature performs no filesystem work.
public actor GRDBMemoryStore: MemoryPersisting {
    private let directory: URL
    private var queue: DatabaseQueue?
    public init(directory: URL) { self.directory = directory }
    public nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Termind/HermesMemory", directoryHint: .isDirectory)
    }

    private func database() throws -> DatabaseQueue {
        try Task.checkCancellation()
        if let queue { return queue }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            db.add(
                function: DatabaseFunction("termindCaseFold", argumentCount: 1, pure: true) { values in
                    guard let text = String.fromDatabaseValue(values[0]) else { return nil }
                    return text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                })
        }
        let opened = try DatabaseQueue(
            path: directory.appending(path: "memory.sqlite").path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("hermes-v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE memory_state (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL);
                    CREATE TABLE snapshots (conversation_id TEXT PRIMARY KEY, content TEXT NOT NULL);
                    CREATE TABLE reviews (conversation_id TEXT PRIMARY KEY, message_id TEXT NOT NULL);
                    CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, modified REAL NOT NULL);
                    CREATE TABLE messages (id TEXT NOT NULL, session_id TEXT NOT NULL, position INTEGER NOT NULL,
                        role TEXT NOT NULL, content TEXT NOT NULL, created REAL NOT NULL,
                        PRIMARY KEY(session_id, id));
                    CREATE VIRTUAL TABLE message_fts USING fts5(content, content='messages', content_rowid='rowid', tokenize='trigram');
                    CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                        INSERT INTO message_fts(rowid, content) VALUES (new.rowid, new.content); END;
                    CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                        INSERT INTO message_fts(message_fts, rowid, content) VALUES ('delete', old.rowid, old.content); END;
                    CREATE INDEX messages_session_position ON messages(session_id, position);
                    """)
        }
        migrator.registerMigration("hermes-policy-learning-v2") { db in
            try db.execute(sql: "DROP TABLE snapshots")
            try db.execute(
                sql: """
                        CREATE TABLE learning_activity (
                            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                            conversation_id TEXT NOT NULL,
                            event_id TEXT NOT NULL,
                            source_message_id TEXT NOT NULL,
                            kind TEXT NOT NULL,
                            reviewed INTEGER NOT NULL DEFAULT 0,
                            UNIQUE(conversation_id,event_id,kind));
                        CREATE INDEX learning_activity_conversation ON learning_activity(conversation_id,sequence);
                        CREATE TABLE reviewed_corrections (
                            conversation_id TEXT NOT NULL,
                            message_id TEXT NOT NULL,
                            PRIMARY KEY(conversation_id,message_id));
                    """)
        }
        migrator.registerMigration("hermes-reference-dates-v3") { db in
            try db.execute(
                sql: "CREATE TABLE memory_references (entry_id TEXT PRIMARY KEY, last_referenced REAL NOT NULL)")
        }
        try migrator.migrate(opened)
        queue = opened
        return opened
    }

    private nonisolated static func state(_ db: Database) throws -> AgentMemoryState {
        guard let bytes = try Data.fetchOne(db, sql: "SELECT data FROM memory_state WHERE id=1") else { return .init() }
        return try JSONDecoder().decode(AgentMemoryState.self, from: bytes)
    }
    public func prepareSession(_ conversationID: UUID) throws { _ = try database() }
    public func memoryState() throws -> AgentMemoryState { try database().read(Self.state) }
    public func memoryReferenceDates() throws -> [UUID: Date] {
        try database().read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT entry_id,last_referenced FROM memory_references")
            return Dictionary(
                uniqueKeysWithValues: rows.compactMap { row -> (UUID, Date)? in
                    guard let id = UUID(uuidString: row["entry_id"]) else { return nil }
                    return (id, Date(timeIntervalSince1970: row["last_referenced"]))
                })
        }
    }
    public func recordMemoryReferences(_ ids: [UUID], at date: Date) throws {
        guard !ids.isEmpty else { return }
        try database().write { db in
            let valid = Set(try Self.state(db).entries.map(\.id))
            for id in Set(ids) where valid.contains(id) {
                try db.execute(
                    sql: """
                        INSERT INTO memory_references(entry_id,last_referenced) VALUES(?,?)
                        ON CONFLICT(entry_id) DO UPDATE SET last_referenced=MAX(last_referenced,excluded.last_referenced)
                        """,
                    arguments: [id.uuidString, date.timeIntervalSince1970])
            }
        }
    }
    private nonisolated static func save(_ state: AgentMemoryState, in db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO memory_state(id,data) VALUES(1,?)",
            arguments: [try JSONEncoder().encode(state)])
        let valid = Set(state.entries.map { $0.id.uuidString })
        for id in try String.fetchAll(db, sql: "SELECT entry_id FROM memory_references") where !valid.contains(id) {
            try db.execute(sql: "DELETE FROM memory_references WHERE entry_id=?", arguments: [id])
        }
    }
    public func replaceTarget(_ target: AgentMemoryTarget, text: String) throws -> AgentMemoryState {
        try database().write { db in
            var current = try Self.state(db)
            var previous = current.entries.filter { $0.target == target }
            let contents = try text.components(separatedBy: "\n§\n").map(MemoryDateAnnotations.content(from:))
                .filter { !$0.isEmpty }
            var matched: [Int: AgentMemoryEntry] = [:]
            for (index, content) in contents.enumerated() {
                if let oldIndex = previous.firstIndex(where: { $0.content == content }) {
                    matched[index] = previous.remove(at: oldIndex)
                }
            }
            let unmatched = contents.indices.filter { matched[$0] == nil }
            if previous.count == unmatched.count {
                for (index, old) in zip(unmatched, previous) { matched[index] = old }
            }
            current.entries.removeAll { $0.target == target }
            for (index, content) in contents.enumerated() {
                let count = current.entries.count
                current = try current.applying([.init(action: .add, target: target, content: content)])
                if current.entries.count > count, let old = matched[index] {
                    current.entries[current.entries.count - 1].id = old.id
                    current.entries[current.entries.count - 1].createdAt = old.createdAt
                    current.entries[current.entries.count - 1].updatedAt =
                        old.content == content ? old.updatedAt : .now
                }
            }
            try Self.save(current, in: db)
            return current
        }
    }
    public func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID,
        reviewedActivityIDs: [UUID]
    ) throws -> AgentMemoryState? {
        try database().write { db in
            let current = try Self.state(db)
            guard current == expected else { return nil }
            let updated = operations.isEmpty ? current : try current.applying(operations)
            try Self.save(updated, in: db)
            try db.execute(
                sql: "INSERT OR REPLACE INTO reviews VALUES(?,?)",
                arguments: [conversationID.uuidString, messageID.uuidString])
            for id in reviewedActivityIDs {
                try db.execute(
                    sql: "UPDATE learning_activity SET reviewed=1 WHERE conversation_id=? AND event_id=?",
                    arguments: [conversationID.uuidString, id.uuidString])
            }
            return updated
        }
    }
    public func applyMemory(_ operations: [AgentMemoryOperation]) throws -> AgentMemoryState {
        try database().write { db in
            let state = try Self.state(db).applying(operations)
            try Self.save(state, in: db)
            return state
        }
    }
    public func lastReviewedMessage(_ conversationID: UUID) throws -> UUID? {
        try database().read { db in
            try String.fetchOne(
                db, sql: "SELECT message_id FROM reviews WHERE conversation_id=?",
                arguments: [conversationID.uuidString]
            )
            .flatMap(UUID.init(uuidString:))
        }
    }
    public func recordActivity(
        _ id: UUID, sourceMessageID: UUID, kind: MemoryActivityKind,
        conversationID: UUID
    ) throws
        -> MemoryLearningProgress
    {
        try database().write { db in
            try db.execute(
                sql:
                    "INSERT OR IGNORE INTO learning_activity(conversation_id,event_id,source_message_id,kind) VALUES(?,?,?,?)",
                arguments: [
                    conversationID.uuidString, id.uuidString, sourceMessageID.uuidString,
                    kind.rawValue,
                ])
            return try Self.learningProgress(db, conversationID: conversationID)
        }
    }
    public func learningProgress(_ conversationID: UUID) throws -> MemoryLearningProgress {
        try database().read { try Self.learningProgress($0, conversationID: conversationID) }
    }
    private nonisolated static func learningProgress(_ db: Database, conversationID: UUID) throws
        -> MemoryLearningProgress
    {
        let rows = try Row.fetchAll(
            db,
            sql:
                "SELECT event_id,source_message_id,kind FROM learning_activity WHERE conversation_id=? AND reviewed=0 ORDER BY sequence",
            arguments: [conversationID.uuidString])
        let cursor = try String.fetchOne(
            db, sql: "SELECT message_id FROM reviews WHERE conversation_id=?",
            arguments: [conversationID.uuidString]
        ).flatMap(UUID.init(uuidString:))
        return MemoryLearningProgress(
            lastReviewedMessage: cursor,
            turns: rows.filter { ($0["kind"] as String) == MemoryActivityKind.turn.rawValue }.count,
            tools: rows.filter { ($0["kind"] as String) == MemoryActivityKind.tool.rawValue }.count,
            events: rows.compactMap { row in
                guard let id = UUID(uuidString: row["event_id"]),
                    let source = UUID(uuidString: row["source_message_id"]),
                    MemoryActivityKind(rawValue: row["kind"]) != nil
                else { return nil }
                return MemoryLearningEvent(id: id, sourceMessageID: source)
            })
    }
    public func correctionWasReviewed(_ messageID: UUID, conversationID: UUID) throws -> Bool {
        try database().read { db in
            try Int.fetchOne(
                db, sql: "SELECT 1 FROM reviewed_corrections WHERE conversation_id=? AND message_id=?",
                arguments: [conversationID.uuidString, messageID.uuidString]) != nil
        }
    }
    public func applyCorrection(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID
    ) throws -> AgentMemoryState? {
        try database().write { db in
            let current = try Self.state(db)
            guard current == expected else { return nil }
            let updated = operations.isEmpty ? current : try current.applying(operations)
            try Self.save(updated, in: db)
            try db.execute(
                sql: "INSERT OR IGNORE INTO reviewed_corrections VALUES(?,?)",
                arguments: [conversationID.uuidString, messageID.uuidString])
            return updated
        }
    }
    public func replaceHistory(_ conversations: [StoredAgentConversation]) async throws {
        let database = try database()
        let ids = Set(conversations.map { $0.id.uuidString })
        try await database.write { db in
            for id in try String.fetchAll(db, sql: "SELECT id FROM sessions") where !ids.contains(id) {
                try db.execute(sql: "DELETE FROM messages WHERE session_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM sessions WHERE id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM reviews WHERE conversation_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM learning_activity WHERE conversation_id=?", arguments: [id])
                try db.execute(sql: "DELETE FROM reviewed_corrections WHERE conversation_id=?", arguments: [id])
            }
        }
        for (batchIndex, conversation) in conversations.enumerated() {
            if batchIndex.isMultiple(of: 50) { await Task.yield() }
            try Task.checkCancellation()
            try await database.write { db in
                let id = conversation.id.uuidString
                let messages = conversation.messages.filter {
                    !$0.isCompaction && ($0.role == .user || $0.role == .assistant || $0.role == .tool)
                }
                // Compare persisted content, not just timestamps: edit/truncate can retain timestamps.
                let existing = try Row.fetchAll(
                    db, sql: "SELECT id,content FROM messages WHERE session_id=? ORDER BY position", arguments: [id])
                let clean = messages.map { message in
                    let calls = message.toolCalls.map { call in
                        call.name + " " + AgentSensitiveDataRedactor.redactedJSON(call.arguments).encodedString
                    }.joined(separator: "\n")
                    return AgentPersistenceRedactor.visibleText(message.text + (calls.isEmpty ? "" : "\n" + calls))
                }
                let unchanged =
                    existing.count == messages.count
                    && zip(existing, messages.indices).allSatisfy {
                        ($0.0["id"] as String) == messages[$0.1].id.uuidString
                            && ($0.0["content"] as String) == clean[$0.1]
                    }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sessions VALUES(?,?,?)",
                    arguments: [id, conversation.title, conversation.metadata.updatedAt.timeIntervalSince1970])
                guard !unchanged else { return }
                try db.execute(sql: "DELETE FROM messages WHERE session_id=?", arguments: [id])
                for (index, message) in messages.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO messages(id,session_id,position,role,content,created) VALUES(?,?,?,?,?,?)",
                        arguments: [
                            message.id.uuidString, id, index, message.role.rawValue, clean[index],
                            message.createdAt.timeIntervalSince1970,
                        ])
                }
                if conversation.lastRunState.isTerminal {
                    try db.execute(
                        sql: """
                            DELETE FROM learning_activity WHERE conversation_id=?
                            AND source_message_id NOT IN (SELECT id FROM messages WHERE session_id=?)
                            """, arguments: [id, id])
                    try db.execute(
                        sql: """
                            DELETE FROM reviewed_corrections WHERE conversation_id=?
                            AND message_id NOT IN (SELECT id FROM messages WHERE session_id=?)
                            """, arguments: [id, id])
                    try db.execute(
                        sql: """
                            DELETE FROM reviews WHERE conversation_id=?
                            AND message_id NOT IN (SELECT id FROM messages WHERE session_id=?)
                            """, arguments: [id, id])
                }
            }
        }
    }
    public func searchSessions(_ request: AgentSessionSearchRequest) throws -> AgentJSONValue {
        let limit = min(20, max(1, request.limit))
        let offset = max(0, request.offset)
        let rawQuery = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try database().read { db in
            if request.conversationID == nil, rawQuery.isEmpty {
                let rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM sessions ORDER BY modified DESC LIMIT ? OFFSET ?",
                    arguments: [limit + 1, offset])
                return .object([
                    "sessions": .array(
                        rows.prefix(limit).map {
                            .object(["conversation_id": .string($0["id"]), "title": .string($0["title"])])
                        }), "next_offset": rows.count > limit ? .number(Double(offset + limit)) : .null,
                ])
            }
            let rows: [Row]
            if rawQuery.isEmpty, let id = request.conversationID {
                let sql = """
                    SELECT m.*,s.title FROM messages m JOIN sessions s ON s.id=m.session_id
                    WHERE m.session_id=? ORDER BY m.position LIMIT ? OFFSET ?
                    """
                rows = try Row.fetchAll(db, sql: sql, arguments: [id.uuidString, limit + 1, offset])
            } else {
                let query = AgentSearchQuery(rawQuery)
                guard !query.terms.isEmpty else {
                    return .object(["messages": .array([]), "next_offset": .null])
                }

                func plan(matchingAll: Bool) -> (
                    fromWhere: String, order: String, arguments: StatementArguments, rankTerms: [String]
                ) {
                    var arguments = StatementArguments()
                    let fromWhere: String
                    let order: String
                    let rankTerms: [String]
                    if let fts = query.fts5Query(matchingAll: matchingAll) {
                        fromWhere = """
                            FROM message_fts JOIN messages m ON m.rowid=message_fts.rowid
                            JOIN sessions s ON s.id=m.session_id WHERE message_fts MATCH ?
                            """
                        arguments += [fts]
                        order = "bm25(message_fts),s.modified DESC,m.session_id,m.position,m.id"
                        rankTerms = []
                    } else {
                        let predicate = Array(
                            repeating: "instr(termindCaseFold(m.content),termindCaseFold(?))>0",
                            count: query.terms.count
                        )
                        .joined(separator: matchingAll ? " AND " : " OR ")
                        fromWhere = """
                            FROM messages m JOIN sessions s ON s.id=m.session_id WHERE (\(predicate))
                            """
                        for term in query.terms { arguments += [term] }
                        let termScores = Array(
                            repeating:
                                "(CASE WHEN instr(termindCaseFold(m.content),termindCaseFold(?))>0 THEN 1 ELSE 0 END)",
                            count: query.terms.count)
                        order = """
                            (CASE WHEN instr(termindCaseFold(m.content),termindCaseFold(?))>0
                                OR instr(termindCaseFold(m.content),termindCaseFold(?))>0 THEN 1 ELSE 0 END) DESC,
                            (\(termScores.joined(separator: " + "))) DESC,
                            s.modified DESC,m.session_id,m.position,m.id
                            """
                        rankTerms = [query.terms.joined(separator: " "), query.terms.joined()] + query.terms
                    }
                    if let id = request.conversationID {
                        arguments += [id.uuidString]
                        return (fromWhere + " AND m.session_id=?", order, arguments, rankTerms)
                    }
                    return (fromWhere, order, arguments, rankTerms)
                }

                // Decide the fallback for the whole result set, not this page's offset.
                let strict = plan(matchingAll: true)
                let hasStrict =
                    try Int.fetchOne(
                        db, sql: "SELECT 1 \(strict.fromWhere) LIMIT 1", arguments: strict.arguments) != nil
                let selected = hasStrict ? strict : plan(matchingAll: false)
                var arguments = selected.arguments
                for term in selected.rankTerms { arguments += [term] }
                arguments += [limit + 1, offset]
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT m.*,s.title \(selected.fromWhere) ORDER BY \(selected.order) LIMIT ? OFFSET ?",
                    arguments: arguments)
            }
            return .object([
                "messages": .array(
                    rows.prefix(limit).map { row in
                        .object([
                            "conversation_id": .string(row["session_id"]), "message_id": .string(row["id"]),
                            "title": .string(row["title"]), "role": .string(row["role"]),
                            "position": .number(Double(row["position"] as Int)),
                            "content": .string(row["content"]),
                        ])
                    }), "next_offset": rows.count > limit ? .number(Double(offset + limit)) : .null,
            ])
        }
    }
    public func rebuildHistoryIndex() throws {
        try database().write { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
        }
    }
    public func close() throws {
        try queue?.close()
        queue = nil
    }
    public func destroy() throws {
        try close()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
