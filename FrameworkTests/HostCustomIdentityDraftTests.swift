import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct HostCustomIdentityDraftTests {
    @Test(arguments: 0..<6)
    func editableTextTracksRepeatedEditsAndReversions(fieldIndex: Int) {
        let fields: [WritableKeyPath<HostCustomIdentityDraft, String>] = [
            \.sshUsername, \.sshPassword, \.telnetUsername, \.telnetPassword, \.proxyPassword, \.telnetProxyPassword,
        ]
        let field = fields[fieldIndex]
        var draft = HostCustomIdentityDraft()
        draft[keyPath: field] = "original"
        let original = draft.editableState
        for _ in 0..<2 {
            draft[keyPath: field] = "changed"
            #expect(draft.editableState != original)
            draft[keyPath: field] = "original"
            #expect(draft.editableState == original)
            draft[keyPath: field] = ""
            #expect(draft.editableState != original)
            draft[keyPath: field] = "original"
            #expect(draft.editableState == original)
        }
    }

    @Test func editableSelectionsTrackRepeatedEditsAndReversions() {
        var draft = HostCustomIdentityDraft()
        var host = Host(name: "Server", host: "server.invalid")
        let original = draft.editableState
        for _ in 0..<2 {
            draft.sshKeyID = UUID()
            #expect(draft.editableState != original)
            draft.sshKeyID = nil
            #expect(draft.editableState == original)
            draft.selectCustomTelnet(on: &host)
            #expect(draft.editableState != original)
            draft.clearTelnetIdentity(on: &host)
            #expect(draft.editableState == original)
            draft.usesCustomProxy = true
            #expect(draft.editableState != original)
            draft.usesCustomProxy = false
            #expect(draft.editableState == original)
            draft.usesCustomTelnetProxy = true
            #expect(draft.editableState != original)
            draft.usesCustomTelnetProxy = false
            #expect(draft.editableState == original)
        }
    }

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

        let original = draft.editableState
        draft.proxyPassword = "changed"
        #expect(draft.editableState != original)
        draft.proxyPassword = "proxy-secret"
        #expect(draft.editableState == original)
        draft.sshPassword = ""
        #expect(draft.editableState != original)
        draft.sshPassword = "ssh-secret"
        #expect(draft.editableState == original)

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

    @Test
    func invalidWakePreferencesRejectBeforeChangingIdentitiesOrSecrets() throws {
        let secrets = HostDraftRecordingSecrets()
        var host = Host(
            name: "Server", host: "server.invalid",
            proxy: HostProxy(kind: .http, hostname: "proxy.invalid", port: 8080))
        host.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        let library = HostLibraryModel(hosts: [host], secrets: secrets)
        var initial = HostCustomIdentityDraft(host: host, library: library)
        initial.sshUsername = "original"
        initial.sshPassword = "ssh-original"
        initial.selectCustomProxy(on: &host, using: library)
        host.proxy?.username = "proxy-original"
        initial.proxyPassword = "proxy-original"
        try initial.save(into: &host, using: library)
        let savedHost = try #require(library.host(host.id))
        let identities = library.identities
        let writes = secrets.writeCount
        let ssh = try #require(library.customIdentity(for: host.id, purpose: .ssh))
        let proxy = try #require(library.customIdentity(for: host.id, purpose: .proxy))

        for preferences in [
            WakeOnLANPreferences(macAddress: "", automaticallyWake: true),
            WakeOnLANPreferences(macAddress: "02:11:22:33:44:GG", automaticallyWake: true),
            WakeOnLANPreferences(macAddress: "02:11:22:33:44:GG"),
        ] {
            for removesProxy in [false, true] {
                var candidate = savedHost
                var draft = HostCustomIdentityDraft(host: candidate, library: library)
                draft.sshUsername = "unsaved"
                draft.sshPassword = "ssh-unsaved"
                draft.proxyPassword = "proxy-unsaved"
                if removesProxy { candidate.proxy = nil }
                candidate.wakeOnLAN = preferences
                #expect(throws: WakeOnLANError.self) {
                    try draft.save(into: &candidate, using: library)
                }
                #expect(library.host(host.id) == savedHost)
                #expect(library.identities == identities)
                #expect(secrets.writeCount == writes)
                #expect(try library.editablePassword(for: ssh) == "ssh-original")
                #expect(try library.editablePassword(for: proxy) == "proxy-original")
            }
        }
    }

    @Test
    func invalidWakePreferencesRejectBeforeCreatingIdentityOrSecret() {
        let secrets = HostDraftRecordingSecrets()
        let library = HostLibraryModel(secrets: secrets)
        var host = Host(name: "Server", host: "server.invalid")
        host.wakeOnLAN.automaticallyWake = true
        var draft = HostCustomIdentityDraft()
        draft.sshUsername = "user"
        draft.sshPassword = "password"
        #expect(throws: WakeOnLANError.self) {
            try draft.save(into: &host, using: library)
        }
        #expect(library.hosts.isEmpty)
        #expect(library.identities.isEmpty)
        #expect(secrets.writeCount == 0)
        #expect(host.identityID == nil)
    }
}

private nonisolated final class HostDraftRecordingSecrets: SecretStoring, @unchecked Sendable {
    private let base = InMemorySecretStore()
    private let lock = NSLock()
    private var writes = 0
    var writeCount: Int { lock.withLock { writes } }

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        try base.string(for: account, storage: storage)
    }

    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        try base.keyCredential(for: account, storage: storage)
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        lock.withLock { writes += 1 }
        try base.setString(value, for: account, storage: storage)
    }

    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {
        lock.withLock { writes += 1 }
        try base.setKeyCredential(value, for: account, storage: storage)
    }

    func removePassword(_ account: String, storage: PasswordStorage) throws {
        lock.withLock { writes += 1 }
        try base.removePassword(account, storage: storage)
    }

    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        lock.withLock { writes += 1 }
        try base.removeKeyCredential(account, storage: storage)
    }
}
