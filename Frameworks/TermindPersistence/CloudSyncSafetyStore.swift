import Foundation
import SwiftData
import TermindDomain

/// Additive V31 models: earlier journal and quarantine model shapes stay frozen.
/// Quarantine is an account/environment/zone-scoped write fence, not just a diagnostic log.
@Model
public final class PersistentCloudSyncQuarantine {
    @Attribute(.unique) public var storageKey = ""
    public var scopeKey = ""
    public var recordName = ""
    public var payloadData = Data()
    public var systemFieldsData: Data?
    public var reasonCode = CloudSyncQuarantineReason.unreadablePayload.rawValue
    public var reason = ""
    public var receivedAt = Date()

    public init(scope: CloudSyncScope, recordName: String) {
        scopeKey = scope.storageKey
        self.recordName = recordName
        storageKey = scope.storageKey + "\(recordName.utf8.count):\(recordName)"
    }
}

/// Written BEFORE CloudKit can advance a cursor or return a save conflict.
/// An interrupted operation forces a fresh fetch, not a replay of unsafe saves.
@Model
public final class PersistentCloudSyncRecovery {
    @Attribute(.unique) public var scopeKey = ""
    public var requiresRefetch = true

    public init(scope: CloudSyncScope) { scopeKey = scope.storageKey }
}

@MainActor
public final class CloudSyncSafetyStore {
    private let context: ModelContext
    public let scope: CloudSyncScope

    public init(context: ModelContext, scope: CloudSyncScope) {
        self.context = context
        self.scope = scope
    }

    public func recovery() throws -> PersistentCloudSyncRecovery {
        let scopeKey = scope.storageKey
        var descriptor = FetchDescriptor<PersistentCloudSyncRecovery>(
            predicate: #Predicate { $0.scopeKey == scopeKey })
        descriptor.fetchLimit = 1
        if let row = try context.fetch(descriptor).first { return row }
        let row = PersistentCloudSyncRecovery(scope: scope)
        context.insert(row)
        return row
    }

    public func blockedRecordNames() throws -> Set<String> {
        let scopeKey = scope.storageKey
        return Set(
            try context.fetch(
                FetchDescriptor<PersistentCloudSyncQuarantine>(predicate: #Predicate { $0.scopeKey == scopeKey })
            ).map(\.recordName))
    }

    public func requiresNewerClient() throws -> Bool {
        try hasQuarantine(reason: .unsupportedFormat)
    }

    public func hasQuarantine(reason: CloudSyncQuarantineReason) throws -> Bool {
        let scopeKey = scope.storageKey
        let reasonCode = reason.rawValue
        var descriptor = FetchDescriptor<PersistentCloudSyncQuarantine>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.reasonCode == reasonCode })
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    public func isUploadBlocked(recordName: String) throws -> Bool {
        try entry(recordName: recordName) != nil
    }

    public func quarantine(
        recordName: String, payloadData: Data, systemFieldsData: Data? = nil,
        reason: String, reasonCode: CloudSyncQuarantineReason = .unreadablePayload
    ) throws {
        let row: PersistentCloudSyncQuarantine
        if let existing = try entry(recordName: recordName) {
            row = existing
        } else {
            row = PersistentCloudSyncQuarantine(scope: scope, recordName: recordName)
            context.insert(row)
        }
        row.payloadData = payloadData
        row.systemFieldsData = systemFieldsData
        row.reason = reason
        row.reasonCode = reasonCode.rawValue
        row.receivedAt = .now
    }

    /// Call only inside the same save as successfully reconciling a supported remote record.
    public func clearQuarantine(recordName: String) throws {
        if let row = try entry(recordName: recordName) { context.delete(row) }
    }

    public func entry(recordName: String) throws -> PersistentCloudSyncQuarantine? {
        let scopeKey = scope.storageKey
        var descriptor = FetchDescriptor<PersistentCloudSyncQuarantine>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.recordName == recordName })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

extension CloudSyncSafetyStore {
    public func capability() throws -> PersistentSyncCapability {
        let scopeKey = scope.storageKey
        if let row = try context.fetch(
            FetchDescriptor<PersistentSyncCapability>(
                predicate: #Predicate { $0.scopeKey == scopeKey })
        ).first {
            return row
        }
        let row = PersistentSyncCapability(scopeKey: scopeKey)
        context.insert(row)
        return row
    }

    /// Removes only safety/cache metadata belonging to this exact replica scope.
    public func purgeScope() throws {
        let key = scope.storageKey
        for row in try context.fetch(
            FetchDescriptor<PersistentCloudSyncQuarantine>(predicate: #Predicate { $0.scopeKey == key }))
        {
            context.delete(row)
        }
        for row in try context.fetch(
            FetchDescriptor<PersistentCloudSyncRecovery>(predicate: #Predicate { $0.scopeKey == key }))
        {
            context.delete(row)
        }
        for row in try context.fetch(
            FetchDescriptor<PersistentSyncCapability>(predicate: #Predicate { $0.scopeKey == key }))
        {
            context.delete(row)
        }
    }

}
