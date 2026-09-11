import SwiftData
import TermindApplication
import TermindPersistence

extension ConnectionHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataConnectionHistoryRepository(context: modelContext))
    }
}
