import SwiftUI
import UniformTypeIdentifiers

nonisolated private let managedCardDragSpace = "termind.managedCardPage.drag"

/// One homogeneous section in a managed card page. Pages decide what a section
/// means; the renderer only needs stable identity, ordered items and capabilities.
struct ManagedCardSection<SectionID: Hashable, Item: Identifiable>: Identifiable {
    let id: SectionID
    let title: String
    let items: [Item]
    var isExpanded: Bool? = nil
    var canAcceptDrop = true
    var showsWhenEmpty = true
}

/// Strongly typed access to selection owned elsewhere, normally WindowModel.
/// Type erasure is kept inside CardPage's geometry preferences and never leaks
/// into a manager page or its model operations.
struct ManagedCardSelection<ID: Hashable> {
    let selected: () -> Set<ID>
    let update: (Set<ID>) -> Void
}

enum ManagedCardSelectionMode {
    case single
    case multiple
}

enum ManagedCardDropPolicy<SectionID: Hashable> {
    case sameSection
    case anySection
    case custom((SectionID, SectionID) -> Bool)

    func allowsMove(from source: SectionID, to destination: SectionID) -> Bool {
        switch self {
        case .sameSection: source == destination
        case .anySection: true
        case .custom(let predicate): predicate(source, destination)
        }
    }
}

/// The model-facing end of reordering. The renderer resolves a pointer to a
/// destination and next sibling, then hands only stable IDs to this closure.
struct ManagedCardReordering<SectionID: Hashable, ID: Hashable> {
    var isEnabled = true
    var dropPolicy: ManagedCardDropPolicy<SectionID>
    let move: (_ ids: [ID], _ destination: SectionID, _ before: ID?) -> Void
}

struct ManagedCardCapabilities<SectionID: Hashable, ID: Hashable> {
    var selection: ManagedCardSelectionMode = .multiple
    var marqueeSelection = true
    var reordering: ManagedCardReordering<SectionID, ID>?
}

/// Everything a business card needs to know about page-level interaction.
struct ManagedCardItemContext<Item: Identifiable> {
    let isSelected: Bool
    let actionItems: [Item]
    let select: () -> Void
    let extendSelection: () -> Void
}

/// Marker for page-specific sheets, alerts and confirmation dialogs applied by
/// the inherited body after the shared page has been rendered.
protocol ManagedCardPresentationModifier: ViewModifier {}

struct EmptyManagedCardPresentation: ManagedCardPresentationModifier {
    func body(content: Content) -> some View { content }
}

/// SwiftUI's protocol-oriented equivalent of a page base class. Conformers
/// provide data and business views; this protocol extension owns the body.
protocol ManagedCardPage: View {
    associatedtype SectionID: Hashable
    associatedtype Item: Identifiable
    associatedtype CardContent: View
    associatedtype HeaderContent: View
    associatedtype GhostContent: View
    associatedtype SupplementaryContent: View
    associatedtype ToolbarContent: View
    associatedtype EmptyContent: View
    associatedtype NoResultsContent: View
    associatedtype FootnoteContent: View
    associatedtype Presentation: ManagedCardPresentationModifier

    var managedSections: [ManagedCardSection<SectionID, Item>] { get }
    var managedSelection: ManagedCardSelection<Item.ID> { get }
    var managedCapabilities: ManagedCardCapabilities<SectionID, Item.ID> { get }
    var isManagedSourceEmpty: Bool { get }
    /// Whether the renderer should reserve and draw the bottom safe-area inset.
    /// An absent footnote must skip the modifier entirely: an inset containing
    /// `EmptyView` can collapse a nested `ScrollView`'s drawable region on macOS.
    var showsManagedFootnote: Bool { get }
    var managedPresentation: Presentation { get }

    @ViewBuilder func managedCard(
        for item: Item, context: ManagedCardItemContext<Item>
    ) -> CardContent
    @ViewBuilder func managedHeader(
        for section: ManagedCardSection<SectionID, Item>, isDropTarget: Bool
    ) -> HeaderContent
    @ViewBuilder func managedGhost(for item: Item) -> GhostContent
    @ViewBuilder func managedSupplementaryContent(for section: SectionID)
        -> SupplementaryContent
    @ViewBuilder func managedToolbar() -> ToolbarContent
    @ViewBuilder func managedEmptyState() -> EmptyContent
    @ViewBuilder func managedNoResultsState() -> NoResultsContent
    @ViewBuilder func managedFootnote() -> FootnoteContent
}

