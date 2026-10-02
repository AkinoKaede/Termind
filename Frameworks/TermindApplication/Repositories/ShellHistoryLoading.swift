import TermindDomain

public nonisolated protocol ShellHistoryLoading: Sendable {
    func load(source: ShellHistorySource?) async throws -> [ShellHistoryRecord]
}
