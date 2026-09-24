import Foundation

/// Durable journal intent. CloudKit's serialized queue is only a scheduling cache.
public nonisolated struct CloudSyncMutation: Equatable, Sendable {
    public enum Operation: String, Sendable { case save, delete }
    public var recordName: String
    public var operation: Operation
    public var version: VaultVersion

    public init(recordName: String, operation: Operation, version: VaultVersion) {
        self.recordName = recordName
        self.operation = operation
        self.version = version
    }
}

public nonisolated struct CloudSyncJournalRecord: Sendable {
    public var mutation: CloudSyncMutation
    public var needsUpload: Bool
    public var hasSystemFields: Bool

    public init(recordName: String, version: VaultVersion, isDeleted: Bool, needsUpload: Bool, hasSystemFields: Bool) {
        mutation = CloudSyncMutation(recordName: recordName, operation: isDeleted ? .delete : .save, version: version)
        self.needsUpload = needsUpload
        self.hasSystemFields = hasSystemFields
    }
}
