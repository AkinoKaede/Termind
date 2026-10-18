import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct VaultEditorProjectionTests {
    @Test func indexedJumpCandidatesMatchAuthoritativeRoutes() {
        let destination = Host(name: "Destination", host: "destination")
        var hosts = (0..<10).map { Host(name: "Hop \($0)", host: "hop\($0)") }
        for index in 1..<hosts.count { hosts[index].jumpHostID = hosts[index - 1].id }
        var cycle = Host(name: "Cycle", host: "cycle")
        cycle.jumpHostID = cycle.id
        var returnsToDestination = Host(name: "Return", host: "return")
        returnsToDestination.jumpHostID = destination.id
        var missing = Host(name: "Missing", host: "missing")
        missing.jumpHostID = UUID()
        var disabled = Host(name: "Disabled", host: "disabled")
        disabled.sshEnabled = false
        var tailscale = Host(name: "Tailscale", host: "tailscale")
        tailscale.tailscale = .init(groupID: UUID(), stableNodeID: "node")
        hosts += [destination, cycle, returnsToDestination, missing, disabled, tailscale]
        let library = HostLibraryModel(hosts: hosts)
        let sections = HostEditorJumpHostProjection.sections(
            for: .init(
                destinationID: destination.id, sshEnabled: true, isTailscaleManaged: false,
                hosts: hosts, groups: []))
        let projected = Set(sections.flatMap(\.hosts).map(\.id))
        for candidate in hosts {
            var proposed = destination
            proposed.jumpHostID = candidate.id
            #expect(projected.contains(candidate.id) == (library.validatedRoute(for: proposed) != nil))
        }
        #expect(projected.contains(hosts[6].id))
        #expect(!projected.contains(hosts[7].id))
        for (sshEnabled, managed) in [(false, false), (true, true)] {
            #expect(
                HostEditorJumpHostProjection.sections(
                    for: .init(
                        destinationID: destination.id, sshEnabled: sshEnabled, isTailscaleManaged: managed,
                        hosts: hosts, groups: [])
                ).isEmpty)
        }
    }

    @Test func jumpSectionsKeepHierarchyAndManualOrder() {
        let first = HostGroup(name: "First", sortIndex: 0)
        let last = HostGroup(name: "Last", sortIndex: 1)
        let child = HostGroup(name: "Child", parentID: first.id)
        var later = Host(name: "Later", host: "later", groupID: first.id)
        later.sortIndex = 2
        var earlier = Host(name: "Earlier", host: "earlier", groupID: first.id)
        earlier.sortIndex = 1
        let nested = Host(name: "Nested", host: "nested", groupID: child.id)
        let final = Host(name: "Final", host: "final", groupID: last.id)
        let ungrouped = Host(name: "Ungrouped", host: "ungrouped")
        let sections = HostEditorJumpHostProjection.sections(
            for: .init(
                destinationID: UUID(), sshEnabled: true, isTailscaleManaged: false,
                hosts: [later, final, nested, earlier, ungrouped], groups: [last, child, first]))
        #expect(sections.map(\.id) == [.group(first.id), .group(child.id), .group(last.id), .ungrouped])
        #expect(sections.first?.hosts.map(\.id) == [earlier.id, later.id])
        #expect(sections[1].title == "First / Child")
    }

    @Test func passwordRevisionRefreshesSameReferenceWritesButNotMetadataEdits() throws {
        let library = HostLibraryModel()
        let credentials = CredentialLibraryModel(library: library)
        let identity = Identity(name: "Test", username: "user")
        try library.upsert(identity, passwordUpdate: .replace("first"))
        let saved = try #require(library.identity(identity.id))
        let initialRevision = credentials.passwordAvailabilityRevision
        try library.upsert(saved, passwordUpdate: .replace("second"))
        #expect(library.identity(identity.id)?.credentialRef == saved.credentialRef)
        #expect(credentials.passwordAvailabilityRevision > initialRevision)
        let replacementRevision = credentials.passwordAvailabilityRevision
        var renamed = saved
        renamed.name = "Renamed"
        try library.upsert(renamed, passwordUpdate: .keep)
        #expect(credentials.passwordAvailabilityRevision == replacementRevision)
        #expect(credentials.passwordAvailability(for: renamed) == .available)
        try library.upsert(renamed, passwordUpdate: .remove)
        #expect(credentials.passwordAvailabilityRevision > replacementRevision)
        #expect(credentials.passwordAvailability(for: saved) == .missing)
    }
}
