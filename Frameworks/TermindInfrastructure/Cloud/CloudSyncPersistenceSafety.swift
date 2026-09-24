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
    static func persistentHistory(context: ModelContext, kind: HistoryRecordKind) -> Self {
        var safety = persistent(
            context: context,
            capabilityID: SyncRecordFormats.history.capabilityID + ";kind:" + kind.rawValue,
            importLegacyQuarantine: { _ in })
        let allBlocked = safety.blockedRecordNames
        safety.blockedRecordNames = { scope in
            Set(
                try allBlocked(scope).filter {
                    HistoryRecordKey(recordName: $0).map { $0.kind == kind } ?? true
                })
        }
        safety.requiresNewerClient = { scope in
            let store = CloudSyncSafetyStore(context: context, scope: scope)
            for name in try store.blockedRecordNames()
            where HistoryRecordKey(recordName: name).map({ $0.kind == kind }) ?? true {
                if try store.entry(recordName: name)?.reasonCode
                    == CloudSyncQuarantineReason.unsupportedFormat.rawValue
                {
                    return true
                }
            }
            return false
        }
        return safety
    }
}
