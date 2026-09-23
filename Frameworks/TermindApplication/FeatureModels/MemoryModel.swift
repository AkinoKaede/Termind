import AgentKit
import Foundation

@Observable @MainActor
public final class MemoryModel {
    public private(set) var isEnabled: Bool
    public private(set) var isBusy = false
    public private(set) var isIndexing = false
    public private(set) var state = AgentMemoryState()
    public private(set) var error: String?
    public var reviewEnabled: Bool {
        didSet {
            defaults?.set(reviewEnabled, forKey: Self.reviewKey)
            if !reviewEnabled {
                for task in reviews.values { task.cancel() }
                pendingReviews.removeAll()
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
    private var isSuspended = false

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
        pendingReviews.removeAll()
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
                state = try await storage.memoryState()
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
            if token == generation {
                state = value
                error = nil
            }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    public func edit(_ target: AgentMemoryTarget, text: String) async {
        guard isEnabled, !isSuspended, let storage else { return }
        let token = generation
        do {
            let updated = try await storage.replaceTarget(target, text: text)
            guard token == generation, isEnabled else { return }
            state = updated
            error = nil
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    public func session(_ id: UUID) async -> (context: AgentMemoryContext, access: any AgentMemoryAccessing)? {
        guard isEnabled, !isSuspended, let storage else { return nil }
        let token = generation
        do {
            let context: AgentMemoryContext
            if let existing = contexts[id] {
                context = existing
            } else {
                let snapshot = try await storage.snapshot(for: id)
                guard token == generation, isEnabled else { return nil }
                context = contexts[id] ?? AgentMemoryContext(snapshot: snapshot)
                contexts[id] = context
            }
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
    fileprivate func read(token: UUID) async throws -> AgentMemoryState {
        let result = try await require(token).memoryState()
        _ = try require(token)
        return result
    }
    @discardableResult
    fileprivate func apply(_ operations: [AgentMemoryOperation], token: UUID) async throws -> AgentMemoryState {
        let result = try await require(token).applyMemory(operations)
        _ = try require(token)
        state = result
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
    public func review(
        conversationID: UUID, messages: [AgentTranscriptMessage], model: any AgentModelCompleting,
        wait: Bool = false
    ) async {
        guard isEnabled, !isSuspended, reviewEnabled, let storage, let last = messages.last?.id else { return }
        let token = generation
        if let running = reviews[conversationID] {
            if wait {
                await running.value
            } else {
                pendingReviews[conversationID] = { [weak self] in
                    await self?.review(conversationID: conversationID, messages: messages, model: model)
                }
                return
            }
        }
        guard token == generation, isEnabled else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                reviews.removeValue(forKey: conversationID)
                if let next = pendingReviews.removeValue(forKey: conversationID) { Task { await next() } }
            }
            do {
                guard try await storage.lastReviewedMessage(conversationID) != last else { return }
                let current = try await read(token: token)
                let operations = try await withThrowingTaskGroup(of: [AgentMemoryOperation].self) { group in
                    group.addTask {
                        try await AgentMemoryLearningService().review(messages: messages, state: current, model: model)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(60))
                        throw CancellationError()
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? []
                }
                _ = try require(token)
                if let updated = try await storage.applyReview(
                    operations, expected: current, messageID: last, conversationID: conversationID)
                {
                    _ = try require(token)
                    state = updated
                }
            } catch is CancellationError {
            } catch { if token == generation { self.error = error.localizedDescription } }
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
        await indexTask?.value
        for task in pending { await task.value }
        do {
            try await storage.destroy()
            state = .init()
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
        historyChanged()
    }
}

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
}
