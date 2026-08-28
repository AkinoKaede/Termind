import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

/// Type-erased selection hooks used by `CardPage`'s background drag gesture.
/// Pages keep their strongly typed selection; the grid only needs stable IDs to
/// compare card frames with the marquee rectangle.
struct CardMarqueeSelection {
    let selected: () -> Set<AnyHashable>
    let update: (Set<AnyHashable>) -> Void
}

private enum CardSelectionCoordinateSpace {
    nonisolated static let name = "Termind.CardSelection"
}

/// Geometry used only by pointer gestures does not belong in SwiftUI state.
/// Publishing every card through a preference and then assigning the aggregate
/// to `@State` makes scrolling a layout feedback loop: moving a lazy-grid cell
/// changes the preference, the state write redraws the page, and the preference
/// is evaluated again in the same display frame. A page-owned reference keeps
/// the latest hit-test geometry without invalidating layout.
private final class CardGeometryStore {
    private var cardFrames: [AnyHashable: (reporter: UUID, frame: CGRect)] = [:]
    private var cardIDsByReporter: [UUID: AnyHashable] = [:]
    private var latestCardFrames: [UUID: CGRect] = [:]
    private var interactiveFrames: [UUID: CGRect] = [:]

    func updateCardFrame(_ frame: CGRect, id: AnyHashable?, reporter: UUID) {
        latestCardFrames[reporter] = frame
        updateCardID(id, reporter: reporter)
    }

    func updateCardID(_ id: AnyHashable?, reporter: UUID) {
        if let previousID = cardIDsByReporter[reporter], previousID != id,
            cardFrames[previousID]?.reporter == reporter
        {
            cardFrames.removeValue(forKey: previousID)
        }

        guard let id, let frame = latestCardFrames[reporter] else {
            cardIDsByReporter.removeValue(forKey: reporter)
            return
        }
        cardIDsByReporter[reporter] = id
        cardFrames[id] = (reporter, frame)
    }

    func removeCardFrame(reporter: UUID) {
        latestCardFrames.removeValue(forKey: reporter)
        guard let id = cardIDsByReporter.removeValue(forKey: reporter) else { return }
        if cardFrames[id]?.reporter == reporter {
            cardFrames.removeValue(forKey: id)
        }
    }

    func updateInteractiveFrame(_ frame: CGRect, reporter: UUID) {
        interactiveFrames[reporter] = frame
    }

    func removeInteractiveFrame(reporter: UUID) {
        interactiveFrames.removeValue(forKey: reporter)
    }

    func card(at point: CGPoint) -> Bool {
        cardFrames.values.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    func interactiveChrome(at point: CGPoint) -> Bool {
        interactiveFrames.values.contains {
            $0.insetBy(dx: -1, dy: -1).contains(point)
        }
    }

    func cardIDs(intersecting rect: CGRect) -> Set<AnyHashable> {
        Set(cardFrames.compactMap { id, value in value.frame.intersects(rect) ? id : nil })
    }
}

private struct CardGeometryStoreKey: EnvironmentKey {
    static let defaultValue: CardGeometryStore? = nil
}

private extension EnvironmentValues {
    var cardGeometryStore: CardGeometryStore? {
        get { self[CardGeometryStoreKey.self] }
        set { self[CardGeometryStoreKey.self] = newValue }
    }
}

/// The shared shape of every manager page, modelled on Rayon: a scrolling page of
/// titled sections, each one a grid of cards.
///
/// Cards rather than a table because these pages answer "which one do I want",
/// not "sort these by column". A card can show a name, an address, a status dot,
/// and two lines of detail in the space a table spends on one column, it reflows
/// instead of truncating when the Sidebar widens, and it gives the primary
/// action — connect, insert, start — somewhere obvious to live.
///
/// The outer stack is deliberately *not* lazy, and turning it back into a
/// `LazyVStack` reintroduces a real bug. A lazy stack estimates the height of the
/// rows it has not built yet, which is fine while the content is static and wrong
/// the moment a section collapses: scrolled to the bottom, most sections above
/// are estimates, and folding one leaves the rest drawn at stale offsets. Its
/// children are sections — a handful even on a large fleet — so measuring them
/// all costs nothing. The laziness that matters is one level down, in `CardGrid`,
/// where the hundreds of cards are.
struct CardPage<Content: View>: View {
    var marqueeSelection: CardMarqueeSelection? = nil
    /// Native item drags (`onDrag`) and a page-wide `DragGesture` both want the
    /// same pointer stream on macOS. Pages with draggable cards disable the
    /// marquee recognizer so AppKit can start its drag session reliably; Shift
    /// click remains available for extending the selection.
    var supportsMarqueeSelection = true
    /// What right-clicking the canvas offers, given where the pointer is. The
    /// page's cards keep their own menus; this only answers for the space
    /// between them, which is where creating a new one now lives.
    var blankAreaMenu: ((CGPoint) -> [NativeMenuEntry])? = nil
    @ViewBuilder var content: Content

