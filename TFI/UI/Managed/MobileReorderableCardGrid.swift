// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

nonisolated enum MobileCardCollection: String, Codable {
    case hosts, snippets, keys, identities, metrics
}

nonisolated struct MobileCardDragItem: Codable, Transferable {
    let id: UUID
    let scope: UUID
    let collection: MobileCardCollection

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mobileCardOrder).visibility(.ownProcess)
    }
}

extension UTType {
    nonisolated static let mobileCardOrder = UTType(
        exportedAs: "com.akinokaede.termind.mobile-card-order", conformingTo: .data)
}

extension EnvironmentValues {
    @Entry var mobileCardReorderSession: MobileCardReorderSession?
    @Entry var mobileCardIsDragPreview = false
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
            guard orderedIDs.last != payload.id else { return nil }
            return MobileCardMove(id: payload.id, before: nil)
        }
        guard target != payload.id, let targetIndex = orderedIDs.firstIndex(of: target) else { return nil }
        let sourceIndex = orderedIDs.firstIndex(of: payload.id)
        let nextIndex = sourceIndex.map { $0 < targetIndex } == true ? targetIndex + 1 : targetIndex
        return MobileCardMove(
            id: payload.id, before: nextIndex < orderedIDs.count ? orderedIDs[nextIndex] : nil)
    }
}

struct MobileCardSectionID: Hashable {
    let collection: MobileCardCollection
    var group: UUID?
}

/// Reordering is a presentation transaction. Hover never writes to the library or sync store.
@Observable @MainActor
final class MobileCardReorderSession {
    struct Placement: Equatable {
        let section: MobileCardSectionID
        let before: UUID?
    }

    let scope = UUID()
    private(set) var payload: MobileCardDragItem?
    private(set) var placement: Placement?
    private(set) var size = CGSize.zero
    @ObservationIgnored private var original: Placement?
    @ObservationIgnored private var pendingMove: ((UUID, UUID?) -> Void)?
    @ObservationIgnored lazy var interaction = MobileCardDragInteraction(owner: self)

    func begin(id: UUID, section: MobileCardSectionID, orderedIDs: [UUID], size: CGSize) {
        guard payload == nil, let index = orderedIDs.firstIndex(of: id) else { return }
        payload = MobileCardDragItem(id: id, scope: scope, collection: section.collection)
        self.size = size
        original = Placement(section: section, before: orderedIDs.dropFirst(index + 1).first)
        placement = original
    }

    func projectedIDs(_ ids: [UUID], in section: MobileCardSectionID) -> [UUID] {
        guard let payload, let placement, payload.collection == section.collection else { return ids }
        var result = ids.filter { $0 != payload.id }
        if placement.section == section {
            let index = placement.before.flatMap { result.firstIndex(of: $0) } ?? result.count
            result.insert(payload.id, at: index)
        }
        return result
    }

    @discardableResult
    func stage(_ request: MobileCardMove, in section: MobileCardSectionID, move: @escaping (UUID, UUID?) -> Void)
        -> Bool
    {
        guard request.id == payload?.id, section.collection == payload?.collection else { return false }
        let next = Placement(section: section, before: request.before)
        guard next != placement else { return false }
        placement = next
        pendingMove = move
        return true
    }

    func commit() {
        guard let payload, let placement else { return }
        let move = placement != original ? pendingMove : nil
        let id = payload.id
        let before = placement.before
        clear()
        move?(id, before)
    }

    func cancel() { clear() }

    private func clear() {
        payload = nil
        placement = nil
        original = nil
        pendingMove = nil
    }
}

struct MobileReorderableCardGrid<Item: Identifiable, Content: View>: View where Item.ID == UUID {
    let items: [Item]
    var compact = false
    var sectionID: UUID?
    let reordering: MobileCardReordering?
    let move: (UUID, UUID?) -> Void
    @ViewBuilder var content: (Item) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.self) private var environment
    @Environment(\.mobileCardReorderSession) private var session

    var body: some View {
        let ids = items.map(\.id)
        let section = reordering.map { MobileCardSectionID(collection: $0.collection, group: sectionID) }
        let projected = section.flatMap { session?.projectedIDs(ids, in: $0) } ?? ids
        MobileCardGrid(compact: compact) {
            ForEach(projected, id: \.self) { id in
                if session?.payload?.id == id {
                    MobileCardReorderPlaceholder(height: session?.size.height ?? 0)
                        .background {
                            region(id: id, section: section, ids: projected, preview: nil)
                        }
                } else if let item = items.first(where: { $0.id == id }) {
                    content(item)
                        .background {
                            region(
                                id: id, section: section, ids: projected,
                                preview: AnyView(content(item).environment(\.self, environment)))
                        }
                }
            }
        }
        .animation(reduceMotion ? nil : MobileCardDragAppearance.animation, value: projected)
        .onChange(of: ids) { _, _ in
            // An external delete/reorder invalidates the draft rather than overwriting newer data.
            session?.cancel()
        }
    }

    @ViewBuilder private func region(
        id: UUID, section: MobileCardSectionID?, ids: [UUID], preview: AnyView?
    ) -> some View {
        if let session, let reordering, let section {
            MobileCardDragRegion(
                session: session, section: section, target: id, orderedIDs: ids, reordering: reordering,
                preview: preview, move: move)
        }
    }
}

struct MobileCardDropTarget: ViewModifier {
    let reordering: MobileCardReordering?
    var sectionID: UUID?
    var isExpanded = true
    var compact = false
    let orderedIDs: [UUID]
    let move: (UUID, UUID?) -> Void
    @Environment(\.mobileCardReorderSession) private var session

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content.background {
                if let session, let reordering {
                    MobileCardDragRegion(
                        session: session,
                        section: MobileCardSectionID(collection: reordering.collection, group: sectionID),
                        target: nil, orderedIDs: orderedIDs, reordering: reordering,
                        preview: nil, move: move)
                }
            }
            if !isExpanded, let session, let reordering, let payload = session.payload,
                session.placement?.section == MobileCardSectionID(collection: reordering.collection, group: sectionID)
            {
                // Reserve an insertion slot without persisting the group's expansion state.
                MobileCardGrid(compact: compact) {
                    MobileCardReorderPlaceholder(height: session.size.height)
                        .background {
                            MobileCardDragRegion(
                                session: session,
                                section: MobileCardSectionID(collection: reordering.collection, group: sectionID),
                                target: payload.id, orderedIDs: orderedIDs, reordering: reordering,
                                preview: nil, move: move)
                        }
                }
            }
        }
        .onChange(of: orderedIDs) { _, _ in session?.cancel() }
    }
}

private struct MobileCardReorderPlaceholder: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

enum MobileCardDragAppearance {
    static var cornerRadius: CGFloat { if #available(iOS 26, *) { 20 } else { 10 } }
    static let animation = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)
}
