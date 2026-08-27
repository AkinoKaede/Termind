import Foundation

nonisolated enum RepositoryChangeReason: String, Hashable, Sendable {
    case initial
    case refresh
    case mutation
}

nonisolated struct RepositoryChange<Value: Sendable>: Sendable {
    let revision: Int64
    let value: Value
    let reason: RepositoryChangeReason
}
