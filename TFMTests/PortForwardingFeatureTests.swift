import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct PortForwardingFeatureTests {
    @Test
    func proxyIdentityRequiresUsernameAndSavedPassword() {
        let eligible = Identity(
            name: "Proxy", username: "proxy", credentialRef: "password-reference"
        )
        let keyOnly = Identity(name: "Key", username: "proxy", keyID: UUID())
        let missingUsername = Identity(
            name: "Missing", username: "  ", credentialRef: "password-reference"
        )

        #expect(eligible.isProxyEligible)
        #expect(!keyOnly.isProxyEligible)
        #expect(!missingUsername.isProxyEligible)
        #expect(
            IdentityEditorConfiguration.proxy.accepts(
                username: "proxy", password: "secret",
                hasConfiguredPassword: false, removesPassword: false
            )
        )
        #expect(
            !IdentityEditorConfiguration.proxy.accepts(
                username: "proxy", password: "",
                hasConfiguredPassword: false, removesPassword: false
            )
        )
        #expect(
            !IdentityEditorConfiguration.proxy.accepts(
                username: "", password: "secret",
                hasConfiguredPassword: false, removesPassword: false
            )
        )
        #expect(
            IdentityEditorConfiguration.proxy.accepts(
                username: "proxy", password: "",
                hasConfiguredPassword: true, removesPassword: false
            )
        )
    }

    @Test
    func removingPasswordClearsProxyIdentityReference() {
        let identity = Identity(
            name: "Proxy", username: "proxy", credentialRef: "password-reference"
        )
        var host = Host(name: "Server", host: "server.example")
        host.proxy = HostProxy(
            kind: .http, hostname: "proxy.example", port: 8080,
            username: "proxy", identityID: identity.id
        )
        let store = HostLibraryModel(hosts: [host], identities: [identity])
        var withoutPassword = identity
        withoutPassword.credentialRef = ""

        store.upsert(withoutPassword)

        #expect(store.host(host.id)?.proxy?.identityID == nil)
        #expect(store.host(host.id)?.proxy?.username == "")
    }

    @Test
    func defaultsAndValidationMatchTheEditorContract() {
        let hostID = UUID()
        let local = PortForwardingRule(hostID: hostID)
        #expect(local.kind == .local)
        #expect(local.bindHost == "127.0.0.1")
        #expect(local.bindPort == 8080)
        #expect(local.targetHost == "localhost")
        #expect(local.targetPort == 80)
        #expect(local.isValid)

        let dynamic = PortForwardingRule(
            hostID: hostID, kind: .dynamic,
            targetHost: "discarded.example", targetPort: 443
        )
        #expect(dynamic.targetHost == nil)
        #expect(dynamic.targetPort == nil)
        #expect(dynamic.isValid)

        let incomplete = PortForwardingRule(
            hostID: hostID, targetHost: "", targetPort: 0
        )
        #expect(!incomplete.isValid)
    }

    @Test
    func routesAreRootFirstAndRejectCyclesOrMoreThanEightHosts() {
        var chain: [TermindDomain.Host] = []
        for index in 0..<8 {
            var host = Host(name: "Host \(index)", host: "host-\(index).example")
            host.jumpHostID = chain.last?.id
            chain.append(host)
        }
        let store = HostLibraryModel(hosts: chain)
        #expect(
            store.validatedRoute(for: chain.last!)?.map { $0.id }
                == chain.map { $0.id }
        )

        var ninth = Host(name: "Ninth", host: "ninth.example")
        ninth.jumpHostID = chain.last?.id
        #expect(store.validatedRoute(for: ninth) == nil)

        var cycle = chain[0]
        cycle.jumpHostID = chain[1].id
        #expect(store.validatedRoute(for: cycle) == nil)
    }

    @Test
    func deletingReferencesCleansJumpProxyIdentityAndRules() {
        let proxyIdentity = Identity(
            name: "Proxy", username: "proxy",
            credentialRef: "termind.password.\(UUID().uuidString)"
        )
        let jump = Host(name: "Jump", host: "jump.example")
        var destination = Host(name: "Destination", host: "destination.example")
        destination.jumpHostID = jump.id
        destination.proxy = HostProxy(
            kind: .http, hostname: "proxy.example", port: 8080,
            username: "proxy", identityID: proxyIdentity.id
        )
        let rule = PortForwardingRule(hostID: jump.id)
        let store = HostLibraryModel(
            hosts: [jump, destination], identities: [proxyIdentity],
            portForwardings: [rule]
        )

        store.projectHostDeletion(jump.id)
        #expect(store.host(destination.id)?.jumpHostID == nil)
        #expect(store.portForwarding(rule.id) == nil)

        store.delete(identityID: proxyIdentity.id)
        #expect(store.host(destination.id)?.proxy?.identityID == nil)
        #expect(store.host(destination.id)?.proxy?.username == "")
    }

    @Test
    func termindV1RoundTripKeepsRoutesAndDropsDynamicTargets() throws {
        let configuration = localModelConfiguration(
            "PortForwardingFeatureTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema,
            configurations: [configuration]
        )
        let store = HostLibraryModel(modelContext: container.mainContext)
        let jump = Host(name: "Jump", host: "jump.example")
        var destination = Host(name: "Destination", host: "destination.example")
        destination.jumpHostID = jump.id
        destination.proxy = HostProxy(
            kind: .socks5, hostname: "proxy.example", port: 1080
        )
        let dynamic = PortForwardingRule(
            hostID: destination.id, kind: .dynamic,
            bindHost: "::1", bindPort: 1088,
            targetHost: "must-not-persist", targetPort: 443, label: "Browser"
        )

        store.upsert(jump)
        store.upsert(destination)
        store.upsert(dynamic)

        let reloaded = HostLibraryModel(modelContext: container.mainContext)
        #expect(reloaded.host(destination.id)?.jumpHostID == jump.id)
        #expect(reloaded.host(destination.id)?.proxy?.kind == .socks5)
        #expect(reloaded.portForwarding(dynamic.id)?.targetHost == nil)
        #expect(reloaded.portForwarding(dynamic.id)?.targetPort == nil)
    }

    @Test
    func sshCommandUsesJumpAndIsUnavailableForProxyRoutes() {
        let identity = Identity(name: "Deploy", username: "deploy")
        var jump = Host(name: "Jump", host: "jump.example", identityID: identity.id)
        let destinationIdentity = Identity(name: "Root", username: "root")
        let destination = Host(
            name: "Destination", host: "destination.example", port: 2222,
            identityID: destinationIdentity.id, jumpHostID: jump.id
        )
        let rule = PortForwardingRule(
            hostID: destination.id, bindPort: 15432,
            targetHost: "db.internal", targetPort: 5432
        )
        let store = HostLibraryModel(
            hosts: [jump, destination], identities: [identity, destinationIdentity]
        )
        let command = store.sshCommand(for: rule)
        #expect(
            command
                == "ssh -N -L 127.0.0.1:15432:db.internal:5432 -J deploy@jump.example -p 2222 root@destination.example"
        )

        jump.proxy = HostProxy(kind: .http, hostname: "proxy.example", port: 8080)
        let proxiedStore = HostLibraryModel(
            hosts: [jump, destination], identities: [identity, destinationIdentity]
        )
        #expect(proxiedStore.sshCommand(for: rule) == nil)
    }

    @Test
    func sshCommandsCoverHostRoutesIPv6AndShellQuoting() {
        let jumpIdentity = Identity(name: "Jump Login", username: "deploy")
        let destinationIdentity = Identity(name: "Destination Login", username: "root")
        let jump = Host(
            name: "IPv6 Jump", host: "2001:db8::10", port: 2200,
            identityID: jumpIdentity.id
        )
        let destination = Host(
            name: "Destination", host: "destination host", port: 2222,
            identityID: destinationIdentity.id, jumpHostID: jump.id
        )
        let store = HostLibraryModel(
            hosts: [jump, destination], identities: [jumpIdentity, destinationIdentity]
        )

        let command = store.sshCommand(for: destination)
        #expect(command == "ssh -J 'deploy@[2001:db8::10]:2200' -p 2222 'root@destination host'")

        let dynamic = PortForwardingRule(
            hostID: destination.id, kind: .dynamic,
            bindHost: "::1", bindPort: 1080
        )
        #expect(
            store.sshCommand(for: dynamic)
                == "ssh -N -D '[::1]:1080' -J 'deploy@[2001:db8::10]:2200' -p 2222 'root@destination host'"
        )
    }

    @Test(arguments: [
        ("root", "192.236.229.190", 22, "ssh root@192.236.229.190"),
        ("deploy-user", "192.0.2.10", 22, "ssh deploy-user@192.0.2.10"),
        ("deploy-user", "server.example", 2222, "ssh -p 2222 deploy-user@server.example"),
        ("root", "2001:db8::10", 22, "ssh root@2001:db8::10"),
        ("", "server.example", 22, "ssh server.example"),
        ("USER_1%+=:,./-", "server.example", 22, "ssh USER_1%+=:,./-@server.example"),
    ])
    func sshCommandDoesNotQuoteExecutableOrOrdinaryLoginAddress(
        username: String, address: String, port: Int, expected: String
    ) {
        let identity = Identity(name: "Login", username: username)
        let host = Host(
            name: "Server", host: address, port: port,
            identityID: identity.id
        )
        let store = HostLibraryModel(hosts: [host], identities: [identity])

        #expect(store.sshCommand(for: host) == expected)
    }

    @Test(arguments: [
        ("root", "server host", "ssh 'root@server host'"),
        ("o'brien", "server.example", "ssh 'o'\"'\"'brien@server.example'"),
        ("root", "$HOME", "ssh 'root@$HOME'"),
        ("root", "server;whoami", "ssh 'root@server;whoami'"),
        ("root", "[2001:db8::10]", "ssh 'root@[2001:db8::10]'"),
        ("用户", "server.example", "ssh '用户@server.example'"),
        ("", ";", "ssh ';'"),
        ("", "$", "ssh '$'"),
        ("", "*", "ssh '*'"),
        ("", "'", "ssh ''\"'\"''"),
        ("", "", "ssh ''"),
    ])
    func sshCommandPreservesShellQuoting(username: String, address: String, expected: String) {
        let identity = Identity(name: "Login", username: username)
        let host = Host(name: "Server", host: address, identityID: identity.id)
        let store = HostLibraryModel(hosts: [host], identities: [identity])

        #expect(store.sshCommand(for: host) == expected)
    }

    @Test(arguments: [
        ("operator", "console.example", "telnet -l operator console.example 2323"),
        ("o'brien", "console host", "telnet -l 'o'\"'\"'brien' 'console host' 2323"),
        ("$", ";", "telnet -l '$' ';' 2323"),
    ])
    func telnetCommandUsesTheSameShellQuoting(username: String, address: String, expected: String) {
        let identity = Identity(name: "Login", username: username)
        let host = Host(
            name: "Console", host: address, sshEnabled: false, telnetEnabled: true,
            telnetPort: 2323, telnetIdentityID: identity.id
        )
        let store = HostLibraryModel(hosts: [host], identities: [identity])

        #expect(store.telnetCommand(for: host) == expected)
    }

    @Test
    func savingAHostPreservesItsIndependentForwardingRules() {
        var host = Host(name: "First", host: "first.example")
        let rule = PortForwardingRule(hostID: host.id)
        let store = HostLibraryModel(hosts: [host], portForwardings: [rule])
        host.name = "Renamed"
        #expect(store.saveHost(host))
        #expect(store.portForwardings == [rule])
    }
}
