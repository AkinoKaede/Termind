import SwiftData

@MainActor
extension ModelContext {
    public func savePendingChanges() throws {
        try commit {}
    }

    public func commit(beforeSave: () throws -> Void = {}, _ operation: () throws -> Void) throws {
        do {
            try operation()
            try beforeSave()
            try save()
        } catch {
            rollback()
            throw error
        }
    }
}
