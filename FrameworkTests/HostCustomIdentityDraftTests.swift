import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct HostCustomIdentityDraftTests {
    @Test
    func loadsAndSavesSSHAndProxyCustomIdentities() throws {
        let secrets = InMemorySecretStore()
        var host = Host(
            name: "Server", host: "server.invalid",
            proxy: HostProxy(kind: .http, hostname: "proxy.invalid", port: 8080))
        let library = HostLibraryModel(hosts: [host], secrets: secrets)
        let ssh = try #require(
            try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .ssh, displayName: host.name,
                username: "deploy", password: "ssh-secret", keyID: nil))
        let proxy = try #require(
            try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "Server Proxy",
                username: "proxy-user", password: "proxy-secret", keyID: nil))
        host.identityID = ssh.id
        host.proxy?.identityID = proxy.id
        host.proxy?.username = proxy.username
        #expect(library.saveHost(host))

        var draft = HostCustomIdentityDraft(host: host, library: library)
        #expect(draft.sshUsername == "deploy")
        #expect(draft.sshPassword == "ssh-secret")
        #expect(draft.usesCustomProxy)
        #expect(draft.proxyPassword == "proxy-secret")
        #expect(draft.sshPasswordIsEditable)
        #expect(draft.proxyPasswordIsEditable)
        #expect(draft.isSSHValid(for: host))
        #expect(draft.isProxyValid(for: host))

        draft.sshUsername = "root"
        draft.proxyPassword = "new-proxy-secret"
        try draft.save(into: &host, using: library)

        let savedSSH = try #require(library.customIdentity(for: host.id, purpose: .ssh))
        let savedProxy = try #require(library.customIdentity(for: host.id, purpose: .proxy))
        #expect(savedSSH.id == ssh.id)
        #expect(savedSSH.ownerHostID == host.id)
        #expect(savedSSH.customPurpose == .ssh)
        #expect(savedSSH.username == "root")
        #expect(savedProxy.id == proxy.id)
        #expect(savedProxy.ownerHostID == host.id)
        #expect(savedProxy.customPurpose == .proxy)
        #expect(try library.editablePassword(for: savedProxy) == "new-proxy-secret")
        #expect(library.host(host.id)?.identityID == savedSSH.id)
        #expect(library.host(host.id)?.proxy?.identityID == savedProxy.id)
    }

    @Test
    func reusableSelectionsRetainCustomIdentitiesUntilTheirOwnerOrProxyIsRemoved() throws {
        var host = Host(
            name: "Server", host: "server.invalid",
            proxy: HostProxy(kind: .socks5, hostname: "proxy.invalid", port: 1080))
        let reusable = Identity(name: "Reusable", username: "shared")
        let library = HostLibraryModel(hosts: [host], identities: [reusable])
        let ssh = try #require(
            try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .ssh, displayName: host.name,
                username: "deploy", password: "", keyID: nil))
        let proxy = try #require(
            try library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "Server Proxy",
                username: "proxy-user", password: "secret", keyID: nil))
        host.identityID = ssh.id
        host.proxy?.identityID = proxy.id
        host.proxy?.username = proxy.username

        var draft = HostCustomIdentityDraft(host: host, library: library)
        draft.selectSSHIdentity(reusable, on: &host)
        draft.selectProxyIdentity(reusable, on: &host)
        try draft.save(into: &host, using: library)
        #expect(library.customIdentity(for: host.id, purpose: .ssh)?.id == ssh.id)
        #expect(library.customIdentity(for: host.id, purpose: .proxy)?.id == proxy.id)
        #expect(library.host(host.id)?.identityID == reusable.id)
        #expect(library.host(host.id)?.proxy?.identityID == reusable.id)

        host.proxy = nil
        try draft.save(into: &host, using: library)
        #expect(library.customIdentity(for: host.id, purpose: .proxy) == nil)
        #expect(library.customIdentity(for: host.id, purpose: .ssh)?.id == ssh.id)
    }

    @Test
    func unavailableProxyPasswordAllowsMetadataEditingButNotPasswordEditing() throws {
        let hostID = UUID()
        let proxy = Identity(
            name: "Proxy", username: "proxy-user", credentialRef: "missing-password",
            passwordStorage: .thisDevice, ownerHostID: hostID, customPurpose: .proxy)
        var host = Host(
            id: hostID, name: "Server", host: "server.invalid",
            proxy: HostProxy(
                kind: .http, hostname: "proxy.invalid", port: 8080,
                username: proxy.username, identityID: proxy.id))
        let library = HostLibraryModel(
            hosts: [host], identities: [proxy], secrets: InMemorySecretStore())
        var draft = HostCustomIdentityDraft(host: host, library: library)

        #expect(draft.usesCustomProxy)
        #expect(!draft.proxyPasswordIsEditable)
        #expect(draft.proxyPassword.isEmpty)
        #expect(draft.isProxyValid(for: host))

        host.proxy?.hostname = "renamed-proxy.invalid"
        try draft.save(into: &host, using: library)
        #expect(library.host(host.id)?.proxy?.hostname == "renamed-proxy.invalid")
        #expect(library.customIdentity(for: host.id, purpose: .proxy)?.credentialRef == "missing-password")
    }

    @Test
    func emptyCustomAuthenticationIsValidAndPersistsNoIdentity() throws {
        var host = Host(
            name: "Server", host: "server.invalid",
            proxy: HostProxy(kind: .http, hostname: "proxy.invalid", port: 8080))
        let library = HostLibraryModel(hosts: [host])
        var draft = HostCustomIdentityDraft(host: host, library: library)
        draft.selectCustomSSH(on: &host)
        draft.selectCustomProxy(on: &host, using: library)

        #expect(draft.isSSHValid(for: host))
        #expect(draft.isProxyValid(for: host))
        try draft.save(into: &host, using: library)
        #expect(library.customIdentity(for: host.id, purpose: .ssh) == nil)
        #expect(library.customIdentity(for: host.id, purpose: .proxy) == nil)
        #expect(library.host(host.id)?.identityID == nil)
        #expect(library.host(host.id)?.proxy?.identityID == nil)
    }
}
