import CloudKit
import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

@MainActor
struct CloudSyncLifecycleSafety {
    var prepare: (CloudSyncScope, CloudSyncScope) throws -> Bool
    var setRecoveryRequired: (CloudSyncScope, Bool) throws -> Void
    var blockedRecordNames: (CloudSyncScope) throws -> Set<String>
    var isUploadBlocked: (CloudSyncScope, String) throws -> Bool
    var requiresNewerClient: (CloudSyncScope) throws -> Bool
    var didCompleteFetch: (CloudSyncScope) throws -> Void = { _ in }

    /// The lifecycle commits both legacy imports and recovery state before creating an engine.
    static func persistent(
        context: ModelContext, capabilityID: String? = nil,
        importLegacyQuarantine: @escaping (CloudSyncScope) throws -> Void = { _ in }
    ) -> Self {
        Self(
            prepare: { scope, legacyScope in
                try importLegacyQuarantine(legacyScope)
                let safety = CloudSyncSafetyStore(context: context, scope: scope)
                if let capabilityID, try safety.capability().capabilityID != capabilityID {
                    return true
                }
                return try safety.recovery().requiresRefetch
            },
            setRecoveryRequired: { scope, required in
                try CloudSyncSafetyStore(context: context, scope: scope).recovery().requiresRefetch = required
            },
            blockedRecordNames: { scope in
                try CloudSyncSafetyStore(context: context, scope: scope).blockedRecordNames()
            },
            isUploadBlocked: { scope, recordName in
                try CloudSyncSafetyStore(context: context, scope: scope).isUploadBlocked(recordName: recordName)
            },
            requiresNewerClient: { scope in
                try CloudSyncSafetyStore(context: context, scope: scope).requiresNewerClient()
            },
            didCompleteFetch: { scope in
                if let capabilityID {
                    try CloudSyncSafetyStore(context: context, scope: scope).capability().capabilityID = capabilityID
                }
            })
    }

    /// History and devices share a zone, so each kind reports only its own blocked records.
    static func persistentHistory(context: ModelContext, kind: HistoryRecordKind) -> Self {
        var safety = persistent(
            context: context, capabilityID: SyncRecordFormats.history.capabilityID + ";kind:" + kind.rawValue)
        safety.blockedRecordNames = { scope in
            try CloudSyncSafetyStore(context: context, scope: scope).blockedRecordNames().filter {
                HistoryRecordKey(recordName: $0).map { $0.kind == kind } ?? true
            }
        }
        safety.requiresNewerClient = { [blockedRecordNames = safety.blockedRecordNames] scope in
            let store = CloudSyncSafetyStore(context: context, scope: scope)
            return try blockedRecordNames(scope).contains {
                try store.entry(recordName: $0)?.reasonCode == CloudSyncQuarantineReason.unsupportedFormat.rawValue
            }
        }
        return safety
    }
}

extension CloudSyncRecordCoding {
    @MainActor
    static func quarantine(
        _ record: CKRecord, error: any Error, in safety: CloudSyncSafetyStore, nativeFields: Bool = false
    ) throws {
        let reasonCode: CloudSyncQuarantineReason
        if error is CloudSyncCompatibilityError {
            reasonCode = .unsupportedFormat
        } else if error is DecodingError {
            reasonCode = .unreadablePayload
        } else {
            reasonCode = .invalidRecord
        }
        try safety.quarantine(
            recordName: record.recordID.recordName,
            // Native-field records require the entire secure archive: preserving only
            // system fields would lose unknown fields that a future reader needs.
            payloadData: nativeFields
                ? try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                : (try? payloadData(from: record, invalidEnvelope: error)) ?? Data(),
            systemFieldsData: try systemFields(of: record),
            reason: error.localizedDescription, reasonCode: reasonCode)
    }

    /// Finishes an asset cache purge that a committed cache purge marked as pending.
    @MainActor
    static func completePendingAssetPurge(
        directoryName: String, context: ModelContext, cacheRoot: URL?, removeItem: (URL) throws -> Void
    ) throws {
        let cleanup = CloudSyncAssetCleanupStore(context: context)
        guard try cleanup.isPending(cacheKey: directoryName) else { return }
        try purgeAssetDirectory(directoryName: directoryName, cacheRoot: cacheRoot, removeItem: removeItem)
        try cleanup.complete(cacheKey: directoryName)
        try context.save()
    }
}
