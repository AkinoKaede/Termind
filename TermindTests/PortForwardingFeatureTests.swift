import Foundation
import SwiftData
import Testing

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
                hasSavedPassword: false, removesPassword: false
            )
        )
        #expect(
            !IdentityEditorConfiguration.proxy.accepts(
                username: "proxy", password: "",
                hasSavedPassword: false, removesPassword: false
            )
        )
        #expect(
            !IdentityEditorConfiguration.proxy.accepts(
                username: "", password: "secret",
                hasSavedPassword: false, removesPassword: false
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
        var chain: [Termind.Host] = []
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

        store.delete(hostID: jump.id)
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
        #expect(command?.contains("-J deploy@jump.example") == true)
        #expect(command?.contains("-p 2222") == true)
        #expect(command?.contains("-L 127.0.0.1:15432:db.internal:5432") == true)

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
        #expect(command?.contains("-J 'deploy@[2001:db8::10]:2200'") == true)
        #expect(command?.contains("-p 2222") == true)
        #expect(command?.hasSuffix("'root@destination host'") == true)

        let dynamic = PortForwardingRule(
            hostID: destination.id, kind: .dynamic,
            bindHost: "::1", bindPort: 1080
        )
        #expect(
            store.sshCommand(for: dynamic)?.contains("-D '[::1]:1080'") == true
        )
    }

    @Test
    func sshCommandKeepsAnOrdinaryLoginAddressReadable() {
        let identity = Identity(name: "Developer", username: "developer")
        let host = Host(
            name: "Example Server", host: "server.example.com",
            identityID: identity.id
        )
        let store = HostLibraryModel(hosts: [host], identities: [identity])

        #expect(
            store.sshCommand(for: host)
                == "ssh developer@server.example.com"
        )
    }

    @Test
    func hostAndForwardingDraftsCommitAsOneHostScopedCollection() {
        let first = Host(name: "First", host: "first.example")
        let second = Host(name: "Second", host: "second.example")
        let oldFirstRule = PortForwardingRule(hostID: first.id, bindPort: 8000)
        let secondRule = PortForwardingRule(hostID: second.id, bindPort: 9000)
        let store = HostLibraryModel(
            hosts: [first, second], portForwardings: [oldFirstRule, secondRule]
        )
        var renamed = first
        renamed.name = "First Renamed"
        let replacement = PortForwardingRule(
            hostID: UUID(), kind: .remote, bindPort: 8080,
            targetHost: "localhost", targetPort: 3000
        )

        #expect(store.upsert(renamed, replacingPortForwardings: [replacement]))
        #expect(store.host(first.id)?.name == "First Renamed")
        #expect(store.portForwarding(oldFirstRule.id) == nil)
        #expect(store.portForwarding(replacement.id)?.hostID == first.id)
        #expect(store.portForwarding(secondRule.id) == secondRule)

        let invalid = PortForwardingRule(
            hostID: first.id, bindPort: 0, targetHost: "", targetPort: 0
        )
        #expect(!store.upsert(renamed, replacingPortForwardings: [invalid]))
        #expect(store.portForwarding(replacement.id) != nil)
    }
}
