import CryptoKit
import Foundation
import Security
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// One device-local store, independent of SwiftData/Vault/CloudKit. Leases fence saves racing an explicit close.
public actor TerminalRecoveryStore {
    public static let shared = TerminalRecoveryStore()
    private let directory: URL
    private let testingKey: Data?
    private var owners: [UUID: UUID] = [:]

    private struct Envelope: Codable {
        let metadata: Data
        let ciphertext: Data
    }

    public init(directory: URL? = nil, testingKey: Data? = nil) {
        self.directory =
            directory
            ?? URL.applicationSupportDirectory
            .appendingPathComponent("Termind/TerminalRecovery", isDirectory: true)
        self.testingKey = testingKey
    }

    public func register(_ id: UUID) -> UUID {
        let lease = UUID()
        owners[id] = lease
        return lease
    }

    public func record(_ id: UUID) throws -> TerminalRecoveryRecord {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: location(id)))
        _ = try AES.GCM.open(
            AES.GCM.SealedBox(combined: envelope.ciphertext), using: key(), authenticating: envelope.metadata)
        let record = try JSONDecoder().decode(TerminalRecoveryRecord.self, from: envelope.metadata)
        guard record.id == id else { throw TerminalTransportError.invalidCheckpoint }
        return record
    }

    public func records() throws -> [TerminalRecoveryRecord] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "terminal" }
        .map {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: $0))
            return try JSONDecoder().decode(TerminalRecoveryRecord.self, from: envelope.metadata)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    public func save(
        _ record: TerminalRecoveryRecord, checkpoint: TerminalTransportCheckpoint, lease: UUID
    ) throws {
        guard owners[record.id] == lease, checkpoint.transport == record.transport else {
            throw CancellationError()
        }
        let metadata = try JSONEncoder().encode(record)
        let payload = try JSONEncoder().encode(checkpoint)
        let ciphertext = try AES.GCM.seal(payload, using: key(), authenticating: metadata).combined!
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
        try JSONEncoder().encode(Envelope(metadata: metadata, ciphertext: ciphertext))
            .write(to: location(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location(record.id).path)
    }

    /// Removes eligibility before returning protocol counters to a caller that can transmit.
    public func consume(_ id: UUID, host: Host) throws -> TerminalTransportCheckpoint {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: location(id)))
        let payload = try AES.GCM.open(
            AES.GCM.SealedBox(combined: envelope.ciphertext), using: key(), authenticating: envelope.metadata)
        let record = try JSONDecoder().decode(TerminalRecoveryRecord.self, from: envelope.metadata)
        guard record.id == id, record.matches(host) else { throw TerminalTransportError.invalidCheckpoint }
        let checkpoint = try JSONDecoder().decode(TerminalTransportCheckpoint.self, from: payload)
        guard checkpoint.version == 1, checkpoint.transport == record.transport else {
            throw TerminalTransportError.invalidCheckpoint
        }
        try remove(id)
        return checkpoint
    }

    public func invalidate(_ id: UUID) throws { try remove(id) }

    public func discard(_ id: UUID) throws {
        owners.removeValue(forKey: id)
        try remove(id)
    }

    private func remove(_ id: UUID) throws {
        let path = location(id)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    private func location(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("terminal")
    }

    private func key() throws -> SymmetricKey {
        if let testingKey { return SymmetricKey(data: testingKey) }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.akinokaede.termind.terminal-recovery",
            kSecAttrAccount as String: "device-key-v1",
            kSecAttrSynchronizable as String: false,
        ]
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        // A missing key must not silently turn existing checkpoints into unrecoverable ciphertext.
        if FileManager.default.fileExists(atPath: directory.path),
            try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: {
                $0.hasSuffix(".terminal")
            })
        {
            throw TerminalTransportError.invalidCheckpoint
        }
        let key = SymmetricKey(size: .bits256)
        var add = match
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(add as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        return key
    }
}
