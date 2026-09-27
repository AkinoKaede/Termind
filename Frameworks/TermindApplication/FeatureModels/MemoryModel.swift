import AgentKit
import Foundation

@Observable @MainActor
public final class MemoryModel {
    public private(set) var isEnabled: Bool
    public private(set) var isBusy = false
    public private(set) var isIndexing = false
    public private(set) var state = AgentMemoryState()
    public private(set) var referenceDates: [UUID: Date] = [:]
    public private(set) var error: String?
    public var reviewEnabled: Bool {
        didSet {
            defaults?.set(reviewEnabled, forKey: Self.reviewKey)
            if !reviewEnabled {
                for task in reviews.values { task.cancel() }
                for task in corrections.values { task.cancel() }
                for task in correctionRetries.values { task.cancel() }
                pendingReviews.removeAll()
                pendingCorrections.removeAll()
                queuedCorrectionIDs.removeAll()
            }
        }
    }
    public var reviewModel: AIModelRef? {
        didSet { defaults?.set(try? JSONEncoder().encode(reviewModel), forKey: Self.modelKey) }
    }
    private static let enabledKey = "hermesMemoryEnabled"
    private static let destroyingKey = "hermesMemoryDestroyPending"
    private static let reviewKey = "hermesMemoryReviewEnabled"
    private static let modelKey = "hermesMemoryReviewModel"
    private let defaults: UserDefaults?
    private let storage: (any MemoryPersisting)?
    private var generation = UUID()
    private var contexts: [UUID: AgentMemoryContext] = [:]
    private var history: (any AgentRunPersisting)?
    private var indexTask: Task<Void, Never>?
    private var indexDirty = false
    private var reviews: [UUID: Task<Void, Never>] = [:]
    private var pendingReviews: [UUID: (@Sendable () async -> Void)] = [:]
    private var corrections: [UUID: Task<Void, Never>] = [:]
    private var pendingCorrections:
        [UUID: [(AgentTranscriptMessage, [AgentTranscriptMessage], any AgentModelCompleting)]] = [:]
    private var queuedCorrectionIDs: Set<UUID> = []
    private var correctionRetries: [UUID: Task<Void, Never>] = [:]
    private var correctionRetryConversations: [UUID: UUID] = [:]
    private var correctionFailures: [UUID: Int] = [:]
    private var correctionOrders: [UUID: [UUID: Int]] = [:]
    private var nextCorrectionOrder: [UUID: Int] = [:]
    private var latestSuccessfulCorrectionOrder: [UUID: Int] = [:]
    private var retryAfter: [UUID: Date] = [:]
    private var learningEpochs: [UUID: UUID] = [:]
    private var isSuspended = false
    public func learningEpoch(for conversationID: UUID) -> UUID {
        if let existing = learningEpochs[conversationID] { return existing }
        let fresh = UUID()
        learningEpochs[conversationID] = fresh
        return fresh
    }
    public func invalidateLearning(for conversationID: UUID) {
        learningEpochs[conversationID] = UUID()
        reviews[conversationID]?.cancel()
        corrections[conversationID]?.cancel()
        pendingReviews.removeValue(forKey: conversationID)
        pendingCorrections.removeValue(forKey: conversationID)
        correctionOrders.removeValue(forKey: conversationID)
        nextCorrectionOrder.removeValue(forKey: conversationID)
        latestSuccessfulCorrectionOrder.removeValue(forKey: conversationID)
        retryAfter.removeValue(forKey: conversationID)
        for id in correctionRetryConversations.filter({ $0.value == conversationID }).keys {
            correctionRetries.removeValue(forKey: id)?.cancel()
            correctionRetryConversations.removeValue(forKey: id)
        }
    }
    public func learningToken(for context: AgentMemoryContext) -> UUID? {
        guard isEnabled, !isSuspended, !isBusy,
            contexts.values.contains(where: { $0 === context })
        else { return nil }
        return generation
    }

