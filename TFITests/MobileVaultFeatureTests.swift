import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileVaultFeatureTests {
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
        #expect(!editor.isDirty)
        editor.label = "Renamed"
        try await editor.save()
        let edited = try #require(app.credentials.key(key.id))
        #expect(edited.label == "Renamed")
        #expect(edited.credentialRef == key.credentialRef)
        #expect(try app.credentials.keyCredential(for: edited) == .software(secret))
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
