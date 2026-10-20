// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct ForwardingLibraryTests {
    @Test func rulesSaveRebindAndDeleteWithoutRewritingHosts() throws {
        let first = Host(name: "First", host: "first.invalid")
        let second = Host(name: "Second", host: "second.invalid")
        let store = HostLibraryModel(hosts: [first, second])
        let model = ForwardingLibraryModel(library: store)
        var rule = PortForwardingRule(hostID: first.id, label: "Database")
        try model.save(rule)
        let savedHosts = store.hosts
        rule.hostID = second.id
        try model.save(rule)
        #expect(model.rules == [rule])
        #expect(store.hosts == savedHosts)
        #expect(store.portForwardings(for: first.id).isEmpty)
        #expect(model.search("second").map(\.id) == [rule.id])
        #expect(model.search("Database").map(\.id) == [rule.id])
        #expect(model.search("8080").map(\.id) == [rule.id])
        try model.delete(rule.id)
        #expect(model.rules.isEmpty)
        #expect(store.hosts == savedHosts)
    }

    @Test func failedSavesAndDeletesRollbackTheRuleSnapshot() throws {
        let host = Host(name: "Server", host: "server.invalid")
        let other = Host(name: "Other", host: "other.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let persistence = ForwardingPersistence(snapshot: VaultSnapshot(hosts: [host, other], portForwardings: [rule]))
        let store = HostLibraryModel(persistence: persistence)
        let model = ForwardingLibraryModel(library: store)
        persistence.fails = true
        var changed = rule
        changed.hostID = other.id
        changed.bindPort = 9000
        changed.colorTag = .orange
        #expect(throws: (any Error).self) { try model.save(changed) }
        #expect(model.rules == [rule])
        #expect(persistence.snapshot.portForwardings == [rule])
        #expect(store.hosts == [host, other])
        #expect(throws: (any Error).self) { try model.delete(rule.id) }
        #expect(model.rules == [rule])
        let new = PortForwardingRule(hostID: host.id, bindPort: 9090)
        #expect(throws: (any Error).self) { try model.save(new) }
        #expect(model.rules == [rule])
        persistence.fails = false
        let saved = try model.save(changed)
        #expect(saved.label == "Other (-L)")
        changed.label = saved.label
        #expect(model.rules == [changed])
    }

    @Test func invalidHostIsRejectedAndOrphansRemainDeletable() throws {
        let orphan = PortForwardingRule(hostID: UUID())
        let store = HostLibraryModel(portForwardings: [orphan])
        let model = ForwardingLibraryModel(library: store)
        #expect(throws: (any Error).self) { try model.save(orphan) }
        try model.delete(orphan.id)
        #expect(model.rules.isEmpty)
    }

    @Test func hostSaveFailurePreservesItsConfigurationAndRules() {
        var host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let persistence = ForwardingPersistence(snapshot: VaultSnapshot(hosts: [host], portForwardings: [rule]))
        let store = HostLibraryModel(persistence: persistence)
        persistence.fails = true
        host.port = 2222
        #expect(!store.saveHost(host))
        #expect(store.host(host.id)?.port == 22)
        #expect(store.portForwardings == [rule])
    }
}

@MainActor
private final class ForwardingPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var fails = false
    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(
        _ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>
    ) throws -> VaultMutationSet {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
}
