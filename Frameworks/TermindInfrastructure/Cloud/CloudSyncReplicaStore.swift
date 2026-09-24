import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

@MainActor
struct CloudSyncReplicaStore {
    var prepare: (CloudSyncScope) throws -> Bool
    var missing: (CloudSyncScope, Set<String>) throws -> [String]
    var complete: (CloudSyncScope) throws -> Void
    var reset: (CloudSyncScope) throws -> Void

    static func persistent(context: ModelContext, records: @escaping () throws -> [CloudSyncJournalRecord]) -> Self {
        Self(
            prepare: { try CloudSyncRecordStateStore(context: context, scope: $0).prepare(records()) },
            missing: { try CloudSyncRecordStateStore(context: context, scope: $0).missingRecordNames(seen: $1) },
            complete: { try CloudSyncRecordStateStore(context: context, scope: $0).completeReconciliation() },
            reset: { try CloudSyncRecordStateStore(context: context, scope: $0).resetZone() })
    }
}
