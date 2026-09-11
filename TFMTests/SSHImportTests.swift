import CryptoKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct SSHImportTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SSHImport-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hash(_ address: String) -> String {
        let salt = Data(repeating: 7, count: 20)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: Data(address.utf8), using: SymmetricKey(data: salt))
        return "|1|\(salt.base64EncodedString())|\(Data(digest).base64EncodedString())"
    }

    @Test
    func hashedKeysMatchPortsAndSurvivePersistenceWithoutHosts() throws {
        let entry = KnownHostEntry(hostname: hash("[2001:db8::1]:2222"), fingerprint: "SHA256:key")
        let decoded = try JSONDecoder().decode(KnownHostEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.matches(hostname: "2001:db8::1", port: 2222))
        #expect(!decoded.matches(hostname: "2001:db8::1", port: 22))
        let store = HostLibraryModel(knownHosts: [decoded])
        let host = Host(name: "IPv6", host: "2001:db8::1", port: 2222)
        #expect(try store.expectedHostKeys(for: host) == [entry.identity])
        store.markKnownHostMismatched(hostname: host.host, port: host.port)
        #expect(store.knownHosts[0].isMismatched)
        store.forgetKnownHosts(for: host)
        #expect(store.knownHosts.isEmpty)
    }

    @Test
    func configHonorsFirstValuesHostPatternsAndOrderedIncludes() {
        let root = URL(fileURLWithPath: "/fixture/.ssh")
        var parser = SSHConfigParser(
            root: root, home: URL(fileURLWithPath: "/fixture"), username: "local",
            files: [
                "/fixture/.ssh/config": """
                Host prod alias
                    HostName prod.example
                    User deploy
                    IdentityFile "~/.ssh/deploy key"
                    Include conf/*.conf
                Host * !alias
                    Port 2222
                Host *
                    User fallback
                """,
                "/fixture/.ssh/conf/01.conf": "Port=2200\nIdentityFile ~/.ssh/second",
                "/fixture/.ssh/conf/02.conf": "Port 2300",
            ])
        let entries = parser.parse().compactMap(\.host)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.port == 2200 && $0.username == "deploy" })
        #expect(entries[0].identityPaths == ["/fixture/.ssh/deploy key", "/fixture/.ssh/second"])
    }

    @Test
    func configReportsCyclesAndDoesNotExecuteMatchOrProxyCommands() {
        let root = URL(fileURLWithPath: "/fixture")
        var parser = SSHConfigParser(
            root: root, home: root, username: "local",
            files: [
                "/fixture/config":
                    "Host app\nHostName app.example\nProxyCommand touch /tmp/never\nInclude loop\nMatch exec \"exit 0\"\nUser wrong",
                "/fixture/loop": "Include config",
            ])
        let entries = parser.parse()
        let host = entries.first { $0.host != nil }
        #expect(host?.host?.username == "local")
        #expect(host?.warnings.contains(where: { $0.contains("proxycommand") }) == true)
        #expect(host?.warnings.contains(where: { $0.contains("Match") }) == true)
        #expect(entries.contains { $0.unavailable })
    }

    @Test
    func knownHostsValidatesWireKeysAndPreservesMultipleEndpoints() throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let content = """
            # comment
            example,[2001:db8::1]:2222 \(material.publicKey)
            \(hash("other.example")) \(material.publicKey)
            @revoked revoked.example \(material.publicKey)
            *.wild.example \(material.publicKey)
            broken ssh-ed25519 AAAA
            """
        let rows = SSHImportParser.knownHosts(content, source: "known_hosts")
        #expect(rows.filter { !$0.unavailable }.count == 3)
        #expect(rows.compactMap(\.knownHost).allSatisfy { $0.fingerprint == material.fingerprint })
        #expect(rows.filter(\.unavailable).count == 3)
        #expect(rows.compactMap(\.knownHost).contains { $0.matches(hostname: "other.example", port: 22) })
    }

    @Test
    func droppedSourcesUseTheSameTypeValidationAsTheFilePicker() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("known_hosts")
        try "# empty".write(to: file, atomically: true, encoding: .utf8)
        let reader = SSHImportReader()
        await #expect(throws: SSHImportSourceError.expectedFolder) {
            _ = try await reader.scan(root: file, knownHostsOnly: false)
        }
        await #expect(throws: SSHImportSourceError.expectedFile) {
            _ = try await reader.scan(root: url, knownHostsOnly: true)
        }
        #expect(try await reader.scan(root: file, knownHostsOnly: true).isEmpty)
    }

    @Test
    func malformedPrivateKeysAreUnavailableRatherThanAskingForAPassphrase() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        try "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----".write(
            to: url.appendingPathComponent("broken"), atomically: true, encoding: .utf8)
        let reader = SSHImportReader()
        let rows = try await reader.scan(root: url, knownHostsOnly: false)
        #expect(rows.count == 1)
        #expect(rows[0].unavailable && !rows[0].selected && !rows[0].requiresPassphrase)
    }

    @Test
    func selectionStartsCheckedAndCollapseDoesNotChangeIt() {
        let model = SSHImportModel(library: HostLibraryModel(), reader: SSHImportReader())
        model.items = [
            SSHImportItem(category: .hosts, name: "a", source: "config"),
            SSHImportItem(category: .keys, name: "b", source: "key"),
            SSHImportItem(category: .knownHosts, name: "c", source: "known_hosts"),
            SSHImportItem(category: .keys, name: "bad", source: "bad", selected: false, unavailable: true),
        ]
        #expect(model.selectedItems().count == 3)
        model.expanded.remove(.keys)
        #expect(model.selectedItems().count == 3)
        model.setSelected(false, category: .keys)
        #expect(model.selectedItems().count == 2)
        model.setSelected(false)
        #expect(!model.canImport)
        model.setSelected(true)
        #expect(model.selectedItems().count == 3)
        #expect(!model.items[3].selected)
    }

    @Test
    func folderImportMigratesSecretsAndIsIdempotent() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        try material.privateKey.write(to: url.appendingPathComponent("id_ed25519"), atomically: true, encoding: .utf8)
        try "Host prod\n HostName prod.example\n User deploy\n IdentityFile ~/.ssh/id_ed25519\n".write(
            to: url.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "prod.example \(material.publicKey)".write(
            to: url.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let store = HostLibraryModel()
        let model = SSHImportModel(library: store, reader: SSHImportReader())
        await model.scan(url, knownHostsOnly: false)
        #expect(model.selectedItems().count == 3)
        #expect(store.hosts.isEmpty && store.keys.isEmpty)
        #expect(model.canImport)
        await model.commit()
        #expect(model.completed)
        #expect(store.hosts.count == 1 && store.keys.count == 1 && store.knownHosts.count == 1)
        let identity = try #require(store.identities.first)
        #expect(identity.username == "deploy" && identity.keyID == store.keys.first?.id)
        #expect(store.keyAvailability(for: try #require(store.keys.first)) == .available)
        let again = SSHImportModel(library: store, reader: SSHImportReader())
        await again.scan(url, knownHostsOnly: false)
        #expect(again.selectedItems().isEmpty)
        #expect(!again.canImport)
    }

    @Test
    func encryptedKeyCanBeUnlockedAndDeselectionRefreshesHostAssociation() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: "test-password")
        try material.privateKey.write(to: url.appendingPathComponent("deploy"), atomically: true, encoding: .utf8)
        try "Host prod\nIdentityFile ~/.ssh/deploy".write(
            to: url.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let model = SSHImportModel(library: HostLibraryModel(), reader: SSHImportReader())
        await model.scan(url, knownHostsOnly: false)
        let id = try #require(model.items.first { $0.category == .keys }?.id)
        #expect(!model.canImport)
        await model.unlock(id, passphrase: "wrong")
        #expect(!model.canImport)
        await model.unlock(id, passphrase: "test-password")
        #expect(model.canImport)
        let host = try #require(model.items.first { $0.host != nil })
        #expect(model.chosenKey(for: host)?.id == id)
        model.setSelected(false, category: .keys)
        #expect(model.chosenKey(for: host) == nil)
        #expect(model.canImport)
    }

    @Test
    func jumpDependenciesAndCyclesBlockCommit() {
        let model = SSHImportModel(library: HostLibraryModel(), reader: SSHImportReader())
        model.items = [
            SSHImportItem(
                category: .hosts, name: "app", source: "config",
                host: SSHImportedHost(alias: "app", hostname: "app", username: "u", jumps: ["jump"])),
            SSHImportItem(
                category: .hosts, name: "jump", source: "config",
                host: SSHImportedHost(alias: "jump", hostname: "jump", username: "u")),
        ]
        #expect(model.canImport)
        model.items[1].selected = false
        #expect(!model.canImport)
        model.items[1].selected = true
        model.items[1].host?.jumps = ["app"]
        #expect(!model.canImport)
        #expect(model.routeProblem != nil)
    }

    @Test
    func importRetainsMismatchWarningsAndRequiresConflictReview() async {
        let original = KnownHostEntry(hostname: "host", fingerprint: "SHA256:old", isMismatched: true)
        let store = HostLibraryModel(knownHosts: [original])
        let model = SSHImportModel(library: store, reader: SSHImportReader())
        model.items = [
            SSHImportItem(
                category: .knownHosts, name: "host", source: "known_hosts",
                knownHost: KnownHostEntry(hostname: "host", fingerprint: "SHA256:new"))
        ]
        #expect(!model.canImport)
        model.items[0].acceptedWarnings = true
        #expect(model.canImport)
        await model.commit()
        #expect(model.completed)
        #expect(store.knownHosts.first?.isMismatched == true)
    }

    @Test
    func multiHopImportsPreserveStandaloneJumpConfigurations() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        try "Host app\nProxyJump first,second\nHost first\nHost second".write(
            to: url.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let store = HostLibraryModel()
        let model = SSHImportModel(library: store, reader: SSHImportReader())
        await model.scan(url, knownHostsOnly: false)
        #expect(model.canImport)
        await model.commit()
        #expect(model.completed)
        let second = try #require(store.hosts.first { $0.name == "second" })
        #expect(second.jumpHostID == nil)
        let app = try #require(store.hosts.first { $0.name == "app" })
        let intermediate = try #require(app.jumpHostID.flatMap(store.host))
        #expect(intermediate.host == "second")
        #expect(intermediate.jumpHostID.flatMap(store.host)?.name == "first")
        let again = SSHImportModel(library: store, reader: SSHImportReader())
        await again.scan(url, knownHostsOnly: false)
        #expect(again.selectedItems().isEmpty)
    }

    @Test
    func externalKeyIsOnlyReadAfterExplicitAuthorization() async throws {
        let url = try root()
        let external = try root()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: external)
        }
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: nil)
        let keyURL = external.appendingPathComponent("deploy")
        try material.privateKey.write(to: keyURL, atomically: true, encoding: .utf8)
        try "Host app\nIdentityFile \(keyURL.path)".write(
            to: url.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let reader = SSHImportReader()
        let before = try await reader.scan(root: url, knownHostsOnly: false)
        #expect(before.compactMap(\.key).isEmpty)
        #expect(before.contains { $0.needsAuthorization == keyURL.path })
        let after = try await reader.scan(root: url, knownHostsOnly: false, grants: [keyURL])
        #expect(after.compactMap(\.key).count == 1)
        #expect(!after.contains { $0.needsAuthorization != nil })
    }

    @Test
    func keychainPagePruningDoesNotEraseKnownHostSelection() {
        let entry = KnownHostEntry(hostname: "host", fingerprint: "SHA256:key")
        let store = HostLibraryModel(knownHosts: [entry])
        let window = WindowModel()
        window.selectVaultItem(.knownHost(entry.id), on: .knownHosts)
        window.pruneVaultSelections(in: CredentialLibraryModel(library: store))
        #expect(window.vaultSelection(for: .knownHosts) == [.knownHost(entry.id)])
    }

    @Test
    func failedSnapshotRollsBackMetadataAndNewCredentials() throws {
        let persistence = FailingImportPersistence()
        let secrets = InMemorySecretStore()
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        let key = SSHKeyRef(label: "Imported", credentialRef: "import-test")
        let batch = SSHImportBatch(
            hosts: [Host(name: "new", host: "new")], keys: [key],
            knownHosts: [KnownHostEntry(hostname: "new", fingerprint: "SHA256:key")],
            credentials: [key.id: .software(SSHPrivateKeySecret(privateKey: "test-private-material"))])
        #expect(throws: (any Error).self) { try store.commitSSHImport(batch) }
        #expect(store.hosts.isEmpty && store.keys.isEmpty && store.knownHosts.isEmpty)
        #expect(try secrets.keyCredential(for: key.credentialRef, storage: key.storage) == nil)
        #expect(!store.saveKnownHost(KnownHostEntry(hostname: "new", fingerprint: "SHA256:key")))
        #expect(store.knownHosts.isEmpty)
    }

    @Test
    func vaultKnownHostNavigationUsesFingerprintAndRetainsSelection() {
        let entry = KnownHostEntry(hostname: "host", fingerprint: "SHA256:key")
        let store = HostLibraryModel(knownHosts: [entry])
        let window = WindowModel()
        window.selectVaultItem(.knownHost(entry.id), on: .knownHosts)
        window.vaultPages.knownHosts.query = "key"
        window.openPage(.hosts)
        window.openPage(.knownHosts)
        window.pruneVaultSelections(in: store)
        #expect(window.vaultSelection(for: .knownHosts) == [.knownHost(entry.id)])
        #expect(window.vaultPages.knownHosts.query == "key")
        #expect(window.findKind == .knownHosts)
        #expect(VaultPage.knownHosts.symbol == "touchid")
        #expect(VaultPage.allCases.last == .knownHosts)
    }
}

@MainActor
private final class FailingImportPersistence: VaultPersisting {
    func load() throws -> VaultSnapshot { VaultSnapshot() }
    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet { throw CocoaError(.fileWriteUnknown) }
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        throw CocoaError(.fileWriteUnknown)
    }
}
