import AgentKit
import Foundation
import Observation
import SwiftData
import Synchronization
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindApplication
@testable import TermindRemoteInfrastructure

@Suite(.timeLimit(.minutes(1))) @MainActor
struct MCPAuthorizationTests {
    private func grant(_ server: MCPServer, token: String = "fixture-token") -> MCPOAuthCredential {
        .init(
            resource: server.url, issuer: "https://issuer.example", configuration: server.oauth ?? .init(),
            clientID: "client", tokenEndpoint: URL(string: "https://issuer.example/token")!,
            accessToken: token, refreshToken: "fixture-refresh")
    }

    @Test func draftsDiscardNewGrantsAndCommitOnlyWithConfiguration() throws {
        let server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let backing = InMemoryMCPAuthorizationStore()
        let model = MCPAuthorizationModel(storage: backing)
        model.synchronize([server])
        let cancelled = try model.draft(for: server)
        try cancelled.save([grant(server)], for: server.id)
        try cancelled.saveRefreshed([grant(server, token: "draft-rotation")], for: server.id)
        #expect(backing.credentials(for: server.id).isEmpty)
        cancelled.discard()
        #expect(backing.credentials(for: server.id).isEmpty)
        let draft = try model.draft(for: server)
        defer { draft.discard() }
        try draft.save([grant(server)], for: server.id)
        enum SaveFailure: Error { case failed }
        #expect(throws: SaveFailure.failed) {
            try draft.commit(server: server) { throw SaveFailure.failed }
        }
        #expect(backing.credentials(for: server.id).isEmpty)
        try draft.commit(server: server) { model.synchronize([server]) }
        #expect(backing.credentials(for: server.id) == [grant(server)])
        #expect(model.isSignedIn(server))
    }

    @Test func stagedGrantChangesPublishLoginStatusForTheEditor() throws {
        let server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let model = MCPAuthorizationModel(storage: InMemoryMCPAuthorizationStore())
        let draft = try model.draft(for: server)
        defer { draft.discard() }
        let changed = Mutex(false)
        withObservationTracking {
            #expect(!draft.isSignedIn)
        } onChange: {
            changed.withLock { $0 = true }
        }
        try draft.save([grant(server)], for: server.id)
        #expect(changed.withLock { $0 })
        #expect(draft.isSignedIn)
    }

    @Test func originAudienceGrantsRemainBoundToTheSavedMCPEndpoint() throws {
        var server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let backing = InMemoryMCPAuthorizationStore()
        let model = MCPAuthorizationModel(storage: backing)
        model.synchronize([server])
        var value = grant(server)
        value.authorizationResource = "https://resource.example/"
        let draft = try model.draft(for: server)
        defer { draft.discard() }
        try draft.save([value], for: server.id)
        try draft.commit(server: server) { model.synchronize([server]) }
        #expect(model.isSignedIn(server))
        #expect(backing.credentials(for: server.id).first?.authorizationResource == "https://resource.example/")
        server.url = "https://resource.example/another-mcp"
        #expect(!model.isSignedIn(server))
        model.synchronize([server])
        #expect(backing.credentials(for: server.id).isEmpty)
    }

    @Test func refreshRotationPersistsBeforeDraftSaveAndSurvivesDiscard() throws {
        let server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let backing = InMemoryMCPAuthorizationStore()
        backing.setCredentials([grant(server)], for: server.id)
        let model = MCPAuthorizationModel(storage: backing)
        model.synchronize([server])
        let draft = try model.draft(for: server)
        var refreshed = grant(server, token: "rotated")
        refreshed.refreshToken = "rotated-refresh"
        try draft.saveRefreshed([refreshed], for: server.id)
        draft.discard()
        #expect(backing.credentials(for: server.id) == [refreshed])
    }

    @Test func changingIssuerClearsDraftSecretWithoutChangingSavedLogin() throws {
        var server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        server.oauth = .init(issuer: "https://issuer.example", clientID: "client")
        let backing = InMemoryMCPAuthorizationStore()
        backing.setCredentials([grant(server)], for: server.id)
        backing.setClientSecret("fixture-client-secret", for: server)
        let model = MCPAuthorizationModel(storage: backing)
        model.synchronize([server])
        let draft = try model.draft(for: server)
        defer { draft.discard() }
        var changed = server
        changed.oauth?.issuer = "https://different.example"
        draft.update(changed)
        #expect(draft.secret.isEmpty)
        #expect(try draft.clientSecret(for: changed) == nil)
        #expect(!draft.isSignedIn)
        #expect(backing.clientSecret(for: server) == "fixture-client-secret")
        #expect(throws: CancellationError.self) { try draft.save([grant(server)], for: server.id) }
        try draft.commit(server: changed) { model.synchronize([changed]) }
        #expect(backing.credentials(for: server.id).isEmpty)
        #expect(backing.clientSecret(for: changed) == nil)
    }

    @Test func configurationChangesAndDeletionInvalidateDeviceGrants() throws {
        var server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let backing = InMemoryMCPAuthorizationStore()
        let model = MCPAuthorizationModel(storage: backing)
        model.synchronize([server])
        backing.setCredentials([grant(server)], for: server.id)
        server.url = "https://another.example/mcp"
        model.synchronize([server])
        #expect(backing.credentials(for: server.id).isEmpty)
        backing.setCredentials([grant(server)], for: server.id)
        model.synchronize([])
        #expect(backing.credentials(for: server.id).isEmpty)
        #expect(!model.isSignedIn(server))
    }

    @Test func retiredToolConfigurationCannotStartAnotherLogin() async throws {
        let server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let model = MCPAuthorizationModel(storage: InMemoryMCPAuthorizationStore())
        model.synchronize([server])
        var changed = server
        changed.oauth = .init(issuer: "https://another.example")
        model.synchronize([changed])
        await #expect(throws: CancellationError.self) {
            try await model.token(for: server, challenge: nil, rejectedToken: nil, interaction: nil)
        }
        model.synchronize([])
        await #expect(throws: CancellationError.self) {
            try await model.token(for: changed, challenge: nil, rejectedToken: nil, interaction: nil)
        }
    }

    @Test func oldSyncPayloadDefaultsToDiscoveryAndNewPayloadContainsNoGrant() throws {
        var server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncedMCPServer(server, sortIndex: 0)))
                as? [String: Any])
        object.removeValue(forKey: "oauth")
        let decoded = try JSONDecoder().decode(
            SyncedMCPServer.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.value.oauth == nil)
        server.oauth = .init(issuer: "https://issuer.example", clientID: "public-id")
        let data = try JSONEncoder().encode(SyncedMCPServer(server, sortIndex: 0))
        #expect(try JSONDecoder().decode(SyncedMCPServer.self, from: data).value.oauth == server.oauth)
        let wire = String(decoding: data, as: UTF8.self)
        #expect(!wire.contains("accessToken") && !wire.contains("refreshToken") && !wire.contains("clientSecret"))
    }

    @Test func version42MigratesSidecarAndReopensTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        var server = MCPServer(name: "Saved", url: "https://resource.example/mcp")
        func writeOldStore() throws {
            let schema = Schema(versionedSchema: TermindSchemaV42.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)])
            container.mainContext.insert(PersistentMCPServer(server, sortIndex: 0))
            try container.mainContext.save()
        }
        try writeOldStore()
        func migrate() throws {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = AIPersistence(context: container.mainContext)
            var snapshot = try store.load()
            #expect(snapshot.mcpServers == [server])
            server.oauth = .init(issuer: "https://issuer.example", clientID: "client")
            snapshot.mcpServers = [server]
            try store.save(snapshot)
        }
        try migrate()
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            #expect(try AIPersistence(context: container.mainContext).load().mcpServers == [server])
            #expect(try container.mainContext.fetchCount(FetchDescriptor<PersistentMCPOAuthConfiguration>()) == 1)
        }
    }

    @Test func keychainUsesOnlyDeviceScopeAndSeparatesServersAndClientBindings() throws {
        let secrets = OAuthRecordingSecrets()
        let keychain = MCPKeychainCredentialStore(keychain: secrets)
        let server = MCPServer(name: "Example", url: "https://resource.example/mcp")
        let other = MCPServer(name: "Other", url: server.url)
        try keychain.setCredentials([grant(server)], for: server.id)
        try keychain.setClientSecret("fixture-secret", for: server)
        #expect(try keychain.credentials(for: server.id) == [grant(server)])
        #expect(try keychain.credentials(for: other.id).isEmpty)
        var changed = server
        changed.oauth = .init(issuer: "https://another.example", clientID: "another")
        #expect(try keychain.clientSecret(for: changed) == nil)
        try keychain.remove(serverID: server.id)
        #expect(try keychain.credentials(for: server.id).isEmpty)
        #expect(try keychain.clientSecret(for: server) == nil)
        #expect(
            secrets.calls.withLock { $0.allSatisfy { $0.0.hasPrefix("termind.mcp.oauth.") && $0.1 == .thisDevice } })
    }

    @Test func authorizationQueueResumesAndCancellationDropsLateCallbacks() async throws {
        let conversation = ConversationModel()
        conversation.handle(.runState(.running))
        func request() -> MCPAuthorizationRequest {
            .init(
                serverID: UUID(), serverName: "Example", issuer: URL(string: "https://issuer.example")!,
                scopes: ["read"],
                url: URL(string: "https://issuer.example/authorize?state=fixture-state")!,
                redirectURI: MCPAuthorizationModel.redirectURI)
        }
        let first = request()
        let pending = Task { try await conversation.requestMCPAuthorization(first) }
        for _ in 0..<100 where conversation.pendingMCPAuthorizations.isEmpty { await Task.yield() }
        #expect(conversation.runState == .waitingForUser)
        #expect(conversation.notificationInteraction?.kind == .mcpAuthorization)
        let callback = MCPAuthorizationModel.redirectURI.appending(queryItems: [
            URLQueryItem(name: "code", value: "fixture-code")
        ])
        conversation.respondToMCPAuthorization(first.id, result: .success(callback))
        #expect(try await pending.value == callback)
        let second = request()
        let cancelled = Task { try await conversation.requestMCPAuthorization(second) }
        for _ in 0..<100 where conversation.pendingMCPAuthorizations.isEmpty { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        conversation.respondToMCPAuthorization(second.id, result: .success(callback))
        let stopped = Task { try await conversation.requestMCPAuthorization(request()) }
        for _ in 0..<100 where conversation.pendingMCPAuthorizations.isEmpty { await Task.yield() }
        conversation.stop()
        await #expect(throws: CancellationError.self) { try await stopped.value }
        #expect(conversation.pendingMCPAuthorizations.isEmpty)
        #expect(conversation.transcript.isEmpty)
        #expect(conversation.messages.isEmpty)
    }
}

private nonisolated final class OAuthRecordingSecrets: SecretStoring, Sendable {
    let calls = Mutex<[(String, PasswordStorage)]>([])
    private let values = InMemorySecretStore()
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        calls.withLock { $0.append((account, storage)) }
        return try values.string(for: account, storage: storage)
    }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        calls.withLock { $0.append((account, storage)) }
        try values.setString(value, for: account, storage: storage)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? { nil }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {}
    func removePassword(_ account: String, storage: PasswordStorage) throws {
        try setString(nil, for: account, storage: storage)
    }
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}
