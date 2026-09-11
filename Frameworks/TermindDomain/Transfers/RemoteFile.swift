import Foundation

public nonisolated struct RemoteFile: Identifiable, Hashable, Sendable {
    public nonisolated enum Kind: String, Hashable, Sendable {
        case file, directory, symbolicLink, special, unknown
    }

    public var path: String
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var modifiedAt: Date?
    public var permissions: UInt32
    public var ownerUID: UInt32
    public var ownerGID: UInt32

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var isHidden: Bool { name.hasPrefix(".") }
    public var permissionMode: UInt32 { permissions & 0o7777 }

    public var octalPermissionDescription: String {
        String(format: "%04o", permissionMode)
    }

    public var permissionDescription: String {
        let type: Character =
            switch kind {
            case .file: "-"
            case .directory: "d"
            case .symbolicLink: "l"
            case .special: "s"
            case .unknown: "?"
            }
        let masks: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        let letters: [Character] = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
        return String([type] + zip(masks, letters).map { permissions & $0.0 == 0 ? "-" : $0.1 })
    }

    public init(
        path: String,
        name: String,
        kind: Kind,
        size: Int64,
        modifiedAt: Date? = nil,
        permissions: UInt32,
        ownerUID: UInt32,
        ownerGID: UInt32
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
    }
}
