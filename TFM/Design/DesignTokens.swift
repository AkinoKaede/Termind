import AppKit
import SwiftUI
import TermindPresentation

/// Central layout constants. Kept as plain numbers rather than a theme object
/// because none of these need to vary at runtime — only the terminal palette does.
nonisolated enum Metrics {
    /// 4pt base grid. Use these instead of literals so density stays consistent.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 10
    }

    enum Sidebar {
        /// One shared column must be comfortable both as a compact navigator
        /// and as a complete assistant transcript. Because the container never
        /// changes, a user-resized width survives every mode and destination switch.
        static let min: CGFloat = 260
        static let ideal: CGFloat = 320
        static let max: CGFloat = 520
        static let statusDot: CGFloat = 7
        /// Vault and Assistant navigation use one comfortable target so every
        /// destination, chat, archive, and new-chat action keeps a steady rhythm.
        static let navigationRowHeight: CGFloat = 44
        /// Workspaces may carry a secondary pane count or host path.
        static let workspaceRowHeight: CGFloat = navigationRowHeight
        /// Shared content inset for the leading glyph and trailing accessory.
        static let navigationRowInset: CGFloat = 6
        /// One shared breathing edge for every card in the left column.
        /// Keeping it here makes list rows across the app line up.
        static let rowHorizontalMargin: CGFloat = 8
        static let rowBackgroundInset: CGFloat = 0
        static let rowBackgroundVerticalInset: CGFloat = 2
        static let rowCornerRadius: CGFloat = 7
        /// The fixed column every sidebar row's leading glyph sits in.
        ///
        /// Fixed rather than left to `Label`, whose icon takes the symbol's own
        /// width — `apple.terminal`, `wind` and `folder.badge.questionmark` are
        /// three different widths, so a section built from plain `Label`s starts
        /// its titles at three different places. See `SidebarRowLabel`.
        static let rowIcon: CGFloat = 16
        /// The local search field at the foot of the Snippets and History modes.
        ///
        /// One height for every mode, so switching between them does not move
        /// the boundary between the list and its footer.
        static let searchFieldHeight: CGFloat = 36
        /// Two lines and a little air: what a history card needs for a command
        /// and its time, a file and its path, or a host and its login address.
        static let historyCardHeight: CGFloat = 52
        /// The same card while a command is being named as a snippet — the row
        /// grows for the field rather than the field being squeezed into 52pt.
        static let historyCardEditingHeight: CGFloat = 66
    }

    /// The window titlebar, which holds the app's one Find field and the New
    /// control belonging to whatever content is in front.
    enum Toolbar {
        /// Wide enough for a login address or a middling command without
        /// truncating, and narrow enough to leave the titlebar mostly window.
        static let searchFieldWidth: CGFloat = 220
        /// Reserved by every destination, including the ones with nothing to
        /// search. AppKit sizes the titlebar to its tallest item, so a toolbar
        /// that empties out is a titlebar that shrinks — and a window whose
        /// content jumps upward the moment the front destination changes.
        static let height: CGFloat = 24
    }

    /// Splits inside a Workspace. Proportions are stored on the layout tree —
    /// see `SplitNode.Branch` — so all that is left here is what the divider
    /// looks like and how small a pane may get.
    enum Split {
        static let headerIconSize: CGFloat = 12
        static let dividerThickness: CGFloat = 1
        /// The grab band centred over the line without taking layout space.
        /// One point of hairline is not a pointer target, and reserving the whole
        /// band would put an eight-point gutter between every pair of panes.
        static let dividerHitLength: CGFloat = 8
        /// No pane shrinks below this along the split axis.
        static let minPaneLength: CGFloat = 160
        /// The strip a split pane reserves for its name and close button.
        ///
        /// Reserved rather than overlaid: a label floating over a terminal
        /// covers the first line of output, which is usually the line the pane
        /// was opened to read.
        static let headerHeight: CGFloat = 24
    }

    /// Manager pages are card grids rather than tables, so these replace the
    /// per-column widths those used to carry.
    enum Card {
        /// Wide enough for `deploy@10.0.1.5` plus a status dot without wrapping,
        /// which is the narrowest useful host card.
        static let min: CGFloat = 240
        static let max: CGFloat = 380
        /// The tinted rounded square each card leads with.
        static let icon: CGFloat = 30
        /// The floor every tile in a grid shares — the natural height of the
        /// standard two-row card, measured at 79pt and rounded onto the grid.
        ///
        /// `CardGrid` aligns its cells to `.top`, so a card that comes out
        /// shorter than its neighbours hangs off the top of the row and reads as
        /// a gap rather than as a smaller card.
        static let minHeight: CGFloat = 80
    }

    /// The host chooser sheet. Deliberately smaller than a window: it is one
    /// question with one answer, and eight rows is enough to recognise a machine
    /// without turning the panel into a second Hosts page.
    enum HostPicker {
        static let width: CGFloat = 560
        static let height: CGFloat = 520
    }

    /// The window-level command palette raised by Command-P.
    ///
    /// It is deliberately wider than a chooser: command subtitles carry a
    /// destination or connection address, while the short fixed height keeps
    /// the window behind it recognisable as the context the command acts on.
    enum QuickOpen {
        static let width: CGFloat = 640
        static let height: CGFloat = 480
        static let cornerRadius: CGFloat = 24
        static let searchHeight: CGFloat = 58
        static let sectionHeight: CGFloat = 30
        static let rowHeight: CGFloat = 52
        static let footerHeight: CGFloat = 34
        static let iconSize: CGFloat = 30
        static let selectionCornerRadius: CGFloat = 12
    }

    enum Welcome {
        /// Templates, recent/saved hosts, and one-off connections share one
        /// row rhythm even though some carry a second line of detail.
        static let rowHeight: CGFloat = 52
        /// The same artwork footprint for templates, Hosts and one-off
        /// connections. Large enough for a recognisable distribution mark and
        /// its overlaid connection state without making the row feel like a card.
        static let leadingIconSize: CGFloat = 32
    }

    enum StatusBar {
        /// Taller than the docked strip it replaces: a floating capsule needs
        /// enough body to read as an object rather than as a seam.
        static let height: CGFloat = 30
        /// How far a working directory may push the capsule before it
        /// truncates. Wide enough for a deep path, short of covering the pane.
        static let maxWidth: CGFloat = 460
        /// How far the capsule floats above the foot of the pane.
        static let floatingInset: CGFloat = Metrics.Space.l
        /// What anything else anchored to the bottom of a pane — the command
        /// generator, the upload notices — has to clear to sit above it.
        ///
        /// A constant rather than a measurement, and applied whether or not the
        /// capsule is currently showing: a notice that changes height depending
        /// on whether a transfer happens to be running is worse than one that
        /// always sits in the same place.
        static let overlayClearance: CGFloat = height + floatingInset * 2

        static func overlayClearance(isEnabled: Bool) -> CGFloat {
            isEnabled ? overlayClearance : 0
        }
    }

    /// The assistant transcript: message bubbles and the Markdown inside them.
    ///
    /// Turns are separated by space rather than by rules, so `turnSpacing` is
    /// doing the work a `Divider` used to. That is the whole reason it needs to
    /// be noticeably larger than `Space.xl` — at ordinary padding the gap reads
    /// as a wrap, not as a change of speaker.
    enum Chat {
        /// The shared reading column in the full Assistant page.
        ///
        /// Transcript, decision forms and composer use one width so the page
        /// reads as a single conversation rather than three nested columns.
        /// Compact Assistant surfaces continue to use all available width.
        static let contentMaxWidth: CGFloat = 840
        static let turnSpacing: CGFloat = 20
        static let blockSpacing = AssistantTranscriptStyle.blockSpacing
        static let bubbleRadius = AssistantTranscriptStyle.bubbleRadius
        /// Sent images are center-cropped thumbnails rather than variable-height
        /// rows, so a batch reads as one compact grid.
        static let imageTile: CGFloat = 160
        static let compactImageTile: CGFloat = 104
        /// The composer is one inset object containing context, draft and controls.
        static let composerRadius: CGFloat = 18
        /// The narrowest the empty column beside a user bubble may get.
        ///
        /// A fixed gutter rather than a percentage width: it needs no
        /// `GeometryReader`, and the bubble still hugs its content instead of
        /// being stretched to a share of the column.
        static let gutter: CGFloat = 56
        /// The same idea at 260pt, where 56 would leave a bubble two words wide.
        static let compactGutter: CGFloat = 24
        /// The leading rule on a block quote and on expanded tool output.
        static let rule: CGFloat = 2
        /// The draft editor's floor and ceiling.
        ///
        /// `TextEditor` has no content-based ideal height — left alone it takes
        /// every point it is offered, so a `maxHeight` alone made an empty
        /// composer stand at its maximum with the caret marooned at the top and
        /// a hand's width of nothing under it. The height is measured from the
        /// draft instead; these two bound the result.
        static let composerMinHeight: CGFloat = 48
        /// Sidebar composers keep their denser one-line floor.
        static let compactComposerMinHeight: CGFloat = 40
        static let composerMaxHeight: CGFloat = 180
        static let compactComposerMaxHeight: CGFloat = 140
        /// The whole empty surface, including its toolbar and insets.
        static let composerSurfaceMinHeight: CGFloat = 110
        static let compactComposerSurfaceMinHeight: CGFloat = 102

        /// How much of the steering queue is shown before it scrolls.
        ///
        /// A ceiling, not a height — the strip is measured from its rows and
        /// only reaches this with four or five of them waiting. Queuing that
        /// much at a working agent is possible but rare, and this is a reminder
        /// of what is waiting, not a second transcript to read.
        static let steeringQueueMaxHeight: CGFloat = 88

        /// The Slash palette keeps the compact native-list density it had before
        /// moving to SwiftUI. It is exactly as tall as its rows until ten are
        /// visible; longer command and option lists scroll in place.
        static let slashMenuRowHeight: CGFloat = 34
        static let slashMenuVisibleRows = 10

        static func slashMenuHeight(rowCount: Int) -> CGFloat {
            CGFloat(min(max(0, rowCount), slashMenuVisibleRows)) * slashMenuRowHeight
        }

        /// How much of a collapsed plan is shown before it fades out.
        ///
        /// About four lines — enough for a `## Goal` heading and the sentence
        /// under it, which is the part that decides whether the rest is worth
        /// opening. A plan is long by construction, so this is what keeps a row
        /// in the transcript from becoming the transcript.
        static let planPreviewHeight: CGFloat = 96

    }

    enum TransferCenter {
        static let width: CGFloat = 360
        static let estimatedRowHeight: CGFloat = 104
        static let maxListHeight: CGFloat = 420

        static func listHeight(itemCount: Int) -> CGFloat {
            let count = max(0, itemCount)
            return min(maxListHeight, CGFloat(count) * estimatedRowHeight + CGFloat(max(0, count - 1)))
        }
    }

    enum VaultContent {
        static let min: CGFloat = 280
        static let splitMinWidth: CGFloat = min + 1 + Metrics.VaultDetail.width
    }

    enum VaultDetail {
        static let width: CGFloat = 320
    }

    enum Window {
        /// Every main page can use this width; multi-column pages adapt their
        /// layout instead of raising the window's minimum when navigating.
        static let detailMin: CGFloat = 360
        static let detailMinHeight: CGFloat = 440

        /// The native sidebar has an outer inset on Liquid Glass; older
        /// systems separate it from the detail column with a one-point divider.
        private static var sidebarSpacing: CGFloat {
            if #available(macOS 26.0, *) { Metrics.Space.m } else { 1 }
        }

        /// Publish the full minimum to the window as well as the detail column.
        /// A detail-only frame constraint can otherwise overflow a narrow window
        /// when the native sidebar reopens.
        static func minWidth(showsSidebar: Bool) -> CGFloat {
            detailMin + (showsSidebar ? Metrics.Sidebar.min + sidebarSpacing : 0)
        }

        /// Preserve a complete reading column beside the sidebar. If its
        /// minimum width no longer fits, the native split view grows the window
        /// when the sidebar opens instead of compressing the Assistant.
        static func sidebarMaxWidth(for availableWidth: CGFloat) -> CGFloat {
            min(
                Metrics.Sidebar.max,
                max(Metrics.Sidebar.min, availableWidth - detailMin - sidebarSpacing)
            )
        }

        /// Root content is a full-height split view. The macOS title bar is
        /// outside this measurement.
        static let minHeight: CGFloat = detailMinHeight
        static let defaultWidth: CGFloat = 1180
        static let defaultHeight: CGFloat = 740
    }
}

