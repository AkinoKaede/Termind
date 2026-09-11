import SwiftData
import TermindPersistence

typealias SwiftDataCommandHistoryRepository = SharedSwiftDataCommandHistoryRepository

extension CommandHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataCommandHistoryRepository(context: modelContext))
    }
}
