import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

@MainActor
struct CloudSyncReplicaStore {
    typealias MissingRecords = (deleted: [String], recreated: [String])

    var prepare: (CloudSyncScope) throws -> Bool
    var handlesRecordName: (String) -> Bool
    var missing: (CloudSyncScope, Set<String>) throws -> MissingRecords
    var reconcileDeletions: (CloudSyncScope, [String]) throws -> MissingRecords
    var recordDeletionHandoff: (CloudSyncScope, CloudSyncMutation) throws -> Void
    var cancelDeletionHandoff: (CloudSyncScope, CloudSyncMutation) throws -> Void
    var complete: (CloudSyncScope) throws -> Void
    var reset: (CloudSyncScope) throws -> Void

    static func persistent(
        context: ModelContext, records: @escaping () throws -> [CloudSyncJournalRecord],
        clearSystemFields: @escaping (String) throws -> Void,
        handlesRecordName: @escaping (String) -> Bool = { _ in true },
        preservesNewerIncarnation: @escaping (String) -> Bool = { _ in true }
    ) -> Self {
        func store(_ scope: CloudSyncScope) -> CloudSyncRecordStateStore {
            CloudSyncRecordStateStore(context: context, scope: scope)
        }
        // A recreated record is a new incarnation; its old system fields would target the deleted record.
        func clearingRecreated(_ result: MissingRecords) throws -> MissingRecords {
            for name in result.recreated { try clearSystemFields(name) }
            return result
        }
        return Self(
            prepare: { try store($0).prepare(records()) },
            handlesRecordName: handlesRecordName,
            missing: { scope, seen in
                try clearingRecreated(
                    store(scope).missingRecordNames(
                        seen: seen, records: records(), preservesNewerIncarnation: preservesNewerIncarnation))
            },
            reconcileDeletions: { scope, names in
                try clearingRecreated(
                    store(scope).reconcileDeletions(
                        names, records: records(), preservesNewerIncarnation: preservesNewerIncarnation))
            },
            recordDeletionHandoff: { try store($0).recordDeletionHandoff($1) },
            cancelDeletionHandoff: { try store($0).cancelDeletionHandoff($1) },
            complete: { try store($0).completeReconciliation() },
            reset: { try store($0).resetZone() })
    }
}
