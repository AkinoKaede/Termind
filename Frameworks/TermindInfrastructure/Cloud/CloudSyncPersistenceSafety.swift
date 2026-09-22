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

    /// The lifecycle commits both legacy imports and recovery state before creating an engine.
    static func persistent(
        context: ModelContext, importLegacyQuarantine: @escaping (CloudSyncScope) throws -> Void
    ) -> Self {
        Self(
            prepare: { scope, legacyScope in
                try importLegacyQuarantine(legacyScope)
                return try CloudSyncSafetyStore(context: context, scope: scope).recovery().requiresRefetch
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
    static func quarantine(_ record: CKRecord, error: any Error, in safety: CloudSyncSafetyStore) throws {
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
            payloadData: (try? payloadData(from: record, invalidEnvelope: error)) ?? Data(),
            systemFieldsData: try systemFields(of: record),
            reason: error.localizedDescription, reasonCode: reasonCode)
    }
}
