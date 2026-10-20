// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

/// Only saved-host references and presentation state survive an app restart.
struct ClosedWorkspaceRecord: Codable, Identifiable {
    let id: UUID
    let title: String
    let symbol: String
    let layout: WorkspaceTemplateLayout?
    let paneNames: [String?]
    let focusedPaneIndex: Int
    var remoteSessions: [RemoteSessionReference?]? = nil

    @MainActor
    init(_ workspace: Workspace, hosts: HostLibraryModel) {
        let layout =
            workspace.panes.contains { $0.sshSession?.isExternalTemporaryConnection == true }
            ? nil : workspace.workspaceTemplateLayout(in: hosts)
        self.remoteSessions = workspace.panes.map { $0.sshSession?.restorableRemoteSession }
        self.id = workspace.id
        self.title = workspace.title(in: hosts)
        self.symbol = workspace.symbol
        self.layout = layout
        self.paneNames = workspace.panes.map(\.customTitle)
        self.focusedPaneIndex = workspace.panes.firstIndex { $0.id == workspace.focusedPaneID } ?? 0
    }

    @MainActor
    func canRestore(in hosts: HostLibraryModel) -> Bool {
        guard let layout else { return false }
        return layout.isValid
            && layout.panes.allSatisfy { pane in
                switch pane {
                case .empty: true
                case .ssh(let id), .sftp(let id): hosts.host(id)?.sshEnabled == true
                case .telnet(let id): hosts.host(id)?.telnetEnabled == true
                case .mosh(let id): hosts.host(id)?.isEnabled(.mosh) == true
                case .eternalTerminal(let id): hosts.host(id)?.isEnabled(.eternalTerminal) == true
                }
            }
    }

    @MainActor
    func restore(in hosts: HostLibraryModel) -> Workspace? {
        guard canRestore(in: hosts), let layout else { return nil }
        let node = layout.makeSplitNode(using: hosts).node
        let workspace = Workspace(pane: node.firstPane)
        workspace.layout = node
        for (pane, name) in zip(workspace.panes, paneNames) { pane.customTitle = name }
        for (pane, reference) in zip(workspace.panes, remoteSessions ?? []) {
            pane.sshSession?.sessionPersistence.attachment = reference
        }
        if workspace.isSplit { workspace.customTitle = title } else { workspace.automaticTitle = title }
        if workspace.panes.indices.contains(focusedPaneIndex) {
            workspace.focusedPaneID = workspace.panes[focusedPaneIndex].id
        }
        return workspace
    }
}