    public init(storage: (any MemoryPersisting)? = nil, defaults: UserDefaults? = nil) {
        self.storage = storage
        self.defaults = defaults
        let pending = defaults?.bool(forKey: Self.destroyingKey) == true
        isEnabled = !pending && storage != nil && defaults?.bool(forKey: Self.enabledKey) == true
        reviewEnabled = defaults?.object(forKey: Self.reviewKey) as? Bool ?? true
        reviewModel = defaults?.data(forKey: Self.modelKey).flatMap {
            try? JSONDecoder().decode(AIModelRef.self, from: $0)
        }
        if pending { Task { await destroy() } }
    }
    public func attachHistory(_ history: any AgentRunPersisting) {
        self.history = history
        historyChanged()
    }
    private func invalidate() {
        generation = UUID()
        for context in contexts.values { context.invalidate() }
        contexts.removeAll()
        indexTask?.cancel()
        for task in reviews.values { task.cancel() }
        for task in corrections.values { task.cancel() }
        for task in correctionRetries.values { task.cancel() }
        pendingReviews.removeAll()
        pendingCorrections.removeAll()
        queuedCorrectionIDs.removeAll()
        correctionRetries.removeAll()
        correctionRetryConversations.removeAll()
        correctionFailures.removeAll()
        correctionOrders.removeAll()
        nextCorrectionOrder.removeAll()
        latestSuccessfulCorrectionOrder.removeAll()
        retryAfter.removeAll()
        learningEpochs.removeAll()
    }
    public func setEnabled(_ enabled: Bool) async {
        guard !isBusy, let storage, defaults?.bool(forKey: Self.destroyingKey) != true else { return }
        isBusy = true
        defer { isBusy = false }
        invalidate()
        isEnabled = enabled
        defaults?.set(enabled, forKey: Self.enabledKey)
        error = nil
        do {
            if enabled {
                let value = try await storage.memoryState()
                let dates = try await storage.memoryReferenceDates()
                state = value
                referenceDates = dates
                historyChanged()
            } else {
                try await storage.close()
            }
        } catch { self.error = error.localizedDescription }
    }
    public func refresh() async {
        guard isEnabled, !isSuspended, let storage else { return }
        let token = generation
        do {
            let value = try await storage.memoryState()
            let dates = try await storage.memoryReferenceDates()
            if token == generation {
                state = value
                referenceDates = dates
                error = nil
            }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    public func edit(_ target: AgentMemoryTarget, text: String) async {
        guard isEnabled, !isSuspended, let storage else { return }
        let token = generation
        do {
            let updated = try await storage.replaceTarget(target, text: text)
            try publishCommittedState(updated, token: token)
            referenceDates = try await require(token).memoryReferenceDates()
            error = nil
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    public func session(_ id: UUID) async -> (context: AgentMemoryContext, access: any AgentMemoryAccessing)? {
        guard isEnabled, !isSuspended, let storage else { return nil }
        let token = generation
        do {
            // Open and migrate the store before exposing tools to the run.
            try await storage.prepareSession(id)
            guard token == generation, isEnabled else { return nil }
            let context = contexts[id] ?? AgentMemoryContext()
            contexts[id] = context
            return (context, MemoryAccess(model: self, token: token))
        } catch {
            if token == generation { self.error = error.localizedDescription }
            return nil
        }
    }
    private func require(_ token: UUID) throws -> any MemoryPersisting {
        try Task.checkCancellation()
        guard isEnabled, !isSuspended, token == generation, !isBusy, let storage else { throw CancellationError() }
        return storage
    }
    private func publishCommittedState(_ updated: AgentMemoryState, token: UUID) throws {
        do {
            _ = try require(token)
        } catch {
            reloadStateForCurrentGeneration()
            throw error
        }
        state = updated
    }
    private func reloadStateForCurrentGeneration() {
        guard isEnabled, !isSuspended, !isBusy, let storage else { return }
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await storage.memoryState()
                let dates = try await storage.memoryReferenceDates()
                guard token == generation, isEnabled, !isSuspended, !isBusy else { return }
                state = value
                referenceDates = dates
                error = nil
            } catch {
                guard token == generation, isEnabled, !isSuspended, !isBusy else { return }
                self.error = error.localizedDescription
            }
        }
    }
    fileprivate func read(token: UUID) async throws -> AgentMemoryState {
        let result = try await require(token).memoryState()
        _ = try require(token)
        return result
    }
    @discardableResult
    fileprivate func apply(_ operations: [AgentMemoryOperation], token: UUID) async throws -> AgentMemoryState {
        let result = try await require(token).applyMemory(operations)
        try publishCommittedState(result, token: token)
        return result
    }
    fileprivate func search(_ request: AgentSessionSearchRequest, token: UUID) async throws -> AgentJSONValue {
        _ = try require(token)
        historyChanged()
        await indexTask?.value
        let result = try await require(token).searchSessions(request)
        _ = try require(token)
        return result
    }
    fileprivate func searchMemory(_ request: AgentMemorySearchRequest, token: UUID) async throws -> AgentJSONValue {
        let result = try await require(token).searchMemories(request)
        let ids =
            result.objectValue?["entries"]?.arrayValue?.compactMap { entry in
                entry.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
            } ?? []
        if !ids.isEmpty {
            try await require(token).recordMemoryReferences(ids, at: .now)
            let dates = try await require(token).memoryReferenceDates()
            _ = try require(token)
            referenceDates = dates
        } else {
            _ = try require(token)
        }
        return result
    }
    public func rebuildHistoryIndex() async {
        guard isEnabled, !isSuspended else { return }
        let token = generation
        historyChanged()
        await indexTask?.value
        do {
            try await require(token).rebuildHistoryIndex()
            if token == generation { error = nil }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }

    public func historyChanged() {
        guard isEnabled, !isSuspended, let storage, let history else { return }
        indexDirty = true
        guard indexTask == nil else { return }
        let token = generation
        isIndexing = true
        indexTask = Task { [weak self] in
            guard let self else { return }
            defer {
                indexTask = nil
                isIndexing = false
                if indexDirty, isEnabled, !isSuspended { historyChanged() }
            }
            do {
                while indexDirty, token == generation, isEnabled, !Task.isCancelled {
                    indexDirty = false
                    let conversations = try await history.loadConversations()
                    _ = try require(token)
                    try await storage.replaceHistory(conversations)
                }
            } catch is CancellationError {
            } catch {
                if token == generation {
                    self.error = error.localizedDescription
                    indexDirty = false
                }
            }
        }
    }
    public func recordActivity(
        conversationID: UUID, userMessageIDs: [UUID], toolInvocations: [MemoryLearningEvent],
        messages: [AgentTranscriptMessage], model: (any AgentModelCompleting)?,
        sessionToken: UUID? = nil, historyEpoch: UUID? = nil
    ) async {
        guard isEnabled, !isSuspended, reviewEnabled, let storage,
            sessionToken == nil || sessionToken == generation,
            historyEpoch == nil || historyEpoch == learningEpoch(for: conversationID)
        else { return }
        let token = generation
        let epoch = learningEpoch(for: conversationID)
        do {
            var progress = try await storage.learningProgress(conversationID)
            guard epoch == learningEpoch(for: conversationID) else { return }
            for id in userMessageIDs {
                _ = try require(token)
                guard epoch == learningEpoch(for: conversationID) else { return }
                progress = try await storage.recordActivity(
                    id, sourceMessageID: id, kind: .turn, conversationID: conversationID)
                guard epoch == learningEpoch(for: conversationID) else { return }
            }
            for event in toolInvocations {
                _ = try require(token)
                guard epoch == learningEpoch(for: conversationID) else { return }
                progress = try await storage.recordActivity(
                    event.id, sourceMessageID: event.sourceMessageID, kind: .tool,
                    conversationID: conversationID)
                guard epoch == learningEpoch(for: conversationID) else { return }
            }
            guard let model, progress.turns >= 10 || progress.tools >= 15 else { return }
            guard retryAfter[conversationID].map({ $0 <= .now }) ?? true else { return }
            await review(
                conversationID: conversationID, messages: messages, model: model,
                force: false, expectedEpoch: epoch)
        } catch is CancellationError {
        } catch { if token == generation { self.error = error.localizedDescription } }
    }

    public nonisolated static func looksLikeCorrection(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 4_000 else { return false }
        if ["没关系", "不是问题", "no problem", "no worries", "actually looks great"].contains(where: value.contains) {
            return false
        }
        let strong = [
            "纠正", "更正", "不对", "别再", "以后请", "以后不要", "记住", "我说错了",
            "correction", "i meant", "not what i", "from now on", "remember that",
        ]
        if strong.contains(where: value.contains) { return true }
        if value.hasPrefix("no,") || value.hasPrefix("no ") || value.hasPrefix("不，") { return true }
        if value.contains("不要") && (value.contains("用") || value.contains("改")) { return true }
        if value.contains("不是") && (value.contains("而是") || value.contains("应该")) { return true }
        if value.contains("actually") && (value.contains("instead") || value.contains("use ")) { return true }
        return false
    }

    public func considerCorrection(
        conversationID: UUID, message: AgentTranscriptMessage, context: [AgentTranscriptMessage],
        model: any AgentModelCompleting, sessionToken: UUID? = nil, historyEpoch: UUID? = nil
    ) {
        let authored = message.authoredText ?? ContextChip.visiblePrompt(in: message.text)
        guard message.origin == nil, isEnabled, !isSuspended, reviewEnabled,
            sessionToken == nil || sessionToken == generation,
            historyEpoch == nil || historyEpoch == learningEpoch(for: conversationID),
            Self.looksLikeCorrection(authored), !queuedCorrectionIDs.contains(message.id),
            (correctionOrders[conversationID]?[message.id] ?? .max)
                > (latestSuccessfulCorrectionOrder[conversationID] ?? 0)
        else { return }
        if correctionOrders[conversationID]?[message.id] == nil {
            let order = nextCorrectionOrder[conversationID, default: 0] + 1
            nextCorrectionOrder[conversationID] = order
            correctionOrders[conversationID, default: [:]][message.id] = order
        }
        queuedCorrectionIDs.insert(message.id)
        var authoredMessage = message
        authoredMessage.authoredText = authored
        pendingCorrections[conversationID, default: []].append((authoredMessage, context, model))
        reviews[conversationID]?.cancel()
        startNextCorrection(conversationID)
    }

    private func startNextCorrection(_ conversationID: UUID) {
        guard corrections[conversationID] == nil,
            let next = pendingCorrections[conversationID]?.first
        else { return }
        pendingCorrections[conversationID]?.removeFirst()
        let token = generation
        let epoch = learningEpoch(for: conversationID)
        let order = correctionOrders[conversationID]?[next.0.id] ?? 0
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                queuedCorrectionIDs.remove(next.0.id)
                corrections.removeValue(forKey: conversationID)
                startNextCorrection(conversationID)
                if pendingCorrections[conversationID]?.isEmpty != false,
                    let pending = pendingReviews.removeValue(forKey: conversationID)
                {
                    Task { await pending() }
                }
            }
            do {
                guard order > (latestSuccessfulCorrectionOrder[conversationID] ?? 0) else { return }
                let storage = try require(token)
                guard try await !storage.correctionWasReviewed(next.0.id, conversationID: conversationID) else {
                    return
                }
                if let running = reviews[conversationID] { await running.value }
                _ = try require(token)
                guard epoch == learningEpoch(for: conversationID) else { return }
                for _ in 0..<2 {
                    let current = try await read(token: token)
                    let operations = try await timedOperations {
                        try await AgentMemoryLearningService().correction(
                            message: next.0, context: next.1, state: current, model: next.2)
                    }
                    _ = try require(token)
                    guard epoch == learningEpoch(for: conversationID) else { return }
                    if let updated = try await storage.applyCorrection(
                        operations, expected: current, messageID: next.0.id, conversationID: conversationID)
                    {
                        try publishCommittedState(updated, token: token)
                        latestSuccessfulCorrectionOrder[conversationID] = order
                        for id in correctionRetryConversations.filter({ $0.value == conversationID }).keys {
                            if let retryOrder = correctionOrders[conversationID]?[id], retryOrder < order {
                                correctionRetries.removeValue(forKey: id)?.cancel()
                                correctionRetryConversations.removeValue(forKey: id)
                            }
                        }
                        correctionFailures.removeValue(forKey: next.0.id)
                        return
                    }
                }
                scheduleCorrectionRetry(next, conversationID: conversationID, token: token, epoch: epoch)
            } catch is CancellationError {
            } catch {
                if token == generation {
                    self.error = error.localizedDescription
                    scheduleCorrectionRetry(next, conversationID: conversationID, token: token, epoch: epoch)
                }
            }
        }
        corrections[conversationID] = task
    }

    private func scheduleCorrectionRetry(
        _ correction: (AgentTranscriptMessage, [AgentTranscriptMessage], any AgentModelCompleting),
        conversationID: UUID, token: UUID, epoch: UUID
    ) {
        guard epoch == learningEpoch(for: conversationID),
            let order = correctionOrders[conversationID]?[correction.0.id],
            order > (latestSuccessfulCorrectionOrder[conversationID] ?? 0)
        else { return }
        let failures = correctionFailures[correction.0.id, default: 0] + 1
        correctionFailures[correction.0.id] = failures
        let delay = min(300, 15 * (1 << min(failures, 5)))
        correctionRetries[correction.0.id]?.cancel()
        correctionRetryConversations[correction.0.id] = conversationID
        correctionRetries[correction.0.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, token == generation,
                epoch == learningEpoch(for: conversationID),
                order > (latestSuccessfulCorrectionOrder[conversationID] ?? 0)
            else { return }
            correctionRetries.removeValue(forKey: correction.0.id)
            correctionRetryConversations.removeValue(forKey: correction.0.id)
            considerCorrection(
                conversationID: conversationID, message: correction.0,
                context: correction.1, model: correction.2, historyEpoch: epoch)
        }
    }

    private func timedOperations(
        _ work: @escaping @Sendable () async throws -> [AgentMemoryOperation]
    ) async throws -> [AgentMemoryOperation] {
        try await withThrowingTaskGroup(of: [AgentMemoryOperation].self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw MemoryReviewTimeout()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    public func review(
        conversationID: UUID, messages: [AgentTranscriptMessage], model: any AgentModelCompleting,
        wait: Bool = false, force: Bool = true, expectedEpoch: UUID? = nil
    ) async {
        guard isEnabled, !isSuspended, reviewEnabled, let storage, !messages.isEmpty else { return }
        let token = generation
        let epoch = learningEpoch(for: conversationID)
        guard expectedEpoch == nil || expectedEpoch == epoch else { return }
        if let correction = corrections[conversationID] {
            if wait {
                await correction.value
            } else {
                pendingReviews[conversationID] = { [weak self] in
                    await self?.review(
                        conversationID: conversationID, messages: messages, model: model,
                        force: force, expectedEpoch: epoch)
                }
                return
            }
        }
        if let running = reviews[conversationID] {
            if wait {
                await running.value
            } else {
                pendingReviews[conversationID] = { [weak self] in
                    await self?.review(
                        conversationID: conversationID, messages: messages, model: model,
                        force: force, expectedEpoch: epoch)
                }
                return
            }
        }
        guard token == generation, epoch == learningEpoch(for: conversationID), isEnabled else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                reviews.removeValue(forKey: conversationID)
                if corrections[conversationID] == nil,
                    let next = pendingReviews.removeValue(forKey: conversationID)
                {
                    Task { await next() }
                }
            }
            do {
                var progress = try await storage.learningProgress(conversationID)
                guard epoch == learningEpoch(for: conversationID) else { return }
                guard force || progress.turns >= 10 || progress.tools >= 15 else { return }
                guard force || (retryAfter[conversationID].map({ $0 <= .now }) ?? true) else { return }
                while true {
                    let cursorIndex = progress.lastReviewedMessage.flatMap { cursor in
                        messages.firstIndex(where: { $0.id == cursor })
                    }
                    let pendingIndex = progress.events.compactMap { event in
                        messages.firstIndex(where: { $0.id == event.sourceMessageID })
                    }.min()
                    let start = min(cursorIndex.map { $0 + 1 } ?? 0, pendingIndex ?? messages.count)
                    guard start < messages.count else { return }
                    var end = start
                    while end < messages.count, end - start < 100 {
                        let candidate = end + 1
                        let serialized = AgentCompaction.serialized(
                            Array(messages[start..<candidate]), toolResultLimit: 300)
                        if serialized.count > 28_000, end > start { break }
                        end = candidate
                    }
                    let messageIDs = Set(messages[start..<end].map(\.id))
                    let reviewedIDs = progress.events.filter { messageIDs.contains($0.sourceMessageID) }.map(\.id)
                    var contextStart = max(0, start - 2)
                    while contextStart < start {
                        let withContext = AgentCompaction.serialized(
                            Array(messages[contextStart..<end]), toolResultLimit: 300)
                        if withContext.count <= 28_000 { break }
                        contextStart += 1
                    }
                    let delta = Array(messages[contextStart..<end])
                    let current = try await read(token: token)
                    let operations = try await timedOperations {
                        try await AgentMemoryLearningService().review(messages: delta, state: current, model: model)
                    }
                    _ = try require(token)
                    guard epoch == learningEpoch(for: conversationID) else { return }
                    guard
                        let updated = try await storage.applyReview(
                            operations, expected: current, messageID: messages[end - 1].id,
                            conversationID: conversationID, reviewedActivityIDs: reviewedIDs)
                    else {
                        retryAfter[conversationID] = .now.addingTimeInterval(30)
                        return
                    }
                    try publishCommittedState(updated, token: token)
                    retryAfter.removeValue(forKey: conversationID)
                    guard end < messages.count else { return }
                    progress = try await storage.learningProgress(conversationID)
                }
            } catch is CancellationError {
            } catch {
                if token == generation {
                    self.error = error.localizedDescription
                    retryAfter[conversationID] = .now.addingTimeInterval(30)
                }
            }
        }
        reviews[conversationID] = task
        if wait { await task.value }
    }
    public func destroy() async {
        guard !isBusy, let storage else { return }
        isBusy = true
        isEnabled = false
        defaults?.set(false, forKey: Self.enabledKey)
        defaults?.set(true, forKey: Self.destroyingKey)
        invalidate()
        indexDirty = false
        let pending = Array(reviews.values)
        let correctionPending = Array(corrections.values)
        let delayed = Array(correctionRetries.values)
        await indexTask?.value
        for task in pending { await task.value }
        for task in correctionPending { await task.value }
        for task in delayed { await task.value }
        do {
            try await storage.destroy()
            state = .init()
            referenceDates = [:]
            error = nil
            defaults?.removeObject(forKey: Self.destroyingKey)
        } catch { self.error = error.localizedDescription }
        isBusy = false
    }
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        invalidate()
    }
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        reloadStateForCurrentGeneration()
        historyChanged()
    }
}

private struct MemoryReviewTimeout: Error {}

private struct MemoryAccess: AgentMemoryAccessing {
    weak var model: MemoryModel?
    let token: UUID
    func memoryState() async throws -> AgentMemoryState {
        guard let model else { throw CancellationError() }
        return try await model.read(token: token)
    }
    func applyMemory(_ operations: [AgentMemoryOperation]) async throws -> AgentMemoryState {
        guard let model else { throw CancellationError() }
        return try await model.apply(operations, token: token)
    }
    func searchSessions(_ request: AgentSessionSearchRequest) async throws -> AgentJSONValue {
        guard let model else { throw CancellationError() }
        return try await model.search(request, token: token)
    }
    func searchMemories(_ request: AgentMemorySearchRequest) async throws -> AgentJSONValue {
        guard let model else { throw CancellationError() }
        return try await model.searchMemory(request, token: token)
    }
}
