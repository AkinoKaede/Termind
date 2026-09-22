import Foundation
import SwiftData
import TermindDomain

public enum TermindSchemaV25IdentityModels {
    @Model
    public final class PersistentIdentity {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var username = ""
        public var credentialRef = ""
        public var passwordStorage = PasswordStorage.iCloud.rawValue
        public var keyID: UUID?
        public var notes = ""
        public var lastUsedAt: Date?
        public var colorTag = TagColor.none.rawValue
        public var sortIndex = 0.0
        public var ownerHostID: UUID?
        public var customPurpose: String?

        public init(_ value: Identity) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Identity) {
            name = value.name
            username = value.username
            credentialRef = value.credentialRef
            passwordStorage = value.passwordStorage.rawValue
            keyID = value.keyID
            notes = value.notes
            lastUsedAt = nil
            colorTag = value.colorTag.rawValue
            sortIndex = value.sortIndex
            ownerHostID = value.ownerHostID
            customPurpose = value.customPurpose?.rawValue
        }

        public var value: Identity {
            Identity(
                id: id, name: name, username: username, credentialRef: credentialRef,
                passwordStorage: PasswordStorage(rawValue: passwordStorage) ?? .iCloud,
                keyID: keyID, notes: notes,
                colorTag: TagColor(rawValue: colorTag) ?? .none, sortIndex: sortIndex,
                ownerHostID: ownerHostID,
                customPurpose: customPurpose.flatMap(HostCustomIdentityPurpose.init(rawValue:))
            )
        }
    }
}
