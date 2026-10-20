// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Resolves the live model at drag time. In particular, picking up the selected
/// workspace changes its merge neighbour before SwiftUI has rendered the deck.
@MainActor
struct PaneLayoutDropController {
    let window: WindowModel
    let workspace: Workspace
    let pane: Pane

    var draggedID: UUID? {
        guard window.displayedWorkspace?.id == workspace.id,
            workspace.layout.pane(pane.id) === pane
        else { return nil }
        switch window.dragging {
        case .workspace(let id): return id
        case .pane(let id):
            // The source remains mounted to keep the native drag alive, but
            // is omitted from the layout preview and must not receive drops.
            return id == pane.id ? nil : id
        case .assistantConversation, nil: return nil
        }
    }

    private var acceptsDrop: Bool {
        guard pane.isCombinable || pane.isEmptySlot else { return false }
        switch window.dragging {
        case .pane(let id):
            return id != pane.id && workspace.layout.pane(id) != nil
        case .workspace(let id):
            guard id != workspace.id else { return false }
            return window.workspaces.first { $0.id == id }?.isCombinable ?? false
        case .assistantConversation, nil: return false
        }
    }

    func preview(at point: CGPoint, in size: CGSize) -> CGRect? {
        guard draggedID != nil, acceptsDrop else { return nil }
        return zone(at: point, in: size).previewRect(in: size)
    }

    func perform(at point: CGPoint, in size: CGSize) -> Bool {
        guard draggedID != nil else { return false }
        // Clear only after mutation: restoring an omitted source first would
        // briefly mount its native surface in both the old and new parents.
        defer { window.dragging = nil }
        guard acceptsDrop else { return true }
        let zone = zone(at: point, in: size)
        switch window.dragging {
        case .workspace(let id):
            if zone == .replace {
                window.fill(pane.id, in: workspace.id, withPanesOf: id)
            } else if let placement = zone.placement {
                window.merge(
                    id, into: workspace.id, beside: pane.id,
                    axis: placement.axis, side: placement.side
                )
            }
        case .pane(let id):
            if zone == .replace {
                window.movePane(id, into: pane.id)
            } else if let placement = zone.placement {
                window.movePane(
                    id, beside: pane.id,
                    axis: placement.axis, side: placement.side
                )
            }
        case .assistantConversation, nil: return false
        }
        return true
    }

    private func zone(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        pane.isEmptySlot ? .replace : PaneDropZone.nearestEdge(to: point, in: size)
    }
}

/// Four proportional edge zones; an empty slot instead replaces its whole area.
enum PaneDropZone: Equatable {
    case leading
    case trailing
    case top
    case bottom
    case replace

    var placement: (axis: SplitAxis, side: SplitSide)? {
        switch self {
        case .leading: (.horizontal, .before)
        case .trailing: (.horizontal, .after)
        case .top: (.vertical, .before)
        case .bottom: (.vertical, .after)
        case .replace: nil
        }
    }

    func previewRect(in size: CGSize) -> CGRect {
        switch self {
        case .leading: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .trailing: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .replace: CGRect(origin: .zero, size: size)
        }
    }

    static func nearestEdge(to point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .trailing }
        let x = point.x / size.width
        let y = point.y / size.height
        let fromLeading = x
        let fromTrailing = 1 - x
        let fromTop = y
        let fromBottom = 1 - y
        let nearest = min(fromLeading, fromTrailing, fromTop, fromBottom)
        return switch nearest {
        case fromLeading: .leading
        case fromTrailing: .trailing
        case fromTop: .top
        default: .bottom
        }
    }
}
