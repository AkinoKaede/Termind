import AppKit
import SwiftUI

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
        /// Keeping it here makes SwiftUI List and ListViewKit rows line up.
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

    /// Settings is a page in the window rather than its own panel, so it needs a
    /// reading width of its own — a `Form` stretched across a 1600pt display puts
    /// the label and its control at opposite ends of the desk.
    enum SettingsPage {
        static let sidebarWidth: CGFloat = 208
        static let contentWidth: CGFloat = 720
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
        static let blockSpacing: CGFloat = 10
        static let bubbleRadius: CGFloat = 14
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
        static let codeInset: CGFloat = 10
        /// The leading rule on a block quote and on expanded tool output.
        static let rule: CGFloat = 2
        /// The caret shown while a reply is still arriving.
        static let caretWidth: CGFloat = 2
        static let caretHeight: CGFloat = 16

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

        /// How tall the slash palette may grow before it scrolls.
        ///
        /// Also a ceiling rather than a height: the palette is measured from the
        /// commands that match, so it shrinks to one row as the name is typed
        /// and closes when nothing matches. With today's three commands it never
        /// reaches this — it exists so a longer list later cannot cover the
        /// conversation it was opened over.
        static let slashMenuMaxHeight: CGFloat = 220

        /// How much of a collapsed plan is shown before it fades out.
        ///
        /// About four lines — enough for a `## Goal` heading and the sentence
        /// under it, which is the part that decides whether the rest is worth
        /// opening. A plan is long by construction, so this is what keeps a row
        /// in the transcript from becoming the transcript.
        static let planPreviewHeight: CGFloat = 96

        /// How much of the task list is shown before it scrolls.
        ///
        /// Taller than the steering strip because this one is read rather than
        /// glanced at — it is the answer to "what is left" — but still a ceiling
        /// measured from the rows, so a three-item list is three items tall.
        static let taskListMaxHeight: CGFloat = 160

        /// How wide the hovered task list is.
        ///
        /// Narrow on purpose. It hangs off a capsule a few characters wide, and
        /// a panel spanning the conversation would read as a new region rather
        /// than as that capsule opening. Task titles are short phrases.
        ///
        /// Two values because an overlay is proposed its *parent's* size — the
        /// capsule's, which is tiny — so this cannot be a `maxWidth` that adapts
        /// on its own. The compact figure is what fits inside a 260pt sidebar
        /// once the composer's own insets are taken off.
        static let taskListWidth: CGFloat = 320
        static let compactTaskListWidth: CGFloat = 232

    }

    enum TransferCenter {
        static let width: CGFloat = 360
        static let maxListHeight: CGFloat = 420
    }

    enum VaultContent {
        static let min: CGFloat = 420
        static let ideal: CGFloat = 680
    }

    enum VaultDetail {
        static let min: CGFloat = 340
        static let ideal: CGFloat = 460
        static let max: CGFloat = 720
    }

    enum Window {
        /// The detail column's own floors. The window-level values below add
        /// the chrome that sits beside or above it; keeping the two concepts
        /// separate prevents layout floors from being counted twice.
        static let detailMin: CGFloat = 320
        static let detailMinHeight: CGFloat = 440

        /// Space to the right of the navigation sidebar in Vault's complete
        /// working layout: two dividers, the main surface, and an Edit/New
        /// detail panel.
        static let trailingContentMinWidth: CGFloat = 1
            + Metrics.VaultContent.min
            + 1
            + Metrics.VaultDetail.min

        /// Vault's complete working layout sets the application floor: the
        /// navigation sidebar, main surface, and an Edit/New detail panel, plus
        /// the two dividers between them. Reserving the third column even while
        /// it is closed prevents opening an editor inside an already-too-narrow
        /// window and keeps every host form usable from the moment it appears.
        static let minWidth: CGFloat = Metrics.Sidebar.min + trailingContentMinWidth

        /// The sidebar may use only width left after the complete Vault work
        /// area has been reserved. It grows with the window, but never outside
        /// its own usability bounds.
        static func sidebarMaxWidth(for availableWidth: CGFloat) -> CGFloat {
            min(
                Metrics.Sidebar.max,
                max(Metrics.Sidebar.min, availableWidth - trailingContentMinWidth)
            )
        }

        /// Root content is a full-height split view. The macOS title bar is
        /// outside this measurement.
        static let minHeight: CGFloat = detailMinHeight
        static let defaultWidth: CGFloat = 1180
        static let defaultHeight: CGFloat = 740
    }
}

/// The one selection highlight in the app.
///
/// Derived from the text color rather than the accent, and with no emphasized /
/// unemphasized pair — a row looks the same whether or not its container is the
/// key responder. That is the whole reason selection is drawn by hand in this
/// app instead of by `List(selection:)`, which flips between accent blue and a
/// faint gray as focus moves. See `SidebarRow` and `HostChooserRow`.
enum Highlight {
    static func fill(isSelected: Bool, isHovering: Bool = false) -> Color {
        if isSelected {
            .accentColor.opacity(0.14)
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
private struct TermindGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(isInteractive),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.regularMaterial)
                    if let tint {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(tint)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

private struct TermindGlassCapsule: ViewModifier {
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(isInteractive),
                in: .capsule
            )
        } else {
            content
                .background {
                    Capsule().fill(.regularMaterial)
                    if let tint { Capsule().fill(tint) }
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

private struct TermindGlassCircle: ViewModifier {
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(tint).interactive(isInteractive),
                in: .circle
            )
        } else {
            content
                .background {
                    Circle().fill(.regularMaterial)
                    if let tint { Circle().fill(tint) }
                }
                .overlay {
                    Circle()
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

/// The Liquid Glass surface shared by every mode of the left column.
///
/// `NavigationSplitView` supplies the column geometry, but the custom AppKit
/// lists inside it do not inherit SwiftUI's source-list background. Hosting one
/// system glass surface behind the complete column keeps list rows and empty
/// space on one coherent material, including behind the window titlebar.
struct SidebarGlassBackground: View {
    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect)
        } else {
            LegacySidebarMaterialBackground()
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

/// A native-feeling emphasized selection: the key window uses an accent fill
/// with reversed content, while an inactive window keeps the same destination
/// legible with a quiet accent wash and accent-colored content.
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
            .foregroundStyle(SidebarSelectionStyle.foreground(
                isSelected: isSelected,
                controlActiveState: controlActiveState,
                unselected: AnyShapeStyle(.primary)
            ))
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
            controlActiveState == .key ? .accentColor : .accentColor.opacity(0.14)
        } else {
            Highlight.fill(isSelected: false, isHovering: isHovering)
        }
    }
}

enum SidebarSelectionStyle {
    static func foreground(
        isSelected: Bool,
        controlActiveState: ControlActiveState,
        unselected: AnyShapeStyle
    ) -> AnyShapeStyle {
        guard isSelected else { return unselected }
        return controlActiveState == .key ? AnyShapeStyle(.white) : AnyShapeStyle(.tint)
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
        modifier(TermindGlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            isInteractive: isInteractive
        ))
    }

    func termindGlassCapsule(
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(TermindGlassCapsule(tint: tint, isInteractive: isInteractive))
    }

    func termindGlassCircle(
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(TermindGlassCircle(tint: tint, isInteractive: isInteractive))
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
    static let statusPulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    static func panel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : panel
    }
}
