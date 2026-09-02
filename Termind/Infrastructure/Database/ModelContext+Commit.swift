import SwiftData

@MainActor
extension ModelContext {
    func savePendingChanges() throws {
        try commit {}
    }

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
