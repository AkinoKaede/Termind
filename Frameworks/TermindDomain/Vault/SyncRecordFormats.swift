import Foundation

/// Breaking wire versions are per record kind, not app releases or SwiftData schemas.
/// Keep V1 DTOs frozen. Adding a version means adding its decoder/upgrader here;
/// merely making a domain property optional does not make an old client's write safe.
public nonisolated struct SyncRecordFormats: Sendable {
    public struct Format: Sendable {
        public let readingVersions: Set<Int>
        public let writingVersion: Int
        public init(readingVersions: Set<Int>, writingVersion: Int) {
            precondition(readingVersions.contains(writingVersion))
            self.readingVersions = readingVersions
            self.writingVersion = writingVersion
        }
    }

    public let formats: [String: Format]
    public init(_ formats: [String: Format]) { self.formats = formats }

    public func supports(kind: String, version: Int) -> Bool {
        formats[kind]?.readingVersions.contains(version) == true
    }

    public func writingVersion(for kind: String) -> Int {
        // Only locally known enum cases reach writers. Unknown remote strings use validate instead.
        guard let format = formats[kind] else { preconditionFailure("No writer registered for \(kind)") }
        return format.writingVersion
    }

    public func validate(kind: String, version: Int) throws {
        guard formats[kind] != nil else { throw CloudSyncCompatibilityError.unsupportedKind(kind) }
        guard supports(kind: kind, version: version) else {
            throw CloudSyncCompatibilityError.unsupportedFormat(version)
        }
    }

    /// Persisted only after a successful full read. A new decoder must replay records
    /// skipped by previous capabilities even if CloudKit has no new change for them.
    public var capabilityID: String {
        formats.keys.sorted().map { kind in
            "\(kind):\(formats[kind]!.readingVersions.sorted().map(String.init).joined(separator: ","))"
        }.joined(separator: ";")
    }

    private static let v1 = Format(readingVersions: [1], writingVersion: 1)
    public static let vault = Self([
        "host": Format(readingVersions: [1, 2, 4, 5, 6, 7], writingVersion: 7),
        "hostGroup": Format(readingVersions: [1, 2, 3, 4, 5, 6, 7], writingVersion: 7), "identity": v1,
        "sshKey": Format(readingVersions: [1, 2, 3], writingVersion: 3),
        "knownHost": v1, "snippet": Format(readingVersions: [1, 2], writingVersion: 2), "snippetPackage": v1,
        "portForwarding": v1, "workspaceTemplate": Format(readingVersions: [1, 2], writingVersion: 2),
        // Legacy readers only; these cases cannot pass Vault upload eligibility.
        "connectionHistory": v1, "device": v1,
    ])
    public static let history = Self([
        "connectionHistory": Format(readingVersions: [1, 2], writingVersion: 2), "device": v1,
    ])
    public static let metrics = Self([
        "selection": Format(readingVersions: [1, 2], writingVersion: 2)
    ])
}
