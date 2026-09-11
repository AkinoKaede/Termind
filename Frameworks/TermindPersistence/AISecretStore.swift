import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentAISecretLocation {
    @Attribute(.unique) public var reference = ""
    public var usesICloud = false
    public var pendingDeletion = false
    public init(reference: String) { self.reference = reference }
}
