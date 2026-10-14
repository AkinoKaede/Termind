import SwiftUI
import TermindPresentation

#if canImport(AppKit)
    import AppKit
#endif

/// Type-erased selection hooks used by `CardPage`'s background marquee.
/// Pages keep their strongly typed selection; the grid only needs stable IDs to
/// compare card frames with the marquee rectangle.
struct CardMarqueeSelection {
    let selected: () -> Set<AnyHashable>
    let update: (Set<AnyHashable>) -> Void
}

private enum CardSelectionCoordinateSpace {
    nonisolated static let name = "Termind.CardSelection"
}

/// Pure geometry shared by the AppKit input bridge and unit tests. Keeping the
/// hit policy here ensures a blank click, a marquee start and the visible
/// selection all agree about where cards and controls are.
enum CardMarqueeSelectionResolver {
    static func rectangle(from start: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    static func isBlank(
        _ point: CGPoint,
        cardFrames: [CGRect],
        interactiveFrames: [CGRect]
    ) -> Bool {
        !contains(point, in: cardFrames) && !contains(point, in: interactiveFrames)
    }

    static func selection<ID: Hashable>(
        intersecting rect: CGRect,
        cardFrames: [ID: CGRect],
        base: Set<ID> = [],
        extendsSelection: Bool = false
    ) -> Set<ID> {
        let intersecting = Set(
            cardFrames.compactMap { id, frame in frame.intersects(rect) ? id : nil }
        )
        return extendsSelection ? base.union(intersecting) : intersecting
    }

    private static func contains(_ point: CGPoint, in frames: [CGRect]) -> Bool {
        frames.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }
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

    func isBlank(at point: CGPoint) -> Bool {
        CardMarqueeSelectionResolver.isBlank(
            point,
            cardFrames: cardFrames.values.map(\.frame),
            interactiveFrames: Array(interactiveFrames.values)
        )
    }

    func cardIDs(intersecting rect: CGRect) -> Set<AnyHashable> {
        CardMarqueeSelectionResolver.selection(
            intersecting: rect,
            cardFrames: cardFrames.mapValues(\.frame)
        )
    }
}

private struct CardGeometryStoreKey: EnvironmentKey {
    static let defaultValue: CardGeometryStore? = nil
}

extension EnvironmentValues {
    fileprivate var cardGeometryStore: CardGeometryStore? {
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
    /// Blank-space input is routed through an AppKit overlay that declines hits
    /// over cards, so marquee selection can coexist with native item drags.
    var supportsMarqueeSelection = true
    /// What right-clicking the canvas offers, given where the pointer is. The
    /// page's cards keep their own menus; this only answers for the space
    /// between them, which is where creating a new one now lives.
    var blankAreaMenu: ((CGPoint) -> [NativeMenuEntry])? = nil
    var blankAreaPrimaryAction: (() -> Void)? = nil
    @ViewBuilder var content: Content

    @State private var geometryStore = CardGeometryStore()
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBase: Set<AnyHashable> = []
    @State private var marqueeExtendsSelection = false

    var body: some View {
        pageScroll
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
            .overlay { marqueeInputHost }
            .overlay { blankAreaMenuHost }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TermindColor.windowSurface)
    }

    /// This is deliberately native rather than a SwiftUI `DragGesture`: an
    /// ancestor drag recognizer competes with `onDrag` even when its callback
    /// later discovers that the pointer started on a card. Hit testing here
    /// rejects card and header points before either interaction begins.
    @ViewBuilder
    private var marqueeInputHost: some View {
        if let marqueeSelection {
            NativeCardMarqueeInput(
                allowsDragging: supportsMarqueeSelection,
                claims: geometryStore.isBlank(at:),
                click: {
                    marqueeSelection.update([])
                    blankAreaPrimaryAction?()
                },
                begin: { point, extendsSelection in
                    marqueeStart = point
                    marqueeCurrent = point
                    marqueeBase = marqueeSelection.selected()
                    marqueeExtendsSelection = extendsSelection
                },
                change: { point in
                    marqueeCurrent = point
                    guard let marqueeRect else { return }
                    let intersecting = geometryStore.cardIDs(intersecting: marqueeRect)
                    marqueeSelection.update(
                        marqueeExtendsSelection
                            ? marqueeBase.union(intersecting)
                            : intersecting
                    )
                },
                end: resetMarquee
            )
        }
    }

