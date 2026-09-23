import AppKit
import ListViewKit
import SwiftUI
import TermindApplication
import TermindPresentation

nonisolated enum AssistantSidebarEscapePolicy {
    static func shouldCloseConversation(
        hasConversation: Bool,
        hasBlockingInteraction: Bool
    ) -> Bool {
        hasConversation && !hasBlockingInteraction
    }
}

enum AssistantConversationMenuSurface {
    case fullScreen
    case sidebar

    /// New Chat and Show Archive are the Assistant's global verbs, so they stay
    /// live with nothing under the pointer. AppKit asks for this after the click,
    /// so the menu reads the matching surface's current state at that moment.
    func blankAreaMenu(
        in window: WindowModel, locale: Locale
    ) -> [NativeMenuEntry] {
        [
            NativeMenuEntry(
                title: AppLocalization.resolve(AppStrings.Assistant.newChat, locale: locale),
                symbol: MenuSymbol.newChat
            ) {
                window.openNewAssistantChat()
            },
            NativeMenuEntry(
                title: AppLocalization.resolve(AppStrings.Assistant.showArchive, locale: locale),
                symbol: MenuSymbol.archive,
                isOn: isArchivePresented(in: window)
            ) { showArchive(in: window) },
        ]
    }

    private func isArchivePresented(in window: WindowModel) -> Bool {
        window.isAssistantArchivePresented
    }

    private func showArchive(in window: WindowModel) {
        switch self {
        case .fullScreen: window.showAssistantArchive()
        case .sidebar: window.showAssistantArchiveInSidebar()
        }
    }
}

/// Assistant's conversation navigator inside the window's shared sidebar: the
/// chat list, over a bar holding the two things you do to the list itself.
///
/// The bar is the same height as the Snippets and History search footers, so
/// every mode of the column ends at the same line. Its two controls are shaped
/// by what they are: New Chat is a capsule because it is a labelled action that
/// takes the width, and Archived is a circle because it is one glyph that
/// toggles. Both share neutral glass, including the archive's selected state.
struct AssistantSidebarView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
            AssistantConversationList(
                selectedID: window.isAssistantArchivePresented
                    ? nil : window.assistantLibrary.selectedConversationID,
                query: window.assistantQuery,
                menuSurface: .fullScreen,
                onOpen: { window.selectAssistant($0) }
            )

            footer
                .frame(height: Metrics.Sidebar.searchFieldHeight)
                .padding(.horizontal, Metrics.Space.m)
                .padding(.vertical, Metrics.Space.s)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: Metrics.Space.s) {
                footerButtons
            }
        } else {
            footerButtons
        }
    }

    private var footerButtons: some View {
        HStack(spacing: Metrics.Space.s) {
            Button {
                window.openNewAssistantChat()
            } label: {
                Label(AppStrings.Assistant.newChat.swiftUIKey, systemImage: "plus.bubble")
                    .foregroundStyle(.primary)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .center
                    )
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .termindGlassCapsule(isInteractive: true)

            Button {
                window.showAssistantArchive()
            } label: {
                Image(systemName: "archivebox")
                    .foregroundStyle(.primary)
                    .fontWeight(window.isAssistantArchivePresented ? .semibold : .regular)
                    .frame(
                        width: Metrics.Sidebar.searchFieldHeight,
                        height: Metrics.Sidebar.searchFieldHeight
                    )
                    .background {
                        if window.isAssistantArchivePresented {
                            Circle().fill(Color.primary.opacity(0.10))
                        }
                    }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .termindGlassCircle(isInteractive: true)
            .help(Text(AppStrings.Assistant.archived))
            .accessibilityLabel(Text(AppStrings.Assistant.archived))
            .accessibilityAddTraits(window.isAssistantArchivePresented ? .isSelected : [])
        }
    }
}

/// The global Assistant contained entirely in a Workspace sidebar.
///
/// It shares the fixed Assistant destination's Chat/Archive route, while opening
/// a chat here still leaves the user's terminal in the foreground.
struct AssistantPanelView: View {
    @Environment(WindowModel.self) private var window
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !isFocusedOnWorkspace {
                AssistantSidebarView()
                    .transition(.opacity)
                    .zIndex(0)
            }

