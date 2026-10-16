import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct LocalNetworkActionTests {
    enum IdentitySelection: CaseIterable { case unsaved, hostCustom, reusable }

    @Test(arguments: IdentitySelection.allCases)
    func macLookupUsesOnlyTheSelectedEditorAuthentication(_ selection: IdentitySelection) async throws {
        let secrets = InMemorySecretStore()
        var host = Host(
            name: "Server", host: "draft.invalid",
            proxy: .init(hostname: "proxy.invalid", username: "proxy-user"))
        host.wakeOnLAN = .init(macAddress: "02:11:22:33:44:55", automaticallyWake: true)
        let custom = selection == .hostCustom
        let identity = Identity(
            name: "Login", username: "saved-user", credentialRef: "saved-ssh",
            ownerHostID: custom ? host.id : nil, customPurpose: custom ? .ssh : nil)
        let proxyIdentity = Identity(
            name: "Proxy", username: "proxy-user", credentialRef: "saved-proxy",
            ownerHostID: custom ? host.id : nil, customPurpose: custom ? .proxy : nil)
        let key = SSHKeyRef(label: "Draft key", credentialRef: "draft-key")
        try secrets.setString("saved-password", for: identity.credentialRef, storage: identity.passwordStorage)
        try secrets.setString(
            "saved-proxy-password", for: proxyIdentity.credentialRef, storage: proxyIdentity.passwordStorage)
        try secrets.setKeyCredential(
            .software(.init(privateKey: "draft-private-key")), for: key.credentialRef, storage: key.storage)
        if selection != .unsaved {
            host.identityID = identity.id
            host.proxy?.identityID = proxyIdentity.id
        } else {
            host.proxy = nil
        }
        let library = HostLibraryModel(
            hosts: selection == .unsaved ? [] : [host], keys: [key],
            identities: selection == .unsaved ? [] : [identity, proxyIdentity], secrets: secrets)
        let originalHosts = library.hosts
        let originalIdentities = library.identities
        let sender = ManualWakeSender()
        library.wakeOnLAN = WakeOnLANController(sender: sender)
        var draft = HostCustomIdentityDraft(host: host, library: library)
        draft.sshUsername = "draft-user"
        draft.sshPassword = "draft-password"
        draft.sshKeyID = key.id
        draft.usesCustomProxy = selection != .reusable
        draft.proxyPassword = "draft-proxy-password"
        let usesDraft = selection != .reusable
        let resolver = MACLookupRecorder(
            password: usesDraft ? "draft-password" : "saved-password",
            proxyPassword: host.proxy == nil ? nil : (usesDraft ? "draft-proxy-password" : "saved-proxy-password"))
        let model = HostMACAddressModel(
            host: host, library: library, resolver: resolver, custom: draft, tailscaleUsername: "ignored")
        defer { model.cancel() }
        model.start()
        try await finish(model)
        #expect(await resolver.username == (usesDraft ? "draft-user" : "saved-user"))
        #expect(await resolver.hasDraftKey == usesDraft)
        #expect(await resolver.proxyUsername == (host.proxy == nil ? nil : "proxy-user"))
        #expect(await resolver.receivedHost == "draft.invalid")
        #expect(await resolver.hasWakeAction == false)
        #expect(await resolver.secretsAreCleared)
        #expect(sender.sent.isEmpty)
        #expect(library.hosts == originalHosts)
        #expect(library.identities == originalIdentities)
        #expect(try secrets.string(for: identity.credentialRef, storage: identity.passwordStorage) == "saved-password")
        #expect(
            try secrets.string(for: proxyIdentity.credentialRef, storage: proxyIdentity.passwordStorage)
                == "saved-proxy-password")
    }

    @Test func macLookupUsesTailscaleUsernameWithoutEditorCredentialsOrWrites() async throws {
        var group = HostGroup(name: "Tailnet")
        group.tailscale = .init(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net"))
        var host = Host(name: "Managed", host: "managed.example.ts.net", groupID: group.id)
        host.tailscale = .init(groupID: group.id, stableNodeID: "node")
        let library = HostLibraryModel(groups: [group])
        let provider = MACLookupTailscaleProvider()
        library.tailscaleConnections = provider
        var draft = HostCustomIdentityDraft()
        draft.sshUsername = "ignored"
        draft.sshPassword = "ignored"
        draft.sshKeyID = UUID()
        let resolver = MACLookupRecorder()
        let model = HostMACAddressModel(
            host: host, library: library, resolver: resolver, custom: draft, tailscaleUsername: "operator")
        defer { model.cancel() }
        model.start()
        try await finish(model)
        #expect(await resolver.username == "operator")
        #expect(await resolver.credentialCount == 0)
        #expect(await resolver.hasNetwork)
        #expect(library.hosts.isEmpty && library.identities.isEmpty)
        #expect(library.groups == [group])
    }

    @Test func lockedManualWakeNeverSendsOrRequestsConfiguration() {
        var hosts = (0..<4).map {
            Host(name: "Host \($0)", host: "host.invalid", createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        hosts[3].wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let library = HostLibraryModel(hosts: hosts)
        library.hostAccess.entitlement = .free
        let sender = ManualWakeSender()
        library.wakeOnLAN = WakeOnLANController(sender: sender)
        #expect(library.requestWake(hosts[3]) == .accessDenied)
        #expect(sender.sent.isEmpty)
        library.hostAccess.entitlement = .purchased(.purchased)
        #expect(library.requestWake(hosts[3]) == .sent)
        #expect(sender.sent.count == 1)
    }

    @Test func manualWakeReadsLatestSavedPreferences() {
        var host = Host(name: "Host", host: "host.invalid")
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let library = HostLibraryModel(hosts: [host])
        let sender = ManualWakeSender()
        library.wakeOnLAN = WakeOnLANController(sender: sender)
        var updated = host
        updated.wakeOnLAN.macAddress = "02:11:22:33:44:66"
        library.upsert(updated)
        #expect(library.requestWake(host) == .sent)
        #expect(sender.sent.map(\.rawValue) == ["02:11:22:33:44:66"])
        updated.wakeOnLAN = .init()
        library.upsert(updated)
        #expect(library.requestWake(host) == .configurationRequired)
        #expect(sender.sent.count == 1)
    }

    @Test func manualWakeReportsMissingServiceAndSendFailure() {
        var host = Host(name: "Host", host: "host.invalid")
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        let library = HostLibraryModel()
        #expect(library.requestWake(host) == .failed)
        let sender = ManualWakeSender()
        library.wakeOnLAN = WakeOnLANController(sender: sender)
        sender.fails = true
        #expect(library.requestWake(host) == .failed)
        #expect(sender.sent.isEmpty)
        sender.fails = false
        #expect(library.requestWake(host) == .sent)
    }

    private func finish(_ model: HostMACAddressModel) async throws {
        for _ in 0..<200 where !model.isFinished {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.isFinished)
    }
}

private actor MACLookupRecorder: HostMACAddressResolving {
    private let password: String?
    private let proxyPassword: String?
    private var secrets: [SSHSecret] = []
    var username: String?
    var proxyUsername: String?
    var receivedHost: String?
    var credentialCount = 0
    var hasDraftKey = false
    var hasWakeAction = false
    var hasNetwork = false
    var secretsAreCleared: Bool { secrets.allSatisfy(\.isConsumed) }

    init(password: String? = nil, proxyPassword: String? = nil) {
        self.password = password
        self.proxyPassword = proxyPassword
    }

    func resolve(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws
        -> [HostMACAddressCandidate]
    {
        let configuration = request.configuration
        username = configuration.username
        proxyUsername = configuration.proxy?.username
        receivedHost = configuration.host
        credentialCount = configuration.credentials.count
        hasWakeAction = configuration.beforeConnect != nil
        hasNetwork = configuration.network != nil
        var receivedPassword = false
        for credential in configuration.credentials {
            switch credential {
            case .password(let secret):
                receivedPassword = true
                #expect(password.map(secret.matches) == true)
                secrets.append(secret)
            case .privateKey(let secret, _, _, _):
                hasDraftKey = secret.matches("draft-private-key")
                secrets.append(secret)
            default: Issue.record("Unexpected credential")
            }
        }
        #expect(receivedPassword == (password != nil))
        if let proxyPassword {
            let secret = try #require(configuration.proxy?.password)
            #expect(secret.matches(proxyPassword))
            secrets.append(secret)
        } else {
            #expect(configuration.proxy == nil)
        }
        return [.init(interface: "en0", address: MACAddress("02:11:22:33:44:55")!)]
    }
}

private nonisolated final class ManualWakeSender: WakeOnLANSending, @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: [MACAddress] = []
    private var shouldFail = false
    var fails: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }
    var sent: [MACAddress] { lock.withLock { addresses } }
    func send(to address: MACAddress) throws {
        try lock.withLock {
            if shouldFail { throw WakeOnLANError.noLocalNetwork }
            addresses.append(address)
        }
    }
}

@MainActor private final class ManualWakeAccess {
    var allowed = false
}

@MainActor private final class MACLookupTailscaleProvider: TailscaleConnectionProviding {
    func connection(for groupID: UUID) throws -> any SSHNetworkDialing { MACLookupDialer() }
}

private nonisolated struct MACLookupDialer: SSHNetworkDialing {
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { throw CancellationError() }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}