extension ManagedCardPage {
    var showsManagedFootnote: Bool { false }

    var body: some View {
        ManagedCardPageRenderer<Self>(
            sections: managedSections,
            selection: managedSelection,
            capabilities: managedCapabilities,
            isSourceEmpty: isManagedSourceEmpty,
            showsFootnote: showsManagedFootnote,
            card: managedCard,
            header: managedHeader,
            ghost: managedGhost,
            supplementaryContent: managedSupplementaryContent,
            toolbar: managedToolbar,
            emptyState: managedEmptyState,
            noResultsState: managedNoResultsState,
            footnote: managedFootnote
        )
        .modifier(managedPresentation)
    }
}

struct ManagedCardDropLocation<SectionID: Hashable>: Equatable {
    let section: SectionID
    /// Index after the cards in flight have been removed.
    let index: Int
}

struct ManagedCardDropSection<SectionID: Hashable, ID: Hashable> {
    let id: SectionID
    let frame: CGRect
    let isExpanded: Bool
    let itemIDs: [ID]
}

/// Pure, testable pointer-to-slot calculation. Capability filtering and source
/// omission happen before this boundary; the resolver only understands layout.
enum ManagedCardDropResolver {
    static func location<SectionID: Hashable, ID: Hashable>(
        at point: CGPoint,
        sections: [ManagedCardDropSection<SectionID, ID>],
        itemFrames: [ID: CGRect]
    ) -> ManagedCardDropLocation<SectionID>? {
        guard
            let section = sections.min(by: {
                verticalDistance(from: point.y, to: $0.frame)
                    < verticalDistance(from: point.y, to: $1.frame)
            })
        else { return nil }

        guard section.isExpanded else {
            return ManagedCardDropLocation(section: section.id, index: section.itemIDs.count)
        }
        for (index, id) in section.itemIDs.enumerated() {
            guard let frame = itemFrames[id] else { continue }
            if point.y < frame.minY || (point.y <= frame.maxY && point.x < frame.midX) {
                return ManagedCardDropLocation(section: section.id, index: index)
            }
        }
        return ManagedCardDropLocation(section: section.id, index: section.itemIDs.count)
    }

    private static func verticalDistance(from y: CGFloat, to frame: CGRect) -> CGFloat {
        if y < frame.minY { return frame.minY - y }
        if y > frame.maxY { return y - frame.maxY }
        return 0
    }
}

private struct ManagedCardDragSession<SectionID: Hashable, ID: Hashable> {
    let source: SectionID
    let ids: [ID]
}

/// Generic implementation behind ManagedCardPage's inherited body.
struct ManagedCardPageRenderer<Page: ManagedCardPage>: View {
    let sections: [ManagedCardSection<Page.SectionID, Page.Item>]
    let selection: ManagedCardSelection<Page.Item.ID>
    let capabilities: ManagedCardCapabilities<Page.SectionID, Page.Item.ID>
    let isSourceEmpty: Bool
    let showsFootnote: Bool
    let card: (Page.Item, ManagedCardItemContext<Page.Item>) -> Page.CardContent
    let header: (ManagedCardSection<Page.SectionID, Page.Item>, Bool) -> Page.HeaderContent
    let ghost: (Page.Item) -> Page.GhostContent
    let supplementaryContent: (Page.SectionID) -> Page.SupplementaryContent
    let toolbar: () -> Page.ToolbarContent
    let emptyState: () -> Page.EmptyContent
    let noResultsState: () -> Page.NoResultsContent
    let footnote: () -> Page.FootnoteContent

    @State private var dragSession: ManagedCardDragSession<Page.SectionID, Page.Item.ID>?
    @State private var omittedIDs: Set<Page.Item.ID> = []
    @State private var ghostLocation: ManagedCardDropLocation<Page.SectionID>?
    @State private var itemFrames: [Page.Item.ID: CGRect] = [:]
    @State private var sectionFrames: [Page.SectionID: CGRect] = [:]

