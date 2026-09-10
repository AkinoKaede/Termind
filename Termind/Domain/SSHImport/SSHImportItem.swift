import Foundation

nonisolated enum SSHImportCategory: String, CaseIterable, Identifiable, Sendable {
    case hosts, keys, knownHosts
    var id: Self { self }
    var title: String {
        switch self {
        case .hosts: String(localized: "Hosts")
        case .keys: String(localized: "Keys")
        case .knownHosts: String(localized: "Known Hosts")
        }
    }
}

/// Public metadata only. The reader retains private material behind item IDs.
nonisolated struct SSHImportItem: Identifiable, Sendable {
    var id = UUID()
    var category: SSHImportCategory
    var name: String
    var source: String
    var selected = true
    var issue: String = ""
    var unavailable = false
    var requiresPassphrase = false
    var needsAuthorization: String?
    var warnings: [String] = []
    var acceptedWarnings = false
    var host: SSHImportedHost?
    var key: SSHKeyRef?
    var knownHost: KnownHostEntry?
    var preferredKeyID: UUID?
    var existingID: UUID?
    var certificatePaths: [String] = []
}

nonisolated struct SSHImportedHost: Sendable {
    var alias: String
    var hostname: String
    var port = 22
    var username: String
    var identityPaths: [String] = []
    var certificatePaths: [String] = []
    var jumps: [String] = []
    var existingKeyID: UUID?
    var usesDefaultIdentityFiles = false
}

nonisolated struct SSHConfigLine: Sendable {
    var keyword: String
    var values: [String]
    var source: String
    var line: Int
}

nonisolated enum SSHImportSourceError: LocalizedError, Equatable {
    case expectedFile, expectedFolder
    var errorDescription: String? {
        switch self {
        case .expectedFile: String(localized: "Choose or drop a single known_hosts file.")
        case .expectedFolder: String(localized: "Choose or drop a single .ssh folder.")
        }
    }
}
