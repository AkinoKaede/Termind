import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

@MainActor
struct CloudSyncReplicaStore {
    struct MissingRecords {
        var deleted: [String]
        var recreated: [String]
    }

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
        Self(
            prepare: { try CloudSyncRecordStateStore(context: context, scope: $0).prepare(records()) },
            handlesRecordName: handlesRecordName,
            missing: { scope, seen in
                let result = try CloudSyncRecordStateStore(context: context, scope: scope)
                    .missingRecordNames(
                        seen: seen, records: records(),
                        preservesNewerIncarnation: preservesNewerIncarnation)
                for name in result.recreated { try clearSystemFields(name) }
                return MissingRecords(deleted: result.deleted, recreated: result.recreated)
            },
            reconcileDeletions: { scope, names in
                let result = try CloudSyncRecordStateStore(context: context, scope: scope)
                    .reconcileDeletions(
                        names, records: records(),
                        preservesNewerIncarnation: preservesNewerIncarnation)
                for name in result.recreated { try clearSystemFields(name) }
                return MissingRecords(deleted: result.deleted, recreated: result.recreated)
            },
            recordDeletionHandoff: {
                try CloudSyncRecordStateStore(context: context, scope: $0).recordDeletionHandoff($1)
            },
            cancelDeletionHandoff: {
                try CloudSyncRecordStateStore(context: context, scope: $0).cancelDeletionHandoff($1)
            },
            complete: { try CloudSyncRecordStateStore(context: context, scope: $0).completeReconciliation() },
            reset: { try CloudSyncRecordStateStore(context: context, scope: $0).resetZone() })
    }
}