            workspaceLayer
                .allowsHitTesting(isFocusedOnWorkspace)
                .accessibilityHidden(!isFocusedOnWorkspace)
                .zIndex(1)
        }
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: isFocusedOnWorkspace
        )
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: window.isAssistantArchivePresented
        )
        .clipped()
    }

    @ViewBuilder
    private var workspaceLayer: some View {
        if window.isAssistantArchivePresented {
            AssistantArchiveView(
                isCompact: true,
                isInteractive: isFocusedOnWorkspace,
                onBack: { window.closeAssistantInSidebar() },
                onOpen: { window.openAssistantInSidebar($0) }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .offset(x: isFocusedOnWorkspace ? 0 : Metrics.Space.xxl)
            .opacity(isFocusedOnWorkspace ? 1 : 0)
        } else {
            workspaceAssistantSurface
        }
    }

    private var isFocusedOnWorkspace: Bool {
        if case .workspace = window.selectedDestination { true } else { false }
    }

    private var workspaceAssistantSurface: some View {
        let exitsAsWhole = window.sidebarAssistantConversation != nil
        let dropConversation =
            window.sidebarAssistantConversation
            ?? window.sidebar.assistantDraft
        // Capture this render's state so an Escape which resolves the form
        // cannot fall through to Back after the resolution synchronously
        // removes the pending request.
        let blocksSidebarEscape =
            window.sidebarAssistantConversation.map {
                $0.pendingApproval != nil || $0.pendingUserInteraction != nil
            } ?? false

        return VStack(spacing: 0) {
            Group {
                if let conversation = window.sidebarAssistantConversation {
                    conversationContent(conversation)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    conversationList
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .offset(
                x: !isFocusedOnWorkspace && !exitsAsWhole ? -Metrics.Space.xxl : 0
            )
            .opacity(isFocusedOnWorkspace || exitsAsWhole ? 1 : 0)
            .animation(
                Motion.panel(reduceMotion: reduceMotion),
                value: window.assistantLibrary.selectedConversationID
            )

            interactionSurface
                .offset(
                    y: !isFocusedOnWorkspace && !exitsAsWhole ? Metrics.Space.xxl : 0
                )
                .opacity(isFocusedOnWorkspace || exitsAsWhole ? 1 : 0)
                .animation(nil, value: window.assistantLibrary.selectedConversationID)
        }
        .offset(x: !isFocusedOnWorkspace && exitsAsWhole ? Metrics.Space.xxl : 0)
        .opacity(isFocusedOnWorkspace || !exitsAsWhole ? 1 : 0)
        .conversationAttachmentDropTarget(
            conversation: dropConversation,
            isEnabled: isFocusedOnWorkspace
        )
        .onKeyPress(.escape, phases: .down) { _ in
            guard
                AssistantSidebarEscapePolicy.shouldCloseConversation(
                    hasConversation: window.assistantLibrary.selectedConversationID != nil,
                    hasBlockingInteraction: blocksSidebarEscape
                )
            else { return .ignored }
            window.closeAssistantInSidebar()
            return .handled
        }
    }

    @ViewBuilder
    private var interactionSurface: some View {
        if let conversation = window.sidebarAssistantConversation {
            ConversationView(
                conversation: conversation, isCompact: true, region: .interaction,
                sessionContext: window.sidebar.sessionContext,
                showsTerminalActions: true,
                onNewChat: { window.closeAssistantInSidebar() }
            )
        } else {
            Divider()
            ComposerView(
                conversation: window.sidebar.assistantDraft,
                prompt: AppStrings.Assistant.prompt,
                sessionContext: window.sidebar.sessionContext,
                terminalSuggestionsAvailable: true,
                onSend: {
                    if let conversation = app.sendNewAgentConversation(
                        window.sidebar.assistantDraft, in: window.assistantLibrary,
                        context: window.sidebar.sessionContext,
                        terminalSuggestionsAvailable: true)
                    {
                        window.assistantSidebarConversationDidStart(conversation)
                    }
                }
            )
        }
    }

    private var conversationList: some View {
        AssistantConversationList(
            selectedID: window.assistantLibrary.selectedConversationID,
            isInteractive: isFocusedOnWorkspace,
            menuSurface: .sidebar,
            onOpen: { window.openAssistantInSidebar($0) }
        )
        .overlay {
            if window.assistantLibrary.pinnedConversations.isEmpty,
                window.assistantLibrary.activeConversations.isEmpty
            {
                ContentUnavailableView(
                    AppStrings.Assistant.noConversations.swiftUIKey,
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(AppStrings.Assistant.sendAMessageBelowToStartOne)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func conversationContent(_ conversation: ConversationModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.s) {
                Button {
                    window.closeAssistantInSidebar()
                } label: {
                    Label(AppStrings.Assistant.backToChats.swiftUIKey, systemImage: "arrow.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(Text(AppStrings.Assistant.backToChats))

                Text(conversation.derivedTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    window.openAssistantFullScreen(conversation.id)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(Text(AppStrings.Assistant.openFullScreen))
            }
            .compactAssistantHeader()
            ConversationView(
                conversation: conversation, isCompact: true, region: .transcript,
                sessionContext: window.sidebar.sessionContext,
                showsTerminalActions: true
            )
        }
    }

}

private struct AssistantConversationList: View {
    let selectedID: UUID?
    /// The titlebar Find field. A non-empty query replaces Pinned and Chats
    /// with one flat Results section — when you are hunting for a conversation,
    /// which of the two groups it was filed under is noise.
    var query: String = ""
    /// False for a copy the Assistant panel keeps mounted behind the one on
    /// screen. See `AssistantConversationListContainer.isInteractive`.
    var isInteractive: Bool = true
    let menuSurface: AssistantConversationMenuSurface
    let onOpen: (UUID) -> Void
    var scope: Scope = .active
    var archiveHorizontalPadding: CGFloat = 0

    typealias Scope = AssistantLibraryModel.SearchScope

    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale
    @AppStorage(DesktopSettingsKey.pinnedChatsSectionExpanded) private var pinnedExpanded = true
    @AppStorage(DesktopSettingsKey.chatsSectionExpanded) private var chatsExpanded = true
    @State private var deleteTarget: ConversationModel?
    @State private var renamingID: ConversationModel.ID?
    @State private var renameTitle = ""

    var body: some View {
        content
            .onChange(of: visibleConversationIDs) {
                guard let renamingID, !visibleConversationIDs.contains(renamingID) else { return }
                cancelRename()
            }
            .onChange(of: selectedID) {
                guard case .active = scope,
                    let id = selectedID,
                    let conversation = window.assistantLibrary.conversation(id: id)
                else { return }
                setExpanded(true, for: conversation.isPinned ? .pinned : .chats)
            }
            .alert(
                AppStrings.Assistant.deleteConversationConfirmation.swiftUIKey,
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ), presenting: deleteTarget
            ) { conversation in
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { deleteTarget = nil }
                Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                    window.deleteAssistantConversation(conversation.id)
                    deleteTarget = nil
                }
            } message: { _ in
                Text(AppStrings.Assistant.deleteConversationWarning)
            }
    }

    private var visibleConversationIDs: Set<ConversationModel.ID> {
        switch scope {
        case .active:
            Set(
                (window.assistantLibrary.pinnedConversations
                    + window.assistantLibrary.activeConversations).map(\.id)
            )
        case .archived:
            Set(window.assistantLibrary.archivedConversations.map(\.id))
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var content: some View {
        switch scope {
        case .active:
            activeList
        case .archived:
            archivedList
        }
    }

    private var activeList: some View {
        // Bound here, in `body`, and captured by value from there on. Every
        // closure below is called back from AppKit — a layout pass filling a
        // recycled row, a drag, a right-click — where reading `@Environment`
        // off this struct is not a legal read: it traps with "No Observable
        // object of type WindowModel found". The list is handed the same
        // reference so it can put it back into each row's hosting view.
        let window = window
        let locale = locale

        return AssistantConversationNativeList(
            items: activeItems,
            window: window,
            // Structural changes are not animated while a section is folding.
            // ListViewKit recycles the rows a collapse removes and reconfigures
            // the section header in place; doing that inside the very click
            // that asked for it tears down the Button mid-dispatch.
            animatesStructuralChanges: false,
            draggedID: { isSearching ? nil : Self.draggedConversationID(in: window) },
            onMove: isSearching
                ? nil
                : { id, target in
                    setExpanded(true, for: target.section)
                    window.moveAssistantConversation(
                        id, toPinned: target.section == .pinned, before: target.beforeID
                    )
                    window.dragging = nil
                },
            blankAreaMenu: { menuSurface.blankAreaMenu(in: window, locale: locale) },
            isInteractive: isInteractive
        ) { item in
            renderedItem(item, window: window)
        }
        .background(Color.clear)
    }

    private var archivedList: some View {
        let window = window
        let locale = locale

        return AssistantConversationNativeList(
            items: archivedItems,
            window: window,
            topInset: Metrics.Space.m,
            bottomInset: Metrics.Space.m,
            blankAreaMenu: { menuSurface.blankAreaMenu(in: window, locale: locale) },
            isInteractive: isInteractive
        ) { item in
            renderedItem(item, window: window)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, archiveHorizontalPadding)
        }
        .background(Color.clear)
    }

    private var activeItems: [AssistantConversationListItem] {
        guard !isSearching else {
            return window.assistantLibrary.search(query, scope: .active).map(item)
        }
        var items: [AssistantConversationListItem] = [
            .section(.pinned, count: window.assistantLibrary.pinnedConversations.count)
        ]
        if pinnedExpanded {
            items.append(contentsOf: window.assistantLibrary.pinnedConversations.map(item))
        }
        items.append(
            .section(.chats, count: window.assistantLibrary.activeConversations.count)
        )
        if chatsExpanded {
            items.append(contentsOf: window.assistantLibrary.activeConversations.map(item))
        }
        return items
    }

    private static func draggedConversationID(
        in window: WindowModel
    ) -> ConversationModel.ID? {
        guard case .assistantConversation(let id)? = window.dragging else { return nil }
        return id
    }

    private var archivedItems: [AssistantConversationListItem] {
        window.assistantLibrary.search(query, scope: .archived).map(item)
    }

    private func item(_ conversation: ConversationModel) -> AssistantConversationListItem {
        .conversation(
            id: conversation.id,
            title: conversation.derivedTitle,
            isArchived: conversation.isArchived,
            isPinned: conversation.isPinned,
            isStreaming: conversation.isStreaming,
            isCompacting: conversation.isCompacting,
            isSelected: selectedID == conversation.id,
            isRenaming: renamingID == conversation.id
        )
    }

    @ViewBuilder
    private func renderedItem(
        _ item: AssistantConversationListItem,
        window: WindowModel
    ) -> some View {
        switch item.content {
        case .section(let section, let count):
            AssistantSectionHeaderRow(section: section, count: count)
        case .conversation(let id, _, _, _, _, _, _, _):
            if let conversation = window.assistantLibrary.conversation(id: id) {
                AssistantConversationRow(
                    conversation: conversation,
                    isSelected: selectedID == conversation.id,
                    onOpen: { onOpen(conversation.id) },
                    onDelete: { deleteTarget = conversation },
                    isRenaming: renamingID == conversation.id,
                    renameTitle: Binding(
                        get: { renameTitle },
                        set: { renameTitle = $0 }
                    ),
                    onBeginRename: { beginRename(conversation) },
                    onCommitRename: { commitRename(conversation) },
                    onCancelRename: cancelRename
                )
                .id(conversation.id)
            }
        }
    }

    /// Used when something *other* than the header opens a section — dropping a
    /// conversation into a folded one, or selecting a chat that lives in it.
    /// The header itself toggles its own storage; see `AssistantSectionHeaderRow`.
    private func setExpanded(
        _ expanded: Bool,
        for section: AssistantConversationListItem.Section
    ) {
        switch section {
        case .pinned: pinnedExpanded = expanded
        case .chats: chatsExpanded = expanded
        }
    }

    private func beginRename(_ conversation: ConversationModel) {
        renamingID = conversation.id
        renameTitle = conversation.derivedTitle
    }

    private func commitRename(_ conversation: ConversationModel) {
        guard renamingID == conversation.id else { return }
        let value = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRename()
        guard !value.isEmpty else { return }
        window.renameAssistantConversation(conversation.id, to: value)
    }

    private func cancelRename() {
        renamingID = nil
        renameTitle = ""
    }
}

/// Pinned and Chats, each folding itself.
///
/// The row reads and writes the expansion flag directly instead of being handed
/// one by the list. That is what keeps the click safe: the list item's value
/// never changes when a section folds, so ListViewKit has no reason to
/// reconfigure this row's hosting view — which it would otherwise do while this
/// Button was still dispatching, replacing the root view out from under it.
///
/// The number, the title and the chevron remain one hit region.
private struct AssistantSectionHeaderRow: View {
    let section: AssistantConversationListItem.Section
    let count: Int

    @AppStorage private var isExpanded: Bool

    init(section: AssistantConversationListItem.Section, count: Int) {
        self.section = section
        self.count = count
        _isExpanded = AppStorage(wrappedValue: true, section.expansionKey)
    }

    var body: some View {
        SidebarSectionHeader(
            title: section.title, count: count, height: 34,
            isExpanded: $isExpanded
        )
    }
}

nonisolated struct AssistantConversationListItem: Identifiable, Hashable, Sendable {
    nonisolated enum Section: String, Hashable, Sendable {
        case pinned
        case chats

        var title: LocalizedStringResource {
            switch self {
            case .pinned: AppStrings.Assistant.pinned
            case .chats: AppStrings.Assistant.chats
            }
        }

        /// The header row reads this itself rather than being handed a flag —
        /// see `AssistantSectionHeaderRow`.
        var expansionKey: String {
            switch self {
            case .pinned: DesktopSettingsKey.pinnedChatsSectionExpanded
            case .chats: DesktopSettingsKey.chatsSectionExpanded
            }
        }
    }

    nonisolated enum ID: Hashable, Sendable {
        case section(Section)
        case conversation(UUID)
    }

    nonisolated enum Content: Hashable, Sendable {
        /// Deliberately without an expansion flag. Folding a section would
        /// otherwise change this value, which makes ListViewKit reconfigure the
        /// header's hosting view — replacing the root view of the very Button
        /// that is still dispatching the click. The row owns that state now.
        case section(Section, count: Int)
        case conversation(
            id: UUID,
            title: String,
            isArchived: Bool,
            isPinned: Bool,
            isStreaming: Bool,
            isCompacting: Bool,
            isSelected: Bool,
            isRenaming: Bool
        )
    }

    let id: ID
    let content: Content

    static func section(_ section: Section, count: Int = 0) -> Self {
        .init(id: .section(section), content: .section(section, count: count))
    }

    static func conversation(
        id: UUID,
        title: String,
        isArchived: Bool,
        isPinned: Bool,
        isStreaming: Bool,
        isCompacting: Bool,
        isSelected: Bool,
        isRenaming: Bool
    ) -> Self {
        .init(
            id: .conversation(id),
            content: .conversation(
                id: id,
                title: title,
                isArchived: isArchived,
                isPinned: isPinned,
                isStreaming: isStreaming,
                isCompacting: isCompacting,
                isSelected: isSelected,
                isRenaming: isRenaming
            )
        )
    }

    var isSection: Bool {
        if case .section = content { true } else { false }
    }

    var section: Section? {
        guard case .section(let section, _) = content else { return nil }
        return section
    }

    var conversationID: UUID? {
        guard case .conversation(let id, _, _, _, _, _, _, _) = content else { return nil }
        return id
    }
}

nonisolated struct AssistantConversationDropTarget: Hashable, Sendable {
    let section: AssistantConversationListItem.Section
    let beforeID: UUID?
}

nonisolated enum AssistantConversationDropResolver {
    static func target(
        items: [AssistantConversationListItem],
        rowFrames: [CGRect],
        pointerY: CGFloat
    ) -> AssistantConversationDropTarget? {
        guard items.count == rowFrames.count, !items.isEmpty else { return nil }

        let index =
            rowFrames.firstIndex { $0.contains(CGPoint(x: $0.midX, y: pointerY)) }
            ?? rowFrames.firstIndex { pointerY < $0.midY }
            ?? (items.count - 1)

        if let section = items[index].section {
            return .init(section: section, beforeID: firstConversation(in: section, items: items))
        }
        guard let id = items[index].conversationID,
            let section = containingSection(at: index, items: items)
        else { return nil }
        if pointerY <= rowFrames[index].midY {
            return .init(section: section, beforeID: id)
        }
        return .init(
            section: section,
            beforeID: nextConversation(after: index, items: items)
        )
    }

    private static func containingSection(
        at index: Int, items: [AssistantConversationListItem]
    ) -> AssistantConversationListItem.Section? {
        items[...index].reversed().compactMap(\.section).first
    }

    private static func firstConversation(
        in section: AssistantConversationListItem.Section,
        items: [AssistantConversationListItem]
    ) -> UUID? {
        guard let sectionIndex = items.firstIndex(where: { $0.section == section }) else {
            return nil
        }
        return nextConversation(after: sectionIndex, items: items)
    }

    private static func nextConversation(
        after index: Int,
        items: [AssistantConversationListItem]
    ) -> UUID? {
        guard index + 1 < items.count else { return nil }
        for item in items[(index + 1)...] {
            if item.section != nil { return nil }
            if let id = item.conversationID { return id }
        }
        return nil
    }
}

private struct AssistantConversationNativeList: NSViewRepresentable {
    typealias NSViewType = AssistantConversationListContainer
    typealias List = ListView<AssistantConversationListItem>
    typealias Renderer = @MainActor (AssistantConversationListItem) -> AnyView

    let items: [AssistantConversationListItem]
    /// Put back into every row's hosting view.
    ///
    /// A row is its own `NSHostingView`, which inherits the environment from
    /// whatever it is attached to — and ListViewKit parks recycled rows in a
    /// reuse pool with no superview. A row rendered from there has no ancestor
    /// to inherit from, so a `@Environment(WindowModel.self)` inside it traps.
    /// Handing it over explicitly makes a row self-sufficient, attached or not.
    let window: WindowModel
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var animatesStructuralChanges = true
    /// Asked at drag time rather than cached from a render pass.
    ///
    /// `onDrag` sets `WindowModel.dragging` and AppKit enters its modal drag
    /// loop in the same breath, so SwiftUI may not run another update between
    /// the drag starting and the pointer arriving here — leaving a cached id
    /// nil and the insertion line hidden for the whole drag.
    var draggedID: () -> UUID? = { nil }
    var onMove: ((UUID, AssistantConversationDropTarget) -> Void)?
    var blankAreaMenu: (() -> [NativeMenuEntry])?
    /// False for a list its own SwiftUI layer keeps mounted but invisible. See
    /// `AssistantConversationListContainer.isInteractive`.
    var isInteractive = true
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [AssistantConversationListItem],
        window: WindowModel,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        animatesStructuralChanges: Bool = true,
        draggedID: @escaping () -> UUID? = { nil },
        onMove: ((UUID, AssistantConversationDropTarget) -> Void)? = nil,
        blankAreaMenu: (() -> [NativeMenuEntry])? = nil,
        isInteractive: Bool = true,
        @ViewBuilder renderer: @escaping @MainActor (AssistantConversationListItem) -> some View
    ) {
        self.items = items
        self.window = window
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.animatesStructuralChanges = animatesStructuralChanges
        self.draggedID = draggedID
        self.onMove = onMove
        self.blankAreaMenu = blankAreaMenu
        self.isInteractive = isInteractive
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        AssistantConversationListContainer(listView: context.coordinator.makeListView())
    }

    func updateNSView(_ container: NSViewType, context: Context) {
        container.draggedID = draggedID
        container.onMove = onMove
        container.blankAreaMenu = blankAreaMenu
        container.isInteractive = isInteractive
        container.locale = locale
        context.coordinator.update(
            listView: container.listView,
            items: items,
            renderer: renderer,
            window: window,
            locale: locale,
            colorScheme: colorScheme,
            topInset: topInset,
            bottomInset: bottomInset,
            animated: animatesStructuralChanges
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var window: WindowModel?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [AssistantConversationListItem] = []

        func makeListView() -> List {
            let listView = List()
            listView.estimatedRowHeight = Metrics.Sidebar.navigationRowHeight
            listView.rows {
                ListRow(AssistantConversationHostingRow.self)
                    .height { item, _ in
                        item.isSection ? 34 : Metrics.Sidebar.navigationRowHeight
                    }
                    .configure { [weak self] row, item, _ in
                        self?.configure(row, item: item)
                    }
            }
            return listView
        }

        func update(
            listView: List,
            items: [AssistantConversationListItem],
            renderer: @escaping Renderer,
            window: WindowModel,
            locale: Locale,
            colorScheme: ColorScheme,
            topInset: CGFloat,
            bottomInset: CGFloat,
            animated: Bool
        ) {
            self.renderer = renderer
            let environmentChanged =
                self.locale != locale || self.colorScheme != colorScheme
                || self.window !== window
            self.window = window
            self.locale = locale
            self.colorScheme = colorScheme
            listView.topInset = topInset
            listView.bottomInset = bottomInset

            let oldIDs = content.map(\.id)
            let newIDs = items.map(\.id)
            if oldIDs == newIDs {
                for (old, new) in zip(content, items) where old != new {
                    listView.update(new)
                }
                if environmentChanged { listView.reloadData() }
            } else {
                listView.apply(items, animated: animated && !content.isEmpty)
            }
            content = items
        }

        private func configure(
            _ row: AssistantConversationHostingRow,
            item: AssistantConversationListItem
        ) {
            guard let renderer, let window else { return }
            let content = renderer(item)
                .environment(window)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(content))
        }
    }
}

@MainActor
final class AssistantConversationListContainer: NSView {
    var locale = Locale.current
    let listView: ListView<AssistantConversationListItem>
    var draggedID: () -> UUID? = { nil }
    var onMove: ((UUID, AssistantConversationDropTarget) -> Void)?
    var blankAreaMenu: (() -> [NativeMenuEntry])?

    /// Whether this is the list on screen.
    ///
    /// `AssistantPanelView` keeps the Workspace layer mounted behind the sidebar
    /// list so the composer draft and the cross-fade survive, which leaves two
    /// of these stacked whenever the destination is not a Workspace. AppKit
    /// honours neither `allowsHitTesting(false)` nor `opacity(0)` when it looks
    /// for a drag destination, so the hidden copy wins and draws its insertion
    /// line where nobody can see it.
    ///
    /// Both halves of the retreat are needed: unregistering alone still leaves
    /// this view claiming the hit test that decides which destination AppKit
    /// walks up from, and refusing the hit test alone still leaves it in the
    /// window's registered destination list.
    var isInteractive = true {
        didSet {
            guard isInteractive != oldValue else { return }
            clearTarget()
            if isInteractive {
                registerForDraggedTypes([.string])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    private let insertionLine = NSView()
    private var target: AssistantConversationDropTarget?

    init(listView: ListView<AssistantConversationListItem>) {
        self.listView = listView
        super.init(frame: .zero)
        listView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listView)
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        insertionLine.wantsLayer = true
        updateAppearanceLayers()
        insertionLine.layer?.cornerRadius = 1
        insertionLine.isHidden = true
        addSubview(insertionLine)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceLayers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    private func updateAppearanceLayers() {
        insertionLine.layer?.backgroundColor =
            TermindColor.resolvedNative(
                TermindColor.nativeAccent,
                for: effectiveAppearance
            ).cgColor
    }

    /// A row's own menu is installed by SwiftUI on its hosting view, which
    /// AppKit finds first — only a right-click that landed on no row walks the
    /// responder chain this far. That is the blank area, with no geometry
    /// needed to recognise it.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = blankAreaMenu?(), !entries.isEmpty else {
            return super.menu(for: event)
        }
        return NativeMenuEntry.menu(entries, locale: locale)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender) ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender) ? .move : []
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        clearTarget()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard updateTarget(sender), let draggedID = draggedID(), let target, let onMove else {
            clearTarget()
            return false
        }
        clearTarget()
        onMove(draggedID, target)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearTarget()
        super.concludeDragOperation(sender)
    }

    private func updateTarget(_ sender: any NSDraggingInfo) -> Bool {
        guard draggedID() != nil,
            sender.draggingPasteboard.availableType(from: [.string]) != nil
        else {
            clearTarget()
            return false
        }
        let point = listView.convert(sender.draggingLocation, from: nil)
        let items = listView.content
        let frames = items.indices.map { listView.rectForRow(at: $0) }
        guard
            let target = AssistantConversationDropResolver.target(
                items: items, rowFrames: frames, pointerY: point.y
            )
        else {
            clearTarget()
            return false
        }
        self.target = target
        showInsertionLine(at: insertionY(for: target, items: items))
        return true
    }

    private func insertionY(
        for target: AssistantConversationDropTarget,
        items: [AssistantConversationListItem]
    ) -> CGFloat {
        if let beforeID = target.beforeID,
            let index = items.firstIndex(where: { $0.conversationID == beforeID })
        {
            return listView.rectForRow(at: index).minY
        }
        if target.section == .pinned,
            let chats = items.firstIndex(where: { $0.section == .chats })
        {
            return listView.rectForRow(at: chats).minY
        }
        var section: AssistantConversationListItem.Section?
        var lastConversationIndex: Int?
        var sectionIndex: Int?
        for (index, item) in items.enumerated() {
            if let value = item.section {
                section = value
                if value == target.section { sectionIndex = index }
            } else if section == target.section, item.conversationID != nil {
                lastConversationIndex = index
            }
        }
        if let lastConversationIndex {
            return listView.rectForRow(at: lastConversationIndex).maxY
        }
        return sectionIndex.map { listView.rectForRow(at: $0).maxY } ?? listView.bounds.maxY
    }

    private func showInsertionLine(at listY: CGFloat) {
        let point = convert(NSPoint(x: 0, y: listY), from: listView)
        insertionLine.frame = CGRect(x: 8, y: point.y - 1, width: max(0, bounds.width - 16), height: 2)
        insertionLine.isHidden = false
    }

    private func clearTarget() {
        target = nil
        insertionLine.isHidden = true
    }
}

@MainActor
private final class AssistantConversationHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        empty()
    }

    /// A recycled row is detached and parked in ListViewKit's reuse pool, where
    /// it may sit for as long as the list lives. Left holding its old root, it
    /// keeps observing that conversation and re-renders on every change — with
    /// no ancestor to inherit the environment from. Emptying it on the way out
    /// is what makes the pool inert.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview == nil else { return }
        empty()
    }

    func configure(rootView: AnyView) {
        hostingView.rootView = rootView
    }

    private func empty() {
        hostingView.rootView = AnyView(EmptyView())
    }
}

private struct AssistantArchiveView: View {
    let isCompact: Bool
    /// False for the compact archive while the sidebar shows the chat list
    /// beneath it. See `AssistantConversationListContainer.isInteractive`.
    var isInteractive: Bool = true
    /// The titlebar Find field, which searches whichever scope is on screen.
    /// The compact sidebar archive passes none — the titlebar is describing the
    /// main content, not this column.
    var query: String = ""
    var onBack: (() -> Void)?
    let onOpen: (UUID) -> Void

    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
            archiveHeader

            AssistantConversationList(
                selectedID: nil,
                query: query,
                isInteractive: isInteractive,
                menuSurface: isCompact ? .sidebar : .fullScreen,
                onOpen: onOpen,
                scope: .archived,
                archiveHorizontalPadding: isCompact ? 0 : Metrics.Space.xl
            )
            .overlay {
                if window.assistantLibrary.archivedConversations.isEmpty {
                    ContentUnavailableView(
                        AppStrings.Assistant.noArchivedChats.swiftUIKey,
                        systemImage: "archivebox",
                        description: Text(AppStrings.Assistant.chatsYouArchiveWillAppearHere)
                    )
                } else if window.assistantLibrary.search(query, scope: .archived).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .background {
            if !isCompact {
                Rectangle()
                    .fill(.background)
            }
        }
    }

    @ViewBuilder
    private var archiveHeader: some View {
        if isCompact {
            archiveHeaderContent
                .compactAssistantHeader()
        } else {
            archiveHeaderContent
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.vertical, Metrics.Space.l)
                .termindGlassBar()
            Divider()
        }
    }

    private var archiveHeaderContent: some View {
        HStack(spacing: Metrics.Space.s) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "arrow.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(Text(AppStrings.Assistant.backToChats))
            }

            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            Text(AppStrings.Assistant.archived)
                .font(isCompact ? .headline : .title2.weight(.semibold))
            Text(window.assistantLibrary.archivedConversations.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.Space.s)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
            Spacer(minLength: 0)
            if isCompact {
                Button {
                    window.showAssistantArchive()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(Text(AppStrings.Assistant.openFullScreen))
            }
        }
    }
}

