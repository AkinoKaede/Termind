import Foundation
import SwiftData
import TermindApplication

/// Migration metadata is local. The reference is shared; the secret never enters SwiftData.
@MainActor
public final class AISecretStore: AISecretStoring {
    private let context: ModelContext
    private let keychain: any SecretStoring
    public var uploadsAuthorized = false

    public init(context: ModelContext, keychain: any SecretStoring) {
        self.context = context
        self.keychain = keychain
    }

    public func string(for reference: String) throws -> String? {
        guard !reference.isEmpty else { return nil }
        let location = try location(for: reference)
        guard !location.pendingDeletion else { return nil }
        return try keychain.string(for: reference, storage: location.usesICloud ? .iCloud : .thisDevice)
    }

    public func setString(_ value: String?, for reference: String) throws {
        guard !reference.isEmpty else { return }
        let location = try location(for: reference)
        if value == nil {
            location.pendingDeletion = true
            try context.save()
            try finishDeletion(location)
            return
        }
        let cloud = location.usesICloud || uploadsAuthorized
        try keychain.setString(value, for: reference, storage: cloud ? .iCloud : .thisDevice)
        if cloud {
            guard try keychain.string(for: reference, storage: .iCloud) == value else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        location.usesICloud = cloud
        location.pendingDeletion = false
        try context.save()
        if cloud { try keychain.setString(nil, for: reference, storage: .thisDevice) }
    }

    /// Called only after the coordinator has checked the account and merge consent.
    public func migrate(_ references: Set<String>) throws {
        guard uploadsAuthorized else { return }
        for row in try context.fetch(FetchDescriptor<PersistentAISecretLocation>()) where row.pendingDeletion {
            try finishDeletion(row)
        }
        for reference in references.sorted() where !reference.isEmpty {
            let row = try location(for: reference)
            guard !row.pendingDeletion else { continue }
            if let local = try keychain.string(for: reference, storage: .thisDevice) {
                // A previously synced value can be newer than a leftover local copy.
                if try keychain.string(for: reference, storage: .iCloud) == nil && !row.usesICloud {
                    try keychain.setString(local, for: reference, storage: .iCloud)
                    guard try keychain.string(for: reference, storage: .iCloud) == local else {
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                if try keychain.string(for: reference, storage: .iCloud) != nil {
                    row.usesICloud = true
                    try context.save()
                    try keychain.setString(nil, for: reference, storage: .thisDevice)
                }
            } else {
                row.usesICloud = true
                try context.save()
            }
        }
    }

    public func acceptRemoteReferences(_ references: Set<String>) throws {
        try context.commit {
            for reference in references where !reference.isEmpty {
                try location(for: reference).usesICloud = true
            }
        }
    }

    private func finishDeletion(_ row: PersistentAISecretLocation) throws {
        if row.usesICloud { try keychain.setString(nil, for: row.reference, storage: .iCloud) }
        try keychain.setString(nil, for: row.reference, storage: .thisDevice)
        // Retain the deletion marker so a delayed Keychain delivery cannot be used.
    }

    private func location(for reference: String) throws -> PersistentAISecretLocation {
        guard reference.hasPrefix("termind.ai."), reference.count > "termind.ai.".count else {
            throw CocoaError(.coderValueNotFound)
        }
        var descriptor = FetchDescriptor<PersistentAISecretLocation>(
            predicate: #Predicate { $0.reference == reference })
        descriptor.fetchLimit = 1
        if let row = try context.fetch(descriptor).first { return row }
        let row = PersistentAISecretLocation(reference: reference)
        context.insert(row)
        return row
    }
}