/// Termind's complete application color vocabulary.
///
/// These are semantic AppKit colors instead of literal RGB values, so the same
/// view instance can move between Aqua and Dark Aqua without being rebuilt.
/// Feature views should use only the neutral surfaces, the app accent, or the
/// three status roles below. Host labels and terminal ANSI palettes are the two
/// deliberate exceptions because color is user-authored content there.
enum TermindColor {
    // MARK: Surfaces

    static var windowSurface: Color { Color(nsColor: .windowBackgroundColor) }
    static var contentSurface: Color { Color(nsColor: .controlBackgroundColor) }
    static var textSurface: Color { Color(nsColor: .textBackgroundColor) }

    // MARK: Foreground and borders

    static var primaryForeground: Color { Color(nsColor: .labelColor) }
    static var secondaryForeground: Color { Color(nsColor: .secondaryLabelColor) }
    static var selectedForeground: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }
    static var transcriptProminentForeground: Color {
        Color(nsColor: nativeTranscriptProminentForeground)
    }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var shadow: Color { Color(nsColor: .shadowColor) }

    // MARK: Accent and status

    static var accent: Color { .accentColor }
    static var success: Color { Color(nsColor: .systemGreen) }
    static var warning: Color { Color(nsColor: .systemOrange) }
    static var danger: Color { Color(nsColor: .systemRed) }

    static var nativeAccent: NSColor { .controlAccentColor }
    static var nativeTranscriptProminentForeground: NSColor {
        NSColor(name: nil) { appearance in
            resolvedTranscriptProminentForeground(for: appearance)
        }
    }

    static func resolvedTranscriptProminentForeground(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    }

    /// CALayer stores a concrete `CGColor`; assigning a named dynamic NSColor
    /// directly can resolve it against the wrong appearance (or to clear while
    /// inside a vibrant source list). Always resolve through the owning view.
    static func resolvedNative(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }
}

