// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// Public credential metadata. Neither DTO has a storage reference or a secret-bearing member.
public nonisolated struct AgentIdentityInfo: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var username: String
    public var keyID: UUID?
    public var storage: PasswordStorage
    public var notes: String
    public var color: TagColor
    public var availability: String = "unknown"
    public var hasCredential: Bool

    public init(_ identity: Identity) {
        id = identity.id
        name = identity.name
        username = identity.username
        keyID = identity.keyID
        storage = identity.passwordStorage
        notes = identity.notes
        color = identity.colorTag
        hasCredential = identity.usesPassword
    }
}

public nonisolated struct AgentKeyInfo: Sendable, Equatable {
    public var id: UUID
    public var label: String
    public var algorithm: SSHKeyAlgorithm
    public var publicKey: String
    public var certificate: String
    public var fingerprint: String
    public var storage: KeyStorage
    public var keySize: Int?
    public var encrypted: Bool
    public var requiresUserPresence: Bool
    public var createdAt: Date
    public var color: TagColor
    public var availability: String = "unknown"

    public init(_ key: SSHKeyRef) {
        id = key.id
        label = key.label
        algorithm = key.algorithm
        publicKey = key.publicKey
        certificate = key.certificate
        fingerprint = key.fingerprint
        storage = key.storage
        keySize = key.keySize
        encrypted = key.hasPassphrase
        requiresUserPresence = key.requiresUserPresence
        createdAt = key.createdAt
        color = key.colorTag
    }
}

@MainActor
public protocol AgentCredentialManaging: AnyObject {
    var managedIdentities: [AgentIdentityInfo] { get }
    var managedKeys: [AgentKeyInfo] { get }
    func saveManagedIdentity(_ value: AgentIdentityInfo, passwordUpdate: IdentityPasswordUpdate) throws
    func deleteManagedIdentity(_ id: UUID) throws
    func saveManagedKey(
        _ value: AgentKeyInfo, credential: StoredSSHKeyCredential?, passphraseUpdate: IdentityPasswordUpdate
    ) throws
    func deleteManagedKey(_ id: UUID) throws
}

extension CredentialLibraryModel: AgentCredentialManaging {
    public var managedIdentities: [AgentIdentityInfo] {
        identities.map {
            var info = AgentIdentityInfo($0)
            info.availability = Self.publicAvailability(passwordAvailability(for: $0))
            return info
        }
    }
    public var managedKeys: [AgentKeyInfo] {
        keys.map {
            var info = AgentKeyInfo($0)
            info.availability = Self.publicAvailability(keyAvailability(for: $0))
            return info
        }
    }

    private static func publicAvailability(_ availability: SecretAvailability) -> String {
        switch availability {
        case .notConfigured: "not_configured"
        case .available: "available"
        case .missing: "missing"
        case .failed: "unavailable"
        }
    }

    public func saveManagedIdentity(_ value: AgentIdentityInfo, passwordUpdate: IdentityPasswordUpdate) throws {
        var identity =
            identities.first { $0.id == value.id }
            ?? Identity(id: value.id, name: value.name, username: value.username)
        identity.name = value.name
        identity.username = value.username
        identity.keyID = value.keyID
        identity.passwordStorage = value.storage
        identity.notes = value.notes
        identity.colorTag = value.color
        try saveIdentity(identity, passwordUpdate: passwordUpdate)
    }

    public func deleteManagedIdentity(_ id: UUID) throws {
        guard identities.contains(where: { $0.id == id }), delete(identityID: id) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public func saveManagedKey(
        _ value: AgentKeyInfo, credential: StoredSSHKeyCredential?, passphraseUpdate: IdentityPasswordUpdate
    ) throws {
        let original = key(value.id)
        var key =
            original
            ?? SSHKeyRef(
                id: value.id, label: value.label, credentialRef: "termind.key.\(UUID().uuidString)")
        key.label = value.label
        key.algorithm = value.algorithm
        key.publicKey = value.publicKey
        key.certificate = value.certificate
        key.fingerprint = value.fingerprint
        key.storage = value.storage
        key.keySize = value.keySize
        key.hasPassphrase = value.encrypted
        key.requiresUserPresence = value.requiresUserPresence
        key.createdAt = value.createdAt
        key.colorTag = value.color
        var replacement = credential
        switch passphraseUpdate {
        case .keep: break
        case .replace, .remove:
            guard case .software(var software)? = try replacement ?? original.flatMap({ try keyCredential(for: $0) })
            else {
                throw CocoaError(.coderInvalidValue)
            }
            switch passphraseUpdate {
            case .replace(let value): software.passphrase = value
            case .remove: software.passphrase = nil
            case .keep: break
            }
            replacement = .software(software)
        }
        try upsert(key, credential: replacement)
    }

    public func deleteManagedKey(_ id: UUID) throws { try delete(keyID: id) }
}
