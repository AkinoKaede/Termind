import ActivityKit
import Foundation

/// One activity summarizes all mobile workspaces. Never contains credentials or terminal output.
nonisolated struct WorkspaceActivityAttributes: ActivityAttributes {
    struct Session: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        var kind: String
        var connected: Bool
        var iconAsset: String? = nil

        var symbol: String { "server.rack" }
        var destinationURL: URL { WorkspaceActivityAttributes.destinationURL(for: id) }
    }

    struct ContentState: Codable, Hashable {
        static let maximumPresentedSessionCount = 4

        var workspaceCount: Int
        var connectedCount: Int
        /// Bounded to fit ActivityKit's payload and the lock-screen layout.
        var sessions: [Session] = []
        var focusedWorkspaceID: UUID?

        static func snapshot(_ workspaces: [Session], focusedID: UUID?) -> Self {
            let focused = workspaces.first(where: { $0.id == focusedID }) ?? workspaces.last
            let ordered =
                focused.map { selected in [selected] + workspaces.filter { $0.id != selected.id } } ?? workspaces
            let visible = ordered.prefix(maximumPresentedSessionCount).map { session in
                var session = session
                session.title = String(decoding: String(session.title.prefix(32)).utf8.prefix(96), as: UTF8.self)
                return session
            }
            return Self(
                workspaceCount: workspaces.count, connectedCount: workspaces.filter(\.connected).count,
                sessions: visible, focusedWorkspaceID: focused?.id)
        }

        var destinationURL: URL {
            focusedWorkspaceID.map(WorkspaceActivityAttributes.destinationURL(for:))
                ?? WorkspaceActivityAttributes.destinationURL
        }
    }

    var scope = "workspaces"

    static var destinationURL: URL { URL(string: "termind://workspaces")! }

    static func destinationURL(for workspaceID: UUID) -> URL {
        URL(string: "termind://workspace/\(workspaceID.uuidString)")!
    }

    static func accepts(_ url: URL) -> Bool {
        url.scheme == "termind" && url.host == "workspaces"
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    static func workspaceID(from url: URL) -> UUID? {
        guard url.scheme == "termind", url.host == "workspace",
            url.query == nil, url.fragment == nil, url.pathComponents.count == 2
        else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
