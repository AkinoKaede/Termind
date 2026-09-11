import SwiftData
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileAppTests {
    @Test func startupUsesTheSharedSchemaAndEmptyRepository() throws {
        let app = try MobileAppModel()
        #expect(try app.hosts.snapshot().value == .empty)
        #expect(Set(app.container.schema.entities.map(\.name)) == Set(TermindPersistence.schema.entities.map(\.name)))
        #expect(MobileDestination.allCases == [.hosts, .assistant, .settings])
    }

    @Test func scenesCanUseTheSameAppRepository() throws {
        let repository = InMemoryHostRepository()
        let app = try MobileAppModel(hosts: repository)
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        try repository.upsertHost(host)
        #expect(try app.hosts.snapshot().value.hosts == [host])
    }
}
