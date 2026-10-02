import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SFTPHistoryTests {
    @Test func visitsAreNormalizedDeduplicatedAndScopedToSession() {
        let first = SFTPHistoryModel()
        let second = SFTPHistoryModel()
        first.record(kind: .directory, path: "/srv/app/")
        first.record(kind: .file, path: "/srv/app/config.json")
        first.record(kind: .directory, path: "/srv/app")
        second.record(kind: .directory, path: "/var/log")
        #expect(first.entries().map(\.path) == ["/srv/app", "/srv/app/config.json"])
        #expect(first.entries(matching: "CONFIG").map(\.kind) == [.file])
        #expect(second.entries().map(\.path) == ["/var/log"])
        first.close()
        #expect(first.entries().isEmpty)
        #expect(second.entries().count == 1)
    }

    @Test func closedHistoryRejectsLateTransferCallbacks() {
        let history = SFTPHistoryModel()
        history.record(kind: .file, path: "/before")
        history.close()
        history.record(kind: .file, path: "/late")
        #expect(history.entries().isEmpty)
        let reopened = SFTPHistoryModel()
        #expect(reopened.entries().isEmpty)
        #expect(reopened.sessionID != history.sessionID)
    }

    @Test func trimRetainsNewestPaths() throws {
        let model = SFTPHistoryModel()
        for index in 0...SFTPHistoryModel.perSessionLimit {
            model.record(kind: .directory, path: "/directory-\(index)")
        }
        let values = model.entries()
        #expect(values.count == SFTPHistoryModel.perSessionLimit)
        #expect(values.last?.path == "/directory-1")
    }
}
