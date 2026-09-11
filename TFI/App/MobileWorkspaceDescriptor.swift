import Foundation

nonisolated struct MobileWorkspaceDescriptor: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case ssh, sftp
        var title: String { self == .ssh ? "SSH" : "SFTP" }
        var symbol: String { self == .ssh ? "terminal" : "folder" }
    }

    var id = UUID()
    var hostID: UUID
    var title: String
    var kind: Kind

    var destinationURL: URL { WorkspaceActivityAttributes.destinationURL(for: id) }
}