/// The one selection highlight in the app.
///
/// Derived from the text color rather than the accent, and with no emphasized /
/// unemphasized pair — a row looks the same whether or not its container is the
/// key responder. That is the whole reason selection is drawn by hand in this
/// app instead of by `List(selection:)`, which flips between accent blue and a
/// faint gray as focus moves. See `SidebarRow` and `HostChooserView`'s explicit
/// keyboard cursor.
enum Highlight {
    static func fill(isSelected: Bool, isHovering: Bool = false) -> Color {
        if isSelected {
            TermindColor.accent.opacity(0.14)
        } else if isHovering {
            .primary.opacity(0.05)
        } else {
            .clear
        }
    }
}

/// One system-adaptive surface for the app's floating controls and cards.
///
/// macOS 26 supplies the real Liquid Glass renderer. The deployment target is
/// still macOS 15, where a native material is the honest fallback: it preserves
/// translucency and accessibility settings without trying to paint a fake
/// highlight gradient that can never respond like system glass.
private struct TermindGlassShape<Shape: InsettableShape>: ViewModifier {
    let shape: Shape
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(isInteractive),
                in: shape
            )
        } else {
            content
                .background {
                    shape.fill(.regularMaterial)
                    if let tint {
                        shape.fill(tint)
                    }
                }
                .overlay {
                    shape
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

private struct TermindGlassBar: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect)
        } else {
            content.background(.bar)
        }
    }
}

