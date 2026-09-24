import Foundation
import SwiftData

/// Retired importer model retained only to preserve the shipped V35 database schema.
@Model
public final class PersistentHistoryImportState {
    @Attribute(.unique) public var scopeKey = ""
    public var engineStateData: Data?
    public var requiresRefetch = true
    public var capabilityID = ""
    public init(scopeKey: String) { self.scopeKey = scopeKey }
}
