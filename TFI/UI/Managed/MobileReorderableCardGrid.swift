// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

nonisolated enum MobileCardCollection: String, Codable {
    case hosts, snippets, keys, identities, metrics
}

/// Only IDs leave the card; the page token and collection fence off unrelated drop destinations.
nonisolated struct MobileCardDragItem: Codable, Transferable {
    let id: UUID
    let scope: UUID
    let collection: MobileCardCollection

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mobileCardOrder)
            .visibility(.ownProcess)
    }
}

extension UTType {
    nonisolated static let mobileCardOrder = UTType(
        exportedAs: "com.akinokaede.termind.mobile-card-order", conformingTo: .data)
}

extension EnvironmentValues {
    @Entry var mobileCardReorderScope: UUID?
    @Entry var mobileCardDragItem: MobileCardDragItem?
}

struct MobileCardMove: Equatable {
    let id: UUID
    let before: UUID?
}

struct MobileCardReordering {
    let collection: MobileCardCollection
    let allowedIDs: Set<UUID>

    func resolve(
        _ payloads: [MobileCardDragItem], scope: UUID, target: UUID?, orderedIDs: [UUID]
    ) -> MobileCardMove? {
        guard payloads.count == 1, let payload = payloads.first,
            payload.scope == scope, payload.collection == collection, allowedIDs.contains(payload.id)
        else { return nil }
        guard let target else {
            // Section headers append, including empty or folded groups.
            guard orderedIDs.last != payload.id else { return nil }
            return MobileCardMove(id: payload.id, before: nil)
        }
        guard target != payload.id, let targetIndex = orderedIDs.firstIndex(of: target) else { return nil }
        let sourceIndex = orderedIDs.firstIndex(of: payload.id)
        // A forward move inserts after the target; a backward or cross-section move inserts before it.
        let nextIndex = sourceIndex.map { $0 < targetIndex } == true ? targetIndex + 1 : targetIndex
        return MobileCardMove(
            id: payload.id, before: nextIndex < orderedIDs.count ? orderedIDs[nextIndex] : nil)
    }
}

struct MobileReorderableCardGrid<Item: Identifiable, Content: View>: View where Item.ID == UUID {
    let items: [Item]
    var compact = false
    let reordering: MobileCardReordering?
    let move: (UUID, UUID?) -> Void
    @ViewBuilder var content: (Item) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mobileCardReorderScope) private var scope

    var body: some View {
        let ids = items.map(\.id)
        MobileCardGrid(compact: compact) {
            ForEach(items) { item in
                content(item)
                    .environment(\.mobileCardDragItem, dragItem(for: item.id))
                    .modifier(
                        MobileCardDropTarget(
                            reordering: reordering, target: item.id, orderedIDs: ids, move: move))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: ids)
    }

    private func dragItem(for id: UUID) -> MobileCardDragItem? {
        guard let scope, let reordering, reordering.allowedIDs.contains(id) else { return nil }
        return MobileCardDragItem(id: id, scope: scope, collection: reordering.collection)
    }
}

/// Applied beside contextMenu on the button's surface, not as a competing long-press gesture.
struct MobileCardDragSource: ViewModifier {
    @Environment(\.mobileCardDragItem) private var payload

    @ViewBuilder func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}

struct MobileCardDropTarget: ViewModifier {
    let reordering: MobileCardReordering?
    var target: UUID? = nil
    let orderedIDs: [UUID]
    let move: (UUID, UUID?) -> Void
    @Environment(\.mobileCardReorderScope) private var scope
    @State private var isTargeted = false

    @ViewBuilder func body(content: Content) -> some View {
        if let reordering, let scope {
            content
                .overlay {
                    if isTargeted {
                        ContainerRelativeShape()
                            .strokeBorder(.tint, lineWidth: 3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .dropDestination(for: MobileCardDragItem.self) { payloads, _ in
                    guard
                        let request = reordering.resolve(
                            payloads, scope: scope, target: target, orderedIDs: orderedIDs
                        )
                    else { return false }
                    move(request.id, request.before)
                    return true
                } isTargeted: {
                    isTargeted = $0
                }
        } else {
            content
        }
    }
}