/// Native material fallback for systems before Liquid Glass.
struct LegacySidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        Self.configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        Self.configure(view)
    }

    static func configure(_ view: NSVisualEffectView) {
        view.material = .windowBackground
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
    }
}

/// A quiet, neutral selection matching the sidebar's glass controls. Both
/// active and inactive windows keep readable foreground content on a gray fill.
///
/// The row's context menu is drawn here rather than by the caller, and it is a
/// native menu rather than SwiftUI's: `contextMenu` derives its source rectangle
/// from the frame of the view it is attached to, which for a sidebar row is the
/// card *plus* the breathing edge around it — a visibly oversized box. AppKit
/// draws no source rectangle, so the outline below can sit exactly on the filled
/// shape, tight to the card.
struct TermindSidebarRowBackground: ViewModifier {
    let isSelected: Bool
    let menu: (() -> [NativeMenuEntry])?

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovering = false
    @State private var isMenuPresented = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(
                SidebarSelectionStyle.foreground(
                    isSelected: isSelected,
                    controlActiveState: controlActiveState,
                    unselected: AnyShapeStyle(.primary)
                )
            )
            .fontWeight(isSelected ? .semibold : .regular)
            .background { backgroundFill }
            .overlay { menuHost }
            .overlay { menuOutline }
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalMargin)
            .onHover { isHovering = $0 }
    }

    /// The one inset the fill, the right-click target and the outline all share,
    /// so a right-clicked row lights up exactly the card the user aimed at.
    private func cardInsets<V: View>(_ view: V) -> some View {
        view
            .padding(.horizontal, Metrics.Sidebar.rowBackgroundInset)
            .padding(.vertical, Metrics.Sidebar.rowBackgroundVerticalInset)
    }

    @ViewBuilder
    private var menuHost: some View {
        if let menu {
            cardInsets(
                NativeRowContextMenu(entries: menu, isPresented: $isMenuPresented)
            )
        }
    }

    @ViewBuilder
    private var menuOutline: some View {
        if isMenuPresented {
            cardInsets(
                RoundedRectangle(cornerRadius: Metrics.Sidebar.rowCornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )
            .allowsHitTesting(false)
        }
    }

    private var backgroundFill: some View {
        cardInsets(
            RoundedRectangle(cornerRadius: Metrics.Sidebar.rowCornerRadius)
                .fill(fillColor)
        )
    }

    private var fillColor: Color {
        if isSelected {
            SidebarSelectionStyle.background(controlActiveState: controlActiveState)
        } else {
            Highlight.fill(isSelected: false, isHovering: isHovering)
        }
    }
}

