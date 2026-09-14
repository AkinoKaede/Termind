import Foundation

public nonisolated enum SSHImportCategory: String, CaseIterable, Identifiable, Sendable {
    case hosts, keys, knownHosts
    public var id: Self { self }
    public var title: String {
        switch self {
        case .hosts: String(localized: "Hosts")
        case .keys: String(localized: "Keys")
        case .knownHosts: String(localized: "Known Hosts")
        }
    }
}

/// Public metadata only. The reader resolves private material from short-lived
/// source descriptors behind item IDs when commit needs it.
public nonisolated struct SSHImportItem: Identifiable, Sendable {
    public var id = UUID()
    public var category: SSHImportCategory
    public var name: String
    public var source: String
    public var selected = true
    public var issue: String = ""
    public var unavailable = false
    public var requiresPassphrase = false
    public var needsAuthorization: String?
    public var warnings: [String] = []
    public var acceptedWarnings = false
    public var host: SSHImportedHost?
    public var key: SSHKeyRef?
    public var knownHost: KnownHostEntry?
    public var preferredKeyID: UUID?
    public var existingID: UUID?
    public var certificatePaths: [String] = []
    public init(
        id: UUID = UUID(), category: SSHImportCategory, name: String, source: String, selected: Bool = true,
        issue: String = "", unavailable: Bool = false, requiresPassphrase: Bool = false,
        needsAuthorization: String? = nil, warnings: [String] = [], acceptedWarnings: Bool = false,
        host: SSHImportedHost? = nil, key: SSHKeyRef? = nil, knownHost: KnownHostEntry? = nil,
        preferredKeyID: UUID? = nil, existingID: UUID? = nil, certificatePaths: [String] = []
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.source = source
        self.selected = selected
        self.issue = issue
        self.unavailable = unavailable
        self.requiresPassphrase = requiresPassphrase
        self.needsAuthorization = needsAuthorization
        self.warnings = warnings
        self.acceptedWarnings = acceptedWarnings
        self.host = host
        self.key = key
        self.knownHost = knownHost
        self.preferredKeyID = preferredKeyID
        self.existingID = existingID
        self.certificatePaths = certificatePaths
    }

}

public nonisolated struct SSHImportedHost: Sendable {
    public var alias: String
    public var hostname: String
    public var port = 22
    public var username: String
    public var identityPaths: [String] = []
    public var certificatePaths: [String] = []
    public var jumps: [String] = []
    public var existingKeyID: UUID?
    public var usesDefaultIdentityFiles = false
    public init(
        alias: String, hostname: String, port: Int = 22, username: String, identityPaths: [String] = [],
        certificatePaths: [String] = [], jumps: [String] = [], existingKeyID: UUID? = nil,
        usesDefaultIdentityFiles: Bool = false
    ) {
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.identityPaths = identityPaths
        self.certificatePaths = certificatePaths
        self.jumps = jumps
        self.existingKeyID = existingKeyID
        self.usesDefaultIdentityFiles = usesDefaultIdentityFiles
    }

}

public nonisolated struct SSHConfigLine: Sendable {
    public var keyword: String
    public var values: [String]
    public var source: String
    public var line: Int
    public init(keyword: String, values: [String], source: String, line: Int) {
        self.keyword = keyword
        self.values = values
        self.source = source
        self.line = line
    }

}

public nonisolated enum SSHImportSourceError: LocalizedError, Equatable {
    case expectedFile, expectedFolder, unsupportedKnownHostsContent, sourceChanged
    public var errorDescription: String? {
        switch self {
        case .expectedFile: String(localized: "Choose or drop a single known_hosts file.")
        case .expectedFolder: String(localized: "Choose or drop a single .ssh folder.")
        case .unsupportedKnownHostsContent: String(localized: "The selected file does not contain Known Hosts records.")
        case .sourceChanged: String(localized: "An imported private key changed or became unavailable. Scan again.")
        }
    }
}
