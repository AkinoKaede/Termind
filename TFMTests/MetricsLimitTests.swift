// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind
@testable import TermindPresentation

@Suite
@MainActor
struct MetricsLimitTests {
    @Test func failedAccessUsesErrorIndicatorRatherThanAnIndefiniteSpinner() {
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Host")
        server.hostAccessError = .entitlementVerificationFailed
        #expect(MetricsInstrumentBody(server: server, sleeping: false).connectionIndicator == .attention)
        server.hostAccessError = .verifyingEntitlement
        server.isConnecting = true
        #expect(MetricsInstrumentBody(server: server, sleeping: false).connectionIndicator == .progress)
    }

    @Test func lockedCardActivationOpensPaywallInsteadOfDetails() {
        let free = ProAccessController.testing(status: .free)
        let host = fixtures(1)[0]
        let model = model([host])
        defer { model.shutdown() }
        let server = ServerMetric(selection: MetricsSelection(id: host.id), name: host.name)
        server.point = MetricsPoint(date: .now, cpu: 50)
        server.hostAccessError = .lockedHost(host.id)
        var inspected = false
        let card = ServerMetricsCard(
            server: server, model: model, inspect: { inspected = true }, upgrade: { free.presentPaywall() })
        card.activate()
        #expect(free.isPaywallPresented)
        #expect(!inspected)
        #expect(server.point != nil)
        free.isPaywallPresented = false
        server.hostAccessError = .verifyingEntitlement
        card.activate()
        #expect(!free.isPaywallPresented)
        #expect(inspected)
    }

    @Test func lockedHostAndJumpDoNotCreateNewWorkspacesOrHistory() {
        var hosts = fixtures(4)
        for index in hosts.indices { hosts[index].createdAt = Date(timeIntervalSince1970: Double(index)) }
        hosts[0].jumpHostID = hosts[3].id
        let pro = ProAccessController.testing(status: .free)
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: pro)
        defer { app.shutdownForTermination() }
        let window = WindowModel()
        #expect(app.open(hosts[3], as: .sshSession, in: window) == nil)
        #expect(app.open(hosts[0], as: .sftpChannel, in: window) == nil)
        #expect(window.workspaces.isEmpty)
        #expect(pro.isPaywallPresented)
        app.open([hosts[0], hosts[1], hosts[3]], as: .sshSession, layout: .oneWorkspace, in: window)
        #expect(window.workspaces.count == 1)
        #expect(window.workspaces.first?.panes.count == 1)
    }

    @Test func hostAccessVerificationFailureUsesConnectionErrorRatherThanWakeNotice() {
        var hosts = fixtures(4)
        for index in hosts.indices { hosts[index].createdAt = Date(timeIntervalSince1970: Double(index)) }
        let app = AppModel(
            hosts: HostLibraryModel(hosts: hosts), proAccess: .testing(status: .verificationFailed))
        defer { app.shutdownForTermination() }
        let window = WindowModel()
        #expect(app.open(hosts[3], as: .sshSession, in: window) == nil)
        #expect(window.hostAccessError == String(localized: AppStrings.Pro.accessVerificationFailed))
        #expect(window.externalConnectionError == nil)
        #expect(window.wakeNotice == nil)
        #expect(!app.proAccess.isPaywallPresented)
    }

    @Test
    func freeMetricsHasNoIndependentCardLimitAndDeduplicates() {
        let hosts = fixtures(6)
        let preferences = LimitMetricsPreferences()
        let model = model(hosts, preferences: preferences)
        defer { model.shutdown() }
        #expect(model.add(Array(hosts.prefix(3))))
        model.setEnabled(false, for: model.servers[0])
        #expect(model.add(hosts + hosts))
        #expect(model.servers.count == 6)
        #expect(preferences.values.count == 6)
        #expect(!model.selections[0].enabled)
    }

    @Test
    func selectionReplacementRetainsSettingsWithoutACommercialLimit() {
        let hosts = fixtures(5)
        let preferences = LimitMetricsPreferences()
        let model = model(hosts, preferences: preferences)
        defer { model.shutdown() }
        #expect(model.add(Array(hosts.prefix(3))))
        model.setEnabled(false, for: model.servers[0])
        let preserved = model.selections[0]
        #expect(model.replaceHosts(selectedIDs: hosts.map(\.id), editableHostIDs: Set(hosts.map(\.id))))
        #expect(model.selections.count == 5)
        #expect(model.selections[0] == preserved)
    }

    @Test
    func selectionReplacementAllowsEmptyAndKeepsUnavailableConfigurations() {
        let hosts = fixtures(3)
        let preferences = LimitMetricsPreferences()
        let model = model(hosts, preferences: preferences)
        defer { model.shutdown() }
        #expect(model.add(hosts))

        #expect(model.replaceHosts(selectedIDs: [], editableHostIDs: [hosts[0].id, hosts[1].id]))
        #expect(model.selections.map(\.id) == [hosts[2].id])
        #expect(model.replaceHosts(selectedIDs: [], editableHostIDs: [hosts[2].id]))
        #expect(model.selections.isEmpty)
        #expect(preferences.values.isEmpty)
    }

    @Test
    func failedSelectionReplacementDoesNotPartiallyRemoveOrAddHosts() {
        let hosts = fixtures(3)
        let preferences = LimitMetricsPreferences()
        let model = model(hosts, preferences: preferences)
        defer { model.shutdown() }
        #expect(model.add(Array(hosts.prefix(2))))
        let saved = preferences.values
        preferences.failsSaving = true

        #expect(
            !model.replaceHosts(
                selectedIDs: [hosts[1].id, hosts[2].id], editableHostIDs: Set(hosts.map(\.id))))
        #expect(model.selections == saved)
        #expect(preferences.values == saved)
        #expect(model.storageError != nil)
    }

    @Test
    func freeMetricsDoesNotPresentPaywall() {
        let free = ProAccessController.testing(status: .free)
        let hosts = fixtures(5)
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: free)
        defer { app.shutdownForTermination() }
        #expect(app.serverMetrics.add(hosts))
        #expect(!free.isPaywallPresented)
    }

    private func fixtures(_ count: Int) -> [TermindDomain.Host] {
        (0..<count).map { Host(name: "Fixture \($0)", host: "fixture\($0).invalid") }
    }

    private func model(
        _ hosts: [TermindDomain.Host], preferences: LimitMetricsPreferences = LimitMetricsPreferences()
    ) -> ServerMetricsModel {
        ServerMetricsModel(
            hosts: HostLibraryModel(hosts: hosts), preferences: preferences,
            makeSampler: { SSHMetricsSampler(connection: RemoteConnectionCoordinator().makeConnection()) }
        )
    }
}

private final class LimitMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    var failsSaving = false
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws {
        if failsSaving { throw CocoaError(.fileWriteUnknown) }
        values = selections
    }
}
