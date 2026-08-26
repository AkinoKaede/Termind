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
        /// changes, a user-resized width survives every mode and tab switch.
        static let min: CGFloat = 260
        static let ideal: CGFloat = 320
        static let max: CGFloat = 520
        /// Color stripe on the leading edge of a host row.
        static let stripeWidth: CGFloat = 2.5
        static let statusDot: CGFloat = 7
        /// Vault and Assistant navigation use one comfortable target so every
        /// destination, chat, archive, and new-chat action keeps a steady rhythm.
        static let navigationRowHeight: CGFloat = 36
        /// Shared content inset for the leading glyph and trailing accessory.
        static let navigationRowInset: CGFloat = 8
        /// The fixed column every sidebar row's leading glyph sits in.
        ///
        /// Fixed rather than left to `Label`, whose icon takes the symbol's own
        /// width — `apple.terminal`, `wind` and `folder.badge.questionmark` are
        /// three different widths, so a section built from plain `Label`s starts
        /// its titles at three different places. See `SidebarRowLabel`.
        static let rowIcon: CGFloat = 16
    }

    enum TabBar {
        static let height: CGFloat = 34
        /// A titled tab never becomes narrower than this. The selected
        /// Workspace keeps this floor while its neighbours continue down to
        /// `compactTabWidth`.
        static let titledTabMinWidth: CGFloat = 120
        /// Icon + one spacing unit + the status/close slot + horizontal padding.
        static let compactTabWidth: CGFloat = 48
        static let maxTabWidth: CGFloat = 240
        static let iconSize: CGFloat = 12
    }

    /// Splits inside a Workspace. Proportions are stored on the layout tree —
    /// see `SplitNode.Branch` — so all that is left here is what the divider
    /// looks like and how small a pane may get.
    enum Split {
        static let dividerThickness: CGFloat = 1
        /// The grab band around the line. One point of hairline is not a pointer
        /// target, and thickening the line itself would put a grey bar between
        /// every pair of panes.
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
        /// Named because `AddCardTile` has to match it. Left to itself that tile
        /// is one line of text in some padding, which came out 32pt shorter than
        /// the cards beside it and made every row it sat in look ragged.
        static let minHeight: CGFloat = 80
    }

    /// The host chooser sheet. Deliberately smaller than a window: it is one
    /// question with one answer, and eight rows is enough to recognise a machine
    /// without turning the panel into a second Hosts page.
    enum HostPicker {
        static let width: CGFloat = 560
        static let height: CGFloat = 520
    }

    /// The small "make one now" sheets a picker raises — a new identity, a new
    /// group. Narrower than the host chooser: three fields and no list to scan,
    /// so the extra width would only stretch the text fields.
    enum CreateSheet {
        static let width: CGFloat = 400
    }

    /// The provider and MCP editors, which are a different animal from
    /// `CreateSheet`: each holds a form *and* a list — dozens of fetched models,
    /// or a server's discovered tools — and 400pt cannot show a model's name
    /// beside its capabilities without one of them truncating.
    ///
    /// A fixed height rather than sizing to content, so the sheet does not jump
    /// when a fetch turns two models into sixty.
    enum EditorSheet {
        static let width: CGFloat = 680
        static let height: CGFloat = 640
        /// The master column of the model list. Wide enough for a full model id
        /// at caption size, which is what you scan by.
        static let listWidth: CGFloat = 236
    }

    /// Settings is a page in the window rather than its own panel, so it needs a
    /// reading width of its own — a `Form` stretched across a 1600pt display puts
    /// the label and its control at opposite ends of the desk.
    enum SettingsPage {
        static let sidebarWidth: CGFloat = 208
        static let contentWidth: CGFloat = 720
    }

    /// The Hosts page's tag filter popover. Narrow because it holds one word per
    /// row, and scrolling beats a panel that runs off the bottom of the window
    /// once a fleet has twenty tags.
    enum TagFilter {
        static let width: CGFloat = 220
        static let maxListHeight: CGFloat = 260
    }

    enum StatusBar {
        static let height: CGFloat = 22
    }

    /// The assistant transcript: message bubbles and the Markdown inside them.
    ///
    /// Turns are separated by space rather than by rules, so `turnSpacing` is
    /// doing the work a `Divider` used to. That is the whole reason it needs to
    /// be noticeably larger than `Space.xl` — at ordinary padding the gap reads
    /// as a wrap, not as a change of speaker.
    enum Chat {
        /// The shared reading column in the full Assistant tab.
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
        /// The column a list marker sits in, so a wrapped second line aligns
        /// under the text rather than under the bullet.
        static let markerColumn: CGFloat = 20
        static let codeInset: CGFloat = 10
        static let tableCellPadding: CGFloat = 6
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
        static let max: CGFloat = 1_000
    }

    enum VaultDetail {
        static let min: CGFloat = 340
        static let ideal: CGFloat = 460
        static let max: CGFloat = 720
    }

    enum Window {
        /// The detail column's own floors. The window-level values below add
        /// the chrome that sits beside or above it; keeping the two concepts
        /// separate prevents accidentally counting the tab strip twice.
        static let detailMin: CGFloat = 320
        static let detailMinHeight: CGFloat = 440

        /// Vault's complete working layout sets the application floor: the
        /// navigation sidebar, main surface, and an Edit/New detail panel, plus
        /// the two dividers between them. Reserving the third column even while
        /// it is closed prevents opening an editor inside an already-too-narrow
        /// window and keeps every host form usable from the moment it appears.
        static let minWidth: CGFloat = Metrics.Sidebar.min
            + 1
            + Metrics.VaultContent.min
            + 1
            + Metrics.VaultDetail.min

        /// Root content includes the pinned tab strip and its divider above the
        /// detail floor. The macOS title bar is outside this measurement.
        static let minHeight: CGFloat = Metrics.TabBar.height + 1 + detailMinHeight
        static let defaultWidth: CGFloat = 1180
        static let defaultHeight: CGFloat = 740
    }
}

/// The native title-bar surface around the traffic-light controls.
///
/// The title bar deliberately uses an exact light/dark pair rather than a
/// semantic color or material. That keeps the traffic-light corner neutral as
/// windows move around the desktop.
enum WindowChrome {
    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .black : .white
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
            .primary.opacity(0.10)
        } else if isHovering {
            .primary.opacity(0.05)
        } else {
            .clear
        }
    }
}

enum Motion {
    static let tabSwitch = Animation.easeOut(duration: 0.12)
    static let panel = Animation.smooth(duration: 0.22)
    static let statusPulse = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    static func panel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : panel
    }
}
