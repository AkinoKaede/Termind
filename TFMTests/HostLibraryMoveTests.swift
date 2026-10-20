// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct HostLibraryMoveTests {
    @Test
    func batchMoveAppendsHostsInSuppliedOrder() {
        let source = HostGroup(name: "Source")
        let destination = HostGroup(name: "Destination")
        let existing = Host(
            name: "Existing", host: "existing.example", groupID: destination.id,
            sortIndex: 7
        )
        let first = Host(name: "First", host: "first.example", groupID: source.id)
        let second = Host(name: "Second", host: "second.example")
        let store = HostLibraryModel(
            hosts: [first, existing, second], groups: [source, destination]
        )

        store.move(hostIDs: [second.id, first.id], into: destination.id)

        #expect(store.hosts(in: destination.id).map(\.id) == [existing.id, second.id, first.id])
        #expect(store.host(second.id)?.groupID == destination.id)
        #expect(store.host(first.id)?.groupID == destination.id)
    }

    @Test
    func batchMoveToUngroupedDeduplicatesAndIgnoresMissingHosts() {
        let group = HostGroup(name: "Group")
        let first = Host(name: "First", host: "first.example", groupID: group.id)
        let second = Host(name: "Second", host: "second.example", groupID: group.id)
        let store = HostLibraryModel(hosts: [first, second], groups: [group])

        store.move(hostIDs: [second.id, UUID(), second.id, first.id], into: nil)

        #expect(store.hosts(in: nil).map(\.id) == [second.id, first.id])
    }

    @Test
    func batchMoveRejectsMissingDestinationGroup() {
        let group = HostGroup(name: "Group")
        let host = Host(name: "Host", host: "host.example", groupID: group.id)
        let store = HostLibraryModel(hosts: [host], groups: [group])

        store.move(hostIDs: [host.id], into: UUID())

        #expect(store.host(host.id)?.groupID == group.id)
    }

    @Test
    func batchMoveCanReorderWithinAGroupBeforeAnotherHost() {
        let group = HostGroup(name: "Group")
        let first = Host(name: "First", host: "first.example", groupID: group.id, sortIndex: 1)
        let second = Host(
            name: "Second", host: "second.example", groupID: group.id, sortIndex: 2
        )
        let third = Host(name: "Third", host: "third.example", groupID: group.id, sortIndex: 3)
        let store = HostLibraryModel(hosts: [first, second, third], groups: [group])

        store.move(hostIDs: [third.id], into: group.id, before: first.id)

        #expect(store.hosts(in: group.id).map(\.id) == [third.id, first.id, second.id])
    }

    @Test
    func batchMoveInsertsAContiguousSelectionAcrossGroups() {
        let source = HostGroup(name: "Source")
        let destination = HostGroup(name: "Destination")
        let first = Host(name: "First", host: "first.example", groupID: source.id)
        let second = Host(name: "Second", host: "second.example", groupID: source.id)
        let before = Host(
            name: "Before", host: "before.example", groupID: destination.id, sortIndex: 1
        )
        let after = Host(
            name: "After", host: "after.example", groupID: destination.id, sortIndex: 2
        )
        let store = HostLibraryModel(
            hosts: [first, second, before, after], groups: [source, destination]
        )

        store.move(hostIDs: [second.id, first.id], into: destination.id, before: after.id)

        #expect(
            store.hosts(in: destination.id).map(\.id)
                == [before.id, second.id, first.id, after.id]
        )
    }
}
