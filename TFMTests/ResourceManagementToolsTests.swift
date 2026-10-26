// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind
@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct ResourceManagementToolsTests {
    @Test func multilineSecretReturnDoesNotSubmitTheForm() {
        for keyCode: UInt16 in [36, 76] {
            #expect(
                ActiveFormKeyDecision.resolve(
                    keyCode: keyCode, hasModifiers: false, hasMarkedText: false,
                    isRepeat: false, isDefaultEnabled: true, isMultilineEditor: true) == .passThrough)
        }
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 53, hasModifiers: false, hasMarkedText: false,
                isRepeat: false, isDefaultEnabled: true, isMultilineEditor: true) == .cancel)
    }

    @Test func hostAndGroupEditsPreserveNullsAndRejectInvalidReferences() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let parent = try await fixture.call(.hostGroup, .add, ["name": .string("Production")])
        let groupID = try parent.resourceID()
        let child = try await fixture.call(
            .hostGroup, .add,
            [
                "name": .string("Child"), "parent_id": .string(groupID.uuidString),
            ])
        let childID = try child.resourceID()
        await #expect(throws: ResourceToolError.self) {
            try await fixture.call(
                .hostGroup, .edit,
                [
                    "host_group_id": .string(groupID.uuidString), "parent_id": .string(childID.uuidString),
                ])
        }
        let added = try await fixture.call(
            .host, .add,
            [
                "address": .string("example.invalid"), "group_id": .string(childID.uuidString),
                "telnet_enabled": .bool(true), "ssh_enabled": .bool(false),
            ])
        let hostID = try added.resourceID()
        _ = try await fixture.call(
            .host, .edit,
            [
                "host_id": .string(hostID.uuidString), "group_id": .null, "name": .string("Renamed"),
            ])
        #expect(fixture.library.host(hostID)?.groupID == childID)
        await #expect(throws: ResourceToolError.self) {
            try await fixture.call(
                .host, .edit,
                [
                    "host_id": .string(hostID.uuidString), "ssh_identity_id": .string(UUID().uuidString),
                ])
        }
        _ = try await fixture.call(.hostGroup, .delete, ["host_group_id": .string(groupID.uuidString)])
        #expect(fixture.library.groups.isEmpty)
        #expect(fixture.library.host(hostID)?.groupID == nil)
        #expect(fixture.library.host(hostID)?.name == "Renamed")
        await #expect(throws: ResourceToolError.self) {
            try await fixture.call(.host, .edit, ["host_id": .string(UUID().uuidString), "name": .string("Missing")])
        }
    }

    @Test func snippetsClearReferencesAndRejectCyclesWithoutChangingTheLibrary() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let package = try await fixture.call(.snippetPackage, .add, ["name": .string("Scripts")])
        let packageID = try package.resourceID()
        await #expect(throws: ResourceToolError.self) {
            try await fixture.call(
                .snippetPackage, .edit,
                [
                    "snippet_package_id": .string(packageID.uuidString), "parent_id": .string(packageID.uuidString),
                ])
        }
        let snippet = try await fixture.call(
            .snippet, .add,
            [
                "title": .string("Inspect"), "body": .string("printf ready"),
                "package_id": .string(packageID.uuidString),
                "target_host_ids": .array([.string(fixture.host.id.uuidString)]),
            ])
        let id = try snippet.resourceID()
        let listing = try await fixture.call(.snippet, .list)
        #expect(listing.objectValue?["snippets"]?.arrayValue?.first?.objectValue?["body"] == nil)
        _ = try await fixture.call(
            .snippet, .edit,
            [
                "snippet_id": .string(id.uuidString), "body": .null,
                "clear_fields": .array([.string("target_host_ids")]),
            ])
        #expect(fixture.library.snippets.first?.body == "printf ready")
        #expect(fixture.library.snippets.first?.targetHostIDs.isEmpty == true)
        _ = try await fixture.call(.snippetPackage, .delete, ["snippet_package_id": .string(packageID.uuidString)])
        #expect(fixture.library.snippets.first?.packageID == nil)
        #expect(fixture.library.snippets.count == 1)
    }

    @Test func metricsSaveOnceAndNeverResumeSleepingOrPausedCollection() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let hostID = AgentJSONValue.string(fixture.host.id.uuidString)
        _ = try await fixture.call(
            .metrics, .add,
            [
                "host_id": hostID, "enabled": .bool(false), "disks": .array([]),
            ])
        #expect(fixture.preferences.saves == 1)
        #expect(fixture.metrics.selections.first?.disks == [])
        let paused = try await fixture.call(.metrics, .refresh, ["host_id": hostID])
        #expect(paused.objectValue?["refresh_requested"] == .bool(false))
        _ = try await fixture.call(.metrics, .start, ["host_id": hostID])
        #expect(fixture.metrics.selections.first?.enabled == true)
        #expect(fixture.metrics.sleeping)
        let sleeping = try await fixture.call(.metrics, .refresh, ["host_id": hostID])
        #expect(sleeping.objectValue?["refresh_requested"] == .bool(false))
        _ = try await fixture.call(
            .metrics, .edit,
            [
                "host_id": hostID, "disks": .null, "clear_fields": .array([.string("disks")]),
            ])
        #expect(fixture.metrics.selections.first?.disks == nil)
        let before = fixture.metrics.selections
        fixture.preferences.fails = true
        await #expect(throws: (any Error).self) {
            try await fixture.call(.metrics, .stop, ["host_id": hostID])
        }
        #expect(fixture.metrics.selections == before)
        #expect(fixture.preferences.values == before)
    }

    @Test func forwardingUsesApplicationRuntimeAndRejectsAnUnavailableHost() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let added = try await fixture.call(
            .portForwarding, .add,
            [
                "host_id": .string(fixture.host.id.uuidString), "kind": .string("dynamic"), "bind_port": .number(8080),
            ])
        let id = try added.resourceID()
        let arguments: [String: AgentJSONValue] = ["port_forwarding_id": .string(id.uuidString)]
        let started = try await fixture.call(.portForwarding, .start, arguments)
        #expect(started.objectValue?["requires_user_action"] == .bool(true))
        #expect(fixture.runtime.started == [id])
        _ = try await fixture.call(
            .portForwarding, .edit, arguments.merging(["bind_port": .number(8081)]) { _, n in n })
        #expect(fixture.runtime.stopped.contains(id))
        fixture.library.projectHostDeletion(fixture.host.id)
        await #expect(throws: ResourceToolError.self) {
            try await fixture.call(.portForwarding, .start, arguments)
        }
    }

    @Test func identityHandlesAreSingleUseAndReadsNeverResolveSecrets() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let secretText = "synthetic-only-identity-secret"
        var bytes = Data(secretText.utf8)
        let handle = try await fixture.broker.issue(AgentSecret(consumingUTF8: &bytes))
        let args: [String: AgentJSONValue] = [
            "name": .string("Login"), "username": .string("root"),
            "password_secret_handle": .string(handle.id.uuidString),
        ]
        let tool = ResourceManagementTool(
            specification: .init(resource: .identity, action: .add), manager: fixture.manager)
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "test", name: tool.descriptor.name,
                arguments: .object(args)))
        _ = try await tool.preflight(invocation)
        #expect(await fixture.broker.count == 1)
        let added = try await fixture.call(.identity, .add, args)
        #expect(await fixture.broker.count == 0)
        #expect(!String(describing: added).contains(secretText))
        let id = try added.resourceID()
        fixture.secrets.rejectReads = true
        _ = try await fixture.call(.identity, .get, ["identity_id": .string(id.uuidString)])
        _ = try await fixture.call(.identity, .list)
        #expect(fixture.secrets.readsWhileRejected == 0)
        fixture.secrets.rejectReads = false
        await #expect(throws: SecretBrokerError.self) {
            try await fixture.call(.identity, .add, args)
        }
        _ = try await fixture.call(
            .identity, .edit, ["identity_id": .string(id.uuidString), "notes": .string("Updated")])
        #expect(fixture.library.identities.first?.usesPassword == true)
        _ = try await fixture.call(
            .identity, .edit,
            [
                "identity_id": .string(id.uuidString), "clear_fields": .array([.string("password")]),
            ])
        #expect(fixture.library.identities.first?.usesPassword == false)
    }

    @Test func softwareKeyGenerationRotationAndMetadataReadsKeepPrivateMaterialPrivate() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let generated = try await fixture.call(.key, .generate, ["label": .string("Generated")])
        let id = try generated.resourceID()
        let original = try #require(fixture.library.keys.first)
        #expect(generated.objectValue?["algorithm"] == .string(SSHKeyAlgorithm.ed25519.rawValue))
        #expect(!String(describing: generated).contains(original.credentialRef))
        let replacement = try SSHKeyMaterial.generate(.ed25519, comment: "rotation", passphrase: nil)
        var bytes = Data(replacement.privateKey.utf8)
        let handle = try await fixture.broker.issue(AgentSecret(consumingUTF8: &bytes))
        let rotated = try await fixture.call(
            .key, .edit,
            [
                "key_id": .string(id.uuidString), "private_key_secret_handle": .string(handle.id.uuidString),
            ])
        #expect(rotated.objectValue?["fingerprint"] == .string(replacement.fingerprint))
        #expect(rotated.objectValue?["public_key"] != generated.objectValue?["public_key"])
        #expect(!String(describing: rotated).contains(replacement.privateKey))
        fixture.secrets.rejectReads = true
        _ = try await fixture.call(.key, .get, ["key_id": .string(id.uuidString)])
        _ = try await fixture.call(.key, .list)
        _ = try await fixture.call(.key, .edit, ["key_id": .string(id.uuidString), "label": .string("Renamed")])
        #expect(fixture.secrets.readsWhileRejected == 0)
    }

    @Test func mcpExportsFamiliesOnceAndDisabledExecutionCannotUseTheSnippetWrapper() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let server = makeMCPServerTools(hosts: [fixture.host], management: fixture.manager)
        let names = server.descriptors.map(\.name)
        #expect(Set(names).isSuperset(of: TermindToolName.managementNames))
        #expect(names.filter { $0 == TermindToolName.listHosts }.count == 1)
        #expect(names.filter { $0 == TermindToolName.getMetrics }.count == 1)
        let result = try await server.call(
            name: TermindToolName.addHostGroup, arguments: .object(["name": .string("MCP")]), runID: UUID(),
            clientName: "Tests", callID: "add", secretBroker: fixture.broker)
        #expect(!result.isError)
        #expect(fixture.library.groups.first?.name == "MCP")
        let disabled = makeMCPServerTools(disabledTools: [TermindToolName.sshExecRun], management: fixture.manager)
        #expect(!disabled.descriptors.contains { $0.name == TermindToolName.runSnippet })
        await #expect(throws: MCPServerToolsError.self) {
            try await disabled.call(
                name: TermindToolName.runSnippet, arguments: .object([:]), runID: UUID(),
                clientName: "Tests", callID: "denied", secretBroker: fixture.broker)
        }
    }

    @Test func schemasRejectPlaintextAndActionsUseTheSharedVocabulary() throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        for spec in ResourceToolSpecification.all {
            let tool = ResourceManagementTool(specification: spec, manager: fixture.manager)
            #expect(tool.descriptor.presentation?.actionKind == spec.action.presentation)
            #expect(tool.descriptor.approvalPolicy == (spec.action.readOnly ? .approve : .ask))
        }
        let spec = ResourceToolSpecification(resource: .identity, action: .add)
        let tool = ResourceManagementTool(specification: spec, manager: fixture.manager)
        #expect(throws: (any Error).self) {
            try AgentJSONSchemaValidator.validate(
                .object([
                    "name": .string("Test"), "username": .string("root"), "password": .string("plaintext"),
                ]), against: tool.descriptor.inputSchema)
        }
        #expect(throws: ResourceToolError.self) {
            try ResourceToolArguments(
                .object([
                    "notes": .string("new"), "clear_fields": .array([.string("notes")]),
                ]), allowedClears: ["notes"])
        }
    }

    @Test func snippetPreflightFreezesApprovalContentAndPlanningRejectsDestructiveScripts() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let snippet = Snippet(title: "Inspect", body: "pwd")
        #expect(fixture.library.saveSnippet(snippet))
        let resolver = AgentHostResolver(store: fixture.library)
        let pool = AgentConnectionPool(
            configuration: { _ in throw ResourceToolError.unsupported },
            routeFingerprint: { _ in throw ResourceToolError.unsupported },
            openConnection: { _ in throw ResourceToolError.unsupported },
            openSFTP: { _ in throw ResourceToolError.unsupported }, sweepInterval: nil)
        let base = SSHExecRunTool(
            authentication: AgentSSHAuthenticationRegistry(resolver: resolver), pool: pool,
            background: AgentBackgroundCommands(sweepInterval: nil), scope: UUID())
        let tool = RunSnippetTool(manager: fixture.manager, base: base, planning: false)
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "snippet", name: TermindToolName.runSnippet,
                arguments: .object([
                    "host_id": .string(fixture.host.id.uuidString), "snippet_id": .string(snippet.id.uuidString),
                ])))
        let approved = try await tool.preflight(invocation)
        var edited = snippet
        edited.body = "rm -rf /tmp/test-resource"
        #expect(fixture.library.saveSnippet(edited))
        #expect(approved.invocation.call.arguments.objectValue?["command"] == .string("pwd"))
        #expect(approved.executionMetadata["snippet_command"] == .string("pwd"))
        let planning = RunSnippetTool(manager: fixture.manager, base: base, planning: true)
        let refused = try await planning.preflight(invocation)
        #expect(refused.approvalPolicy == .deny)
        #expect(refused.invocation.call.arguments.objectValue?["command"] == .string(edited.body))
    }

    @Test func foreignAndPartiallyConsumedHandlesCannotBeReused() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        var bytes = Data("synthetic-passphrase".utf8)
        let handle = try await fixture.broker.issue(AgentSecret(consumingUTF8: &bytes))
        let arguments = try ResourceToolArguments(
            .object([
                "passphrase_secret_handle": .string(handle.id.uuidString),
                "private_key_secret_handle": .string(UUID().uuidString),
            ]))
        await #expect(throws: SecretBrokerError.self) {
            try await ResourceSecretInputs.consume(arguments, broker: SecretBroker())
        }
        #expect(await fixture.broker.count == 1)
        await #expect(throws: SecretBrokerError.self) {
            try await ResourceSecretInputs.consume(arguments, broker: fixture.broker)
        }
        #expect(await fixture.broker.count == 0)
        await #expect(throws: SecretBrokerError.self) { try await fixture.broker.consume(handle) }
    }

    @Test func encryptedKeyImportAndClearingSavedPassphraseDoNotReencryptPrivateMaterial() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let phrase = "synthetic-unlock-phrase"
        let material = try await Task.detached {
            try SSHKeyMaterial.generate(.ed25519, comment: "encrypted", passphrase: phrase)
        }.value
        var keyBytes = Data(material.privateKey.utf8)
        var phraseBytes = Data(phrase.utf8)
        let keyHandle = try await fixture.broker.issue(AgentSecret(consumingUTF8: &keyBytes))
        let phraseHandle = try await fixture.broker.issue(AgentSecret(consumingUTF8: &phraseBytes))
        let result = try await fixture.call(
            .key, .add,
            [
                "private_key_secret_handle": .string(keyHandle.id.uuidString),
                "passphrase_secret_handle": .string(phraseHandle.id.uuidString),
            ])
        let id = try result.resourceID()
        let key = try #require(fixture.library.key(id))
        #expect(key.hasPassphrase)
        #expect(!String(describing: result).contains(phrase))
        #expect(await fixture.broker.count == 0)
        _ = try await fixture.call(
            .key, .edit,
            [
                "key_id": .string(id.uuidString), "clear_fields": .array([.string("passphrase")]),
            ])
        guard
            case .software(let saved)? = try fixture.secrets.base.keyCredential(
                for: key.credentialRef, storage: key.storage)
        else {
            Issue.record("Expected an imported software key")
            return
        }
        #expect(saved.passphrase == nil)
        #expect(saved.privateKey == material.privateKey)
        #expect(fixture.library.key(id)?.hasPassphrase == true)
    }

    @Test func secureEnclaveGenerationUsesInjectedMaterialWithoutReturningItsHandle() async throws {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let publicMaterial = try SSHKeyMaterial.generate(.ecdsa(bits: 256), comment: "test", passphrase: nil)
        let handle = Data("synthetic-enclave-capability".utf8)
        let manager = AgentResourceManager(
            credentials: CredentialLibraryModel(library: fixture.library),
            snippets: SnippetLibraryModel(library: fixture.library),
            forwardings: ForwardingLibraryModel(library: fixture.library),
            forwardingRuntime: fixture.runtime, metrics: fixture.metrics,
            generateEnclave: { _, _ in
                SecureEnclaveKeyMaterial(
                    credential: .init(dataRepresentation: handle), publicKey: publicMaterial.publicKey,
                    fingerprint: publicMaterial.fingerprint)
            })
        let spec = ResourceToolSpecification(resource: .key, action: .generate)
        let result = try await manager.perform(
            spec, arguments: ResourceToolArguments(.object(["storage": .string("secureEnclave")])),
            broker: fixture.broker)
        #expect(result.objectValue?["bits"] == .number(256))
        #expect(!String(describing: result).contains(handle.base64EncodedString()))
        #expect(!String(describing: result).contains("synthetic-enclave-capability"))
        await #expect(throws: ResourceToolError.self) {
            try await manager.perform(
                spec,
                arguments: ResourceToolArguments(
                    .object([
                        "storage": .string("secureEnclave"), "algorithm": .string("rsa"),
                    ])), broker: fixture.broker)
        }
    }

    @Test func presentationUsesLocalizedActionsAndNeverClaimsRefreshProducedASample() {
        let fixture = ResourceFixture()
        defer { fixture.metrics.shutdown() }
        let renderer = TermindToolPresentationProfiles.renderer
        for (action, english) in [
            (ResourceToolSpecification.Action.add, "Added"), (.generate, "Generated"), (.stop, "Stopped"),
        ] {
            let tool = ResourceManagementTool(
                specification: .init(resource: action == .stop ? .portForwarding : .key, action: action),
                manager: fixture.manager)
            let invocation = AgentToolInvocation(
                runID: UUID(),
                call: .init(
                    id: "presentation", name: tool.descriptor.name,
                    arguments: .object([:])))
            let card = AgentToolCard(invocation: invocation, descriptor: tool.descriptor, state: .completed)
            #expect(renderer.summary(for: card, locale: Locale(identifier: "en")).hasPrefix(english))
            let chinese = renderer.summary(for: card, locale: Locale(identifier: "zh-Hans"))
            #expect(!chinese.contains(english))
            #expect(!chinese.contains("managed_"))
        }
        let tool = ResourceManagementTool(
            specification: .init(resource: .metrics, action: .refresh), manager: fixture.manager)
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "refresh", name: tool.descriptor.name,
                arguments: .object([:])))
        let card = AgentToolCard(
            invocation: invocation, descriptor: tool.descriptor, state: .completed,
            result: .init(callID: "refresh", content: "{\"refresh_requested\":false}"))
        #expect(renderer.summary(for: card, locale: Locale(identifier: "en")) == "Refresh not requested")
        #expect(renderer.batchSummary(for: [card], locale: Locale(identifier: "en")) == "Refresh not requested")
    }
}

