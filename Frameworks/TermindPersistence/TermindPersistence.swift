import Foundation
import SwiftData

#if os(macOS)
    import ObjectiveC
#endif

/// The complete, versioned store shared by both apps. Platform entry points
/// choose storage and own the container lifetime, never the model set.
@MainActor
public enum TermindPersistence {
    #if os(macOS)
        private final class WeakStoreLock {
            weak var value: PersistentStoreLock?
            init(_ value: PersistentStoreLock) { self.value = value }
        }

        private static var storeLocks: [URL: WeakStoreLock] = [:]
        private static var storeLockAssociation: UInt8 = 0
    #endif

    // Local schema migrations do not change the independently versioned CloudKit envelopes.
    public static let schema = Schema(versionedSchema: TermindSchemaV56.self)

    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        precondition(!inMemory || url == nil, "An in-memory store cannot also have a file URL")
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(
                "Termind", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        // Acquire before SwiftData can open or migrate the database. Containers in
        // this process share a lease; another process must wait for all of them.
        #if os(macOS)
            let lock = try inMemory ? nil : storeLock(for: configuration.url)
        #endif
        let container = try ModelContainer(
            for: schema, migrationPlan: TermindMigrationPlan.self, configurations: [configuration])
        #if os(macOS)
            if let lock {
                objc_setAssociatedObject(container, &storeLockAssociation, lock, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        #endif
        return container
    }

    #if os(macOS)
        private static func storeLock(for url: URL) throws -> PersistentStoreLock {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            storeLocks = storeLocks.filter { $0.value.value != nil }
            if let existing = storeLocks[canonicalURL]?.value { return existing }
            let lock = try PersistentStoreLock(storeURL: canonicalURL)
            storeLocks[canonicalURL] = WeakStoreLock(lock)
            return lock
        }
    #endif
}
