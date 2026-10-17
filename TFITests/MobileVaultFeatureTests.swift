import CryptoKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileVaultFeatureTests {
    @Test(arguments: [LocalDiscoveryProtocol.ssh, .telnet])
    func discoveryUsesTheSelectedProtocolWithoutRequestingPro(_ connectionProtocol: LocalDiscoveryProtocol) throws {
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = .testing(status: .free)
        let app = try MobileAppModel(dependencies: dependencies)
        defer { app.outbox.stop() }
        let model = app.localDiscoveryModel(protocol: connectionProtocol)
        #expect(model.connectionProtocol == connectionProtocol)
        #expect(model.phase == .idle)
        #expect(!app.pro.isPaywallPresented)
    }

    @Test func webAuthnGenerationUsesOriginalEditorAndPreferredVerification() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let editor = MobileKeyEditorModel(mode: .generate, credentials: app.credentials, defaultStorage: .thisDevice)
        editor.label = "YubiKey"
        editor.colorTag = .blue
        editor.passphrase = "unused"
        editor.confirmation = "mismatch"
        #expect(!editor.canSave)
        editor.usesWebAuthn = true
        #expect(editor.canSave)
        #expect(editor.verification == .preferred)
        let credential = SecurityKeyCredential(
            credentialID: Data([1, 2, 3]), publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation)
        try await editor.save { name, verification in
            #expect(name == "YubiKey")
            #expect(verification == .preferred)
            return credential
        }
        let key = try #require(app.credentials.keys.first { $0.label == "YubiKey" })
        #expect(key.algorithm == .securityKey && key.storage == .external)
        #expect(key.colorTag == .blue && !key.hasPassphrase)
        #expect(key.securityKey == credential)
    }

    @Test func webAuthnImportReadsReferencesAndAppliesSelectedVerification() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let editor = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials, defaultStorage: .thisDevice)
        editor.usesWebAuthn = true
        #expect(!editor.canSave)
        var credential = SecurityKeyCredential(
            credentialID: Data([4, 5, 6]), publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation,
            userVerification: .required)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try WebAuthnSSH.exportReference(credential).write(to: url, atomically: true, encoding: .utf8)
        try await editor.loadFile(url)
        #expect(editor.verification == .required && editor.canSave)
        editor.verification = .discouraged
        editor.label = "Imported YubiKey"
        try await editor.save()
        let key = try #require(app.credentials.keys.first { $0.label == "Imported YubiKey" })
        credential.userVerification = .discouraged
        #expect(key.securityKey == credential)
    }

    @Test func invalidWebAuthnImportDoesNotSaveAKey() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let editor = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        editor.usesWebAuthn = true
        editor.securityKeyReference = "invalid"
        let count = app.credentials.keys.count
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(app.credentials.keys.count == count)
    }

    @Test func appDefaultsNewCredentialsToThisDeviceWhenVaultSyncIsOff() throws {
        let domain = "MobileVaultCredentialDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        let app = try MobileAppModel(inMemory: true, defaults: defaults)
        defer { app.outbox.stop() }

        #expect(app.newVaultKeyStorage == .thisDevice)
        #expect(app.newVaultPasswordStorage == .thisDevice)
        let generator = MobileKeyEditorModel(
            mode: .generate,
            credentials: app.credentials,
            defaultStorage: app.newVaultKeyStorage)
        #expect(generator.storage == .thisDevice)

        generator.storage = .iCloud
        #expect(generator.storage == .iCloud)
    }

    @Test func hostMenuSeparatesConnectionEditingAndDeletionActions() {
        #expect(
            MobileHostMenuPolicy.sections == [
                [.ssh, .mosh, .eternalTerminal, .telnet, .sftp],
                [.wake, .tailscale],
                [.edit, .duplicate],
                [.delete],
            ])

        var host = TermindDomain.Host(name: "Remote", host: "remote.example.invalid")
        #expect(
            MobileHostMenuPolicy.sections(for: host) == [
                [.ssh, .sftp],
                [.edit, .duplicate],
                [.delete],
            ])

        host.sshEnabled = false
        host.telnetEnabled = true
        #expect(
            MobileHostMenuPolicy.sections(for: host) == [
                [.telnet],
                [.edit, .duplicate],
                [.delete],
            ])

        host.sshEnabled = true
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        #expect(MobileHostMenuPolicy.sections(for: host, hasTailscalePeer: true) == MobileHostMenuPolicy.sections)

        host.sshEnabled = false
        host.telnetEnabled = false
        #expect(
            MobileHostMenuPolicy.sections(for: host) == [
                [.wake],
                [.edit, .duplicate],
                [.delete],
            ])
    }

    @Test(arguments: ["", " ", "invalid", "FF:FF:FF:FF:FF:FF"], [false, true])
    func hostMenuHidesWakeWithoutAValidMAC(macAddress: String, hasTailscalePeer: Bool) {
        var host = TermindDomain.Host(name: "Remote", host: "remote.example.invalid")
        host.wakeOnLAN.macAddress = macAddress
        #expect(
            MobileHostMenuPolicy.sections(for: host, hasTailscalePeer: hasTailscalePeer)
                == [[.ssh, .sftp]] + (hasTailscalePeer ? [[.tailscale]] : []) + [[.edit, .duplicate], [.delete]])
    }

    @Test(arguments: [false, true])
    func hostMenuPlacesConfiguredWakeAboveTailscale(isTailscaleManaged: Bool) {
        var host = TermindDomain.Host(name: "Remote", host: "remote.example.invalid")
        host.wakeOnLAN.macAddress = "02:11:22:33:44:55"
        if isTailscaleManaged {
            host.tailscale = .init(groupID: UUID(), stableNodeID: "wake-test")
        }
        #expect(
            MobileHostMenuPolicy.sections(for: host) == [
                [.ssh, .sftp],
                isTailscaleManaged ? [.wake, .tailscale] : [.wake],
                [.edit, .duplicate],
                [.delete],
            ])
    }

    @Test func duplicatingAHostPersistsAnIndependentCopyWithTheSameConfiguration() async throws {
        let group = HostGroup(name: "Production")
        let jump = TermindDomain.Host(name: "Jump", host: "jump.example.invalid")
        let host = TermindDomain.Host(
            name: "Remote", host: "remote.example.invalid", port: 2222, identityID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100),
            jumpHostID: jump.id,
            proxy: HostProxy(kind: .socks5, hostname: "proxy.example.invalid", port: 1080),
            sftpChannelInitialPath: "/srv/app", groupID: group.id, tags: ["production", "api"],
            colorTag: .teal, detectedDistribution: DetectedDistribution(id: "debian"),
            shellIntegrationMode: .enabled, portForwardingMaxConnections: 12)
        var dependencies = MobileAppDependencies.testing()
        let container = try TermindPersistence.makeContainer(inMemory: true)
        _ = try HostPersistence(context: container.mainContext).save(.init(hosts: [jump, host], groups: [group]))
        dependencies.container = container
        let app = try MobileAppModel(dependencies: dependencies)
        let original = try #require(app.library.host(host.id))

        await app.duplicateHost(original)

        #expect(app.library.hosts.count == 3)
        #expect(app.library.host(original.id) == original)
        let copy = try #require(app.library.hosts.first { $0.id != jump.id && $0.id != original.id })
        #expect(copy.id != original.id)
        #expect(copy.name == "Remote copy")
        var expected = original
        expected.id = copy.id
        expected.name = copy.name
        expected.sortIndex = copy.sortIndex
        #expect(copy.createdAt != nil)
        #expect(copy.createdAt != original.createdAt)
        expected.createdAt = copy.createdAt
        #expect(copy == expected)
        app.outbox.stop()
    }

    @Test func deletingAGroupTreeCanKeepOrRemoveItsHosts() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }

        let keptRoot = HostGroup(name: "Keep")
        let keptChild = HostGroup(name: "Child", parentID: keptRoot.id)
        let keptHost = TermindDomain.Host(
            name: "Kept", host: "kept.example.invalid", groupID: keptChild.id)
        app.library.upsert(keptRoot)
        app.library.upsert(keptChild)
        app.library.upsert(keptHost)

        app.deleteHostGroup(keptRoot.id, keepHosts: true)

        #expect(app.library.groups.isEmpty)
        #expect(app.library.host(keptHost.id)?.groupID == nil)

        let removedRoot = HostGroup(name: "Remove")
        let removedChild = HostGroup(name: "Child", parentID: removedRoot.id)
        let removedHost = TermindDomain.Host(
            name: "Removed", host: "removed.example.invalid", groupID: removedChild.id)
        app.library.upsert(removedRoot)
        app.library.upsert(removedChild)
        app.library.upsert(removedHost)

        app.deleteHostGroup(removedRoot.id, keepHosts: false)

        #expect(app.library.groups.isEmpty)
        #expect(app.library.host(removedHost.id) == nil)
        let stored = try HostPersistence(context: ModelContext(app.container)).load()
        #expect(stored.groups.isEmpty)
        #expect(stored.hosts.map(\.id) == [keptHost.id])
        #expect(stored.hosts.first?.groupID == nil)
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
        #expect(!generated.publicKey.isEmpty && !generated.fingerprint.isEmpty)

        let replacement = try SSHKeyMaterial.generate(.ed25519, comment: "fixture", passphrase: nil)
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        #expect(!importer.canSave)
        #expect(importer.defaultName == "")
        importer.privateKey = replacement.privateKey
        await importer.refreshPublicMaterial()
        #expect(importer.defaultName == "Ed25519")
        #expect(importer.canSave)
        try await importer.save()
        let imported = try #require(app.credentials.keys.first { $0.id != generated.id })
        #expect(imported.label == "Ed25519")
        #expect(imported.publicKey.isEmpty && imported.fingerprint.isEmpty)

        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: generated)
        await editor.loadPrivateKey()
        editor.label = ""
        editor.privateKey = replacement.privateKey
        #expect(editor.defaultName == "")
        await editor.refreshPublicMaterial()
        #expect(editor.defaultName == "Ed25519")
        #expect(editor.canSave)
        try await editor.save()
        let edited = try #require(app.credentials.key(generated.id))
        #expect(edited.label == "Ed25519")
        #expect(edited.algorithm == .ed25519)
        #expect(edited.publicKey.isEmpty && edited.fingerprint.isEmpty)
        let reopened = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: edited)
        #expect(reopened.label == "Ed25519")
        await reopened.loadPrivateKey()
        reopened.privateKey = "invalid replacement"
        #expect(reopened.defaultName == "")
        await reopened.refreshPublicMaterial()
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
        let library = HostLibraryModel(hosts: [host])
        var identityDraft = HostCustomIdentityDraft(host: host, library: library)
        #expect(identityDraft.isProxyValid(for: host))

        host.proxy = HostEditorBindings.selectProxy(.http, current: nil)
        #expect(host.proxy?.port == 8080)
        #expect(!identityDraft.isProxyValid(for: host))

        host.proxy?.hostname = "proxy.example"
        #expect(identityDraft.isProxyValid(for: host))
        host.proxy?.port = 0
        #expect(!identityDraft.isProxyValid(for: host))
        host.proxy?.port = 8080
        host.proxy = HostEditorBindings.selectProxy(.socks5, current: host.proxy)
        #expect(host.proxy?.port == 1080)
        #expect(host.proxy?.hostname == "proxy.example")

        host.proxy?.port = 9000
        host.proxy = HostEditorBindings.selectProxy(.http, current: host.proxy)
        #expect(host.proxy?.port == 9000)

        let identity = Identity(
            name: "Proxy", username: "proxy-user", credentialRef: "termind.password.proxy")
        identityDraft.selectProxyIdentity(identity, on: &host)
        #expect(host.proxy?.identityID == identity.id)
        #expect(host.proxy?.username == "proxy-user")
        #expect(identityDraft.isProxyValid(for: host))

        host.proxy?.username = ""
        #expect(!identityDraft.isProxyValid(for: host))
        identityDraft.clearProxyIdentity(on: &host)
        #expect(host.proxy?.identityID == nil)
        #expect(host.proxy?.username.isEmpty == true)
        #expect(identityDraft.isProxyValid(for: host))

        host.proxy = HostEditorBindings.selectProxy(nil, current: host.proxy)
        #expect(host.proxy == nil)
    }

    @Test func mobileTagFieldAddsCreatesAndRemovesTagsLikeTheDesktopField() {
        let suggestions = ["api", "production", "web"]

        #expect(
            TagFieldPolicy.rows(tags: ["production"], suggestions: suggestions, query: "PI") == [
                .existing("api"), .create("PI"),
            ])
        #expect(
            TagFieldPolicy.rows(tags: [], suggestions: suggestions, query: "API") == [
                .existing("api")
            ])
        #expect(
            TagFieldPolicy.rows(tags: ["production"], suggestions: suggestions, query: "edge") == [
                .create("edge")
            ])
        #expect(TagFieldPolicy.submission(query: " API ", suggestions: suggestions) == "api")
        #expect(TagFieldPolicy.adding(" api ", to: ["production"]) == ["production", "api"])
        #expect(TagFieldPolicy.adding(" Production ", to: ["production"]) == ["production"])
        #expect(TagFieldPolicy.adding("   ", to: ["production"]) == ["production"])
        #expect(TagFieldPolicy.removing("production", from: ["production", "api"]) == ["api"])
    }

    @Test func aTagDisappearsAfterItsLastHostStopsUsingIt() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        var first = TermindDomain.Host(name: "First", host: "first.example.invalid", tags: ["production"])
        var second = TermindDomain.Host(name: "Second", host: "second.example.invalid", tags: ["production"])
        app.library.upsert(first)
        app.library.upsert(second)
        #expect(app.library.allTags == ["production"])

        first.tags = []
        app.library.upsert(first)
        #expect(app.library.allTags == ["production"])

        second.tags = []
        app.library.upsert(second)
        #expect(app.library.allTags.isEmpty)
    }

    @Test func identityCreationConfigurationsMatchHostAndProxyRequirements() {
        let identity = Identity(name: "Deploy", username: "deploy", keyID: UUID())

        #expect(MobileIdentityEditorConfiguration.standard.showsKey)
        #expect(
            MobileIdentityEditorConfiguration.standard.canSave(
                identity: identity, password: "", hasConfiguredPassword: false))
        #expect(!MobileIdentityEditorConfiguration.proxy.showsKey)
        #expect(
            !MobileIdentityEditorConfiguration.proxy.canSave(
                identity: identity, password: "", hasConfiguredPassword: false))
        #expect(
            MobileIdentityEditorConfiguration.proxy.canSave(
                identity: identity, password: "secret", hasConfiguredPassword: false))
        #expect(
            MobileIdentityEditorConfiguration.proxy.canSave(
                identity: identity, password: "", hasConfiguredPassword: true))
    }

    @Test func identityEditorDistinguishesNewAndSavedEntries() throws {
        let app = try MobileAppModel(inMemory: true)
        let identity = Identity(name: "Deploy", username: "deploy")

        #expect(MobileIdentityEditor(app: app, identity: identity).isNew)
        #expect(
            MobileIdentityEditor(app: app, identity: identity).title
                == String(localized: AppStrings.Keychain.newIdentity))
        app.library.upsert(identity)
        #expect(!MobileIdentityEditor(app: app, identity: identity).isNew)
        #expect(
            MobileIdentityEditor(app: app, identity: identity).title
                == String(localized: AppStrings.Keychain.editIdentity))
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

        var identityDraft = HostCustomIdentityDraft()
        identityDraft.selectSSHIdentity(createdIdentity, on: &host)
        #expect(host.identityID == createdIdentity.id)
        identityDraft.selectProxyIdentity(createdIdentity, on: &host)
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

    @Test func savedPassphraseDefaultsAndEditingPreserveOrRemoveTheSavedValue() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        #expect(generator.savePassphrase)
        generator.passphrase = "test-only-passphrase"
        generator.confirmation = generator.passphrase
        try await generator.save()
        let original = try #require(app.credentials.keys.first)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: original)
        await editor.loadPrivateKey()
        #expect(editor.savePassphrase && !editor.isDirty)
        #expect(editor.passphrase == "test-only-passphrase")
        editor.label = "Renamed"
        try await editor.save()
        guard case .software(let saved)? = try app.credentials.keyCredential(for: original) else {
            Issue.record("Expected saved key")
            return
        }
        #expect(saved.passphrase == "test-only-passphrase")
        let updated = try #require(app.credentials.key(original.id))
        let cancelled = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: updated)
        await cancelled.loadPrivateKey()
        cancelled.savePassphrase = false
        cancelled.clearSensitiveDrafts()
        #expect(app.credentials.hasSavedPassphrase(for: updated))
        let remover = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: updated)
        await remover.loadPrivateKey()
        remover.savePassphrase = false
        #expect(remover.isDirty)
        #expect(remover.passphrase == "test-only-passphrase")
        #expect(app.credentials.hasSavedPassphrase(for: updated))
        try await remover.save()
        guard case .software(let removed)? = try app.credentials.keyCredential(for: updated) else {
            Issue.record("Expected saved key")
            return
        }
        #expect(removed.passphrase == nil)
        #expect(removed.privateKey == saved.privateKey)
        #expect(app.credentials.key(original.id)?.hasPassphrase == true)
        #expect(app.credentials.key(original.id)?.publicKey == original.publicKey)
        #expect(!app.credentials.hasSavedPassphrase(for: updated))
        #expect(app.library.requiresPassphraseEntry(for: updated))
        let reopened = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: updated)
        await reopened.loadPrivateKey()
        #expect(!reopened.savePassphrase && reopened.passphrase.isEmpty && !reopened.isDirty)
        reopened.passphrase = "test-only-passphrase"
        #expect(!reopened.savePassphrase)
        reopened.savePassphrase = true
        try await reopened.save()
        #expect(app.credentials.hasSavedPassphrase(for: updated))
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        #expect(importer.savePassphrase)
        importer.privateKey = saved.privateKey
        importer.passphrase = "test-only-passphrase"
        importer.savePassphrase = false
        try await importer.save()
        let imported = try #require(app.credentials.keys.first { $0.id != original.id })
        guard case .software(let importedSecret)? = try app.credentials.keyCredential(for: imported) else {
            Issue.record("Expected imported key")
            return
        }
        #expect(importedSecret.passphrase == nil)
    }

    @Test func disablingPassphraseSavingBeforeTypingKeepsGeneratedAndImportedKeysEncrypted() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        generator.savePassphrase = false
        for value in ["first", "", "test-only-passphrase"] {
            generator.passphrase = value
            #expect(!generator.savePassphrase)
        }
        generator.confirmation = generator.passphrase
        try await generator.save()
        let generated = try #require(app.credentials.keys.first)
        guard case .software(let secret)? = try app.credentials.keyCredential(for: generated) else {
            Issue.record("Expected generated key")
            return
        }
        #expect(secret.passphrase == nil && generated.hasPassphrase)
        #expect(throws: (any Error).self) {
            try SSHKeyMaterial.inspect(privateKey: secret.privateKey, passphrase: nil, comment: "fixture")
        }
        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        importer.savePassphrase = false
        importer.privateKey = secret.privateKey
        importer.passphrase = "test-only-passphrase"
        #expect(!importer.savePassphrase)
        try await importer.save()
        let imported = try #require(app.credentials.keys.first { $0.id != generated.id })
        guard case .software(let importedSecret)? = try app.credentials.keyCredential(for: imported) else {
            Issue.record("Expected imported key")
            return
        }
        #expect(importedSecret.passphrase == nil && imported.hasPassphrase)
        #expect(imported.publicKey.isEmpty)
    }

    @Test func replacingPrivateKeyDoesNotReuseItsSavedPassphrase() async throws {
        let app = try MobileAppModel(inMemory: true)
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        generator.passphrase = "old-passphrase"
        generator.confirmation = generator.passphrase
        try await generator.save()
        let key = try #require(app.credentials.keys.first)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: key)
        await editor.loadPrivateKey()
        editor.privateKey = try SSHKeyMaterial.generate(.ed25519, comment: "replacement", passphrase: nil).privateKey
        #expect(editor.passphrase.isEmpty)
        try await editor.save()
        guard case .software(let secret)? = try app.credentials.keyCredential(for: key) else {
            Issue.record("Expected replacement key")
            return
        }
        #expect(secret.passphrase == nil)
        #expect(app.credentials.key(key.id)?.hasPassphrase == false)
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
        invalid.privateKey = "not a private key"
        invalid.passphrase = "wrong"
        await #expect(throws: (any Error).self) { try await invalid.save() }
        #expect(app.credentials.keys.count == 1)

        let importer = MobileKeyEditorModel(mode: .importKey, credentials: app.credentials)
        importer.label = "Imported"
        importer.privateKey = secret.privateKey
        importer.passphrase = "test-only-passphrase"
        try await importer.save()
        #expect(app.credentials.keys.count == 2)
        let imported = try #require(app.credentials.keys.first { $0.id != key.id })
        #expect(imported.publicKey.isEmpty && imported.fingerprint.isEmpty && imported.hasPassphrase)

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
        #expect(editor.publicKey.isEmpty)
        editor.publicKey = replacement.publicKey
        await editor.refreshPublicMaterial()
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

    @Test func missingPrivateKeyAllowsMetadataOnlyEditWithoutCreatingACredential() async throws {
        let original = SSHKeyRef(
            label: "Missing", publicKey: "ssh-ed25519 test", fingerprint: "SHA256:test",
            credentialRef: "termind.key.\(UUID())", storage: .thisDevice)
        let library = HostLibraryModel(keys: [original], secrets: InMemorySecretStore())
        let credentials = CredentialLibraryModel(library: library)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: credentials, key: original)

        await editor.loadPrivateKey()
        #expect(editor.privateKeyLoadError != nil)
        #expect(!editor.canEditPrivateKey)
        #expect(editor.canSave)

        editor.storage = .iCloud
        #expect(!editor.canSave)
        editor.storage = original.storage
        editor.privateKey = "replacement"
        #expect(!editor.canSave)
        editor.privateKey = ""
        editor.certificate = "not an SSH certificate"
        #expect(editor.canSave)
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(credentials.key(original.id) == original)
        editor.certificate = ""

        editor.label = "Renamed Missing"
        editor.colorTag = .orange
        try await editor.save()
        let updated = try #require(credentials.key(original.id))
        #expect(updated.label == "Renamed Missing")
        #expect(updated.colorTag == .orange)
        #expect(updated.credentialRef == original.credentialRef)
        #expect(updated.publicKey == original.publicKey)
        #expect(try credentials.keyCredential(for: updated) == nil)
    }

    @Test func missingIdentityPasswordLocksOnlyPasswordEditing() throws {
        let app = try MobileAppModel(inMemory: true)
        let identity = Identity(
            name: "Remote", username: "deploy", credentialRef: "termind.password.remote",
            passwordStorage: .thisDevice)
        app.library.upsert(identity)

        let editor = MobileIdentityEditor(app: app, identity: identity)
        #expect(!editor.canEditPassword)
        #expect(
            MobileIdentityEditorConfiguration.standard.canSave(
                identity: identity, password: "", hasConfiguredPassword: true))
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

    @Test func editingICloudSoftwareKeyCannotMoveItToThisDevice() async throws {
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
        #expect(!editor.canSelectThisDevice)
        editor.storage = .thisDevice
        #expect(!editor.canSave)
        await #expect(throws: (any Error).self) { try await editor.save() }

        let updated = try #require(credentials.key(original.id))
        #expect(updated.storage == .iCloud)
        #expect(try secrets.keyCredential(for: original.credentialRef, storage: .thisDevice) == nil)
        #expect(try secrets.keyCredential(for: original.credentialRef, storage: .iCloud) == secret)
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
        var host = TermindDomain.Host(
            name: "Remote", host: "example.invalid",
            proxy: HostProxy(kind: .http, hostname: "proxy.invalid", port: 8080))
        app.library.upsert(host)
        let dependent = TermindDomain.Host(name: "Dependent", host: "dependent.invalid", jumpHostID: host.id)
        app.library.upsert(dependent)
        let reusable = Identity(name: "Reusable", username: "shared")
        app.library.upsert(reusable)
        let ssh = try #require(
            try app.library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .ssh, displayName: host.name,
                username: "deploy", password: "ssh-secret", keyID: nil))
        let proxy = try #require(
            try app.library.saveCustomIdentity(
                ownerHostID: host.id, purpose: .proxy, displayName: "Remote Proxy",
                username: "proxy", password: "proxy-secret", keyID: nil))
        let retained = try #require(
            try app.library.saveCustomIdentity(
                ownerHostID: dependent.id, purpose: .ssh, displayName: dependent.name,
                username: "dependent", password: "retained-secret", keyID: nil))
        host.identityID = ssh.id
        host.proxy?.identityID = proxy.id
        host.proxy?.username = proxy.username
        #expect(app.library.saveHost(host))

        app.deleteHost(host.id)
        #expect(app.library.host(host.id) == nil)
        #expect(app.library.identity(ssh.id) == nil)
        #expect(app.library.identity(proxy.id) == nil)
        #expect(app.library.identity(reusable.id) == reusable)
        #expect(app.library.identity(retained.id)?.ownerHostID == dependent.id)
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
        #expect(Set(saved.identities.map(\.id)) == [reusable.id, retained.id])
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
