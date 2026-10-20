// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

extension AppModel {
    var closedWorkspaceRecords: [RecentlyClosedRecord<ClosedWorkspaceRecord>] {
        recentlyClosedStore.entries.filter { record in
            !record.items.isEmpty
                && record.items.allSatisfy { item in
                    closedWorkspaceInstances[record.id]?.contains { $0.id == item.id } == true
                        || item.canRestore(in: hostLibrary)
                }
        }
    }

    func rememberClosedWorkspaces(_ workspaces: [Workspace], isWindow: Bool = false, selectedID: UUID? = nil) {
        guard !workspaces.isEmpty else { return }
        let record = RecentlyClosedRecord(
            items: workspaces.map { ClosedWorkspaceRecord($0, hosts: hostLibrary) },
            isWindow: isWindow, selectedItemID: selectedID)
        closedWorkspaceInstances[record.id] = workspaces
        recentlyClosedStore.record(record, persist: record.items.allSatisfy { $0.layout != nil })
        let retained = Set(recentlyClosedStore.entries.map(\.id))
        closedWorkspaceInstances = closedWorkspaceInstances.filter { retained.contains($0.key) }
    }

    func reopenClosedRecord(_ id: UUID, in window: WindowModel?) {
        guard let record = closedWorkspaceRecords.first(where: { $0.id == id }) else { return }
        if record.isWindow || window == nil {
            mainWindows.reopenClosedWindow(id, from: window)
        } else if let window {
            restoreClosedRecord(id, into: window)
        }
    }

    /// Consume only after a destination exists; failed scene creation leaves history intact.
    func restoreClosedRecord(_ id: UUID, into window: WindowModel, itemID: UUID? = nil) {
        guard !window.isClosed, var record = closedWorkspaceRecords.first(where: { $0.id == id }) else { return }
        let items = record.items.filter { itemID == nil || $0.id == itemID }
        guard !items.isEmpty else { return }
        let restored = items.compactMap { item in
            closedWorkspaceInstances[id]?.first { $0.id == item.id } ?? item.restore(in: hostLibrary)
        }
        guard restored.count == items.count else { return }
        for workspace in restored {
            workspace.prepareForReopen()
            window.open(workspace)
        }
        if itemID == nil, let selected = items.firstIndex(where: { $0.id == record.selectedItemID }) {
            window.select(restored[selected].id)
        }
        let removed = Set(items.map(\.id))
        record.items.removeAll { removed.contains($0.id) }
        closedWorkspaceInstances[id]?.removeAll { removed.contains($0.id) }
        if record.items.isEmpty {
            recentlyClosedStore.remove(id)
            closedWorkspaceInstances[id] = nil
        } else {
            recentlyClosedStore.update(record)
        }
    }
}
