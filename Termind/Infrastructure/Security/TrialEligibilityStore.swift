import CloudKit
import CryptoKit
import Foundation
import Security

nonisolated struct TrialProof: Codable, Equatable, Sendable {
    static let formatVersion = 1

    var version = formatVersion
    var installationID: UUID
    var startedAt: Date
    var lastTrustedAt: Date
    var nonce: Data
}

nonisolated struct SignedTrialProof: Codable, Equatable, Sendable {
    var proof: TrialProof
    var authenticationCode: Data
}

nonisolated enum TrialProofCodec {
    static func sign(_ proof: TrialProof, key: Data) throws -> Data {
        let payload = try canonicalData(proof)
        let code = Data(
            HMAC<SHA256>.authenticationCode(
                for: payload, using: SymmetricKey(data: key)
            )
        )
        return try JSONEncoder().encode(
            SignedTrialProof(proof: proof, authenticationCode: code)
        )
    }

    static func verify(_ data: Data, key: Data) throws -> TrialProof? {
        let envelope = try JSONDecoder().decode(SignedTrialProof.self, from: data)
        guard envelope.proof.version == TrialProof.formatVersion else { return nil }
        let payload = try canonicalData(envelope.proof)
        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                envelope.authenticationCode,
                authenticating: payload,
                using: SymmetricKey(data: key)
            )
        else { return nil }
        return envelope.proof
    }

    private static func canonicalData(_ proof: TrialProof) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(proof)
    }
}

nonisolated struct TrialKeychainStore: Sendable {
    static let installKeyService = "com.akinokaede.termind.commerce.install-key.v1"
    static let proofService = "com.akinokaede.termind.commerce.trial-proof.v1"
    static let account = "termind-pro-trial"

    let accessGroup: String

    init(accessGroup: String = ApplicationIdentity.keychainAccessGroup) {
        self.accessGroup = accessGroup
    }

    func installKey() throws -> Data? { try data(service: Self.installKeyService) }
    func proof() throws -> Data? { try data(service: Self.proofService) }

    func setInstallKey(_ value: Data) throws {
        try set(value, service: Self.installKeyService)
    }

    func setProof(_ value: Data) throws {
        try set(value, service: Self.proofService)
    }

    private func data(service: String) throws -> Data? {
        var query = baseQuery(service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainSecretError.status(status) }
        guard let value = result as? Data else { throw KeychainSecretError.unexpectedValue }
        return value
    }

    private func set(_ value: Data, service: String) throws {
        let match = baseQuery(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainSecretError.status(update) }
        var add = match
        for (key, value) in attributes {
            add[key] = value
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainSecretError.status(status) }
    }

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

actor TrialEligibilityStore {
    nonisolated static let duration: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let defaultsKey = "commerce.pro.trial-proof.v1"
    nonisolated static let containerIdentifier = "iCloud.com.akinokaede.termind"
    nonisolated static let zoneName = "TermindCommerceV1"
    nonisolated static let recordType = "TrialEligibility"
    nonisolated static let recordName = "termind-pro-trial-v1"

    private let keychain: TrialKeychainStore
    private let defaults: UserDefaults
    private let database: CKDatabase?

    init(
        keychain: TrialKeychainStore = TrialKeychainStore(),
        defaults: UserDefaults = .standard,
        container: CKContainer? = CKContainer(identifier: containerIdentifier)
    ) {
        self.keychain = keychain
        self.defaults = defaults
        database = container?.privateCloudDatabase
    }

    func assessment(now: Date = .now, includeCloud: Bool = true) async -> TrialAssessment {
        let localEnvelope = defaults.data(forKey: Self.defaultsKey)
        let keychainEnvelope = try? keychain.proof()
        var key = try? keychain.installKey()
        let hasLocalEvidence = localEnvelope != nil || keychainEnvelope != nil
        let cloudStartedAt = includeCloud ? await cloudStartDate() : nil

        if key == nil, let cloudStartedAt {
            key = try? createInstallKey()
            if let key {
                let restored = makeProof(startedAt: cloudStartedAt, now: now)
                try? persist(restored, key: key)
            }
        }

        guard let key else {
            return hasLocalEvidence || cloudStartedAt != nil ? .recoveryRequired : .available
        }

        let candidates = [localEnvelope, keychainEnvelope].compactMap { data -> TrialProof? in
            guard let data else { return nil }
            return try? TrialProofCodec.verify(data, key: key)
        }
        if hasLocalEvidence && candidates.isEmpty { return .recoveryRequired }
        var proof: TrialProof
        if let localProof = candidates.min(by: { $0.startedAt < $1.startedAt }) {
            proof = localProof
        } else if let cloudStartedAt {
            proof = makeProof(startedAt: cloudStartedAt, now: now)
        } else {
            // The install key is created only when a trial starts. If it
            // survives while both proof copies disappear, fail closed rather
            // than treating deliberate proof deletion as a fresh install.
            return .recoveryRequired
        }

        if let cloudStartedAt, cloudStartedAt < proof.startedAt {
            proof.startedAt = cloudStartedAt
        }
        let effectiveNow = max(now, proof.lastTrustedAt)
        proof.lastTrustedAt = effectiveNow
        try? persist(proof, key: key)
        let expiration = proof.startedAt.addingTimeInterval(Self.duration)
        return effectiveNow < expiration ? .active(expiresAt: expiration) : .expired
    }

    func start(now: Date = .now) async throws -> TrialAssessment {
        let existing = await assessment(now: now, includeCloud: true)
        guard existing == .available else { return existing }
        let key = try keychain.installKey() ?? createInstallKey()
        var proof = makeProof(startedAt: now, now: now)
        try persist(proof, key: key)
        if let serverDate = await createCloudRecord(startedAt: now), serverDate < proof.startedAt {
            proof.startedAt = serverDate
            try persist(proof, key: key)
        }
        return .active(expiresAt: proof.startedAt.addingTimeInterval(Self.duration))
    }

    private func makeProof(startedAt: Date, now: Date) -> TrialProof {
        TrialProof(
            installationID: UUID(), startedAt: startedAt,
            lastTrustedAt: max(startedAt, now), nonce: randomData(count: 32)
        )
    }

    private func createInstallKey() throws -> Data {
        let key = randomData(count: 32)
        try keychain.setInstallKey(key)
        return key
    }

    private func persist(_ proof: TrialProof, key: Data) throws {
        let data = try TrialProofCodec.sign(proof, key: key)
        try keychain.setProof(data)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
    }

    private func cloudStartDate() async -> Date? {
        guard let database else { return nil }
        do {
            let record = try await database.record(for: recordID)
            let declared = record["startedAt"] as? Date
            return [declared, record.creationDate].compactMap { $0 }.min()
        } catch { return nil }
    }

    private func createCloudRecord(startedAt: Date) async -> Date? {
        guard let database else { return nil }
        if let existing = await cloudStartDate() { return existing }
        do {
            _ = try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: []
            )
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record["startedAt"] = startedAt as NSDate
            record["formatVersion"] = NSNumber(value: TrialProof.formatVersion)
            let saved = try await database.save(record)
            return [saved["startedAt"] as? Date, saved.creationDate].compactMap { $0 }.min()
        } catch {
            return await cloudStartDate()
        }
    }
}