    @State private var geometryStore = CardGeometryStore()
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBase: Set<AnyHashable> = []
    @State private var marqueeExtendsSelection = false
    @State private var dragStartedOnCard = false

    var body: some View {
        Group {
            if supportsMarqueeSelection {
                pageScroll.simultaneousGesture(marqueeGesture)
            } else {
                pageScroll
            }
        }
        .overlay {
            if let marqueeRect {
                RoundedRectangle(cornerRadius: Metrics.Radius.small)
                    .fill(Color.accentColor.opacity(0.10))
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1)
                    .frame(width: marqueeRect.width, height: marqueeRect.height)
                    .position(x: marqueeRect.midX, y: marqueeRect.midY)
                    .allowsHitTesting(false)
            }
        }
        .overlay { blankAreaMenuHost }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    /// Declines every point occupied by a card or by a section header, so those
    /// keep the menus they already have and only the canvas answers here.
    @ViewBuilder
    private var blankAreaMenuHost: some View {
        if let blankAreaMenu {
            NativeBlankAreaMenu(
                claims: { point in
                    !geometryStore.card(at: point)
                        && !geometryStore.interactiveChrome(at: point)
                },
                entries: blankAreaMenu
            )
        }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                content
            }
            .padding(Metrics.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.cardGeometryStore, geometryStore)
        }
        .coordinateSpace(name: CardSelectionCoordinateSpace.name)
        .simultaneousGesture(backgroundTapGesture)
    }

    /// A page-level spatial tap can distinguish the canvas from a card without
    /// competing with the card's own tap recognizer. The card keeps its click;
    /// the unoccupied canvas clears the page selection.
    private var backgroundTapGesture: some Gesture {
        SpatialTapGesture(coordinateSpace: .named(CardSelectionCoordinateSpace.name))
            .onEnded { value in
                guard let marqueeSelection else { return }
                let hitCard = geometryStore.card(at: value.location)
                let hitInteractiveChrome = geometryStore.interactiveChrome(at: value.location)
                if !hitCard && !hitInteractiveChrome { marqueeSelection.update([]) }
            }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(CardSelectionCoordinateSpace.name))
            .onChanged { value in
                guard let marqueeSelection else { return }

                if marqueeStart == nil {
                    marqueeStart = value.startLocation
                    marqueeCurrent = value.location
                    marqueeBase = marqueeSelection.selected()
                    marqueeExtendsSelection = Self.shiftIsPressed
                    // A card drag belongs to the card. Marquee selection starts
                    // only in the page's empty space, matching Finder.
                    dragStartedOnCard = geometryStore.card(at: value.startLocation)
                }

                guard !dragStartedOnCard else { return }
                marqueeCurrent = value.location
                guard let marqueeRect else { return }

                let enclosed = geometryStore.cardIDs(intersecting: marqueeRect)
                marqueeSelection.update(
                    marqueeExtendsSelection ? marqueeBase.union(enclosed) : enclosed
                )
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBase.removeAll()
                marqueeExtendsSelection = false
                dragStartedOnCard = false
            }
    }

    private var marqueeRect: CGRect? {
        guard !dragStartedOnCard, let marqueeStart, let marqueeCurrent else { return nil }
        return CGRect(
            x: min(marqueeStart.x, marqueeCurrent.x),
            y: min(marqueeStart.y, marqueeCurrent.y),
            width: abs(marqueeCurrent.x - marqueeStart.x),
            height: abs(marqueeCurrent.y - marqueeStart.y)
        )
    }

    private static var shiftIsPressed: Bool {
        #if canImport(AppKit)
            NSEvent.modifierFlags.contains(.shift)
        #else
            false
        #endif
    }
}

