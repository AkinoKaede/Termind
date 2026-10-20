// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

nonisolated struct MobileWorkspaceDescriptor: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var hostID: UUID
    var title: String
    var kind: ConnectionHistoryEntry.Kind
    var remoteSession: RemoteSessionReference?

    var destinationURL: URL { WorkspaceActivityAttributes.destinationURL(for: id) }
}

nonisolated struct MobileWorkspaceDirectoryLaunch: Equatable, Sendable {
    var hostID: UUID
    var kind: ConnectionHistoryEntry.Kind
    var path: String
}