@MainActor
private final class ResourceFixture {
    let host = Host(name: "Test", host: "test.invalid")
    let library: HostLibraryModel
    let metrics: ServerMetricsModel
    let preferences = ResourceMetricsPreferences()
    let secrets = ResourceSecretStore()
    let runtime = ResourceForwardingRuntime()
    let manager: AgentResourceManager
    let broker = SecretBroker()

    init() {
        library = HostLibraryModel(hosts: [host], secrets: secrets)
        metrics = ServerMetricsModel(
            hosts: library, preferences: preferences,
            makeSampler: {
                preconditionFailure("Resource tests must never start collection")
            })
        metrics.suspend()
        metrics.start()
        let hosts = AgentHostLibrary(library: library)
        hosts.requestDeletion = { [library] id in
            library.projectHostDeletion(id)
            return true
        }
        library.willDeletePortForwardings = { [runtime] ids in ids.forEach(runtime.stop) }
        manager = AgentResourceManager(
            credentials: CredentialLibraryModel(library: library), snippets: SnippetLibraryModel(library: library),
            forwardings: ForwardingLibraryModel(library: library), forwardingRuntime: runtime, metrics: metrics,
            hosts: hosts)
    }

    func call(
        _ resource: ResourceToolSpecification.Resource, _ action: ResourceToolSpecification.Action,
        _ fields: [String: AgentJSONValue] = [:]
    ) async throws -> AgentJSONValue {
        let spec = ResourceToolSpecification(resource: resource, action: action)
        let tool = ResourceManagementTool(specification: spec, manager: manager)
        try AgentJSONSchemaValidator.validate(.object(fields), against: tool.descriptor.inputSchema)
        return try await manager.perform(
            spec, arguments: ResourceToolArguments(.object(fields), allowedClears: spec.clearableFields), broker: broker
        )
    }
}