enum SidebarSelectionStyle {
    static func background(controlActiveState: ControlActiveState) -> Color {
        Color.primary.opacity(controlActiveState == .key ? 0.10 : 0.06)
    }

    static func foreground(
        isSelected: Bool,
        controlActiveState: ControlActiveState,
        unselected: AnyShapeStyle
    ) -> AnyShapeStyle {
        guard controlActiveState == .key else { return AnyShapeStyle(.secondary) }
        return isSelected ? AnyShapeStyle(.primary) : unselected
    }

    static func iconForeground(
        isSelected: Bool,
        controlActiveState: ControlActiveState
    ) -> AnyShapeStyle {
        if controlActiveState == .key { return AnyShapeStyle(TermindColor.accent) }
        return foreground(
            isSelected: isSelected,
            controlActiveState: controlActiveState,
            unselected: AnyShapeStyle(.primary)
        )
    }
}

private struct TermindSidebarSectionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

extension View {
    func termindGlassSurface(
        cornerRadius: CGFloat = Metrics.Radius.large,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            TermindGlassShape(
                shape: RoundedRectangle(cornerRadius: cornerRadius),
                tint: tint,
                isInteractive: isInteractive
            ))
    }

    func termindGlassCapsule(
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            TermindGlassShape(
                shape: Capsule(), tint: tint, isInteractive: isInteractive
            ))
    }

    func termindGlassCircle(
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            TermindGlassShape(
                shape: Circle(), tint: tint, isInteractive: isInteractive
            ))
    }

    func termindGlassBar() -> some View {
        modifier(TermindGlassBar())
    }

    func termindSidebarRowBackground(isSelected: Bool) -> some View {
        modifier(TermindSidebarRowBackground(isSelected: isSelected, menu: nil))
    }

    /// The same row, with a native right-click menu and an outline that hugs
    /// the card. Prefer this over a separate `.contextMenu`, which would draw a
    /// source rectangle around the row's whole frame — margin included.
    func termindSidebarRow(
        isSelected: Bool,
        menu: @escaping () -> [NativeMenuEntry]
    ) -> some View {
        modifier(TermindSidebarRowBackground(isSelected: isSelected, menu: menu))
    }

    func termindSidebarSectionLabel() -> some View {
        modifier(TermindSidebarSectionLabel())
    }
}

enum Motion {
    static let workspaceSwitch = Animation.easeOut(duration: 0.12)
    static let panel = Animation.smooth(duration: 0.22)
    static let dropTarget = Animation.spring(duration: 0.28, bounce: 0.16)

    static func panel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : panel
    }

    static func dropTarget(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : dropTarget
    }
}
