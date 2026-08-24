import SwiftUI

/// Central layout constants. Kept as plain numbers rather than a theme object
/// because none of these need to vary at runtime — only the terminal palette does.
enum Metrics {
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
        /// The sidebar is a page navigator now, not a data list — the widest
        /// thing in it is "Port Forwarding" plus a badge, so it can be narrower
        /// than it was and still never truncate.
        static let min: CGFloat = 180
        static let ideal: CGFloat = 216
        static let max: CGFloat = 300
        /// Color stripe on the leading edge of a host row.
        static let stripeWidth: CGFloat = 2.5
        static let statusDot: CGFloat = 7
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
        static let minTabWidth: CGFloat = 120
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
        static let width: CGFloat = 720
    }

    /// The Hosts page's tag filter popover. Narrow because it holds one word per
    /// row, and scrolling beats a panel that runs off the bottom of the window
    /// once a fleet has twenty tags.
    enum TagFilter {
        static let width: CGFloat = 220
        static let maxListHeight: CGFloat = 260
    }

    enum ContextPanel {
        static let min: CGFloat = 260
        static let ideal: CGFloat = 320
        static let max: CGFloat = 520
    }

    enum StatusBar {
        static let height: CGFloat = 22
    }

    enum TransferCenter {
        static let width: CGFloat = 360
        static let maxListHeight: CGFloat = 420
    }

    enum Window {
        /// The detail column's own floor, applied to the detail `VStack` itself.
        ///
        /// Deliberately *not* summed into a window-level `minWidth`: wrapping a
        /// `NavigationSplitView` in a `.frame` takes the width negotiation away
        /// from the split view, which then lays out at the sum of its columns'
        /// ideal widths and centres that inside the window — clipping the
        /// sidebar on the left and the Context Panel on the right. The window
        /// minimum comes from `.windowResizability(.contentMinSize)` instead,
        /// which reads these three floors through the view tree.
        static let detailMin: CGFloat = 320
        static let minHeight: CGFloat = 440
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
