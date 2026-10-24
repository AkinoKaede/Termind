// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileCardReorderingTests {
    @Test(arguments: [(0, 1), (0, 7), (3, 4), (7, 0), (4, 3), (6, 2)])
    func reordersInBothDirectionsIncludingAcrossCompactGridRows(source: Int, target: Int) throws {
        let ids = (0..<8).map { _ in UUID() }
        let scope = UUID()
        let policy = MobileCardReordering(collection: .hosts, allowedIDs: Set(ids))
        let payload = MobileCardDragItem(id: ids[source], scope: scope, collection: .hosts)
        let move = try #require(policy.resolve([payload], scope: scope, target: ids[target], orderedIDs: ids))
        var result = ids.filter { $0 != move.id }
        let insertion = move.before.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(move.id, at: insertion)
        #expect(result[target] == ids[source])
        #expect(result.filter { $0 != move.id } == ids.filter { $0 != move.id })
    }

    @Test func acceptsCrossGroupCardsAndEmptyOrFoldedSectionHeaders() throws {
        let moving = UUID()
        let target = UUID()
        let scope = UUID()
        let policy = MobileCardReordering(collection: .snippets, allowedIDs: [moving, target])
        let payload = MobileCardDragItem(id: moving, scope: scope, collection: .snippets)
        #expect(
            policy.resolve([payload], scope: scope, target: target, orderedIDs: [target])
                == MobileCardMove(id: moving, before: target))
        #expect(
            policy.resolve([payload], scope: scope, target: nil, orderedIDs: [])
                == MobileCardMove(id: moving, before: nil))
        #expect(
            policy.resolve([payload], scope: scope, target: nil, orderedIDs: [target])
                == MobileCardMove(id: moving, before: nil))
    }

    @Test func rejectsOtherPagesCollectionsDeletedOrProtectedCardsAndMultipleItems() {
        let id = UUID()
        let target = UUID()
        let scope = UUID()
        let policy = MobileCardReordering(collection: .keys, allowedIDs: [id, target])
        let valid = MobileCardDragItem(id: id, scope: scope, collection: .keys)
        let rejected = [
            MobileCardDragItem(id: id, scope: UUID(), collection: .keys),
            MobileCardDragItem(id: id, scope: scope, collection: .identities),
            MobileCardDragItem(id: UUID(), scope: scope, collection: .keys),
        ]
        for payload in rejected {
            #expect(policy.resolve([payload], scope: scope, target: target, orderedIDs: [id, target]) == nil)
        }
        #expect(policy.resolve([], scope: scope, target: target, orderedIDs: [id, target]) == nil)
        #expect(policy.resolve([valid, valid], scope: scope, target: target, orderedIDs: [id, target]) == nil)
        #expect(policy.resolve([valid], scope: scope, target: UUID(), orderedIDs: [id, target]) == nil)
        #expect(policy.resolve([valid], scope: scope, target: id, orderedIDs: [id, target]) == nil)
        #expect(policy.resolve([valid], scope: scope, target: nil, orderedIDs: [target, id]) == nil)
    }

    @Test func hostDropMovesBetweenGroupsAndReopensInTheSavedOrder() throws {
        let app = try MobileAppModel(inMemory: true)
        let first = HostGroup(name: "First")
        let second = HostGroup(name: "Second")
        app.library.upsert(first)
        app.library.upsert(second)
        let moving = TermindDomain.Host(name: "Moving", host: "moving.invalid", groupID: first.id)
        let target = TermindDomain.Host(name: "Target", host: "target.invalid", groupID: second.id)
        app.library.upsert(moving)
        app.library.upsert(target)
        let scope = UUID()
        let policy = MobileCardReordering(collection: .hosts, allowedIDs: [moving.id, target.id])
        let payload = MobileCardDragItem(id: moving.id, scope: scope, collection: .hosts)
        let request = try #require(
            policy.resolve([payload], scope: scope, target: target.id, orderedIDs: [target.id]))
        app.library.move(hostIDs: [request.id], into: second.id, before: request.before)
        #expect(app.library.hosts(in: first.id).isEmpty)
        #expect(app.library.hosts(in: second.id).map(\.id) == [moving.id, target.id])
        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(stored.hosts.first { $0.id == moving.id }?.groupID == second.id)
        #expect(
            stored.hosts.filter { $0.groupID == second.id }.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
                == [moving.id, target.id])

        app.library.move(hostIDs: [moving.id], into: nil)
        let ungrouped = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(ungrouped.hosts.first { $0.id == moving.id }?.groupID == nil)
    }

    @Test func snippetDropIntoAnEmptyPackagePersistsWithoutChangingContent() throws {
        let app = try MobileAppModel(inMemory: true)
        let package = SnippetPackage(name: "Destination")
        app.snippets.upsert(package)
        let snippet = Snippet(title: "Inspect", body: "pwd")
        app.snippets.upsert(snippet)
        app.snippets.setSnippetPackageExpanded(false, for: package.id)
        let scope = UUID()
        let policy = MobileCardReordering(collection: .snippets, allowedIDs: [snippet.id])
        let request = try #require(
            policy.resolve(
                [MobileCardDragItem(id: snippet.id, scope: scope, collection: .snippets)],
                scope: scope, target: nil, orderedIDs: []))
        app.snippets.move(snippetIDs: [request.id], into: package.id, before: request.before)
        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        let saved = try #require(stored.snippets.first { $0.id == snippet.id })
        #expect(saved.packageID == package.id)
        #expect(saved.body == "pwd")
        #expect(app.snippets.isSnippetPackageExpanded(package.id))
    }

    @Test func keyAndIdentityOrderRoundTripsIndependently() throws {
        let app = try MobileAppModel(inMemory: true)
        let keys = (0..<3).map { SSHKeyRef(label: "Key \($0)", algorithm: .ed25519) }
        let identities = (0..<3).map { Identity(name: "Identity \($0)", username: "deploy") }
        for key in keys { try app.credentials.upsert(key) }
        for identity in identities { #expect(app.library.upsert(identity)) }
        app.credentials.move(keyIDs: [keys[0].id], before: nil)
        app.credentials.move(identityIDs: [identities[2].id], before: identities[0].id)
        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(
            stored.keys.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
                == [keys[1].id, keys[2].id, keys[0].id])
        #expect(
            stored.identities.sorted { $0.sortIndex < $1.sortIndex }.map(\.id)
                == [identities[2].id, identities[0].id, identities[1].id])
    }

    @Test func metricsDropPersistsOrderAndRetainsLiveServerInstances() throws {
        let app = try MobileAppModel(inMemory: true)
        let defaults = try #require(UserDefaults(suiteName: "card-order-\(UUID())"))
        let store = MetricsSyncPersistence(context: ModelContext(app.container), defaults: defaults)
        let hosts = (0..<3).map { TermindDomain.Host(name: "Host \($0)", host: "host\($0).invalid") }
        for host in hosts { app.library.upsert(host) }
        let metrics = MobileMetricsModel(preferences: store, hosts: app.library, services: .testing)
        defer { metrics.core.shutdown() }
        metrics.pause()
        #expect(metrics.add(hosts.map(\.id)))
        let first = try #require(metrics.servers.first)
        let scope = UUID()
        let policy = MobileCardReordering(collection: .metrics, allowedIDs: Set(hosts.map(\.id)))
        let request = try #require(
            policy.resolve(
                [MobileCardDragItem(id: first.id, scope: scope, collection: .metrics)], scope: scope,
                target: hosts[2].id, orderedIDs: metrics.servers.map(\.id)))
        metrics.core.move([request.id], before: request.before)
        #expect(metrics.servers.map(\.id) == [hosts[1].id, hosts[2].id, hosts[0].id])
        #expect(metrics.servers.last === first)
        let reopened = MobileMetricsModel(
            preferences: MetricsSyncPersistence(context: ModelContext(app.container), defaults: defaults),
            hosts: app.library, services: .testing)
        defer { reopened.core.shutdown() }
        reopened.pause()
        reopened.core.start()
        #expect(reopened.selections.map(\.id) == [hosts[1].id, hosts[2].id, hosts[0].id])
    }

    @Test func failedMetricsSaveLeavesTheOriginalOrderIntact() {
        let hosts = (0..<3).map { TermindDomain.Host(name: "Host \($0)", host: "host\($0).invalid") }
        let store = ReorderMetricsPreferences()
        let metrics = MobileMetricsModel(
            preferences: store, hosts: HostLibraryModel(hosts: hosts), services: .testing)
        defer { metrics.core.shutdown() }
        metrics.pause()
        #expect(metrics.add(hosts.map(\.id)))
        store.failsSaving = true
        metrics.core.move([hosts[0].id], before: nil)
        #expect(metrics.selections.map(\.id) == hosts.map(\.id))
        #expect(store.values.map(\.id) == hosts.map(\.id))
        #expect(metrics.core.storageError != nil)
    }
}

private final class ReorderMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    var failsSaving = false
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws {
        if failsSaving { throw CocoaError(.fileWriteUnknown) }
        values = selections
    }
}
