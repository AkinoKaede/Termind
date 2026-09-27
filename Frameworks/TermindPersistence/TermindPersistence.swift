import Foundation
import SwiftData

/// The complete, versioned store shared by both apps. Platform entry points
/// choose storage and own the container lifetime, never the model set.
@MainActor
public enum TermindPersistence {
    // Local schema migrations do not change the independently versioned CloudKit envelopes.
    public static let schema = Schema(versionedSchema: TermindSchemaV42.self)

    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        precondition(!inMemory || url == nil, "An in-memory store cannot also have a file URL")
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(
                "Termind", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        return try ModelContainer(
            for: schema, migrationPlan: TermindMigrationPlan.self, configurations: [configuration])
    }
}