    /// Declines every point occupied by a card or by a section header, so those
    /// keep the menus they already have and only the canvas answers here.
    @ViewBuilder
    private var blankAreaMenuHost: some View {
        if let blankAreaMenu {
            NativeBlankAreaMenu(
                claims: geometryStore.isBlank(at:),
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
    }

    private var marqueeRect: CGRect? {
        guard let marqueeStart, let marqueeCurrent else { return nil }
        return CardMarqueeSelectionResolver.rectangle(from: marqueeStart, to: marqueeCurrent)
    }

    private func resetMarquee() {
        marqueeStart = nil
        marqueeCurrent = nil
        marqueeBase.removeAll()
        marqueeExtendsSelection = false
    }
}

#if canImport(AppKit)
    /// A transparent left-mouse-only overlay for the canvas between cards.
    /// Once it accepts mouse-down, AppKit keeps subsequent drag/up events routed
    /// here even when the pointer leaves the view bounds.
    private struct NativeCardMarqueeInput: NSViewRepresentable {
        var allowsDragging = true
        var claims: (CGPoint) -> Bool = { _ in true }
        var click: () -> Void = {}
        var begin: (CGPoint, Bool) -> Void = { _, _ in }
        var change: (CGPoint) -> Void = { _ in }
        var end: () -> Void = {}

        func makeNSView(context: Context) -> MarqueeInputView {
            MarqueeInputView()
        }

        func updateNSView(_ view: MarqueeInputView, context: Context) {
            view.allowsDragging = allowsDragging
            view.claims = claims
            view.click = click
            view.begin = begin
            view.change = change
            view.end = end
        }

        static func dismantleNSView(_ view: MarqueeInputView, coordinator: ()) {
            view.cancelTracking()
        }

        @MainActor
        final class MarqueeInputView: NSView {
            var allowsDragging = true
            var claims: (CGPoint) -> Bool = { _ in true }
            var click: () -> Void = {}
            var begin: (CGPoint, Bool) -> Void = { _, _ in }
            var change: (CGPoint) -> Void = { _ in }
            var end: () -> Void = {}

            private var start: CGPoint?
            private var extendsSelection = false
            private var exceededDragThreshold = false
            private var marqueeStarted = false

            override var isFlipped: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? {
                guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
                    !Self.hitsVisibleScroller(event, in: window?.contentView)
                else { return nil }
                let local = convert(point, from: superview)
                guard bounds.contains(local), claims(local) else { return nil }
                return self
            }

            override func mouseDown(with event: NSEvent) {
                start = convert(event.locationInWindow, from: nil)
                extendsSelection = event.modifierFlags.contains(.shift)
                exceededDragThreshold = false
                marqueeStarted = false
            }

            override func mouseDragged(with event: NSEvent) {
                guard let start else { return }
                let current = convert(event.locationInWindow, from: nil)
                if !exceededDragThreshold {
                    exceededDragThreshold = hypot(current.x - start.x, current.y - start.y) >= 5
                }
                guard exceededDragThreshold, allowsDragging else { return }
                if !marqueeStarted {
                    marqueeStarted = true
                    begin(start, extendsSelection)
                }
                change(current)
            }

            override func mouseUp(with event: NSEvent) {
                if marqueeStarted {
                    end()
                } else if !exceededDragThreshold {
                    click()
                }
                clearTracking()
            }

            func cancelTracking() {
                if marqueeStarted { end() }
                clearTracking()
            }

            override func viewWillMove(toWindow newWindow: NSWindow?) {
                if newWindow == nil { cancelTracking() }
                super.viewWillMove(toWindow: newWindow)
            }

            private func clearTracking() {
                start = nil
                extendsSelection = false
                exceededDragThreshold = false
                marqueeStarted = false
            }

            private static func hitsVisibleScroller(_ event: NSEvent, in view: NSView?) -> Bool {
                guard let view, !view.isHidden, view.alphaValue > 0 else { return false }
                if let scroller = view as? NSScroller,
                    scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil))
                {
                    return true
                }
                return view.subviews.contains { hitsVisibleScroller(event, in: $0) }
            }
        }
    }
#endif

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
        Group {
            if select == nil, let toggle {
                Button(action: toggle) { paddedLabel }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(title))
                    .accessibilityHint(Text(isCollapsed ? AppStrings.Common.expand : AppStrings.Common.collapse))
            } else {
                paddedLabel.onTapGesture { select?() }
            }
        }
        // Same fill as `SidebarRow`, and fixed for the same reason: derived from
        // the text color rather than the accent, so it does not change with the
        // accent or with which view happens to hold focus.
        .background(fill, in: .rect(cornerRadius: Metrics.Radius.medium))
        .contentShape(.rect(cornerRadius: Metrics.Radius.medium))
        .cardInteractiveFrame()
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [])
    }

    private var label: some View {
        HStack(spacing: Metrics.Space.s) {
            if let toggle {
                if select == nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                } else {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isCollapsed ? AppStrings.Common.expand : AppStrings.Common.collapse))
                }
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
    }

    private var paddedLabel: some View {
        label
            .padding(.horizontal, isInteractive ? Metrics.Space.s : 0)
            .padding(.vertical, isInteractive ? Metrics.Space.xs : 0)
    }

    private var isInteractive: Bool { select != nil || toggle != nil }

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
    func cardInteractiveFrame() -> some View {
        modifier(CardInteractiveFrameModifier())
    }
}

/// The grid itself. Adaptive columns, so the same page works at 600pt with the
/// Sidebar widened and at 1600pt on an external display.
struct CardGrid<Content: View>: View {
    var minimumWidth: CGFloat = Metrics.Card.min
    var maximumWidth: CGFloat = Metrics.Card.max
    @ViewBuilder var content: Content

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: minimumWidth, maximum: max(minimumWidth, maximumWidth)),
                spacing: Metrics.Space.l,
                alignment: .top
            )
        ]
    }

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
    var activatesOnSingleClick = false
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
                    select: {
                        select()
                        if activatesOnSingleClick { activate?() }
                    },
                    extendSelection: extendSelection,
                    activate: activatesOnSingleClick ? nil : activate
                )
            )
            .focusable(activatesOnReturn && activate != nil)
            .termindInputAwareFocusEffect()
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