@MainActor
private final class ResourceForwardingRuntime: AgentForwardingControlling {
    var started: [UUID] = []
    var stopped: [UUID] = []
    func start(_ id: UUID) { started.append(id) }
    func stop(_ id: UUID) { stopped.append(id) }
    func managementStatus(_ id: UUID) -> AgentForwardingStatus {
        .init(
            state: started.contains(id) ? "awaiting_authentication" : "stopped",
            requiresUserAction: started.contains(id))
    }
}

@MainActor
private final class ResourceMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    var saves = 0
    var fails = false
    func load() throws -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws {
        saves += 1
        if fails { throw CocoaError(.fileWriteUnknown) }
        values = selections
    }
}

private final class ResourceSecretStore: SecretStoring, @unchecked Sendable {
    let base = InMemorySecretStore()
    private let lock = NSLock()
    private var rejecting = false
    private var rejectedReads = 0
    var rejectReads: Bool {
        get { lock.withLock { rejecting } }
        set { lock.withLock { rejecting = newValue } }
    }
    var readsWhileRejected: Int { lock.withLock { rejectedReads } }
    private func checkRead() throws {
        try lock.withLock {
            if rejecting {
                rejectedReads += 1
                throw CocoaError(.fileReadNoPermission)
            }
        }
    }
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        try checkRead()
        return try base.string(for: account, storage: storage)
    }
    func containsString(for account: String, storage: PasswordStorage) throws -> Bool {
        try base.containsString(for: account, storage: storage)
    }
    func containsKeyCredential(for account: String, storage: KeyStorage) throws -> Bool {
        try base.containsKeyCredential(for: account, storage: storage)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? {
        try checkRead()
        return try base.keyCredential(for: account, storage: storage)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        try base.setString(value, for: account, storage: storage)
    }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {
        try base.setKeyCredential(value, for: account, storage: storage)
    }
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try base.removePassword(account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {
        try base.removeKeyCredential(account, storage: storage)
    }
}

extension AgentJSONValue {
    fileprivate func resourceID() throws -> UUID {
        let text = try #require(objectValue?["id"]?.stringValue)
        return try #require(UUID(uuidString: text))
    }
}
