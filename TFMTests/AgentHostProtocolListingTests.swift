import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@Suite @MainActor
struct AgentHostProtocolListingTests {
    @Test
    func listingIncludesTelnetOnlyHostsWithProtocolMetadata() {
        let ssh = Host(name: "SSH", host: "ssh.invalid")
        let telnet = Host(
            name: "Telnet", host: "telnet.invalid",
            sshEnabled: false, telnetEnabled: true)
        let resolver = AgentHostResolver(store: HostLibraryModel(hosts: [ssh, telnet]))

        let listing = resolver.listing()
        #expect(listing.hosts.map(\.id) == [ssh.id, telnet.id])
        #expect(listing.hosts[0].protocols.map(\.name) == [.ssh])
        #expect(listing.hosts[1].protocols.map(\.name) == [.telnet])
        #expect(!resolver.canResolve(telnet.id))
    }
}
