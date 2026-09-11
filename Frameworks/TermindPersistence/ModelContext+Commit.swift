import SwiftData

@MainActor
extension ModelContext {
    public func savePendingChanges() throws {
        try commit {}
    }

    public func commit(_ operation: () throws -> Void) throws {
        do {
            try operation()
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}
