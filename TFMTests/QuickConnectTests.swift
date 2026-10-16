import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
struct QuickConnectParserTests {
    @Test(arguments: [
        "telnet host", "telnet host 2323", "telnet -l user host", "/usr/bin/telnet -luser host 2323",
    ])
    func acceptsTelnetCommands(_ command: String) throws {
        let input = try connection(command)
        #expect(input.connectionProtocol == .telnet)
        #expect(input.destination.host == "host")
        if command.contains("2323") { #expect(input.destination.port == 2323) }
        if command.contains("-l") { #expect(input.destination.username == "user") }
    }

    @Test(arguments: ["telnet", "telnet -l", "telnet host 0", "telnet -x host", "telnet host 23 uptime"])
    func rejectsIncompleteOrUnsupportedTelnetCommands(_ command: String) {
        switch QuickConnectParser.parse(command) {
        case .invalid, .incomplete: break
        default: Issue.record("Expected invalid or incomplete Telnet input: \(command)")
        }
    }

    @Test(arguments: ["user@host:2222", "ssh -p 2222 user@host", "ssh user@host -p2222", "ssh -luser -oPort=2222 host"])
    func acceptsLoginAndPort(_ command: String) throws {
        let input = try connection(command)
        #expect(input.destination.host == "host")
        #expect(input.destination.username == "user")
        #expect(input.destination.port == 2222)
    }

    @Test(arguments: ["[2001:db8::1]:2222", "ssh -p2222 2001:db8::1", "ssh user@[2001:db8::1]:2222"])
    func preservesIPv6(_ command: String) throws {
        let input = try connection(command)
        #expect(input.destination.host == "2001:db8::1")
        #expect(input.destination.port == 2222)
    }

    @Test func recognizesOptionsAndShellQuotingWithoutEvaluation() throws {
        let input = try connection(
            "\tssh -o 'User deploy' -o HostName=server.invalid -J 'a@first:2200,b@[::1]' \"My Server\"  ")
        #expect(input.destination.host == "My Server")
        #expect(input.destination.username == "deploy")
        #expect(input.hostname == "server.invalid")
        #expect(input.jumps?.map(\.host) == ["first", "::1"])
        #expect(input.jumps?.first?.port == 2200)
        #expect(try connection("ssh My\\ Server").destination.host == "My Server")
        #expect(try connection("ssh 'Team'\"'\"'s Server'").destination.host == "Team's Server")
    }

    @Test func openSSHFirstAssignmentWinsAndExplicitPortOverridesShorthand() throws {
        #expect(try connection("ssh -p2222 -oPort=2223 host").destination.port == 2222)
        #expect(try connection("ssh -oPort=2223 -p2222 host").destination.port == 2223)
        #expect(try connection("ssh -lalice bob@host").destination.username == "alice")
        #expect(try connection("ssh bob@host -lalice").destination.username == "bob")
        #expect(try connection("ssh host:2222 -p2223").destination.port == 2223)
        #expect(try connection("ssh -l alice@example.org host").destination.username == "alice@example.org")
        #expect(try connection("alice@example.org@host").destination.username == "alice@example.org")
        #expect(try connection("ssh -Jfirst -oProxyJump=second host").jumps?.first?.host == "first")
    }

    @Test func distinguishesInheritedAndClearedRoutes() throws {
        #expect(try connection("ssh host").jumps == nil)
        #expect(try connection("ssh -o ProxyJump=none host").jumps == [])
        #expect(try connection("/usr/bin/ssh -- host").destination.host == "host")
    }

    @Test(arguments: ["", "search two words", "scp source destination", "sftp user@host"])
    func ordinaryQueriesStaySearches(_ text: String) {
        #expect(QuickConnectParser.parse(text) == .search)
    }

    @Test(arguments: ["ssh", "ssh -p", "ssh -o User", "ssh 'unterminated", "ssh host\\", "ssh user@[::1"])
    func incompleteInputHasNoConnectableTarget(_ text: String) {
        guard case .incomplete = QuickConnectParser.parse(text) else {
            Issue.record("Expected incomplete input: \(text)")
            return
        }
    }

    @Test(arguments: [
        "ssh -i ~/.ssh/id_ed25519 host", "ssh -o IdentityFile=key host", "ssh -L 80:db:80 host",
        "ssh -N host", "ssh -o StrictHostKeyChecking=no host", "ssh host uptime", "ssh host;uptime",
        "ssh $(hostname)", "ssh -p0 host", "ssh -p65536 host", "ssh -p-22 host", "ssh @host",
        "ssh -Jfirst -Jsecond host", "ssh -oProxyJump=first -Jsecond host", "ssh -Jfirst, host",
    ])
    func rejectsUnsupportedOrInvalidCommands(_ text: String) {
        guard case .invalid = QuickConnectParser.parse(text) else {
            Issue.record("Expected invalid input: \(text)")
            return
        }
    }

    @Test(arguments: ["zh-Hans", "zh-Hant"])
    func diagnosticsUseTheRequestedLanguage(_ language: String) {
        guard
            case .invalid(let message) = QuickConnectParser.parse(
                "ssh -i key host", locale: Locale(identifier: language))
        else {
            Issue.record("Expected an unsupported-option diagnostic")
            return
        }
        #expect(message.contains(language == "zh-Hans" ? "不支持" : "不支援"))
    }

    private func connection(_ command: String) throws -> QuickConnectInput {
        guard case .connection(let input) = QuickConnectParser.parse(command) else {
            throw CocoaError(.coderInvalidValue)
        }
        return input
    }
}

@Suite @MainActor
struct QuickConnectRouteTests {
    @Test func aliasesReuseMetadataAndOverriddenUserDoesNotInheritCredentials() throws {
        let originalIdentity = Identity(name: "Production", username: "root", credentialRef: "original")
        let original = Host(name: "prod", host: "server.invalid", identityID: originalIdentity.id)
        let library = HostLibraryModel(hosts: [original], identities: [originalIdentity])
        let unchanged = try resolve("ssh prod", in: library)
        #expect(unchanged.isSaved)
        #expect(unchanged.host == original)
        let changed = try resolve("ssh -p2222 -ldeploy prod", in: library)
        #expect(!changed.isSaved)
        #expect(changed.host.id != original.id)
        #expect(changed.host.port == 2222)
        #expect(changed.host.identityID == nil)
        #expect(changed.username == "deploy")
        #expect(library.host(original.id) == original)
        #expect(library.identities == [originalIdentity])
    }

    @Test func usernameOnUnboundAliasIsAlsoATemporaryOverride() throws {
        let original = Host(name: "prod", host: "server.invalid")
        let library = HostLibraryModel(hosts: [original])
        let target = try resolve("ssh deploy@prod", in: library)
        #expect(!target.isSaved)
        #expect(target.host.id != original.id)
        #expect(target.username == "deploy")
    }

    @Test func aliasesRequireUniqueExactNames() throws {
        let first = Host(name: "prod", host: "first.invalid")
        let second = Host(name: "prod", host: "second.invalid")
        let library = HostLibraryModel(hosts: [first, second])
        #expect(throws: TermindSSHError.self) { try resolve("ssh prod", in: library) }
        #expect(throws: TermindSSHError.self) { try resolve("ssh -Jprod target", in: library) }
        #expect(try resolve("ssh production", in: library).host.host == "production")
    }

    @Test func explicitJumpsReplaceTheTargetRouteAndInheritOnlyFirstHopPrerequisites() throws {
        let root = Host(name: "root", host: "root.invalid")
        let jump = Host(name: "jump", host: "jump.invalid", jumpHostID: root.id)
        let old = Host(name: "old", host: "old.invalid")
        let target = Host(name: "prod", host: "prod.invalid", jumpHostID: old.id)
        let library = HostLibraryModel(hosts: [root, jump, old, target])
        #expect(try resolve("ssh prod", in: library).route.hosts.map(\.id) == [old.id, target.id])
        let overridden = try resolve("ssh -Jjump,user@new:2222 prod", in: library)
        #expect(overridden.route.hosts.map(\.host) == ["root.invalid", "jump.invalid", "new", "prod.invalid"])
        #expect(overridden.route.isValid)
        #expect(try resolve("ssh -oProxyJump=none prod", in: library).route.hosts.count == 1)
        #expect(library.host(target.id) == target)
        #expect(throws: TermindSSHError.self) { try resolve("ssh -Jjump root", in: library) }
        #expect(throws: TermindSSHError.self) { try resolve("ssh -Ja,b,c,d,e,f,g,h destination", in: library) }
    }

    @Test func temporaryJumpLoginCanPrepareWithoutSaving() async throws {
        let library = HostLibraryModel()
        let target = try resolve("ssh -Jbastion@jump:2222 deploy@target", in: library)
        let preparation = try library.prepareSSHConnection(for: target.route, submissions: [:])
        let configuration = try await preparation.resolve(trustPolicy: .allowChallenge)
        #expect(configuration.username == "deploy")
        #expect(configuration.jumps.first?.username == "bastion")
        #expect(configuration.jumps.first?.port == 2222)
        let jumps = try library.sshJumpConfigurations(for: target.route, submissions: [:], trustPolicy: .allowChallenge)
        #expect(jumps.first?.username == "bastion")
        #expect(library.hosts.isEmpty)
        #expect(library.identities.isEmpty)
    }

    @Test func sessionAndReconnectCopyKeepTheSnapshot() throws {
        let source = Host(name: "prod", host: "prod.invalid")
        let library = HostLibraryModel(hosts: [source])
        let target = try resolve("ssh -p2222 -Jjump deploy@prod", in: library)
        let window = WindowModel()
        let app = AppModel(hosts: library)
        defer { app.shutdownForTermination() }
        let workspace = try #require(app.openQuickConnect(target, in: window))
        let session = try #require(workspace.focusedPane.sshSession)
        #expect(session.connectionRoute == target.route)
        #expect(session.connectionHost(session.hostID, using: library)?.port == 2222)
        #expect(session.copyForReconnect().connectionRoute == target.route)
        #expect(library.hosts == [source])
    }

    @Test func unnamedTemporaryJumpRequestsItsOwnAuthentication() throws {
        let library = HostLibraryModel()
        let target = try resolve("ssh -Jjump deploy@target", in: library)
        let session = SSHSessionModel(host: target.host, usernameHint: target.username)
        session.connectionRoute = target.route
        session.connect(using: library)
        #expect(session.pendingAuthentication?.host.id == target.route.hosts.first?.id)
        #expect(session.pendingAuthentication?.username == "")
        session.disconnect()
        #expect(library.hosts.isEmpty)
    }

    @Test func savingCopiesOnlyChangedRecordsAndCommitsOnce() throws {
        let jump = Host(name: "jump", host: "jump.invalid")
        let source = Host(name: "prod", host: "prod.invalid", jumpHostID: jump.id)
        let persistence = QuickConnectPersistence(snapshot: VaultSnapshot(hosts: [jump, source]))
        let library = HostLibraryModel(persistence: persistence)
        let target = try resolve("ssh -p2222 deploy@prod", in: library)
        let saved = try library.saveConnectionRoute(target.route)
        #expect(persistence.saveCount == 1)
        #expect(library.hosts.count == 3)
        #expect(saved.hosts.first?.id == jump.id)
        let destination = try #require(saved.hosts.last)
        #expect(destination.id != source.id)
        #expect(destination.name != source.name)
        #expect(library.identity(for: destination)?.username == "deploy")
        #expect(library.host(source.id) == source)
        #expect(library.validatedRoute(for: destination)?.count == 2)
        #expect(try library.saveConnectionRoute(saved) == saved)
        #expect(persistence.saveCount == 1)
        #expect(library.hosts.count == 3)
    }

    @Test func authenticationSaveIncludesUnsavedPrerequisitesAndCopiesSharedIdentity() throws {
        let identity = Identity(name: "Root", username: "root", credentialRef: "original")
        let source = Host(name: "prod", host: "prod.invalid", identityID: identity.id)
        let secrets = InMemorySecretStore()
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let library = HostLibraryModel(hosts: [source], identities: [identity], secrets: secrets)
        let target = try resolve("ssh -Jbastion@jump -p2222 prod", in: library)
        let submission = SSHAuthenticationSubmission(username: "root", password: "new", identityID: identity.id)
        let saved = try library.saveConnectionRoute(
            target.route, authentication: submission, authenticationHostID: target.host.id, suppliedPassword: "new")
        let destination = try #require(saved.hosts.last)
        let savedIdentity = try #require(library.identity(for: destination))
        #expect(savedIdentity.id != identity.id)
        #expect(try library.passwordCredential(for: savedIdentity) == "new")
        #expect(try library.passwordCredential(for: identity) == "old")
        #expect(library.validatedRoute(for: destination)?.count == 2)
        #expect(library.host(source.id) == source)
    }

    @Test func continueAndSavePersistsTheRouteBeforePromptingForItsNextJump() throws {
        let library = HostLibraryModel()
        let target = try resolve("ssh -Jfirst,second deploy@target", in: library)
        let session = SSHSessionModel(host: target.host, usernameHint: target.username)
        session.connectionRoute = target.route
        session.connect(using: library)
        let firstID = try #require(session.pendingAuthentication?.host.id)
        #expect(firstID == target.route.hosts[0].id)
        session.continueAuthentication(
            identityID: nil, username: "bastion", password: nil, passphrase: nil, keyID: nil, save: true, using: library
        )
        #expect(library.hosts.count == 3)
        let saved = try #require(session.connectionRoute)
        #expect(library.validatedRoute(for: saved.hosts[2])?.count == 3)
        #expect(session.pendingAuthentication?.host.id == saved.hosts[1].id)
        #expect(saved.usernames[firstID] == "bastion")
        session.disconnect()
        #expect(session.copyForReconnect().connectionRoute == saved)
    }

    @Test func failedRouteSaveRollsBackHostsIdentitiesAndPassword() throws {
        let persistence = QuickConnectPersistence(snapshot: VaultSnapshot())
        persistence.failsSave = true
        let secrets = QuickConnectSecrets()
        let library = HostLibraryModel(persistence: persistence, secrets: secrets)
        let target = try resolve("ssh -Ja@jump b@target", in: library)
        let submission = SSHAuthenticationSubmission(username: "b", password: "secret")
        #expect(throws: TermindSSHError.self) {
            try library.saveConnectionRoute(
                target.route, authentication: submission, authenticationHostID: target.host.id,
                suppliedPassword: "secret")
        }
        #expect(library.hosts.isEmpty)
        #expect(library.identities.isEmpty)
        #expect(secrets.writes == secrets.removals)
        #expect(!secrets.writes.isEmpty)
        persistence.failsSave = false
        let saved = try library.saveConnectionRoute(target.route)
        #expect(saved.hosts.count == 2)
        #expect(library.hosts.count == 2)
    }

    private func resolve(_ command: String, in library: HostLibraryModel) throws -> QuickConnectTarget {
        guard case .connection(let input) = QuickConnectParser.parse(command) else {
            throw CocoaError(.coderInvalidValue)
        }
        return try QuickConnectResolver.resolve(input, in: library)
    }
}

@MainActor
private final class QuickConnectPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var failsSave = false
    var saveCount = 0
    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(
        _ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>
    ) throws -> VaultMutationSet {
        saveCount += 1
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
}

private final class QuickConnectSecrets: SecretStoring, @unchecked Sendable {
    private let store = InMemorySecretStore()
    private(set) var writes: [String] = []
    private(set) var removals: [String] = []
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        try store.string(for: account, storage: storage)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        writes.append(account)
        try store.setString(value, for: account, storage: storage)
    }
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        removals.append(account)
        try store.removePassword(account, storage: storage)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? { nil }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {}
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}