/// A titled group of cards. The count sits in the header because a section that
/// scrolled off the bottom is otherwise indistinguishable from an empty one.
struct CardSection<Content: View>: View {
    /// A plain `String`, not a `LocalizedStringKey`: half these headers are group
    /// names the user typed, and running those through the catalogue would be
    /// wrong. Static headers pass `String(localized:)`, which still extracts.
    let title: String
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            CardSectionHeader(title: title, count: count)
            CardGrid { content }
        }
    }
}

/// The title row a section leads with, on its own so a section whose header does
/// something — a group, which can be collapsed, selected, renamed, deleted — can
/// reuse it instead of drawing a second one that has to be kept looking alike.
///
/// Every interactive part is optional and off by default, so the plain sections
/// on Keychain, Snippets and the rest render exactly as they did.
struct CardSectionHeader: View {
    /// A plain `String` for the same reason as `CardSection.title`: half of
    /// these are names the user typed.
    let title: String
    var count: Int?
    /// `nil` means no disclosure triangle — the section cannot be collapsed.
    var toggle: (() -> Void)?
    var isCollapsed = false
    var select: (() -> Void)?
    var isSelected = false
    /// A host card is currently over this section and can be filed here.
    var isDropTarget = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            if let toggle {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isCollapsed ? "Expand" : "Collapse"))
            }

            Text(title)
                .font(.headline)

            if let count {
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.Space.s)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: .capsule)
            }
        }
        .padding(.horizontal, select == nil ? 0 : Metrics.Space.s)
        .padding(.vertical, select == nil ? 0 : Metrics.Space.xs)
        // Same fill as `SidebarRow`, and fixed for the same reason: derived from
        // the text color rather than the accent, so it does not change with the
        // accent or with which view happens to hold focus.
        .background(fill, in: .rect(cornerRadius: Metrics.Radius.medium))
        .contentShape(.rect(cornerRadius: Metrics.Radius.medium))
        .onTapGesture { select?() }
        .cardInteractiveFrame()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [])
    }

    private var fill: Color {
        if isDropTarget {
            Color.accentColor.opacity(0.16)
        } else if select == nil {
            .clear
        } else if isSelected {
            .primary.opacity(0.10)
        } else if isHovering {
            .primary.opacity(0.05)
        } else {
            .clear
        }
    }
}

/// Marks controls that sit in the card canvas but are not selectable cards.
/// A click on one should perform that control, not also look like a click on
/// empty space and clear the page selection.
private struct CardInteractiveFrameModifier: ViewModifier {
    @Environment(\.cardGeometryStore) private var geometryStore
    @State private var reporterID = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(CardSelectionCoordinateSpace.name))
            } action: { frame in
                geometryStore?.updateInteractiveFrame(frame, reporter: reporterID)
            }
            .onDisappear {
                geometryStore?.removeInteractiveFrame(reporter: reporterID)
            }
    }
}

private struct CardFrameModifier: ViewModifier {
    let selectionID: AnyHashable?

    @Environment(\.cardGeometryStore) private var geometryStore
    @State private var reporterID = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(CardSelectionCoordinateSpace.name))
            } action: { newFrame in
                geometryStore?.updateCardFrame(
                    newFrame,
                    id: selectionID,
                    reporter: reporterID
                )
            }
            .onChange(of: selectionID) {
                geometryStore?.updateCardID(selectionID, reporter: reporterID)
            }
            .onDisappear {
                geometryStore?.removeCardFrame(reporter: reporterID)
            }
    }
}

extension View {
    fileprivate func cardInteractiveFrame() -> some View {
        modifier(CardInteractiveFrameModifier())
    }
}