private struct CompactAssistantHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(0.55)
            }
    }
}

extension View {
    fileprivate func compactAssistantHeader() -> some View {
        modifier(CompactAssistantHeader())
    }
}

struct AssistantConversationRow: View {
    let conversation: ConversationModel
    let isSelected: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let isRenaming: Bool
    @Binding var renameTitle: String
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @Environment(WindowModel.self) private var window
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.locale) private var locale
    @State private var hovering = false

    @ViewBuilder
    var body: some View {
        if canDrag {
            row
                .onDrag {
                    window.dragging = .assistantConversation(conversation.id)
                    return NSItemProvider(object: conversation.id.uuidString as NSString)
                } preview: {
                    ItemDragPreview(title: conversation.derivedTitle, symbol: "sparkles")
                }
        } else {
            row
        }
    }

    private var row: some View {
        rowContent
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.Sidebar.navigationRowHeight)
            .contentShape(.rect)
            .termindSidebarRow(isSelected: isSelected) { contextMenu }
            .onTapGesture {
                guard !isRenaming else { return }
                window.dragging = nil
                onOpen()
            }
            .onHover { hovering = $0 }
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var contextMenu: [NativeMenuEntry] {
        let managementDisabled = conversation.isStreaming || conversation.isCompacting
        var entries: [NativeMenuEntry] = [
            NativeMenuEntry(
                title: localized(AppStrings.Assistant.openFullScreen), symbol: MenuSymbol.openFullScreen
            ) {
                window.openAssistantFullScreen(conversation.id)
            },
            .separator,
        ]
        if !conversation.isArchived {
            entries.append(
                NativeMenuEntry(
                    title: conversation.isPinned
                        ? localized(AppStrings.Assistant.unpin) : localized(AppStrings.Assistant.pin),
                    symbol: conversation.isPinned ? MenuSymbol.unpin : MenuSymbol.pin
                ) { window.toggleAssistantPin(conversation.id) }
            )
        }
        entries.append(
            NativeMenuEntry(
                title: localized(AppStrings.Common.rename),
                symbol: MenuSymbol.rename,
                action: onBeginRename
            )
        )
        // Archive gets an active chat off the list. Permanent deletion is only
        // offered after the chat has already moved to Archive.
        entries.append(.separator)
        entries.append(
            NativeMenuEntry(
                title: conversation.isArchived
                    ? localized(AppStrings.Assistant.unarchive) : localized(AppStrings.Assistant.archive),
                symbol: conversation.isArchived ? MenuSymbol.unarchive : MenuSymbol.archive,
                isEnabled: conversation.isArchived || !managementDisabled
            ) {
                window.setAssistantArchived(
                    conversation.id, archived: !conversation.isArchived
                )
            }
        )
        if conversation.isArchived {
            entries.append(
                NativeMenuEntry(
                    title: localized(AppStrings.Common.delete), symbol: MenuSymbol.delete,
                    imageVisibility: .visible
                ) {
                    onDelete()
                }
            )
        }
        return entries
    }

    var canDrag: Bool {
        !conversation.isArchived && !isRenaming
    }

    private var rowContent: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: conversation.isArchived ? "archivebox" : "sparkles")
                .foregroundStyle(
                    SidebarSelectionStyle.iconForeground(
                        isSelected: isSelected,
                        controlActiveState: controlActiveState
                    ))
            if isRenaming {
                SidebarInlineRenameField(
                    text: $renameTitle,
                    prompt: String(localized: AppStrings.Assistant.conversationName),
                    isSelected: isSelected,
                    controlActiveState: controlActiveState,
                    onSubmit: onCommitRename,
                    onCancel: onCancelRename
                ).singleLinePaste()
                    .frame(height: 18)
            } else {
                Text(conversation.derivedTitle).lineLimit(1)
            }
            Spacer(minLength: Metrics.Space.xs)
            if hovering, !isRenaming, !conversation.isStreaming, !conversation.isCompacting {
                Button {
                    window.setAssistantArchived(
                        conversation.id, archived: !conversation.isArchived
                    )
                } label: {
                    Image(systemName: conversation.isArchived ? "arrow.uturn.backward" : "archivebox")
                        .font(.caption)
                        // Keep this action legible with the row's text in both
                        // active and inactive windows.
                        .foregroundStyle(
                            SidebarSelectionStyle.foreground(
                                isSelected: isSelected,
                                controlActiveState: controlActiveState,
                                unselected: AnyShapeStyle(.secondary)
                            ))
                }
                .buttonStyle(.plain)
                .help(
                    Text(
                        conversation.isArchived
                            ? localized(AppStrings.Assistant.unarchive) : localized(AppStrings.Assistant.archive)
                    ))
            }
        }
    }

    private func localized(_ key: LocalizedStringResource) -> String {
        AppLocalization.resolve(key, locale: locale)
    }
}

/// The second pinned destination's main conversation surface.
///
/// It passes no session context, and that is the point: this tab is not attached
/// to a Workspace, so there is no focused pane whose host and directory it could
/// honestly claim to be sending.
struct AssistantView: View {
    @Environment(WindowModel.self) private var window
    @Environment(AppModel.self) private var app

    var body: some View {
        if window.isAssistantArchivePresented {
            AssistantArchiveView(
                isCompact: false,
                query: window.assistantQuery,
                onOpen: { window.selectAssistant($0) }
            )
            .background(TermindColor.windowSurface)
        } else if let conversation = window.assistantLibrary.selectedConversation {
            ConversationView(
                conversation: conversation,
                onNewChat: { window.openNewAssistantChat() }
            )
            .background(TermindColor.windowSurface)
        } else {
            ConversationView(
                conversation: window.assistantLibrary.draftConversation,
                onSend: sendNewConversation
            )
            .background(TermindColor.windowSurface)
        }
    }

    private func sendNewConversation() {
        _ = app.sendNewAgentDraft(in: window.assistantLibrary)
    }
}
