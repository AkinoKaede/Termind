import Foundation
import TermindDomain

/// Read the untyped header before decoding any domain enum or applying defaults.
/// An unknown kind is an upgrade requirement, not a corrupt record and not a new local entity.
public nonisolated struct SyncRecordHeader: Decodable, Sendable {
    public struct Key: Decodable, Sendable {
        public let kind: String
        public let id: UUID
    }
    public let formatVersion: Int
    public let key: Key
}

/// Each registration owns its historical decoder. Tests can register an actual V2
/// adapter without enabling V2 writes in the shipping app. Production registrations
/// must be changed together with SyncRecordFormats and their fixture tests.
public nonisolated struct VersionedRecordDecoder<Value: Sendable>: Sendable {
    public typealias Decode = @Sendable (Data) throws -> Value
    private let decoders: [String: [Int: Decode]]
    public init(_ decoders: [String: [Int: Decode]]) { self.decoders = decoders }

    public func decode(_ data: Data) throws -> Value {
        let header = try JSONDecoder().decode(SyncRecordHeader.self, from: data)
        guard let versions = decoders[header.key.kind] else {
            throw CloudSyncCompatibilityError.unsupportedKind(header.key.kind)
        }
        guard let decode = versions[header.formatVersion] else {
            throw CloudSyncCompatibilityError.unsupportedFormat(header.formatVersion)
        }
        return try decode(data)
    }
}