/// The grid itself. Adaptive columns, so the same page works at 600pt with the
/// Sidebar widened and at 1600pt on an external display.
struct CardGrid<Content: View>: View {
    @ViewBuilder var content: Content

    private let columns = [
        GridItem(
            .adaptive(minimum: Metrics.Card.min, maximum: Metrics.Card.max),
            spacing: Metrics.Space.l,
            alignment: .top
        )
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.Space.l) {
            content
        }
    }
}

/// One card.
///
/// Single click selects, double click activates — the Finder contract, and the
/// one every list in this app already follows. Two `onTapGesture`s rather than a
/// `Button`: a button would swallow the double click and give back a control
/// that cannot be selected without also being triggered.
struct CardTile<Content: View>: View {
    var selectionID: AnyHashable? = nil
    var isSelected: Bool = false
    var select: () -> Void = {}
    var extendSelection: (() -> Void)?
    var activate: (() -> Void)?
    var activatesOnReturn = false
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.Space.l)
            // A floor rather than a height: the two-row card this page is built
            // around already measures 80pt, so this changes nothing today. It is
            // here so a card that loses a row — a host with no tags, a future
            // one-line tile — still sits level with its neighbours.
            .frame(minHeight: Metrics.Card.minHeight, alignment: .top)
            .background(
                isHovering && !isSelected ? Color.primary.opacity(0.035) : .clear,
                in: .rect(cornerRadius: Metrics.Radius.large)
            )
            .termindGlassSurface(
                cornerRadius: Metrics.Radius.large,
                tint: isSelected ? Color.accentColor.opacity(0.16) : nil,
                isInteractive: true
            )
            // Nothing a card holds may paint outside the card. Clipped here
            // rather than trusted to each page, because the failure is silent
            // until it isn't: one subtitle that will not compress and the text
            // draws over the neighbouring tile. The border below survives the
            // clip — `strokeBorder` insets, so the stroke is inside the shape.
            .clipShape(.rect(cornerRadius: Metrics.Radius.large))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.large)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(.rect(cornerRadius: Metrics.Radius.large))
            .modifier(
                CardTapModifier(
                    select: select,
                    extendSelection: extendSelection,
                    activate: activate
                )
            )
            .focusable(activatesOnReturn && activate != nil)
            .onKeyPress(.return) {
                guard activatesOnReturn, let activate else { return .ignored }
                activate()
                return .handled
            }
            .modifier(CardFrameModifier(selectionID: selectionID))
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
    }

}

/// A selection-only card has no double-click recognizer at all. Besides making
/// one click immediate in Keychain, this avoids turning two clicks into a
/// special selection gesture. Host cards opt into the second recognizer because
/// their double click has a distinct meaning: Connect.
private struct CardTapModifier: ViewModifier {
    let select: () -> Void
    let extendSelection: (() -> Void)?
    let activate: (() -> Void)?

    func body(content: Content) -> some View {
        if let activate {
            content
                .onTapGesture(count: 2, perform: activate)
                .onTapGesture(perform: performSelection)
        } else {
            content.onTapGesture(perform: performSelection)
        }
    }

    private func performSelection() {
        #if canImport(AppKit)
            if NSEvent.modifierFlags.contains(.shift), let extendSelection {
                extendSelection()
                return
            }
        #endif
        select()
    }
}

/// The tinted rounded square a card leads with. Gives every page the same
/// left-hand rhythm whatever it is listing.
struct CardIcon: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.Radius.medium)
            .fill(tint.opacity(0.16))
            .frame(width: Metrics.Card.icon, height: Metrics.Card.icon)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
    }
}

/// A one-word capsule: a tag, an algorithm, a transfer state.
struct CardChip: View {
    let text: String
    var symbol: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: Metrics.Space.xxs) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(foreground)
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, 2)
        .background(fill, in: .capsule)
        .lineLimit(1)
    }

    private var foreground: AnyShapeStyle {
        if let tint { AnyShapeStyle(tint) } else { AnyShapeStyle(.secondary) }
    }

    private var fill: AnyShapeStyle {
        if let tint {
            AnyShapeStyle(tint.opacity(0.14))
        } else {
            AnyShapeStyle(.quaternary.opacity(0.6))
        }
    }
}
