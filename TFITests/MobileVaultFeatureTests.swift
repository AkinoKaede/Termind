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
    @Test func forwardingEnabledIntentUsesInjectedDevicePreferences() throws {
        let suite = "MobileForwardingIntentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = try MobileAppModel(inMemory: true, forwardingDefaults: defaults)
        let host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        #expect(app.library.upsert(host, replacingPortForwardings: [rule]))

        app.forwardings.setEnabled(true, for: rule.id)
        #expect(app.forwardings.isEnabled(rule.id))
        #expect(defaults.stringArray(forKey: SettingsKey.portForwardingEnabledRuleIDs) == [rule.id.uuidString])
        app.forwardings.suspendAll()
        #expect(app.forwardings.isEnabled(rule.id))
        app.forwardings.setEnabled(false, for: rule.id)
        #expect(!app.forwardings.isEnabled(rule.id))
    }

    @Test func unsavedForwardingIntentWaitsUntilTheHostIsSaved() throws {
        let suite = "MobilePendingForwardingIntentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = try MobileAppModel(inMemory: true, forwardingDefaults: defaults)
        let host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        let rule = PortForwardingRule(hostID: host.id)

        app.forwardings.setEnabled(true, for: rule.id)
        #expect(app.forwardings.isEnabled(rule.id))
        #expect(app.forwardings.state(for: rule.id) == .stopped)
        #expect(app.library.upsert(host, replacingPortForwardings: [rule]))
        #expect(app.forwardings.state(for: rule.id) != .stopped)
        app.forwardings.setEnabled(false, for: rule.id)
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
        let item = SSHImportItem(
            category: .hosts, name: "Remote", source: "config",
            host: SSHImportedHost(alias: "remote", hostname: "example.invalid", username: ""))
        let model = SSHImportModel(library: app.library, reader: MobileImportFixture(items: [item]))
        await model.scan(URL(fileURLWithPath: "/fixture/.ssh"), knownHostsOnly: false)
        #expect(!model.canImport)
        model.items[0].host?.username = "deploy"
        #expect(model.canImport)
        await model.commit()
        #expect(model.completed)
        let host = try #require(app.library.hosts.first)
        #expect(app.library.identity(for: host)?.username == "deploy")
    }

    @Test func forwardingEditsValidateAndStopOnlyTheChangedRule() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Remote", host: "example.invalid")
        app.library.upsert(host)
        var rule = PortForwardingRule(hostID: host.id)
        try app.forwardingLibrary.save(rule)
        #expect(!app.forwardings.isEnabled(rule.id))
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

private actor MobileImportFixture: SSHImportReading {
    let items: [SSHImportItem]
    init(items: [SSHImportItem]) { self.items = items }
    func scan(root: URL, knownHostsOnly: Bool, grants: [URL]) -> [SSHImportItem] { items }
    func unlock(id: UUID, name: String, passphrase: String) throws -> SSHKeyRef { throw CocoaError(.coderInvalidValue) }
    func credentials(for ids: Set<UUID>) -> [UUID: StoredSSHKeyCredential] { [:] }
    func discard() {}
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
