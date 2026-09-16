import Foundation

@MainActor
final class MCPTransferBudget {
    private var active: Set<UUID> = []
    func claim(_ id: UUID) -> Bool {
        guard active.count < 4, !active.contains(id) else { return false }
        active.insert(id)
        return true
    }
    func release(_ id: UUID) { active.remove(id) }
}
