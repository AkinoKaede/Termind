import Foundation

nonisolated struct MobileWorkspaceDescriptor: Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case ssh, sftp
        var symbol: String { self == .ssh ? "terminal" : "folder" }
    }

    var id = UUID()
    var hostID: UUID
    var title: String
    var kind: Kind

    var destinationURL: URL { WorkspaceActivityAttributes.destinationURL(for: id) }
}

nonisolated struct MobileWorkspaceDirectoryLaunch: Equatable, Sendable {
    var hostID: UUID
    var kind: MobileWorkspaceDescriptor.Kind
    var path: String
}