    @ViewBuilder
    var body: some View {
        let page = Group {
            if isSourceEmpty {
                emptyState()
            } else if !hasVisibleContent {
                noResultsState()
            } else {
                collection
            }
        }
        .background(.background)
        .safeAreaInset(edge: .top, spacing: 0) { toolbar() }

        if showsFootnote {
            page.safeAreaInset(edge: .bottom, spacing: 0) { footnote() }
        } else {
            page
        }
    }

    private var hasVisibleContent: Bool {
        sections.contains { !$0.items.isEmpty || $0.showsWhenEmpty }
    }

    private var activeReordering: ManagedCardReordering<Page.SectionID, Page.Item.ID>? {
        guard let reordering = capabilities.reordering, reordering.isEnabled else {
            return nil
        }
        return reordering
    }

    private var collection: some View {
        CardPage(
            marqueeSelection: marqueeSelection,
            supportsMarqueeSelection: capabilities.marqueeSelection
                && activeReordering == nil
        ) {
            ForEach(sections) { section in
                managedSection(section)
            }
        }
        .contentShape(.rect)
        .coordinateSpace(.named(managedCardDragSpace))
        .onDrop(
            of: [.text],
            delegate: ManagedCardDropDelegate(
                isActive: activeReordering != nil,
                location: dropLocation(at:),
                ghostLocation: $ghostLocation,
                perform: performDrop,
                cancel: cancelDrag
            )
        )
        // AppKit does not expose drag-ended to SwiftUI. The next normal click
        // restores a source released outside every valid destination.
        .simultaneousGesture(TapGesture().onEnded(cancelDrag))
    }

