import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct HostEditorBindingsTests {
    @Test func creatingRelatedRecordsLeavesExistingSelectionsAndDraftsUntouched() {
        let identity = Identity(name: "Shared", username: "deploy")
        var host = Host(name: "Server", host: "server.invalid")
        host.identityID = identity.id
        host.groupID = UUID()
        var custom = HostCustomIdentityDraft()
        custom.sshUsername = "unsaved-user"
        let original = host
        var creations: [HostEditorCreation] = []
        let fields = HostEditorBindings(
            host: Binding(get: { host }, set: { host = $0 }),
            customIdentity: Binding(get: { custom }, set: { custom = $0 }),
            library: HostLibraryModel(identities: [identity]), create: { creations.append($0) })

        fields.identityChoice.wrappedValue = .new
        fields.telnetIdentityChoice.wrappedValue = .new
        fields.proxyIdentityChoice.wrappedValue = .new
        fields.telnetProxyIdentityChoice.wrappedValue = .new
        fields.groupChoice.wrappedValue = .new

        #expect(host == original)
        #expect(custom.sshUsername == "unsaved-user")
        #expect(fields.identityChoice.wrappedValue == .existing(identity.id))
        #expect(creations == [.identity, .telnetIdentity, .proxyIdentity, .telnetProxyIdentity, .group])
    }

    @Test func telnetCustomAndNoneRemainDistinctWithoutASavedCustomIdentity() {
        let identity = Identity(name: "Shared", username: "deploy")
        var host = Host(name: "Server", host: "server.invalid", telnetEnabled: true)
        var custom = HostCustomIdentityDraft()
        custom.telnetUsername = "unsaved-user"
        let fields = HostEditorBindings(
            host: Binding(get: { host }, set: { host = $0 }),
            customIdentity: Binding(get: { custom }, set: { custom = $0 }),
            library: HostLibraryModel(identities: [identity]), create: { _ in })

        fields.identityChoice.wrappedValue = .existing(identity.id)
        fields.telnetIdentityChoice.wrappedValue = .custom
        #expect(host.telnetIdentityID == nil)
        #expect(fields.telnetIdentityChoice.wrappedValue == .custom)
        fields.telnetIdentityChoice.wrappedValue = .existing(identity.id)
        #expect(host.telnetIdentityID == identity.id)
        fields.telnetIdentityChoice.wrappedValue = .unset
        #expect(host.telnetIdentityID == nil)
        #expect(fields.telnetIdentityChoice.wrappedValue == .unset)
        #expect(custom.telnetUsername == "unsaved-user")
        #expect(host.identityID == identity.id)
    }

    @Test(arguments: [false, true])
    func proxyEditsShareDefaultPortPolicyAndKeepProtocolsIndependent(_ telnet: Bool) {
        var host = Host(name: "Server", host: "server.invalid", telnetEnabled: true)
        var custom = HostCustomIdentityDraft()
        let fields = HostEditorBindings(
            host: Binding(get: { host }, set: { host = $0 }),
            customIdentity: Binding(get: { custom }, set: { custom = $0 }),
            library: HostLibraryModel(), create: { _ in })
        let kind = telnet ? fields.telnetProxyKind : fields.proxyKind
        let port = telnet ? fields.telnetProxyInt(\.port) : fields.proxyInt(\.port)
        let hostname = telnet ? fields.telnetProxyString(\.hostname) : fields.proxyString(\.hostname)

        kind.wrappedValue = .http
        hostname.wrappedValue = "proxy.invalid"
        kind.wrappedValue = .socks5
        #expect(port.wrappedValue == HostProxy.ProtocolKind.socks5.defaultPort)
        #expect(hostname.wrappedValue == "proxy.invalid")
        port.wrappedValue = 9999
        kind.wrappedValue = .http
        #expect(port.wrappedValue == 9999)
        #expect(telnet ? host.proxy == nil : host.telnetProxy == nil)
        kind.wrappedValue = nil
        hostname.wrappedValue = "must-not-recreate.invalid"
        #expect(host.proxy == nil && host.telnetProxy == nil)
    }
}
