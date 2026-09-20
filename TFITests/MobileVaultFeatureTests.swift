import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileVaultFeatureTests {
    @Test func hostMenuSeparatesConnectionEditingAndDeletionActions() {
        #expect(
            MobileHostMenuPolicy.sections == [
                [.ssh, .sftp],
                [.edit, .duplicate],
                [.delete],
            ])
    }

    @Test func duplicatingAHostPersistsAnIndependentCopyWithTheSameConfiguration() throws {
        let app = try MobileAppModel(inMemory: true)
        let group = HostGroup(name: "Production")
        let jump = TermindDomain.Host(name: "Jump", host: "jump.example.invalid")
        app.library.upsert(group)
        app.library.upsert(jump)
        let host = TermindDomain.Host(
            name: "Remote", host: "remote.example.invalid", port: 2222, identityID: UUID(),
            jumpHostID: jump.id,
            proxy: HostProxy(kind: .socks5, hostname: "proxy.example.invalid", port: 1080),
            sftpChannelInitialPath: "/srv/app", groupID: group.id, tags: ["production", "api"],
            colorTag: .teal, detectedDistribution: DetectedDistribution(id: "debian"),
            shellIntegrationMode: .enabled, portForwardingMaxConnections: 12)
        app.library.upsert(host)
        let original = try #require(app.library.host(host.id))

        app.duplicateHost(original)

        #expect(app.library.hosts.count == 3)
        #expect(app.library.host(original.id) == original)
        let copy = try #require(app.library.hosts.first { $0.id != jump.id && $0.id != original.id })
        #expect(copy.id != original.id)
        #expect(copy.name == "Remote copy")
        var expected = original
        expected.id = copy.id
        expected.name = copy.name
        expected.sortIndex = copy.sortIndex
        #expect(copy == expected)
        app.outbox.stop()
    }

    @Test func editingAHostPreservesTheMacForwardingPoolLimit() throws {
        let app = try MobileAppModel(inMemory: true)
        var host = TermindDomain.Host(
            name: "Remote", host: "example.invalid", portForwardingMaxConnections: 12)
        app.library.upsert(host)
        host.name = "Renamed"
        app.library.upsert(host)
        #expect(app.library.host(host.id)?.portForwardingMaxConnections == 12)
        app.outbox.stop()
    }

    @Test func blankKeyNamesUseTheCurrentAlgorithmForGenerationImportAndReplacement() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        generator.algorithm = .ecdsa
        generator.label = " \n"
        #expect(generator.defaultName == "ECDSA")
        #expect(generator.canSave)
        try await generator.save()
        let generated = try #require(app.credentials.keys.first)
        #expect(generated.label == "ECDSA")

        let replacement = try SSHKeyMaterial.generate(.ed25519, comment: "fixture", passphrase: nil)
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        #expect(!importer.canSave)
        #expect(importer.defaultName == "")
        importer.privateKey = replacement.privateKey
        await importer.derivePublicMaterial()
        #expect(importer.defaultName == "Ed25519")
        #expect(importer.canSave)
        try await importer.save()
        let imported = try #require(app.credentials.keys.first { $0.id != generated.id })
        #expect(imported.label == "Ed25519")

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: generated)
        await editor.loadPrivateKey()
        editor.label = ""
        editor.privateKey = replacement.privateKey
        #expect(editor.defaultName == "")
        await editor.derivePublicMaterial()
        #expect(editor.defaultName == "Ed25519")
        #expect(editor.canSave)
        try await editor.save()
        let edited = try #require(app.credentials.key(generated.id))
        #expect(edited.label == "Ed25519")
        #expect(edited.algorithm == .ed25519)
        let reopened = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: edited)
        #expect(reopened.label == "Ed25519")
        await reopened.loadPrivateKey()
        reopened.privateKey = "invalid replacement"
        #expect(reopened.defaultName == "")
        await reopened.derivePublicMaterial()
        #expect(reopened.defaultName == "")
        reopened.privateKey = ""
        #expect(reopened.defaultName == "")
        #expect(!reopened.canSave)
    }

    @Test func enclaveMetadataCanSaveABlankNameWithoutGeneratingAKey() async throws {
        let original = SSHKeyRef(label: "Custom", algorithm: .ecdsa256, storage: .secureEnclave)
        let library = HostLibraryModel(keys: [original])
        let credentials = CredentialLibraryModel(library: library)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)
        editor.label = " \t"
        #expect(editor.defaultName == "Secure Enclave")
        #expect(editor.canSave)
        try await editor.save()
        #expect(credentials.key(original.id)?.label == "Secure Enclave")
        #expect(credentials.key(original.id)?.publicKey == original.publicKey)
    }

    @Test func hostProxyEditorAppliesDefaultsPreservesCustomPortsAndValidatesAuthentication() {
        var host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        #expect(MobileHostEditorPolicy.canSave(host))

        host.proxy = MobileHostEditorPolicy.selectProxy(.http, current: nil)
        #expect(host.proxy?.port == 8080)
        #expect(!MobileHostEditorPolicy.canSave(host))

        host.proxy?.hostname = "proxy.example"
        #expect(MobileHostEditorPolicy.canSave(host))
        host.proxy?.port = 0
        #expect(!MobileHostEditorPolicy.canSave(host))
        host.proxy?.port = 8080
        host.proxy = MobileHostEditorPolicy.selectProxy(.socks5, current: host.proxy)
        #expect(host.proxy?.port == 1080)
        #expect(host.proxy?.hostname == "proxy.example")

        host.proxy?.port = 9000
        host.proxy = MobileHostEditorPolicy.selectProxy(.http, current: host.proxy)
        #expect(host.proxy?.port == 9000)

        let identity = Identity(
            name: "Proxy", username: "proxy-user", credentialRef: "termind.password.proxy")
        host.proxy = MobileHostEditorPolicy.selectProxyIdentity(identity, current: host.proxy)
        #expect(host.proxy?.identityID == identity.id)
        #expect(host.proxy?.username == "proxy-user")
        #expect(MobileHostEditorPolicy.canSave(host))

        host.proxy?.username = ""
        #expect(!MobileHostEditorPolicy.canSave(host))
        host.proxy = MobileHostEditorPolicy.selectProxyIdentity(nil, current: host.proxy)
        #expect(host.proxy?.identityID == nil)
        #expect(host.proxy?.username.isEmpty == true)
        #expect(MobileHostEditorPolicy.canSave(host))

        host.proxy = MobileHostEditorPolicy.selectProxy(nil, current: host.proxy)
        #expect(host.proxy == nil)
    }

    @Test func identityCreationConfigurationsMatchHostAndProxyRequirements() {
        let identity = Identity(name: "Deploy", username: "deploy", keyID: UUID())

        #expect(MobileIdentityEditorConfiguration.standard.showsKey)
        #expect(
            MobileIdentityEditorConfiguration.standard.canSave(
                identity: identity, password: "", hasSavedPassword: false, removesPassword: false))
        #expect(!MobileIdentityEditorConfiguration.proxy.showsKey)
        #expect(
            !MobileIdentityEditorConfiguration.proxy.canSave(
                identity: identity, password: "", hasSavedPassword: false, removesPassword: false))
        #expect(
            MobileIdentityEditorConfiguration.proxy.canSave(
                identity: identity, password: "secret", hasSavedPassword: false, removesPassword: false))
    }

    @Test func identityEditorUsesNewAndEditTitles() throws {
        let app = try MobileAppModel(inMemory: true)
        let identity = Identity(name: "Deploy", username: "deploy")

        #expect(MobileIdentityEditor(app: app, identity: identity).title == String(localized: "New Identity"))
        app.library.upsert(identity)
        #expect(MobileIdentityEditor(app: app, identity: identity).title == String(localized: "Edit Identity"))
        app.outbox.stop()
    }

    @Test func newlyCreatedIdentitiesAreAppliedOnlyAfterTheEditorSaves() {
        let originalIdentity = Identity(name: "Original", username: "old")
        let createdIdentity = Identity(name: "Created", username: "new")
        var host = TermindDomain.Host(
            name: "Remote", host: "example.invalid", identityID: originalIdentity.id,
            proxy: HostProxy(
                kind: .http, hostname: "proxy.example.invalid", port: 8080,
                username: originalIdentity.username, identityID: originalIdentity.id))

        #expect(host.identityID == originalIdentity.id)
        #expect(host.proxy?.identityID == originalIdentity.id)

        host = MobileHostEditorPolicy.selectIdentity(createdIdentity, current: host)
        #expect(host.identityID == createdIdentity.id)
        host.proxy = MobileHostEditorPolicy.selectProxyIdentity(createdIdentity, current: host.proxy)
        #expect(host.proxy?.identityID == createdIdentity.id)
        #expect(host.proxy?.username == createdIdentity.username)
    }

    @Test func proxyIdentityChoicesRequireAnAvailablePasswordOnThisDevice() throws {
        let app = try MobileAppModel(inMemory: true)
        let available = Identity(name: "Available", username: "proxy")
        let missing = Identity(
            name: "Missing", username: "proxy", credentialRef: "termind.password.missing")
        let keyOnly = Identity(name: "Key only", username: "proxy", keyID: UUID())

        try app.library.upsert(available, passwordUpdate: .replace("secret"))
        app.library.upsert(missing)
        app.library.upsert(keyOnly)

        let storedAvailable = try #require(app.library.identity(available.id))
        #expect(app.library.isProxyEligibleOnThisDevice(storedAvailable))
        #expect(!app.library.isProxyEligibleOnThisDevice(missing))
        #expect(!app.library.isProxyEligibleOnThisDevice(keyOnly))
    }

    @Test func savingAndForegroundingNeverStartForwardings() throws {
        let suite = "MobileManualForwardingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        defaults.set([rule.id.uuidString], forKey: "portForwarding.enabledRuleIDs")
        let app = try MobileAppModel(inMemory: true, defaults: defaults)
        app.library.upsert(host)
        try app.forwardingLibrary.save(rule)
        let sceneID = UUID()
        app.sceneChanged(sceneID, phase: .active)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        #expect(app.forwardings.connection(for: rule.id) == nil)
        app.forwardings.stopAll()
        app.sceneChanged(sceneID, phase: .background)
        app.sceneChanged(sceneID, phase: .active)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        app.removeScene(sceneID)
    }

    @Test func encryptedKeyGenerationImportAndMetadataEditingKeepTheSecretOutOfRecords() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        #expect(!generator.isDirty)
        generator.label = "Generated"
        #expect(generator.isDirty)
        #expect(generator.storage == .iCloud)
        generator.passphrase = "test-only-passphrase"
        generator.confirmation = "test-only-passphrase"
        try await generator.save()
        let key = try #require(app.credentials.keys.first)
        #expect(key.hasPassphrase)
        #expect(generator.privateKey.isEmpty && generator.passphrase.isEmpty)
        let savedCredential = try app.credentials.keyCredential(for: key)
        guard case .software(let secret) = try #require(savedCredential) else {
            Issue.record("Expected a software key")
            return
        }
        let record = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        #expect(!record.contains("PRIVATE KEY"))
        #expect(!record.contains("test-only-passphrase"))

        let invalid = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        invalid.label = "Invalid"
        invalid.privateKey = secret.privateKey
        invalid.passphrase = "wrong"
        await #expect(throws: (any Error).self) { try await invalid.save() }
        #expect(app.credentials.keys.count == 1)

        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        importer.label = "Imported"
        importer.privateKey = secret.privateKey
        importer.passphrase = "test-only-passphrase"
        try await importer.save()
        #expect(app.credentials.keys.count == 2)
        #expect(app.credentials.keys.allSatisfy { $0.fingerprint == key.fingerprint })

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
        await editor.loadPrivateKey()
        #expect(!editor.isDirty)
        #expect(editor.privateKey == secret.privateKey)
        editor.label = "Renamed"
        try await editor.save()
        let edited = try #require(app.credentials.key(key.id))
        #expect(edited.label == "Renamed")
        #expect(edited.credentialRef == key.credentialRef)
        #expect(try app.credentials.keyCredential(for: edited) == .software(secret))
    }

    @Test func editingSoftwareKeyReplacesPrivateMaterialAndDerivedMetadata() async throws {
        let app = try MobileAppModel(inMemory: true)
        let originalMaterial = try SSHKeyMaterial.generate(.ed25519, comment: "original", passphrase: nil)
        let original = SSHKeyRef(
            label: "Deploy", algorithm: originalMaterial.algorithm, publicKey: originalMaterial.publicKey,
            fingerprint: originalMaterial.fingerprint, credentialRef: "termind.key.\(UUID())", storage: .iCloud,
            keySize: originalMaterial.keySize)
        try app.credentials.upsert(
            original, credential: .software(SSHPrivateKeySecret(privateKey: originalMaterial.privateKey)))

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: original)
        #expect(editor.isLoadingPrivateKey)
        #expect(!editor.canSave)
        await editor.loadPrivateKey()
        #expect(editor.privateKeyLoadError == nil)
        #expect(editor.privateKey == originalMaterial.privateKey)
        #expect(!editor.isDirty)
        #expect(editor.canSave)

        let replacement = try SSHKeyMaterial.generate(.rsa(bits: 2048), comment: "replacement", passphrase: nil)
        editor.privateKey = replacement.privateKey
        await editor.derivePublicMaterial()
        #expect(editor.replacesPublicKey)
        #expect(editor.fingerprint == replacement.fingerprint)
        try await editor.save()

        let updated = try #require(app.credentials.key(original.id))
        #expect(updated.id == original.id)
        #expect(updated.credentialRef == original.credentialRef)
        #expect(updated.algorithm == .rsa)
        #expect(updated.keySize == 2048)
        #expect(updated.fingerprint == replacement.fingerprint)
        #expect(updated.publicKey.hasPrefix("ssh-rsa "))
        #expect(!updated.hasPassphrase)
        #expect(
            try app.credentials.keyCredential(for: updated)
                == .software(SSHPrivateKeySecret(privateKey: replacement.privateKey))
        )
        #expect(editor.privateKey.isEmpty && editor.passphrase.isEmpty)
    }

    @Test func encryptedSoftwareKeyCanBeRenamedWithoutReenteringItsPassphrase() async throws {
        let app = try MobileAppModel(inMemory: true)
        let material = try SSHKeyMaterial.generate(
            .ed25519, comment: "protected", passphrase: "test-only-passphrase")
        let original = SSHKeyRef(
            label: "Protected", algorithm: material.algorithm, publicKey: material.publicKey,
            fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())", storage: .iCloud,
            keySize: material.keySize, hasPassphrase: true)
        let secret = SSHPrivateKeySecret(privateKey: material.privateKey)
        try app.credentials.upsert(original, credential: .software(secret))

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: original)
        await editor.loadPrivateKey()
        editor.label = "Renamed Protected"
        try await editor.save()

        let updated = try #require(app.credentials.key(original.id))
        #expect(updated.label == "Renamed Protected")
        #expect(updated.hasPassphrase)
        #expect(updated.publicKey == original.publicKey)
        #expect(updated.fingerprint == original.fingerprint)
        #expect(try app.credentials.keyCredential(for: updated) == .software(secret))
    }

    @Test func missingPrivateKeyCannotBeOverwrittenByMetadataOnlyEdit() async throws {
        let original = SSHKeyRef(
            label: "Missing", publicKey: "ssh-ed25519 test", fingerprint: "SHA256:test",
            credentialRef: "termind.key.\(UUID())", storage: .thisDevice)
        let library = HostLibraryModel(keys: [original], secrets: InMemorySecretStore())
        let credentials = CredentialLibraryModel(library: library)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)

        await editor.loadPrivateKey()
        #expect(editor.privateKeyLoadError != nil)
        #expect(!editor.canSave)
        editor.label = "Should Not Save"
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(credentials.key(original.id) == original)
    }

    @Test func invalidPrivateKeyAndCertificateEditsPreserveTheOriginalCredential() async throws {
        let app = try MobileAppModel(inMemory: true)
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "original", passphrase: nil)
        let original = SSHKeyRef(
            label: "Deploy", algorithm: material.algorithm, publicKey: material.publicKey,
            fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())", storage: .iCloud,
            keySize: material.keySize)
        let secret = SSHPrivateKeySecret(privateKey: material.privateKey)
        try app.credentials.upsert(original, credential: .software(secret))

        let invalidKeyEditor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: original)
        await invalidKeyEditor.loadPrivateKey()
        invalidKeyEditor.privateKey = "not a private key"
        await #expect(throws: (any Error).self) { try await invalidKeyEditor.save() }
        #expect(app.credentials.key(original.id) == original)
        #expect(try app.credentials.keyCredential(for: original) == .software(secret))

        let invalidCertificateEditor = MobileKeyEditorModel(
            mode: .edit, credentials: app.credentials, key: original)
        await invalidCertificateEditor.loadPrivateKey()
        invalidCertificateEditor.certificate = "not an SSH certificate"
        await #expect(throws: (any Error).self) { try await invalidCertificateEditor.save() }
        #expect(app.credentials.key(original.id) == original)
        #expect(try app.credentials.keyCredential(for: original) == .software(secret))
    }

    @Test func editingSoftwareKeyMovesItsCredentialBetweenStorageClasses() async throws {
        let secrets = MobileStorageAwareSecretStore()
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "move", passphrase: nil)
        let original = SSHKeyRef(
            label: "Move", algorithm: material.algorithm, publicKey: material.publicKey,
            fingerprint: material.fingerprint, credentialRef: "termind.key.\(UUID())", storage: .iCloud,
            keySize: material.keySize)
        let secret = StoredSSHKeyCredential.software(SSHPrivateKeySecret(privateKey: material.privateKey))
        let library = HostLibraryModel(keys: [original], secrets: secrets)
        let credentials = CredentialLibraryModel(library: library)
        try credentials.upsert(original, credential: secret)

        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)
        await editor.loadPrivateKey()
        editor.storage = .thisDevice
        try await editor.save()

        let updated = try #require(credentials.key(original.id))
        #expect(updated.storage == .thisDevice)
        #expect(try secrets.keyCredential(for: original.credentialRef, storage: .thisDevice) == secret)
        #expect(try secrets.keyCredential(for: original.credentialRef, storage: .iCloud) == nil)
    }

    @Test func importRequiresAnExplicitUsernameWhenTheConfigurationOmitsIt() async throws {
        let app = try MobileAppModel(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appending(path: "config")
        let config = "Host remote\n    HostName example.invalid\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let model = SSHImportModel(library: app.library, reader: SSHImportReader(username: "", home: root))
        await model.scan(root, knownHostsOnly: false)
        #expect(model.error == nil)
        #expect(model.selectedItems(.hosts).count == 1)
        #expect(model.selectedItems(.identities).count == 1)
        #expect(!model.canImport)
        await model.commit()
        #expect(!model.completed)
        #expect(app.library.hosts.isEmpty && app.library.identities.isEmpty)

        // Rescan the corrected source so both Host and Identity previews are rebuilt together.
        try (config + "    User deploy\n").write(to: configURL, atomically: true, encoding: .utf8)
        await model.scan(root, knownHostsOnly: false)
        #expect(model.error == nil)
        #expect(model.selectedItems(.identities).map { $0.identity?.username } == ["deploy"])
        #expect(model.canImport)
        await model.commit()
        #expect(model.completed)
        #expect(model.error == nil)
        #expect(app.library.hosts.count == 1 && app.library.identities.count == 1)
        let host = try #require(app.library.hosts.first)
        #expect(app.library.identity(for: host)?.username == "deploy")
    }

    @Test func forwardingEditsValidateAndStopOnlyTheChangedRule() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        app.library.upsert(host)
        var rule = PortForwardingRule(hostID: host.id)
        try app.forwardingLibrary.save(rule)
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        var stopped: [UUID] = []
        app.library.willDeletePortForwardings = { stopped.append(contentsOf: $0) }
        rule.bindPort = 9000
        try app.forwardingLibrary.save(rule)
        #expect(stopped == [rule.id])
        var invalid = rule
        invalid.bindPort = 0
        #expect(throws: (any Error).self) { try app.forwardingLibrary.save(invalid) }
        #expect(app.forwardingLibrary.portForwarding(rule.id)?.bindPort == 9000)
        try app.forwardingLibrary.delete(rule.id)
        #expect(app.forwardingLibrary.rules.isEmpty)
    }

    @Test func deletingAHostCompletesDurableCleanup() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        app.library.upsert(host)
        let dependent = TermindDomain.Host(name: "Dependent", host: "dependent.invalid", jumpHostID: host.id)
        app.library.upsert(dependent)
        app.deleteHost(host.id)
        #expect(app.library.host(host.id) == nil)
        var finished = false
        for _ in 0..<100 {
            let context = ModelContext(app.container)
            let jobs = try context.fetch(FetchDescriptor<PersistentOutboxJob>())
            if jobs.count == 5 && jobs.allSatisfy({ $0.status == OutboxJobStatus.succeeded.rawValue }) {
                finished = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finished)
        let saved = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(!saved.hosts.contains(where: { $0.id == host.id }))
        #expect(saved.hosts.first(where: { $0.id == dependent.id })?.jumpHostID == nil)
    }
}

private final class MobileStorageAwareSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String: String] = [:]
    private var keys: [String: StoredSSHKeyCredential] = [:]

    func string(for account: String, storage: PasswordStorage) throws -> String? {
        lock.withLock { strings["\(storage.rawValue):\(account)"] }
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        lock.withLock { strings["\(storage.rawValue):\(account)"] = value }
    }

    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        lock.withLock { keys["\(storage.rawValue):\(account)"] }
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {
        lock.withLock { keys["\(storage.rawValue):\(account)"] = value }
    }

    func removePassword(_ account: String, storage: PasswordStorage) throws {
        lock.withLock { strings["\(storage.rawValue):\(account)"] = nil }
    }

    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        lock.withLock { keys["\(storage.rawValue):\(account)"] = nil }
    }
}
