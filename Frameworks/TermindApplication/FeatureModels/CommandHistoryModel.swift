import Foundation
import TermindDomain

/// One terminal's memory-only file snapshot and subsequent shell events.
@MainActor
@Observable
public final class CommandHistoryModel {
    public static let perSessionLimit = HistoryLimits.retainedEntries
    public let sessionID: UUID
    public private(set) var revision: UInt64 = 0
    public private(set) var loadError: String?
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    private var values: [CommandHistoryEntry]
    private var isClosed = false
    private var loadTask: Task<Void, Never>?
    private var loadID: UUID?

    public init(sessionID: UUID = UUID(), entries: [CommandHistoryEntry] = []) {
        self.sessionID = sessionID
        values = Array(entries.filter { $0.sessionID == sessionID }.prefix(Self.perSessionLimit)).map {
            var entry = $0
            entry.command = CommandHistoryEntry.normalizingLineContinuations(in: entry.command)
            return entry
        }
    }

    public func entries(matching query: String = "") -> [CommandHistoryEntry] {
        query.isEmpty ? values : values.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }

    @discardableResult
    public func record(_ command: String, at date: Date = Date()) -> CommandHistoryEntry? {
        let command = CommandHistoryEntry.normalizingLineContinuations(in: command)
        guard !isClosed, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !ShellHistoryFilter.isIntegrationCommand(command)
        else { return nil }
        let entry = CommandHistoryEntry(sessionID: sessionID, command: command, executedAt: date)
        values.insert(entry, at: 0)
        trim()
        revision &+= 1
        return entry
    }

    @discardableResult
    public func recordCompletion(
        for id: CommandHistoryEntry.ID, exitStatus: Int32, duration: TimeInterval?
    ) -> CommandHistoryEntry? {
        guard !isClosed, let index = values.firstIndex(where: { $0.id == id }) else { return nil }
        values[index].exitStatus = exitStatus
        values[index].duration = duration.flatMap { $0.isFinite ? max(0, $0) : nil }
        revision &+= 1
        return values[index]
    }

    public func load(using loader: any ShellHistoryLoading, source: ShellHistorySource?) {
        guard !isClosed, !hasLoaded, loadTask == nil else { return }
        let token = UUID()
        loadID = token
        isLoading = true
        loadError = nil
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await loader.load(source: source)
                guard let self, self.loadID == token, !self.isClosed, !Task.isCancelled else { return }
                self.merge(snapshot)
                self.hasLoaded = true
                self.finishLoading()
            } catch {
                guard let self, self.loadID == token, !self.isClosed, !Task.isCancelled else { return }
                self.loadError = error.localizedDescription
                self.finishLoading()
            }
        }
    }

    /// Disconnect cancels only the current read; reconnect retains a completed snapshot.
    public func cancelLoading() {
        loadID = nil
        loadTask?.cancel()
        finishLoading()
    }

    /// Closing is terminal, including while a closed pane remains in the reopen stack.
    public func close() {
        isClosed = true
        cancelLoading()
        values.removeAll()
        loadError = nil
        revision &+= 1
    }

    private func finishLoading() {
        loadTask = nil
        isLoading = false
    }

    private func merge(_ snapshot: [ShellHistoryRecord]) {
        // Consume matches one at a time: repeated executions must not collapse into a set.
        var unmatched = values
        let imported = snapshot.reversed().compactMap { record -> CommandHistoryEntry? in
            let command = CommandHistoryEntry.normalizingLineContinuations(in: record.command)
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !ShellHistoryFilter.isIntegrationCommand(command)
            else { return nil }
            if let date = record.executedAt,
                let index = unmatched.firstIndex(where: {
                    $0.command == command
                        && $0.executedAt.map {
                            floor($0.timeIntervalSince1970) == floor(date.timeIntervalSince1970)
                        } == true
                })
            {
                unmatched.remove(at: index)
                return nil
            }
            return CommandHistoryEntry(
                sessionID: sessionID, command: command, executedAt: record.executedAt, duration: record.duration)
        }
        values.append(contentsOf: imported)
        trim()
        revision &+= 1
    }

    private func trim() {
        if values.count > Self.perSessionLimit { values.removeLast(values.count - Self.perSessionLimit) }
    }
}
