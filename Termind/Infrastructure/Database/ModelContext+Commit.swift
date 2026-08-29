import SwiftData

@MainActor
extension ModelContext {
    func commit(_ operation: () throws -> Void) throws {
        do {
            try operation()
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}
