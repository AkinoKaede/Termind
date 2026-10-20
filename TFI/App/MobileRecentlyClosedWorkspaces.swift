// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import TermindPresentation

extension MobileAppModel {
    var closedWorkspaceRecords: [RecentlyClosedRecord<MobileWorkspaceDescriptor>] {
        recentlyClosedStore.entries.filter { record in
            !record.items.isEmpty
                && record.items.allSatisfy { item in
                    guard !containsWorkspace(item.id) else { return false }
                    if closedWorkspaceStates[record.id]?.contains(where: {
                        $0.descriptor.id == item.id && !$0.connectionOrigin.allowsPersistence
                    }) == true {
                        return true
                    }
                    guard let host = library.host(item.hostID) else { return false }
                    return MobileConnectionHistoryActionPolicy.isAvailable(item.kind, for: host)
                }
        }
    }

    func rememberClosedWorkspaces(_ states: [MobileWorkspace.ReopenState], isWindow: Bool = false) {
        guard !states.isEmpty else { return }
        let record = RecentlyClosedRecord(items: states.map(\.descriptor), isWindow: isWindow)
        closedWorkspaceStates[record.id] = states
        recentlyClosedStore.record(record, persist: false)
        let retained = Set(recentlyClosedStore.entries.map(\.id))
        closedWorkspaceStates = closedWorkspaceStates.filter { retained.contains($0.key) }
    }

    func forgetClosedWorkspaces(for hostID: UUID) {
        for var record in recentlyClosedStore.entries {
            record.items.removeAll { $0.hostID == hostID }
            closedWorkspaceStates[record.id]?.removeAll { $0.descriptor.hostID == hostID }
            if record.items.isEmpty {
                recentlyClosedStore.remove(record.id)
                closedWorkspaceStates[record.id] = nil
            } else {
                recentlyClosedStore.update(record)
            }
        }
    }

    func requestClosedWindow(_ id: UUID) {
        guard closedWorkspaceRecords.contains(where: { $0.id == id && $0.isWindow }),
            pendingClosedWindows.insert(id).inserted
        else { return }
        createWorkspaceWindow(id) { [weak self] in
            self?.pendingClosedWindows.remove(id)
            self?.error = String(localized: AppStrings.Workspace.restoreWorkspacesFailure)
        }
    }

    func restoreClosedWindow(_ id: UUID, into session: MobileWorkspaceSessionModel) -> UUID? {
        guard pendingClosedWindows.remove(id) != nil,
            closedWorkspaceRecords.contains(where: { $0.id == id && $0.isWindow })
        else { return nil }
        return restoreClosedRecord(id, into: session)
    }

    func restoreClosedRecord(_ id: UUID, into session: MobileWorkspaceSessionModel, itemID: UUID? = nil) -> UUID? {
        guard !session.isDiscarded, var record = closedWorkspaceRecords.first(where: { $0.id == id }) else {
            return nil
        }
        let items = record.items.filter { itemID == nil || $0.id == itemID }
        guard !items.isEmpty else { return nil }
        let states = items.map { item in
            closedWorkspaceStates[id]?.first { $0.descriptor.id == item.id } ?? .init(descriptor: item)
        }
        session.restoreClosedStates(states)
        let removed = Set(items.map(\.id))
        record.items.removeAll { removed.contains($0.id) }
        closedWorkspaceStates[id]?.removeAll { removed.contains($0.descriptor.id) }
        if record.items.isEmpty {
            recentlyClosedStore.remove(id)
            closedWorkspaceStates[id] = nil
        } else {
            recentlyClosedStore.update(record)
        }
        return items.first { $0.id == record.selectedItemID }?.id ?? items.first?.id
    }
}
