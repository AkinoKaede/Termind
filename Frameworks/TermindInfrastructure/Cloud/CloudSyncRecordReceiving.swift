import CloudKit

/// Decodes a remote batch while making an unreadable representation win over every readable representation of the
/// same record name. Callers keep category filtering and transactional merge work at the coordinator boundary.
func decodeCloudSyncRecords<Envelope>(
    _ records: [CKRecord],
    included: (CKRecord) -> Bool,
    decode: (CKRecord) throws -> Envelope,
    quarantine: (CKRecord, any Error) throws -> Void,
    logFailure: (any Error) -> Void
) throws -> [(record: CKRecord, envelope: Envelope)] {
    var decoded: [(record: CKRecord, envelope: Envelope)] = []
    var rejectedRecordNames = Set<String>()
    for record in records where included(record) {
        do {
            decoded.append((record, try decode(record)))
        } catch {
            logFailure(error)
            try quarantine(record, error)
            rejectedRecordNames.insert(record.recordID.recordName)
        }
    }
    return decoded.filter { !rejectedRecordNames.contains($0.record.recordID.recordName) }
}
