import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

/// One tab in the tab bar.
///
/// ```
/// ┌────────────────────────┐
/// │ ▣  web-01 · ~/log   ● ×│
/// └────────────────────────┘
/// ```
///
/// A drag *source* and nothing else. Dropping is the strip's job — see
/// `TabBarView` — because the preview it draws is a ghost slot that reflows the
/// whole row, and a target that moves the tabs under the pointer cannot also be
/// one of the tabs being moved.
///
/// Dropping a tab anywhere in the strip reorders it. Building a Workspace means
/// dragging a tab *out* of the strip and onto the edge of a pane; everything a
/// Workspace contains was opened on its own first, so no gesture connects
/// anywhere as a side effect.
struct TabItemView: View {
    let tab: Workspace
    let isSelected: Bool
    /// Written back so `TabBarView` can turn a pointer position into an
    /// insertion index without asking each tab whether the drag is over it.
    @Binding var frame: CGRect

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: tab.symbol)
                .font(.system(size: Metrics.TabBar.iconSize))
                .foregroundStyle(isSelected ? .primary : .secondary)

            if isRenaming {
                TextField("Tab Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .focused($titleFieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
            } else {
                titleStack
            }

            Spacer(minLength: 0)

            trailingControl
        }
        .padding(.horizontal, Metrics.Space.m)
        .frame(
            minWidth: Metrics.TabBar.minTabWidth,
            maxWidth: Metrics.TabBar.maxTabWidth,
            maxHeight: .infinity
        )
        .background(background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
                .opacity(isSelected ? 0 : 1)
        }
        .contentShape(.rect)
        .onTapGesture { window.select(tab.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded(beginRename))
        .onHover { isHovering = $0 }
        .help(Text(tab.title(in: app.hosts)))
        .contextMenu { menu }
        // `onDrag` rather than `draggable`, for the closure: the drop targets have
        // to know what is in flight while it is still in flight. See
        // `WindowModel.dragging`.
        .onDrag {
            window.dragging = .workspace(tab.id)
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(TabBarView.stripSpace))
        } action: {
            frame = $0
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Pieces

    private var titleStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tab.title(in: app.hosts))
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            if let subtitle = tab.subtitle(in: app.hosts) {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    /// The close button replaces the status dot on hover: the dot matters when
    /// you are scanning tabs, the close button when you are pointing at one.
    @ViewBuilder
    private var trailingControl: some View {
        if isHovering {
            Button {
                closeFromClick()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Close tab — ⌥-click to close the others"))
        } else if tab.status != .disconnected || tab.hasUnreadOutput {
            StatusDot(status: tab.status, hasUnread: tab.hasUnreadOutput, size: 6)
                .frame(width: 14)
        } else {
            Color.clear.frame(width: 14, height: 14)
        }
    }

    /// No drop state to draw. Where a drag would land is shown by the ghost slot
    /// the strip opens, not by anything on the tabs themselves.
    @ViewBuilder
    private var background: some View {
        if isSelected {
            Rectangle().fill(.background)
        } else if isHovering {
            Rectangle().fill(.quaternary.opacity(0.5))
        } else {
            Rectangle().fill(.clear)
        }
    }

    @ViewBuilder
    private var menu: some View {
        // Sections carry a trailing divider rather than a leading one, so a menu
        // that opens with Close because everything above it was withheld does
        // not open with a rule instead.
        //
        // Absent rather than greyed for a tab that can never be renamed or
        // split: a manager page has no use for any of it, and dead items are
        // things to read before finding Close. The menu bar keeps its items and
        // disables instead — items that come and go *there* are worse.
        if tab.isRenameable {
            Button("Rename", action: beginRename)
            if namedTitle != nil {
                // Clears whichever store the name actually went to — the pane's
                // for a single-pane tab, the tab's for a Workspace. See
                // `WindowModel.rename`.
                Button("Reset Name") { window.rename(tab.id, to: "") }
            }
            Divider()
        }
        // No Combine item: that is the drag, and a menu listing every other open
        // tab would be a second way to do it that goes stale as tabs close.
        if tab.isCombinable {
            if tab.isSplit {
                // A tab menu points at the whole Workspace, not whichever pane
                // last held the caret. Its one duplicate is therefore another
                // tab with the complete layout.
                Button("Duplicate") { act { window.duplicateSelectedInNewTab() } }
            } else {
                Menu("Duplicate") {
                    Button("In Current Workspace") {
                        act { window.duplicateSelected(axis: .horizontal) }
                    }
                    Button("In New Tab") {
                        act { window.duplicateSelectedInNewTab() }
                    }
                }
            }
            Divider()
            Button("Split Right") { act { window.splitSelected(axis: .horizontal) } }
            Button("Split Down") { act { window.splitSelected(axis: .vertical) } }
            Divider()
        }
        Button("Close Tab") { window.close(tab.id) }
        Button("Close Others") { window.closeOthers(than: tab.id) }
        Button("Close All") { window.closeAll() }
    }

    // MARK: - Actions

    /// The split and duplicate commands act on whatever is selected, so a menu
    /// item on a tab that is not the front one has to select it first. One
    /// definition of "what gets acted on" beats a parallel set of by-id calls.
    private func act(_ action: () -> Void) {
        window.select(tab.id)
        action()
    }

    /// The name the user gave this tab, wherever it is kept.
    private var namedTitle: String? {
        tab.isSplit ? tab.customTitle : tab.focusedPane.customTitle
    }

    /// Guarded here rather than at each caller: the double-click reaches this
    /// directly, and a gesture that silently does nothing is better than a text
    /// field that opens on the Keychain tab and then refuses to keep what you
    /// typed.
    private func beginRename() {
        guard tab.isRenameable else { return }
        draftTitle = tab.title(in: app.hosts)
        isRenaming = true
        titleFieldFocused = true
    }

    private func commitRename() {
        window.rename(tab.id, to: draftTitle)
        isRenaming = false
    }

    /// ⌥-click on the close button closes every *other* tab, matching Safari.
    private func closeFromClick() {
        #if canImport(AppKit)
            if NSEvent.modifierFlags.contains(.option) {
                window.closeOthers(than: tab.id)
                return
            }
        #endif
        window.close(tab.id)
    }
}
