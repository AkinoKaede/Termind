// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import ActivityKit
import Foundation

/// One activity summarizes all mobile workspaces. Never contains credentials or terminal output.
nonisolated struct WorkspaceActivityAttributes: ActivityAttributes {
    struct Recovery: Codable, Hashable {
        var version = 1
        var sourceWorkspaceID: UUID
        var hostID: UUID
        var kind: String
        /// Opaque, versioned domain reference. Never included in deep links.
        var remoteSession: Data?
    }

    struct Session: Codable, Hashable, Identifiable {
        var id: UUID
        var title: String
        var kind: String
        var connected: Bool
        var iconAsset: String? = nil
        var iconSystemName: String? = nil
        var recovery: Recovery? = nil

        var destinationURL: URL {
            WorkspaceActivityAttributes.destinationURL(for: id)
        }
    }

    struct ContentState: Codable, Hashable {
        static let maximumPresentedSessionCount = 6

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
            var result = Self(
                workspaceCount: workspaces.count, connectedCount: workspaces.filter(\.connected).count,
                sessions: visible, focusedWorkspaceID: focused?.id)
            // Leave room for Activity attributes and system encoding overhead. Drop whole entries,
            // never part of an identity. The focused entry is first and therefore retained longest.
            while !result.sessions.isEmpty, (try? JSONEncoder().encode(result).count) ?? Int.max > 3500 {
                result.sessions.removeLast()
            }
            if !result.sessions.contains(where: { $0.id == result.focusedWorkspaceID }) {
                result.focusedWorkspaceID = result.sessions.first?.id
            }
            return result
        }

        var destinationURL: URL {
            sessions.first(where: { $0.id == focusedWorkspaceID })?.destinationURL
                ?? focusedWorkspaceID.map(WorkspaceActivityAttributes.destinationURL(for:))
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
            url.user == nil, url.password == nil, url.port == nil,
            url.fragment == nil, url.pathComponents.count == 2
        else { return nil }
        if url.query != nil, recovery(from: url) == nil { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    static func recovery(from url: URL) -> Recovery? {
        guard url.scheme == "termind", url.host == "workspace",
            url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
            url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent),
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            items.count == 3, Set(items.map(\.name)) == ["v", "host", "kind"],
            items.first(where: { $0.name == "v" })?.value == "1",
            let rawHost = items.first(where: { $0.name == "host" })?.value,
            let host = UUID(uuidString: rawHost),
            let kind = items.first(where: { $0.name == "kind" })?.value,
            ["ssh", "mosh", "eternalTerminal", "sftp", "telnet"].contains(kind)
        else { return nil }
        return Recovery(sourceWorkspaceID: id, hostID: host, kind: kind)
    }
}
