import SwiftData
import TermindPersistence

typealias SwiftDataConnectionHistoryRepository = SharedSwiftDataConnectionHistoryRepository

extension ConnectionHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataConnectionHistoryRepository(context: modelContext))
    }
}
