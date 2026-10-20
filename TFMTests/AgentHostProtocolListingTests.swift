// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@Suite @MainActor
struct AgentHostProtocolListingTests {
    @Test
    func listingIncludesTelnetOnlyHostsWithProtocolMetadata() async throws {
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

        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(id: "list", name: "list_hosts", arguments: .object([:])))
        let result = try await ListHostsTool(hosts: resolver).execute(
            invocation,
            context: AgentToolExecutionContext(
                runID: invocation.runID, userIntent: "Discover hosts",
                secretBroker: SecretBroker(), userInteraction: UnavailableAgentUserInteraction(),
                preflightMetadata: [:], authorize: { _ in .allow }))
        let payload = try #require(result.untrustedPayload)
        let hosts = try #require(
            try AgentJSONValue.decode(Data(payload.utf8)).objectValue?["hosts"]?.arrayValue)
        let telnetJSON = try #require(
            hosts.first { $0.objectValue?["id"] == .string(telnet.id.uuidString) }?.objectValue)
        #expect(telnetJSON["protocols"]?.arrayValue?.first?.objectValue?["name"] == .string("telnet"))
    }
}
