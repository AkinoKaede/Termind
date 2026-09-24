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
        context: ModelContext, capabilityID: String? = nil, capabilityProvider: (() -> String)? = nil,
        importLegacyQuarantine: @escaping (CloudSyncScope) throws -> Void
    ) -> Self {
        Self(
            prepare: { scope, legacyScope in
                try importLegacyQuarantine(legacyScope)
                let safety = CloudSyncSafetyStore(context: context, scope: scope)
                if let expected = capabilityProvider?() ?? capabilityID,
                    try safety.capability().capabilityID != expected
                {
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
                if let expected = capabilityProvider?() ?? capabilityID {
                    try CloudSyncSafetyStore(context: context, scope: scope).capability().capabilityID = expected
                }
            })
    }
}

extension CloudSyncRecordCoding {
    nonisolated static func validateFormat(in data: Data, supported: Int) throws {
        struct Header: Decodable { var formatVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        if header.formatVersion > supported {
            throw CloudSyncCompatibilityError.unsupportedFormat(header.formatVersion)
        }
        guard header.formatVersion == supported else { throw CocoaError(.coderReadCorrupt) }
    }

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
}

extension CloudSyncLifecycleSafety {
    /// Source quarantine must fence destination writes without appearing in the
    /// configuration category's status. Account/environment identity stays intact.
    static func persistentHistory(
        context: ModelContext, includesHistory: @escaping () -> Bool,
        importLegacyQuarantine: @escaping (CloudSyncScope) throws -> Void
    ) -> Self {
        var safety = persistent(
            context: context,
            capabilityProvider: {
                SyncRecordFormats.history.capabilityID + (includesHistory() ? ";events:on" : ";events:off")
            }, importLegacyQuarantine: importLegacyQuarantine)
        let destinationBlocked = safety.blockedRecordNames
        safety.blockedRecordNames = { scope in
            let names = try destinationBlocked(scope).union(
                CloudSyncSafetyStore(context: context, scope: scope.historyImportScope).blockedRecordNames())
            return Set(
                names.filter { includesHistory() || HistoryRecordKey(recordName: $0)?.kind != .connectionHistory })
        }
        let destinationIsBlocked = safety.isUploadBlocked
        safety.isUploadBlocked = { scope, name in
            try destinationIsBlocked(scope, name)
                || CloudSyncSafetyStore(context: context, scope: scope.historyImportScope).isUploadBlocked(
                    recordName: name)
        }
        let destinationRequiresUpdate = safety.requiresNewerClient
        safety.requiresNewerClient = { scope in
            if includesHistory() {
                return try destinationRequiresUpdate(scope)
                    || CloudSyncSafetyStore(context: context, scope: scope.historyImportScope).requiresNewerClient()
            }
            for replica in [scope, scope.historyImportScope] {
                let store = CloudSyncSafetyStore(context: context, scope: replica)
                for name in try store.blockedRecordNames()
                where HistoryRecordKey(recordName: name)?.kind != .connectionHistory {
                    if try store.entry(recordName: name)?.reasonCode
                        == CloudSyncQuarantineReason.unsupportedFormat.rawValue
                    {
                        return true
                    }
                }
            }
            return false
        }
        return safety
    }
}
