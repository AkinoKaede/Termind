import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentVaultSyncEntry {
    @Attribute(.unique) public var recordName = ""
    public var kind = VaultRecordKind.host.rawValue
    public var entityID = UUID()
    public var envelopeData = Data()
    public var systemFieldsData: Data?
    public var needsUpload = false

    public init(envelope: VaultEnvelope, needsUpload: Bool) throws {
        try apply(envelope, needsUpload: needsUpload)
    }

    public func apply(_ envelope: VaultEnvelope, needsUpload: Bool) throws {
        recordName = envelope.key.recordName
        kind = envelope.key.kind.rawValue
        entityID = envelope.key.id
        envelopeData = try VaultSyncCodec.encode(envelope)
        self.needsUpload = needsUpload
    }

    public var envelope: VaultEnvelope? { try? VaultSyncCodec.decode(envelopeData) }
}

@Model
public final class PersistentVaultSyncState {
    @Attribute(.unique) public var key = "vault-sync"
    public var installationID = UUID()
    public var engineStateData: Data?
    public var boundUserRecordName: String?
    public var pendingUserRecordName: String?
    public var bootstrapCompleted = false
    public var lastSuccessfulSync: Date?

    public init() {}
}

@Model
public final class PersistentVaultSyncQuarantine {
    @Attribute(.unique) public var recordName = ""
    public var payloadData = Data()
    public var reason = ""
    public var receivedAt = Date()

    public init(recordName: String, payloadData: Data, reason: String) {
        self.recordName = recordName
        self.payloadData = payloadData
        self.reason = reason
    }
}

/// Stable CloudKit V1 encoding is deliberately independent of domain Codable.
public nonisolated enum VaultSyncCodec {
    public static func encode(_ envelope: VaultEnvelope) throws -> Data {
        if case .host(let host) = envelope.payload, host.isTailscaleManaged {
            throw TailscaleConfigurationError.managedHost
        }
        if case .hostGroup(let group) = envelope.payload, group.tailscale != nil, envelope.formatVersion == 1 {
            throw CocoaError(.coderInvalidValue)
        }
        try SyncRecordFormats.vault.validate(kind: envelope.key.kind.rawValue, version: envelope.formatVersion)
        guard envelope.isValid else { throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if envelope.formatVersion == 8 {
            return try encoder.encode(VaultWireV8.Envelope(envelope))
        }
        if case .host(let host) = envelope.payload, host.createdAt != nil {
            throw CocoaError(.coderInvalidValue)
        }
        if envelope.formatVersion == 7 {
            return try encoder.encode(VaultWireV7.Envelope(envelope))
        }
        if case .host(let host) = envelope.payload, host.wakeOnLAN != .init() {
            throw CocoaError(.coderInvalidValue)
        }
        if case .hostGroup(let group) = envelope.payload,
            group.tailscale?.hostPreferences.values.contains(where: { $0.wakeOnLAN != .init() }) == true
        {
            throw CocoaError(.coderInvalidValue)
        }
        if envelope.formatVersion == 6 {
            return try encoder.encode(VaultWireV6.Envelope(envelope))
        }
        if case .host(let host) = envelope.payload, host.terminalTransports != .init() {
            throw CocoaError(.coderInvalidValue)
        }
        if case .hostGroup(let group) = envelope.payload,
            group.tailscale?.hostPreferences.values.contains(where: { $0.terminalTransports != .init() }) == true
        {
            throw CocoaError(.coderInvalidValue)
        }
        if envelope.formatVersion < 5 {
            if case .host(let host) = envelope.payload, host.iconOverrideID != nil {
                throw CocoaError(.coderInvalidValue)
            }
            if case .hostGroup(let group) = envelope.payload,
                group.tailscale?.hostPreferences.values.contains(where: { $0.iconOverrideID != nil }) == true
            {
                throw CocoaError(.coderInvalidValue)
            }
        }
        if envelope.formatVersion == 5 {
            return try encoder.encode(VaultWireV5.Envelope(envelope))
        }
        if envelope.formatVersion < 4 {
            if case .host(let host) = envelope.payload, host.sessionPersistence != .init(enabled: false) {
                throw CocoaError(.coderInvalidValue)
            }
            if case .hostGroup(let group) = envelope.payload,
                group.tailscale?.hostPreferences.values.contains(where: {
                    $0.sessionPersistence != .init(enabled: false)
                }) == true
            {
                throw CocoaError(.coderInvalidValue)
            }
        }
        if envelope.formatVersion == 4 {
            return try encoder.encode(VaultWireV4.Envelope(envelope))
        }
        if envelope.formatVersion == 3 {
            return try encoder.encode(VaultWireV3.Envelope(envelope))
        }
        if envelope.formatVersion == 2, envelope.key.kind == .workspaceTemplate {
            return try encoder.encode(VaultWorkspaceWireV2(envelope))
        }
        if envelope.formatVersion == 2 {
            return try encoder.encode(VaultWireV2.Envelope(envelope))
        }
        return try encoder.encode(VaultWireV1.Envelope(envelope))
    }

    private static let decoder: VersionedRecordDecoder<VaultEnvelope> = {
        var decoders: [String: [Int: @Sendable (Data) throws -> VaultEnvelope]] = [:]
        for kind in VaultRecordKind.allCases {
            decoders[kind.rawValue] = [1: { try JSONDecoder().decode(VaultWireV1.Envelope.self, from: $0).domainValue }]
        }
        decoders[VaultRecordKind.workspaceTemplate.rawValue]?[2] = {
            try JSONDecoder().decode(VaultWorkspaceWireV2.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.sshKey.rawValue]?[2] = {
            try JSONDecoder().decode(VaultWireV2.Envelope.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.snippet.rawValue]?[2] = {
            try JSONDecoder().decode(VaultWireV2.Envelope.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.host.rawValue]?[8] = {
            try JSONDecoder().decode(VaultWireV8.Envelope.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.host.rawValue]?[2] = {
            try JSONDecoder().decode(VaultWireV2.Envelope.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.hostGroup.rawValue]?[2] = {
            try JSONDecoder().decode(VaultWireV2.Envelope.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.sshKey.rawValue]?[3] = {
            try JSONDecoder().decode(VaultWireV3.Envelope.self, from: $0).domainValue
        }
        decoders[VaultRecordKind.hostGroup.rawValue]?[3] = {
            try JSONDecoder().decode(VaultWireV3.Envelope.self, from: $0).domainValue
        }
        for kind in [VaultRecordKind.host, .hostGroup] {
            decoders[kind.rawValue]?[7] = { try JSONDecoder().decode(VaultWireV7.Envelope.self, from: $0).domainValue }
            decoders[kind.rawValue]?[6] = { try JSONDecoder().decode(VaultWireV6.Envelope.self, from: $0).domainValue }
            decoders[kind.rawValue]?[5] = { try JSONDecoder().decode(VaultWireV5.Envelope.self, from: $0).domainValue }
            decoders[kind.rawValue]?[4] = { try JSONDecoder().decode(VaultWireV4.Envelope.self, from: $0).domainValue }
        }
        return VersionedRecordDecoder(decoders)
    }()

    public static func decode(_ data: Data) throws -> VaultEnvelope {
        let envelope = try decoder.decode(data)
        guard envelope.isValid else { throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName) }
        return envelope
    }
}
