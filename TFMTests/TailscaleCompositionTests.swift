import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct TailscaleCompositionTests {
    @Test func defaultMemoryCompositionCannotStartOrEraseLiveProfiles() async throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        let profileID = UUID()
        try store.save(.init(groupID: group.id, profileID: profileID))
        let app = AppModel(hosts: library, tailscaleStore: store)
        for _ in 0..<200 where app.tailscale.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(app.tailscale.error != nil)
        #expect(app.tailscale.runningGroups.isEmpty)
        await app.tailscale.logout(groupID: group.id)
        // The disabled eraser fails closed, leaving the retry marker untouched.
        #expect(try store.pendingCleanupProfiles() == [profileID])
        await app.shutdownForTermination().value
    }
}
