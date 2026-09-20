import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct MetricsLimitTests {
    @Test
    func freeLimitCountsPausedCardsAndRejectsTheFourthBeforeSaving() {
        let hosts = fixtures(4)
        let preferences = LimitMetricsPreferences()
        var denied = 0
        let model = model(hosts, preferences: preferences, denied: { denied += 1 })
        defer { model.shutdown() }
        #expect(model.add(Array(hosts.prefix(3))))
        model.setEnabled(false, for: model.servers[0])
        let saved = preferences.values
        #expect(model.remainingCardSlots == 0)
        #expect(!model.add(hosts[3]))
        #expect(model.servers.count == 3)
        #expect(preferences.values == saved)
        #expect(denied == 1)
        model.remove(hosts[1].id)
        #expect(model.remainingCardSlots == 1)
        #expect(model.add(hosts[3]))
        #expect(model.servers.count == 3)
    }

    @Test
    func batchAdmissionIsAtomicAndDuplicateHostsDoNotConsumeSlots() {
        let hosts = fixtures(5)
        let preferences = LimitMetricsPreferences()
        let model = model(hosts, preferences: preferences)
        defer { model.shutdown() }
        #expect(model.add(hosts[0]))
        #expect(!model.add(Array(hosts[1...3])))
        #expect(model.servers.map(\.id) == [hosts[0].id])
        #expect(model.add([hosts[0], hosts[1], hosts[1], hosts[2]]))
        #expect(model.servers.count == 3)
        #expect(model.add([hosts[0], hosts[0]]))
        #expect(!model.add(hosts[4]))
        #expect(preferences.values.count == 3)
    }

    @Test
    func proAccessCanChangeWithoutRebuildingTheModel() {
        let hosts = fixtures(6)
        var unlimited = false
        let model = model(hosts, limit: { unlimited ? nil : 3 })
        defer { model.shutdown() }
        #expect(model.add(Array(hosts.prefix(3))))
        #expect(!model.add(hosts[3]))
        unlimited = true
        #expect(model.remainingCardSlots == nil)
        #expect(model.add(Array(hosts.suffix(3))))
        #expect(model.servers.count == 6)
        unlimited = false
        #expect(model.remainingCardSlots == 0)
        #expect(model.servers.count == 6)
        #expect(!model.requestAddition())
    }

    @Test
    func restoredConfigurationIsNotDeletedButCountsAgainstNewAdditions() {
        let hosts = fixtures(5)
        let preferences = LimitMetricsPreferences()
        preferences.values = hosts.prefix(4).map { MetricsSelection(id: $0.id, enabled: false) }
        let saved = preferences.values
        let model = model(hosts, preferences: preferences)
        defer { model.shutdown() }
        model.start()
        #expect(model.servers.count == 4)
        #expect(!model.add(hosts[4]))
        #expect(preferences.values == saved)
    }

    @Test
    func toolbarAdmissionUsesTheSameLimitBeforeOpeningTheChooser() {
        let hosts = fixtures(4)
        var denied = false
        let model = model(hosts, denied: { denied = true })
        defer { model.shutdown() }
        model.add(Array(hosts.prefix(3)))
        let window = WindowModel()
        window.metricsModel = model
        window.selectedDestination = .metrics
        window.creationActions.first?.perform()
        #expect(denied)
        #expect(window.presentations.hostChooser == nil)
    }

    @Test
    func productionWiringUsesTheExistingProPaywallAndIncludesSubscriptionAccess() {
        let free = ProAccessController.testing(status: .free(trialAvailable: true))
        let app = AppModel(hosts: HostLibraryModel(), proAccess: free)
        defer { app.shutdownForTermination() }
        #expect(app.serverMetrics.remainingCardSlots == 3)
        #expect(!app.serverMetrics.requestAddition(count: 4))
        #expect(free.isPaywallPresented)
        #expect(free.requestedFeature == .unlimitedMetrics)
        for status in [
            EntitlementStatus.subscription(
                ProSubscriptionStatus(
                    phase: .introductoryTrial, expiresAt: .distantFuture, willAutoRenew: true,
                    ownership: .purchased)),
            .purchased(.purchased), .purchased(.familyShared),
        ] {
            let access = ProAccessController.testing(status: status)
            #expect(access.canUse(.unlimitedMetrics))
        }
    }

    private func fixtures(_ count: Int) -> [TermindDomain.Host] {
        (0..<count).map { Host(name: "Fixture \($0)", host: "fixture\($0).invalid") }
    }

    private func model(
        _ hosts: [TermindDomain.Host], preferences: LimitMetricsPreferences = LimitMetricsPreferences(),
        limit: @escaping () -> Int? = { 3 }, denied: @escaping () -> Void = {}
    ) -> ServerMetricsModel {
        ServerMetricsModel(
            hosts: HostLibraryModel(hosts: hosts), preferences: preferences,
            makeSampler: { SSHMetricsSampler(connection: RemoteConnectionCoordinator().makeConnection()) },
            cardLimit: limit, limitReached: denied
        )
    }
}

private final class LimitMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) { values = selections }
}
