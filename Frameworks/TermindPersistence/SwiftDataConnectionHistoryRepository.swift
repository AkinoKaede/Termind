import Foundation
import SwiftData
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// The connection-history shape shipped through V31.
public enum TermindSchemaV31ConnectionHistoryModels {
    @Model
    public final class PersistentConnectionHistoryEntry {
        @Attribute(.unique) public var id: UUID = UUID()
        public var hostID: UUID = UUID()
        public var kind = ConnectionHistoryEntry.Kind.ssh.rawValue
        public var connectedAt = Date(timeIntervalSince1970: 0)

        public init(_ value: ConnectionHistoryEntry) {
            id = value.id
            hostID = value.hostID
            kind = value.kind.rawValue
            connectedAt = value.connectedAt
        }
    }
}

/// V32 adds synchronized origin and lifecycle metadata without changing the historical entity name.
public enum TermindSchemaV32ConnectionHistoryModels {
    @Model
    public final class PersistentConnectionHistoryEntry {
        @Attribute(.unique) public var id: UUID = UUID()
        public var hostID: UUID = UUID()
        public var kind = ConnectionHistoryEntry.Kind.ssh.rawValue
        public var connectedAt = Date(timeIntervalSince1970: 0)
        public var sourceDeviceID: UUID?
        public var endedAt: Date?

        public init(_ value: ConnectionHistoryEntry) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: ConnectionHistoryEntry) {
            hostID = value.hostID
            kind = value.kind.rawValue
            connectedAt = value.connectedAt
            sourceDeviceID = value.sourceDeviceID
            endedAt = value.endedAt
        }

        public var value: ConnectionHistoryEntry {
            ConnectionHistoryEntry(
                id: id, hostID: hostID,
                kind: ConnectionHistoryEntry.Kind(rawValue: kind) ?? .ssh,
                connectedAt: connectedAt, sourceDeviceID: sourceDeviceID,
                endedAt: endedAt
            )
        }
    }

}

public typealias PersistentConnectionHistoryEntry =
    TermindSchemaV32ConnectionHistoryModels.PersistentConnectionHistoryEntry
@MainActor
public final class SwiftDataConnectionHistoryRepository: ConnectionHistoryRepository {
    private let context: ModelContext
    public var didRecordVaultChanges: ((VaultMutationSet) -> Void)?

    public init(context: ModelContext) { self.context = context }

    public func entries() throws -> [ConnectionHistoryEntry] {
        try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
            .map(\.value)
            .sorted(by: ConnectionHistoryEntry.isNewer)
    }

    public func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
        try commitMutation {
            context.insert(PersistentConnectionHistoryEntry(entry))
            let rows = try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
                .sorted { ConnectionHistoryEntry.isNewer($0.value, $1.value) }
            for row in rows.dropFirst(limit) { context.delete(row) }
        }
    }

    public func end(_ id: ConnectionHistoryEntry.ID, at date: Date) throws {
        try commitMutation {
            guard let row = try entry(id), row.endedAt == nil else { return }
            row.endedAt = max(date, row.connectedAt)
        }
    }

    public func delete(_ id: ConnectionHistoryEntry.ID) throws {
        try commitMutation {
            if let row = try entry(id) { context.delete(row) }
        }
    }

    public func clear(for hostID: Host.ID) throws {
        try commitMutation {
            try context.delete(
                model: PersistentConnectionHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }

    public func clearAll() throws {
        try commitMutation {
            try context.delete(model: PersistentConnectionHistoryEntry.self)
        }
    }

    private func entry(_ id: UUID) throws -> PersistentConnectionHistoryEntry? {
        var descriptor = FetchDescriptor<PersistentConnectionHistoryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func commitMutation(_ operation: () throws -> Void) throws {
        var mutations = VaultMutationSet.empty
        try context.commit {
            try operation()
            mutations = try VaultSyncJournal(context: context).recordCurrentConnectionHistory(
                try entries())
        }
        if !mutations.isEmpty { didRecordVaultChanges?(mutations) }
    }
}
