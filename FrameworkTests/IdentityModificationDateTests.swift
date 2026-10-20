// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite(.serialized)
@MainActor
struct IdentityModificationDateTests {
    @Test
    func legacyIdentityUsageFieldIsIgnoredAndNotReencoded() throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        object["lastUsedAt"] = 123
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Identity.self, from: legacyData)
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])

        #expect(decoded == identity)
        #expect(reencoded["lastUsedAt"] == nil)
    }

    @Test
    func credentialReadsDoNotTouchIdentityModificationDate() throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.deploy", passwordStorage: .thisDevice
        )
        let persistence = IdentityModificationPersistence(
            snapshot: VaultSnapshot(identities: [identity]))
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        try secrets.setString("secret", for: identity.credentialRef, storage: identity.passwordStorage)
        let before = store.identityModifiedAt(identity.id)

        #expect(store.passwordAvailability(for: identity) == .available)
        _ = store.sshCredentials(for: identity)

        #expect(persistence.saveCount == 0)
        #expect(store.identityModifiedAt(identity.id) == before)
    }

    @Test
    func replacingAnExistingPasswordTouchesTheIdentityRecord() throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.deploy", passwordStorage: .thisDevice
        )
        let persistence = IdentityModificationPersistence(
            snapshot: VaultSnapshot(identities: [identity]))
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let before = try #require(store.identityModifiedAt(identity.id))

        try store.upsert(identity, passwordUpdate: .replace("new"))

        #expect(try secrets.string(for: identity.credentialRef, storage: identity.passwordStorage) == "new")
        #expect(persistence.lastTouchedKeys == [VaultRecordKey(kind: .identity, id: identity.id)])
        #expect(try #require(store.identityModifiedAt(identity.id)) > before)
    }

    @Test
    func addingAndRemovingAPasswordEachTouchTheIdentityRecord() throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(name: "Deploy", username: "deploy", passwordStorage: .thisDevice)
        let persistence = IdentityModificationPersistence(
            snapshot: VaultSnapshot(identities: [identity]))
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        let original = try #require(store.identityModifiedAt(identity.id))

        try store.upsert(identity, passwordUpdate: .replace("new"))
        let added = try #require(store.identity(identity.id))
        let addedAt = try #require(store.identityModifiedAt(identity.id))
        #expect(added.usesPassword)
        #expect(addedAt > original)

        try store.upsert(added, passwordUpdate: .remove)
        let removed = try #require(store.identity(identity.id))
        #expect(!removed.usesPassword)
        #expect(try #require(store.identityModifiedAt(identity.id)) > addedAt)
    }

    @Test
    func changingTheSelectedKeyAdvancesIdentityButEditingTheKeyDoesNot() throws {
        let first = SSHKeyRef(label: "First")
        var second = SSHKeyRef(label: "Second")
        var identity = Identity(name: "Deploy", username: "deploy", keyID: first.id)
        let persistence = IdentityModificationPersistence(
            snapshot: VaultSnapshot(identities: [identity], keys: [first, second]))
        let store = HostLibraryModel(persistence: persistence)
        let original = try #require(store.identityModifiedAt(identity.id))

        identity.keyID = second.id
        #expect(store.upsert(identity))
        let selectedKeyChanged = try #require(store.identityModifiedAt(identity.id))
        #expect(selectedKeyChanged > original)

        second.label = "Renamed"
        try store.upsert(second)
        #expect(store.identityModifiedAt(identity.id) == selectedKeyChanged)
    }

    @Test
    func failedPasswordSaveRollsBackSecretAndModificationDate() throws {
        let secrets = InMemorySecretStore()
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.deploy", passwordStorage: .thisDevice
        )
        let persistence = IdentityModificationPersistence(
            snapshot: VaultSnapshot(identities: [identity]))
        let store = HostLibraryModel(persistence: persistence, secrets: secrets)
        try secrets.setString("old", for: identity.credentialRef, storage: identity.passwordStorage)
        let before = store.identityModifiedAt(identity.id)
        persistence.failsSave = true

        #expect(throws: (any Error).self) {
            try store.upsert(identity, passwordUpdate: .replace("new"))
        }

        #expect(try secrets.string(for: identity.credentialRef, storage: identity.passwordStorage) == "old")
        #expect(store.identityModifiedAt(identity.id) == before)
    }
}

@MainActor
private final class IdentityModificationPersistence: VaultPersisting {
    var snapshot: VaultSnapshot
    var dates: [VaultRecordKey: Date]
    var saveCount = 0
    var failsSave = false
    var lastTouchedKeys: Set<VaultRecordKey> = []
    private var clock = Date(timeIntervalSince1970: 100)

    init(snapshot: VaultSnapshot) {
        self.snapshot = snapshot
        let initialDate = Date(timeIntervalSince1970: 100)
        dates = Dictionary(
            uniqueKeysWithValues: snapshot.recordPayloads.keys.map { ($0, initialDate) })
    }

    func load() throws -> VaultSnapshot { snapshot }

    func save(
        _ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>
    ) throws -> VaultMutationSet {
        saveCount += 1
        if failsSave { throw CocoaError(.fileWriteUnknown) }
        let oldPayloads = self.snapshot.recordPayloads
        let newPayloads = snapshot.recordPayloads
        let changed = Set(
            newPayloads.compactMap { key, payload in
                oldPayloads[key] != payload || keys.contains(key) ? key : nil
            })
        clock = clock.addingTimeInterval(1)
        for key in changed { dates[key] = clock }
        self.snapshot = snapshot
        lastTouchedKeys = keys
        return VaultMutationSet(keys: changed)
    }

    func modificationDates() throws -> [VaultRecordKey: Date] { dates }
}