    @ViewBuilder
    private func managedSection(
        _ section: ManagedCardSection<Page.SectionID, Page.Item>
    ) -> some View {
        let content = VStack(alignment: .leading, spacing: Metrics.Space.l) {
            header(section, ghostLocation?.section == section.id)

            if section.isExpanded ?? true {
                CardGrid { cards(in: section) }
            }
        }

        if section.canAcceptDrop, activeReordering != nil {
            content.onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(managedCardDragSpace))
            } action: {
                sectionFrames[section.id] = $0
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func cards(
        in section: ManagedCardSection<Page.SectionID, Page.Item>
    ) -> some View {
        let displayed = section.items.filter { !omittedIDs.contains($0.id) }

        ForEach(Array(displayed.enumerated()), id: \.element.id) { index, item in
            if ghostLocation?.section == section.id, ghostLocation?.index == index {
                ghosts
            }
            draggableCard(item, in: section.id)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(managedCardDragSpace))
                } action: {
                    itemFrames[item.id] = $0
                }
        }
        if ghostLocation?.section == section.id, ghostLocation?.index == displayed.count {
            ghosts
        }
        supplementaryContent(section.id)
    }

    @ViewBuilder
    private func draggableCard(_ item: Page.Item, in section: Page.SectionID) -> some View {
        let card = card(item, itemContext(for: item))
        if activeReordering != nil {
            card.onDrag {
                beginDrag(from: item, in: section)
                return NSItemProvider(object: String(describing: item.id) as NSString)
            }
        } else {
            card
        }
    }

    @ViewBuilder
    private var ghosts: some View {
        ForEach(draggedItems) { item in
            ghost(item)
        }
    }

    // MARK: Selection

    private var visibleItems: [Page.Item] { sections.flatMap(\.items) }

    private var selectedIDs: Set<Page.Item.ID> { selection.selected() }

    private var marqueeSelection: CardMarqueeSelection {
        CardMarqueeSelection(
            selected: { Set(selectedIDs.map { AnyHashable($0) }) },
            update: { erased in
                setSelection(Set(erased.compactMap { $0.base as? Page.Item.ID }))
            }
        )
    }

    private func itemContext(for item: Page.Item) -> ManagedCardItemContext<Page.Item> {
        let selected = selectedIDs.contains(item.id)
        let actions =
            selected
            ? visibleItems.filter { selectedIDs.contains($0.id) }
            : [item]
        return ManagedCardItemContext(
            isSelected: selected,
            actionItems: actions,
            select: { setSelection([item.id]) },
            extendSelection: { toggleSelection(item.id) }
        )
    }

    private func toggleSelection(_ id: Page.Item.ID) {
        guard capabilities.selection == .multiple else {
            setSelection([id])
            return
        }
        var updated = selectedIDs
        if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
        setSelection(updated)
    }

    private func setSelection(_ ids: Set<Page.Item.ID>) {
        let valid = ids.intersection(Set(visibleItems.map(\.id)))
        if capabilities.selection == .single {
            selection.update(Set(visibleItems.lazy.filter { valid.contains($0.id) }.prefix(1).map(\.id)))
        } else {
            selection.update(valid)
        }
    }

    // MARK: Reordering

    private var draggedItems: [Page.Item] {
        guard let dragSession else { return [] }
        let wanted = Set(dragSession.ids)
        return visibleItems.filter { wanted.contains($0.id) }
    }

    private func beginDrag(from item: Page.Item, in source: Page.SectionID) {
        guard let reordering = activeReordering else { return }
        let actionItems = itemContext(for: item).actionItems
        let sourceIDs = Set(
            sections.first(where: { $0.id == source })?.items.map(\.id) ?? []
        )
        let items =
            reordering.dropPolicy.allowsMove(from: source, to: source)
                && isFixedSection(policy: reordering.dropPolicy)
            ? actionItems.filter { sourceIDs.contains($0.id) }
            : actionItems
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }

        dragSession = ManagedCardDragSession(source: source, ids: ids)
        ghostLocation = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard dragSession?.ids == ids else { return }
            omittedIDs = Set(ids)
        }
    }

    private func isFixedSection(
        policy: ManagedCardDropPolicy<Page.SectionID>
    ) -> Bool {
        if case .sameSection = policy { return true }
        return false
    }

    private func dropLocation(at point: CGPoint) -> ManagedCardDropLocation<Page.SectionID>? {
        guard let reordering = activeReordering, let dragSession else { return nil }
        let moving = Set(dragSession.ids)
        let candidates = sections.compactMap {
            section -> ManagedCardDropSection<Page.SectionID, Page.Item.ID>? in
            guard section.canAcceptDrop,
                reordering.dropPolicy.allowsMove(from: dragSession.source, to: section.id),
                let frame = sectionFrames[section.id]
            else { return nil }
            return ManagedCardDropSection(
                id: section.id, frame: frame,
                isExpanded: section.isExpanded ?? true,
                itemIDs: section.items.lazy.filter { !moving.contains($0.id) }.map(\.id)
            )
        }
        return ManagedCardDropResolver.location(
            at: point, sections: candidates, itemFrames: itemFrames
        )
    }

    private func performDrop(_ location: ManagedCardDropLocation<Page.SectionID>) {
        guard let reordering = activeReordering, let dragSession,
            let section = sections.first(where: { $0.id == location.section })
        else {
            cancelDrag()
            return
        }
        let moving = Set(dragSession.ids)
        let remaining = section.items.filter { !moving.contains($0.id) }
        let index = min(location.index, remaining.count)
        let next = index < remaining.count ? remaining[index].id : nil
        reordering.move(dragSession.ids, location.section, next)
        cancelDrag()
    }

    private func cancelDrag() {
        dragSession = nil
        omittedIDs.removeAll()
        ghostLocation = nil
    }
}

private struct ManagedCardDropDelegate<SectionID: Hashable>: DropDelegate {
    let isActive: Bool
    let location: (CGPoint) -> ManagedCardDropLocation<SectionID>?
    @Binding var ghostLocation: ManagedCardDropLocation<SectionID>?
    let perform: (ManagedCardDropLocation<SectionID>) -> Void
    let cancel: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isActive && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) { ghostLocation = location(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        ghostLocation = location(info.location)
        return DropProposal(operation: ghostLocation == nil ? .cancel : .move)
    }

    func dropExited(info: DropInfo) { ghostLocation = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let landed = location(info.location) else {
            cancel()
            return false
        }
        perform(landed)
        return true
    }
}
