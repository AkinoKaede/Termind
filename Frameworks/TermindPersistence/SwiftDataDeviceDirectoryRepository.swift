import Foundation
import SwiftData
import TermindApplication
import TermindDomain

public enum TermindSchemaV32DeviceModels {
    @Model
    public final class PersistentDeviceRecord {
        @Attribute(.unique) public var id = UUID()
        public var displayName = ""

        public init(_ value: DeviceRecord) {
            id = value.id
            displayName = value.displayName
        }

        public var value: DeviceRecord {
            DeviceRecord(id: id, displayName: displayName)
        }
    }
}

public typealias PersistentDeviceRecord = TermindSchemaV32DeviceModels.PersistentDeviceRecord

@MainActor
public final class SwiftDataDeviceDirectoryRepository: DeviceDirectoryRepository {
    private let context: ModelContext
    public var didRecordVaultChanges: ((VaultMutationSet) -> Void)?

    public init(context: ModelContext) { self.context = context }

    public func devices() throws -> [DeviceRecord] {
        try context.fetch(FetchDescriptor<PersistentDeviceRecord>()).map(\.value)
    }

    public func upsert(_ device: DeviceRecord) throws {
        var mutations = VaultMutationSet.empty
        try context.commit {
            let id = device.id
            var descriptor = FetchDescriptor<PersistentDeviceRecord>(
                predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                guard existing.displayName != device.displayName else { return }
                existing.displayName = device.displayName
            } else {
                context.insert(PersistentDeviceRecord(device))
            }
            mutations = try VaultSyncJournal(context: context).recordCurrentDevices(try devices())
        }
        if !mutations.isEmpty { didRecordVaultChanges?(mutations) }
    }
}
