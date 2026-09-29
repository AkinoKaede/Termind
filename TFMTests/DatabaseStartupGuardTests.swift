import TermindPersistence
import Testing

@testable import Termind

@Suite @MainActor
struct DatabaseStartupGuardTests {
    @Test func permitsTheCurrentProcess() throws {
        try DatabaseStartupGuard.checkProcessIdentifiers([100], current: 100)
        try DatabaseStartupGuard.checkProcessIdentifiers([], current: 100)
    }

    @Test func refusesAnOlderInstanceEvenWhenItDoesNotImplementStoreLocking() {
        #expect(throws: PersistentStoreAccessError.inUse) {
            try DatabaseStartupGuard.checkProcessIdentifiers([100, 200], current: 100)
        }
    }
}
