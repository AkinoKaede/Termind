import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct KeyExportTests {
    @Test func openingAndMissingSelectionNeverConnect() async throws {
        let fixture = KeyExportFixture()
        let model = fixture.model()
        #expect(!model.canStart)
        model.start()
        #expect(await fixture.transport.connects == 0)
        model.hostID = fixture.host.id
        #expect(model.canStart)
        #expect(fixture.library.keyExportUnavailableReason(for: fixture.host) == nil)
    }

    @Test func existingPublicKeyExportsWithoutReadingPrivateMaterialAndAttachesCustomIdentity() async throws {
        let fixture = KeyExportFixture()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await wait { model.phase == .succeeded }
        #expect(await fixture.transport.derivations == 0)
        #expect(await fixture.transport.installed == [fixture.key.publicKey])
        let host = try #require(fixture.library.host(fixture.host.id))
        let identity = try #require(fixture.library.identity(for: host))
        #expect(identity.isHostCustom && identity.ownerHostID == host.id)
        #expect(identity.keyID == fixture.key.id && identity.username == "deploy")
        #expect(fixture.library.identity(fixture.identity.id)?.keyID == nil)
        #expect(fixture.library.host(fixture.other.id)?.identityID == fixture.identity.id)
    }

    @Test func absentPublicKeyIsDerivedOnlyForTheCurrentExport() async throws {
        let fixture = KeyExportFixture(publicKey: "")
        try fixture.storePrivateKey()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await wait { model.phase == .succeeded }
        #expect(await fixture.transport.derivations == 1)
        #expect(await fixture.transport.installed == ["ssh-ed25519 derived"])
        #expect(fixture.library.key(fixture.key.id)?.publicKey == "")
        #expect(fixture.library.key(fixture.key.id)?.fingerprint == "")
    }

    @Test func encryptedKeyWithoutSavedPassphraseRequiresTheExportForm() async throws {
        let fixture = KeyExportFixture(publicKey: "", encrypted: true)
        try fixture.storePrivateKey()
        let model = fixture.model()
        model.hostID = fixture.host.id
        #expect(model.needsExportPassphrase && !model.canStart)
        model.exportPassphrase = "unlock"
        #expect(model.canStart)
        model.start()
        try await wait { model.phase == .succeeded }
        #expect(model.authenticationPrompt == nil)
        #expect(model.exportPassphrase.isEmpty)
        #expect(await fixture.transport.passphrases == ["unlock"])
        #expect(fixture.library.requiresPassphraseEntry(for: fixture.key))
    }

    @Test func savedPassphraseIsReusedAndBadPassphraseReturnsToTheForm() async throws {
        let fixture = KeyExportFixture(publicKey: "", encrypted: true)
        try fixture.storePrivateKey(passphrase: "wrong")
        await fixture.transport.requirePassphrase("correct")
        let model = fixture.model()
        model.hostID = fixture.host.id
        #expect(!model.needsExportPassphrase)
        model.start()
        try await wait { model.passphraseError != nil }
        #expect(model.phase == .editing && !model.journey.isPresented)
        #expect(model.needsExportPassphrase && model.authenticationPrompt == nil)
        #expect(await fixture.transport.connects == 0)
        model.exportPassphrase = "correct"
        model.saveExportPassphrase = true
        model.start()
        try await wait { model.phase == .succeeded }
        guard case .software(let secret)? = try fixture.library.keyCredential(for: fixture.key) else {
            Issue.record("Missing private key")
            return
        }
        #expect(secret.passphrase == "correct")
        #expect(fixture.library.key(fixture.key.id)?.publicKey == "")
    }

    @Test func missingHostIdentityUsesTheConnectionJourney() async throws {
        let fixture = KeyExportFixture()
        var host = fixture.host
        host.identityID = nil
        #expect(fixture.library.saveHost(host))
        let model = fixture.model()
        model.hostID = host.id
        model.start()
        try await wait { model.authenticationPrompt != nil }
        let prompt = try #require(model.authenticationPrompt)
        #expect(model.journey.waitsForLocalIdentity)
        model.submitAuthentication(
            promptID: prompt.id, identityID: nil, username: "alice", password: "one-use",
            passphrase: nil, keyID: nil, save: false)
        try await wait { model.phase == .succeeded }
        let saved = try #require(fixture.library.host(host.id))
        let identity = try #require(fixture.library.identity(for: saved))
        #expect(identity.isHostCustom && identity.username == "alice" && !identity.usesPassword)
    }

    @Test func firstUseTrustIsPresentedAndCancellationNeverInstalls() async throws {
        let fixture = KeyExportFixture()
        await fixture.transport.challengeTrust()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await wait { model.connection.pendingHostKey != nil }
        #expect(model.journey.checkpoint?.kind == .hostKey)
        model.cancel()
        try await waitAsync { await fixture.transport.disconnects > 0 }
        #expect(await fixture.transport.installed.isEmpty)
        #expect(fixture.library.knownHosts.isEmpty)
    }

    @Test func acceptingTrustContinuesTheSameExport() async throws {
        let fixture = KeyExportFixture()
        await fixture.transport.challengeTrust()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await wait { model.connection.pendingHostKey != nil }
        let prompt = try #require(model.connection.pendingHostKey)
        model.acceptHostKey(prompt.observation, operationID: model.operationID, remember: true)
        try await wait { model.phase == .succeeded }
        #expect(fixture.library.knownHosts.count == 1)
        #expect(await fixture.transport.connects == 1)
    }

    @Test func anOldTrustCallbackCannotApproveANewAttemptForTheSameHost() async throws {
        let fixture = KeyExportFixture()
        await fixture.transport.challengeTrust()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await wait { model.connection.pendingHostKey != nil }
        let observation = try #require(model.connection.pendingHostKey?.observation)
        let oldOperation = model.operationID
        model.cancel()
        model.start()
        try await wait { model.connection.pendingHostKey != nil }
        model.acceptHostKey(observation, operationID: oldOperation, remember: true)
        #expect(model.connection.pendingHostKey != nil && fixture.library.knownHosts.isEmpty)
        #expect(await fixture.transport.installed.isEmpty)
        model.acceptHostKey(observation, operationID: model.operationID, remember: false)
        try await wait { model.phase == .succeeded }
    }

    @Test func aConnectionArrivingAfterCancellationIsClosedWithoutExporting() async throws {
        let fixture = KeyExportFixture()
        await fixture.transport.delayConnection()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await waitAsync { await fixture.transport.isWaiting }
        model.cancel()
        await fixture.transport.finishConnection()
        try await waitAsync { await fixture.transport.disconnects > 0 }
        #expect(await fixture.transport.installed.isEmpty)
        #expect(fixture.library.host(fixture.host.id)?.identityID == fixture.identity.id)
    }

    @Test func jumpLoginAndKeyboardAuthenticationStayInTheJourney() async throws {
        let fixture = KeyExportFixture()
        var jump = fixture.other
        jump.identityID = nil
        #expect(fixture.library.saveHost(jump))
        var target = fixture.host
        target.jumpHostID = jump.id
        #expect(fixture.library.saveHost(target))
        await fixture.transport.challengeKeyboard()
        let model = fixture.model()
        model.hostID = target.id
        model.start()
        try await wait { model.authenticationPrompt != nil }
        let prompt = try #require(model.authenticationPrompt)
        #expect(prompt.host.id == jump.id)
        model.submitAuthentication(
            promptID: prompt.id, identityID: nil, username: "gateway", password: "temporary",
            passphrase: nil, keyID: nil, save: false)
        try await wait { model.connection.keyboardAuthentication.current != nil }
        let challenge = try #require(model.connection.keyboardAuthentication.current)
        #expect(challenge.hostID == jump.id)
        model.connection.keyboardAuthentication.respond(challenge.id, answers: ["one-time-code"])
        try await wait { model.phase == .succeeded }
        #expect(await fixture.transport.keyboardAnswers == ["one-time-code"])
        #expect(fixture.library.identity(for: jump) == nil)
        let saved = try #require(fixture.library.host(target.id))
        #expect(fixture.library.identity(for: saved)?.username == "deploy")
    }

    @Test func proxyAuthenticationIsSeparateFromTheAttachedSSHIdentity() async throws {
        let fixture = KeyExportFixture()
        var target = fixture.host
        target.proxy = HostProxy(hostname: "proxy.invalid")
        #expect(fixture.library.saveHost(target))
        await fixture.transport.challengeProxy()
        let model = fixture.model()
        model.hostID = target.id
        model.start()
        try await wait { model.authenticationPrompt != nil }
        let prompt = try #require(model.authenticationPrompt)
        #expect(prompt.isProxy)
        model.submitAuthentication(
            promptID: prompt.id, identityID: nil, username: "proxy-user", password: "temporary",
            passphrase: nil, keyID: nil, save: false)
        try await wait { model.phase == .succeeded }
        let saved = try #require(fixture.library.host(target.id))
        #expect(fixture.library.identity(for: saved)?.username == "deploy")
        #expect(saved.proxy?.identityID == nil)
        #expect(await fixture.transport.connects == 2)
    }

    @Test func bindingFailureRollsBackAndRetryDoesNotExecuteAgain() async throws {
        let fixture = KeyExportFixture()
        let persistence = ExportPersistence(
            snapshot: VaultSnapshot(
                hosts: [fixture.host, fixture.other], identities: [fixture.identity], keys: [fixture.key]))
        let library = HostLibraryModel(persistence: persistence)
        let model = KeyExportModel(key: fixture.key, library: library, services: fixture.services)
        model.hostID = fixture.host.id
        persistence.failsSave = true
        model.start()
        try await wait { if case .attachmentFailed = model.phase { true } else { false } }
        #expect(model.didExport)
        #expect(library.host(fixture.host.id)?.identityID == fixture.identity.id)
        #expect(library.identities.count == 1)
        persistence.failsSave = false
        model.retry()
        #expect(model.phase == .succeeded)
        #expect(await fixture.transport.installed.count == 1)
        #expect(await fixture.transport.connects == 1)
    }

    @Test func attachingCopiesSavedPasswordWithoutSharingItsReference() throws {
        let fixture = KeyExportFixture()
        try fixture.library.upsert(fixture.identity, passwordUpdate: .replace("saved-password"))
        try fixture.library.attachExportedKey(fixture.key.id, to: fixture.host.id, username: "deploy")
        let host = try #require(fixture.library.host(fixture.host.id))
        let custom = try #require(fixture.library.identity(for: host))
        let shared = try #require(fixture.library.identity(fixture.identity.id))
        #expect(custom.credentialRef != shared.credentialRef)
        #expect(try fixture.library.editablePassword(for: custom) == "saved-password")
        #expect(fixture.library.delete(identityID: custom.id))
        #expect(try fixture.library.editablePassword(for: shared) == "saved-password")
    }

    @Test func scriptFailureRequiresExplicitRetryAndNeverAttaches() async throws {
        let fixture = KeyExportFixture()
        await fixture.transport.failInstall()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.start()
        try await wait { if case .failed = model.phase { true } else { false } }
        #expect(model.executionStarted && !model.didExport)
        #expect(fixture.library.host(fixture.host.id)?.identityID == fixture.identity.id)
        #expect(await fixture.transport.installed.count == 1)
        model.editOptions()
        #expect(!model.journey.isPresented)
        model.options.script = "exit 0"
        #expect(model.canStart)
        #expect(await fixture.transport.installed.count == 1)
    }

    @Test func invalidOptionsNeverConnect() {
        let fixture = KeyExportFixture()
        let model = fixture.model()
        model.hostID = fixture.host.id
        model.options.filename = "../authorized_keys"
        #expect(!model.canStart)
        model.options.filename = "keys"
        model.options.script = " "
        #expect(!model.canStart)
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        try await waitAsync { condition() }
    }
    private func waitAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private struct KeyExportFixture {
    let key: SSHKeyRef
    let identity = Identity(name: "Shared", username: "deploy")
    let host: TermindDomain.Host
    let other: TermindDomain.Host
    let library: HostLibraryModel
    let transport = ExportTransport()
    init(publicKey: String = "ssh-ed25519 existing", encrypted: Bool = false) {
        key = SSHKeyRef(label: "Deploy", publicKey: publicKey, credentialRef: "key", hasPassphrase: encrypted)
        host = TermindDomain.Host(name: "First", host: "first.invalid", identityID: identity.id)
        other = TermindDomain.Host(name: "Second", host: "second.invalid", identityID: identity.id)
        library = HostLibraryModel(hosts: [host, other], keys: [key], identities: [identity])
    }
    var services: KeyExportServices {
        KeyExportServices(derivePublicKey: transport.derive, connect: transport.connect)
    }
    func model() -> KeyExportModel { KeyExportModel(key: key, library: library, services: services) }
    func storePrivateKey(passphrase: String? = nil) throws {
        try library.upsert(
            key, credential: .software(SSHPrivateKeySecret(privateKey: "private", passphrase: passphrase)))
    }
}

private actor ExportTransport: KeyExportSession {
    var derivations = 0
    var connects = 0
    var disconnects = 0
    var installed: [String] = []
    var passphrases: [String] = []
    var keyboardAnswers: [String] = []
    private var expectedPassphrase: String?
    private var asksTrust = false
    private var installFails = false
    private var delaysConnection = false
    private var asksKeyboard = false
    private var asksProxy = false
    private var connectionContinuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { connectionContinuation != nil }
    func requirePassphrase(_ value: String) { expectedPassphrase = value }
    func challengeTrust() { asksTrust = true }
    func challengeKeyboard() { asksKeyboard = true }
    func challengeProxy() { asksProxy = true }
    func failInstall() { installFails = true }
    func delayConnection() { delaysConnection = true }
    func finishConnection() {
        connectionContinuation?.resume()
        connectionContinuation = nil
    }
    func derive(_ key: SSHKeyRef, _ credential: SSHResolvedKeyCredential, _ override: SSHSecret?) async throws -> String
    {
        defer {
            credential.clearSecrets()
            override?.clear()
        }
        derivations += 1
        if case .software(_, let saved) = credential, let passphrase = override ?? saved {
            let value = try passphrase.withUnsafeCStringAndConsume { pointer, _ in String(cString: pointer) }
            passphrases.append(value)
            if let expectedPassphrase, value != expectedPassphrase { throw CocoaError(.coderInvalidValue) }
        }
        return "ssh-ed25519 derived"
    }
    func connect(_ request: SSHConnectionRequest, _ progress: SSHRouteProgressHandler?) async throws
        -> any KeyExportSession
    {
        defer { request.configuration.clearSecrets() }
        connects += 1
        var opened = false
        defer { if !opened { disconnects += 1 } }
        if asksProxy {
            asksProxy = false
            throw TermindSSHError.proxyAuthentication(
                hostID: request.configuration.hostID, serverChallenge: true, message: "Proxy authentication required")
        }
        if delaysConnection {
            await withCheckedContinuation { connectionContinuation = $0 }
        }
        if asksTrust {
            let config = request.configuration
            let challenge = SSHHostKeyChallenge(
                hostID: config.hostID,
                observation: SSHHostKeyObservation(
                    hostname: config.host, port: config.port, algorithm: .ed25519, fingerprint: "SHA256:test"),
                expectedHostKeys: [])
            let decision = try await request.authorizeHostKey?(challenge)
            guard decision == .accept else {
                throw CancellationError()
            }
        }
        if asksKeyboard {
            let config = request.configuration
            let hop = config.jumps.first
            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: hop?.id ?? config.hostID,
                hostname: hop?.host ?? config.host, port: hop?.port ?? config.port,
                username: hop?.username ?? config.username, round: 1, name: "Verification", instruction: "",
                prompts: [.init(text: "Code", echo: false)])
            keyboardAnswers = try await request.keyboardInteractive?(challenge) ?? []
        }
        opened = true
        return self
    }
    func install(publicKey: String, options: KeyExportOptions) async throws {
        installed.append(publicKey)
        if installFails { throw CocoaError(.fileWriteUnknown) }
    }
    func disconnect() async { disconnects += 1 }
}

@MainActor
private final class ExportPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var failsSave = false
    init(snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet {
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
}
