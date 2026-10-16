import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct MetricsHostAccessTests {
    @Test(arguments: [false, true])
    func lockedTargetsAndJumpsKeepSelectionsAndCacheWithoutStartingWorkers(lockedJump: Bool) throws {
        var hosts = (0..<4).map {
            TermindDomain.Host(
                name: "Host \($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        if lockedJump { hosts[0].jumpHostID = hosts[3].id }
        let target = hosts[lockedJump ? 0 : 3]
        let library = HostLibraryModel(hosts: hosts)
        let preferences = LockedMetricsPreferences()
        let model = ServerMetricsModel(
            hosts: library, preferences: preferences,
            makeSampler: { preconditionFailure("A locked or paused monitor must not create a sampler") })
        model.suspend()
        defer { model.shutdown() }
        #expect(model.add(target))
        let server = try #require(model.servers.first)
        server.point = MetricsPoint(date: .now, cpu: 75)
        server.history = [try #require(server.point)]
        library.hostAccess.entitlement = .free
        model.reconcile()
        model.resume()
        model.reconcile()
        #expect(server.isHostLocked)
        #expect(!server.isConnecting)
        #expect(!server.showsConnectionJourney)
        #expect(model.snapshot(for: target.id)?.state == .locked)
        #expect(server.point?.cpu == 75)
        #expect(server.history.count == 1)
        #expect(preferences.values.map(\.id) == [target.id])
        model.remove(target.id)
        #expect(model.servers.isEmpty)
        #expect(preferences.values.isEmpty)
    }

    @Test(arguments: [EntitlementStatus.loading, .verificationFailed])
    func unresolvedAccessIsNotPresentedAsAQuotaLock(status: EntitlementStatus) throws {
        let hosts = (0..<4).map {
            TermindDomain.Host(
                name: "Host \($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let library = HostLibraryModel(hosts: hosts)
        library.hostAccess.entitlement = status
        let model = ServerMetricsModel(
            hosts: library, preferences: LockedMetricsPreferences(),
            makeSampler: { preconditionFailure("Unresolved access must not start a sampler") })
        defer { model.shutdown() }
        #expect(model.add(hosts[3]))
        let server = try #require(model.servers.first)
        #expect(!server.isHostLocked)
        #expect(server.hostAccessError != nil)
        #expect(model.snapshot(for: server.id)?.state == (status == .loading ? .connecting : .failed))
    }
}

@MainActor private final class LockedMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) { values = selections }
}
