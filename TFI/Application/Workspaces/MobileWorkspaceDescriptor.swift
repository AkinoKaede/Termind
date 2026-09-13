import Foundation
import TermindDomain

nonisolated struct MobileWorkspaceDescriptor: Hashable, Identifiable, Sendable {
    var id = UUID()
    var hostID: UUID
    var title: String
    var kind: ConnectionHistoryEntry.Kind
    var duplicateIndex = 0

    var destinationURL: URL { WorkspaceActivityAttributes.destinationURL(for: id) }
}

nonisolated struct MobileWorkspaceDirectoryLaunch: Equatable, Sendable {
    var hostID: UUID
    var kind: ConnectionHistoryEntry.Kind
    var path: String
}
