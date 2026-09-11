import SwiftData
import TermindApplication
import TermindPersistence

extension CommandHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataCommandHistoryRepository(context: modelContext))
    }
}
