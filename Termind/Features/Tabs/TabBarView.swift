import SwiftUI
import UniformTypeIdentifiers

/// The tab strip above the detail column.
///
/// Hand-drawn rather than using native window tabs: tab contents are
/// heterogeneous (terminal / files / chat / forwards) and each needs its own
/// icon, connection dot, and unread marker, none of which `NSWindow` tabs can
/// show. Native window merging (⇧⌘M) still works — that is the *window* layer,
/// which is orthogonal to this one.
///
/// The strip owns every drop that lands on it, rather than each tab owning its
/// own. Two reasons, and they are the same reason twice: the preview is a ghost
/// slot that pushes the neighbouring tabs apart, and a target that moves the
/// tabs under the pointer cannot also *be* one of the tabs it moves — per-tab
/// `dropEntered`/`dropExited` would fight the reflow and flicker. One target
/// spanning the strip has no enter and exit to fight with, and it covers the
/// empty space past the last tab for free.
///
/// A tab dropped here is reordered; a pane dropped here is lifted out into a tab
/// of its own. Neither ever merges — merging is dragging a tab *out* of the
/// strip and onto the edge of a pane. See `WindowModel.merge`.
struct TabBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    /// Where the ghost slot is standing, as an index into `displayedTabs`.
    /// Nil whenever the pointer is not over the strip.
    @State private var ghostIndex: Int?
    /// Each tab's frame in the strip's coordinate space, which is how a pointer
    /// position becomes an insertion index. Reported by `TabItemView`.
    @State private var tabFrames: [Workspace.ID: CGRect] = [:]

    /// Named so the tabs and the drop delegate measure against the same origin.
    ///
    /// `nonisolated` because `TabItemView` reads it inside the `onGeometryChange`
    /// transform, which is a `Sendable` closure and cannot touch main-actor
    /// state — and a coordinate space name is a constant string, not state.
    nonisolated static let stripSpace = "termind.tabStrip"

    var body: some View {
        HStack(spacing: 0) {
            PinnedTopLevelTabItem(
                title: "Vault", symbol: "lock.square.stack",
                isSelected: window.selectedTopLevelTab == .vault,
                action: window.selectVault
            )
            PinnedTopLevelTabItem(
                title: "Chat", symbol: "sparkles",
                isSelected: window.selectedTopLevelTab == .chat,
                action: { window.selectChat() }
            )
            Divider()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        // Iterate the real collection so the `TabItemView` that
                        // started an AppKit drag stays mounted until that drag
                        // ends. Removing the source cancels the native session
                        // before a pane can receive `dropEntered`.
                        ForEach(window.tabs) { tab in
                            let isDragged = draggedWorkspaceID == tab.id
                            let displayedIndex = displayedTabs.firstIndex { $0.id == tab.id }

                            if let displayedIndex, ghostIndex == displayedIndex { ghost }
                            TabItemView(
                                tab: tab,
                                // Follow the tab that is actually in front. While
                                // the selected Workspace is being dragged, its
                                // neighbour temporarily becomes the merge target
                                // and should look active too.
                                isSelected: tab.id == window.displayedTab?.id,
                                frame: binding(for: tab)
                            )
                            .id(tab.id)
                            // Leave the drag-source view alive while making its
                            // slot behave as though the tab had already left.
                            .frame(width: isDragged ? 0 : nil)
                            .opacity(isDragged ? 0 : 1)
                            .clipped()
                            .allowsHitTesting(!isDragged)
                            .accessibilityHidden(isDragged)
                        }
                        if ghostIndex == displayedTabs.count { ghost }
                    }
                    .animation(Motion.tabSwitch, value: ghostIndex)
                }
                .coordinateSpace(.named(Self.stripSpace))
                // On the ScrollView rather than its content, so the target spans
                // the whole strip — including the gap past the last tab, which
                // is where a pane goes to become the last tab.
                .onDrop(
                    of: [.text],
                    delegate: StripDropDelegate(
                        window: window,
                        index: { insertionIndex(at: $0) },
                        ghostIndex: $ghostIndex
                    )
                )
                .onChange(of: window.selectedTabID) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.tabSwitch) { proxy.scrollTo(id) }
                }
            }

            Divider()
            newTabMenu
            batchStartupButton
            overflowMenu
        }
        .frame(height: Metrics.TabBar.height)
        .background(.regularMaterial)
    }

    /// The strip drawn without the tab in flight, the same way
    /// `TabContentView.displayedLayout` draws a Workspace without the pane in
    /// flight — what you are looking at is the arrangement you would get.
    ///
    /// Everything downstream works in this list's coordinates: the ghost index,
    /// `insertionIndex`, and `WindowModel.move(_:to:)`. Dropping the tab back on
    /// the strip has to land where the ghost stood, and the ghost stands in a
    /// list this tab has already left.
    ///
    /// A pane drag removes no tab, so for panes the two lists are identical.
    private var displayedTabs: [Workspace] {
        guard let id = draggedWorkspaceID else { return window.tabs }
        return window.tabs.filter { $0.id != id }
    }

    private var draggedWorkspaceID: Workspace.ID? {
        guard case .workspace(let id)? = window.dragging else { return nil }
        return id
    }

    private func binding(for tab: Workspace) -> Binding<CGRect> {
        Binding(
            get: { tabFrames[tab.id] ?? .zero },
            set: { tabFrames[tab.id] = $0 }
        )
    }

    /// How many displayed tabs sit left of the pointer — which is where the
    /// ghost stands, and where the drop lands.
    ///
    /// Stable under the ghost's own reflow: opening a slot at *k* only pushes the
    /// tabs at and after *k* further right, and those were already right of the
    /// pointer. So the count cannot change under itself, and the preview does not
    /// oscillate between two positions while the pointer holds still.
    private func insertionIndex(at location: CGPoint) -> Int {
        displayedTabs.reduce(into: 0) { count, tab in
            guard let frame = tabFrames[tab.id], frame.midX < location.x else { return }
            count += 1
        }
    }

    /// The slot that opens where the drop will land.
    ///
    /// It carries the icon and name of whatever is in flight, because for a pane
    /// the answer to "what lands here" is a thing that does not exist yet — a new
    /// tab holding that pane. An insertion line can say where; only this can say
    /// what. Dashed and translucent, which is the language `EmptyPaneView`
    /// already uses for a space waiting to be filled.
    @ViewBuilder
    private var ghost: some View {
        if let (symbol, title) = draggedIdentity {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: Metrics.TabBar.iconSize))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Metrics.Space.m)
            .frame(width: Metrics.TabBar.minTabWidth)
            .frame(maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.12))
            .overlay {
                Rectangle()
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var draggedIdentity: (symbol: String, title: String)? {
        switch window.dragging {
        case .pane(let id):
            guard let pane = window.pane(id) else { return nil }
            return (pane.symbol, pane.sidebarTitle(in: app.hosts))
        case .workspace(let id):
            guard let tab = window.tabs.first(where: { $0.id == id }) else { return nil }
            return (tab.symbol, tab.title(in: app.hosts))
        case nil:
            return nil
        }
    }

    /// Every drop the strip takes, for both payloads.
    ///
    /// A `DropDelegate` rather than `dropDestination`, for the reason the pane
    /// area's is one: the ghost has to follow the pointer while the drag is still
    /// live, and `isTargeted` is a single Bool that cannot say *where*.
    private struct StripDropDelegate: DropDelegate {
        let window: WindowModel
        let index: (CGPoint) -> Int
        @Binding var ghostIndex: Int?

        func validateDrop(info: DropInfo) -> Bool {
            window.dragging?.isLayoutPayload == true
        }

        func dropEntered(info: DropInfo) {
            ghostIndex = index(info.location)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            ghostIndex = index(info.location)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            ghostIndex = nil
        }

        /// Reads what is in flight from the model rather than the pasteboard,
        /// which would resolve one drop too late — see `WindowModel.dragging`.
        func performDrop(info: DropInfo) -> Bool {
            let landed = index(info.location)
            ghostIndex = nil
            let dragged = window.dragging
            switch dragged {
            case .pane(let id): window.detachPane(id, at: landed)
            case .workspace(let id): window.move(id, to: landed)
            case nil: return false
            }
            // A pane stays absent from its source layout until it has reached
            // the new tab. Restoring the drag state first creates two transient
            // parents for one persistent native terminal.
            window.dragging = nil
            return true
        }
    }

    private var newTabMenu: some View {
        Menu {
            // No keyboard shortcuts here — TermindCommands owns them, and declaring
            // them twice makes AppKit pick one arbitrarily.
            // Same order as the File menu, so the two lists of the same four
            // verbs cannot be read as two different lists.
            Button("Connect") { app.connect(in: window) }
            Button("New Chat") { window.openChat() }
            Button("New Host") { window.openHostEditor(host: nil) }

            let recents = app.hosts.recents(limit: 5)
            if !recents.isEmpty {
                Divider()
                Section("Recent") {
                    ForEach(recents) { host in
                        Button(host.name) { app.open(host, as: .sshSession, in: window) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            app.connect(in: window)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32)
        .help(Text("New tab"))
    }

    /// Opens the multi-host chooser without hiding this frequent action in the
    /// new-tab menu. `wind` is also the symbol used by the chooser itself.
    private var batchStartupButton: some View {
        Button {
            app.batchStartup(in: window)
        } label: {
            Image(systemName: "wind")
        }
        .buttonStyle(.borderless)
        .frame(width: 28)
        .help(Text("Batch Startup"))
        .accessibilityLabel(Text("Batch Startup"))
    }

    /// Lists every tab, including ones scrolled out of sight — the only way to
    /// reach tab 14 when nine fit on screen.
    private var overflowMenu: some View {
        Menu {
            Button {
                window.selectVault()
            } label: {
                Label("Vault", systemImage: "lock.square.stack")
            }
            Button {
                window.selectChat()
            } label: {
                Label("Chat", systemImage: "sparkles")
            }
            if !window.tabs.isEmpty { Divider() }
            ForEach(window.tabs) { tab in
                Button {
                    window.select(tab.id)
                } label: {
                    Label(tab.title(in: app.hosts), systemImage: tab.symbol)
                }
            }
            if window.canReopen {
                Divider()
                Button("Reopen Closed Tab") { window.reopenLastClosed() }
            }
        } label: {
            Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .disabled(window.tabs.isEmpty && !window.canReopen)
        .help(Text("All tabs"))
    }
}

private struct PinnedTopLevelTabItem: View {
    let title: LocalizedStringKey
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: Metrics.TabBar.iconSize))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, Metrics.Space.m)
            .frame(width: 112)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Rectangle().fill(.background)
            } else if isHovering {
                Rectangle().fill(.quaternary.opacity(0.5))
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 1).opacity(isSelected ? 0 : 1)
        }
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
