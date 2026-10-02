import Foundation
import SwiftData

/// Original local enrollment shape. Never add fields to this historical model.
public enum TermindSchemaV47TailscaleModels {
    @Model
    public final class PersistentTailscaleLocalState {
        @Attribute(.unique) public var groupID: UUID
        public var profileID: UUID
        public var peersData: Data
        public init(groupID: UUID, profileID: UUID, peersData: Data = Data()) {
            self.groupID = groupID
            self.profileID = profileID
            self.peersData = peersData
        }
    }
}
