import AppKit
import ListViewKit
import SwiftUI

/// Assistant's conversation navigator inside the window's shared sidebar.
struct AssistantSidebarView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
            chatList
            Divider()
            HStack(spacing: Metrics.Space.s) {
                Button {
                    window.openNewAssistantChat()
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                        .padding(.leading, Metrics.Sidebar.navigationRowInset)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: Metrics.Sidebar.navigationRowHeight,
                            alignment: .leading
                        )
                        .contentShape(.rect)
                }
                .termindSidebarGlassButton()

                Button {
                    window.showAssistantArchive()
                } label: {
                    Image(systemName: "archivebox")
                        .foregroundStyle(
                            window.isAssistantArchivePresented ? Color.accentColor : Color.primary
                        )
                        .frame(
                            width: Metrics.Sidebar.navigationRowHeight,
                            height: Metrics.Sidebar.navigationRowHeight
                        )
                }
                .termindSidebarGlassButton()
                .help(Text("Archived"))
                .accessibilityLabel(Text("Archived"))
                .accessibilityAddTraits(window.isAssistantArchivePresented ? .isSelected : [])
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
        }
    }

    private var chatList: some View {
        AssistantConversationList(
            selectedID: window.isAssistantArchivePresented
                ? nil : window.assistantLibrary.selectedConversationID,
            onOpen: { window.selectAssistant($0) }
        )
    }
}

/// The global Assistant contained entirely in a Workspace sidebar.
///
/// Its route is deliberately separate from the fixed Assistant tab's selection:
/// opening a chat here never takes the user's terminal out of the foreground.
struct AssistantPanelView: View {
    @Environment(WindowModel.self) private var window
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if !isFocusedOnWorkspace {
                AssistantSidebarView()
            } else if window.sidebar.isAssistantArchivePresented {
                AssistantArchiveView(
                    isCompact: true,
                    onBack: { window.closeAssistantInSidebar() },
                    onOpen: { window.openAssistantInSidebar($0) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let conversation = window.sidebarAssistantConversation {
                conversationDetail(conversation)
            } else {
                landing
            }
        }
        .animation(
            Motion.tabSwitch,
            value: window.sidebar.isAssistantArchivePresented
        )
    }

    private var isFocusedOnWorkspace: Bool {
        if case .workspace = window.selectedDestination { true } else { false }
    }

    private var landing: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer(minLength: 0)
                Button {
                    openAssistantFullScreen()
                } label: {
                    Label("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)

            Divider()
            conversationList
            Divider()
            ComposerView(
                conversation: window.sidebar.assistantDraft,
                prompt: "Ask anything…",
                surfaceStyle: .sidebar,
                sessionContext: window.sidebar.sessionContext,
                includesTerminalSuggestion: true,
                onSend: {
                    if let conversation = window.sendAssistantSidebarDraft() {
                        app.startAgentRun(
                            conversation, context: window.sidebar.sessionContext,
                            includesTerminalSuggestion: true
                        )
                    }
                }
            )
        }
    }

    private var conversationList: some View {
        AssistantConversationList(
            selectedID: window.sidebar.assistantConversationID,
            onOpen: { window.openAssistantInSidebar($0) }
        )
        .overlay {
            if window.assistantLibrary.pinnedConversations.isEmpty,
                window.assistantLibrary.activeConversations.isEmpty
            {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Send a message below to start one.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func conversationDetail(_ conversation: ConversationModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.s) {
                Button {
                    window.closeAssistantInSidebar()
                } label: {
                    Label("Back to Chats", systemImage: "arrow.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(Text("Back to Chats"))

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
                .help(Text("Open Full Screen"))
            }
            .compactAssistantHeader()
            ConversationView(
                conversation: conversation, isCompact: true,
                sessionContext: window.sidebar.sessionContext,
                showsTerminalActions: true,
                onNewChat: { window.closeAssistantInSidebar() }
            )
        }
    }

    private func openAssistantFullScreen() {
        if let id = window.sidebar.assistantConversationID
            ?? window.assistantLibrary.selectedConversationID
        {
            window.openAssistantFullScreen(id)
        } else {
            window.openAssistantFullScreen()
        }
    }
}

private struct AssistantConversationList: View {
    let selectedID: UUID?
    let onOpen: (UUID) -> Void
    var scope: Scope = .active
    var archiveMaxWidth: CGFloat?

    enum Scope {
        case active
        case archived
    }

    @Environment(WindowModel.self) private var window
    @State private var deleteTarget: ConversationModel?
    @State private var renamingID: ConversationModel.ID?
    @State private var renameTitle = ""

    var body: some View {
        content
        .onChange(of: visibleConversationIDs) {
            guard let renamingID, !visibleConversationIDs.contains(renamingID) else { return }
            cancelRename()
        }
        .alert(
            "Delete Conversation?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ), presenting: deleteTarget
        ) { conversation in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                window.deleteAssistantConversation(conversation.id)
                deleteTarget = nil
            }
        } message: { _ in
            Text("This permanently removes the conversation and its scratch files.")
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
        AssistantConversationNativeList(
            items: activeItems,
            draggedID: draggedConversationID,
            onMove: { id, target in
                window.moveAssistantConversation(
                    id, toPinned: target.section == .pinned, before: target.beforeID
                )
                window.dragging = nil
            }
        ) { item in
            renderedItem(item)
        }
        .background(Color.clear)
    }

    private var archivedList: some View {
        AssistantConversationNativeList(
            items: archivedItems,
            topInset: Metrics.Space.m,
            bottomInset: Metrics.Space.m
        ) { item in
            renderedItem(item)
                .frame(maxWidth: archiveMaxWidth ?? .infinity)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, archiveMaxWidth == nil ? 0 : Metrics.Space.xl)
        }
        .background(Color.clear)
    }

    private var activeItems: [AssistantConversationListItem] {
        var items: [AssistantConversationListItem] = [.section(.pinned)]
        items.append(contentsOf: window.assistantLibrary.pinnedConversations.map(item))
        items.append(.section(.chats))
        items.append(contentsOf: window.assistantLibrary.activeConversations.map(item))
        return items
    }

    private var draggedConversationID: ConversationModel.ID? {
        guard case .assistantConversation(let id)? = window.dragging else { return nil }
        return id
    }

    private var archivedItems: [AssistantConversationListItem] {
        window.assistantLibrary.archivedConversations.map(item)
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
    private func renderedItem(_ item: AssistantConversationListItem) -> some View {
        switch item.content {
        case .section(let section):
            Text(section.title)
                .termindSidebarSectionLabel()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(
                    .horizontal,
                    Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
                )
                .padding(.top, Metrics.Space.m)
                .padding(.bottom, Metrics.Space.xs)
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

    private func beginRename(_ conversation: ConversationModel) {
        renamingID = conversation.id
        renameTitle = conversation.derivedTitle
    }

    private func commitRename(_ conversation: ConversationModel) {
        let value = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        window.renameAssistantConversation(conversation.id, to: value)
        cancelRename()
    }

    private func cancelRename() {
        renamingID = nil
        renameTitle = ""
    }
}

nonisolated struct AssistantConversationListItem: Identifiable, Hashable, Sendable {
    nonisolated enum Section: String, Hashable, Sendable {
        case pinned
        case chats

        var title: LocalizedStringKey {
            switch self {
            case .pinned: "Pinned"
            case .chats: "Chats"
            }
        }
    }

    nonisolated enum ID: Hashable, Sendable {
        case section(Section)
        case conversation(UUID)
    }

    nonisolated enum Content: Hashable, Sendable {
        case section(Section)
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

    static func section(_ section: Section) -> Self {
        .init(id: .section(section), content: .section(section))
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
        guard case .section(let section) = content else { return nil }
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

        let index = rowFrames.firstIndex { $0.contains(CGPoint(x: $0.midX, y: pointerY)) }
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
            beforeID: nextConversation(after: index, in: section, items: items)
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
        return nextConversation(after: sectionIndex, in: section, items: items)
    }

    private static func nextConversation(
        after index: Int,
        in section: AssistantConversationListItem.Section,
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
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var draggedID: UUID?
    var onMove: ((UUID, AssistantConversationDropTarget) -> Void)?
    let renderer: Renderer

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [AssistantConversationListItem],
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        draggedID: UUID? = nil,
        onMove: ((UUID, AssistantConversationDropTarget) -> Void)? = nil,
        @ViewBuilder renderer: @escaping @MainActor (AssistantConversationListItem) -> some View
    ) {
        self.items = items
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.draggedID = draggedID
        self.onMove = onMove
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSViewType {
        AssistantConversationListContainer(listView: context.coordinator.makeListView())
    }

    func updateNSView(_ container: NSViewType, context: Context) {
        container.draggedID = draggedID
        container.onMove = onMove
        context.coordinator.update(
            listView: container.listView,
            items: items,
            renderer: renderer,
            locale: locale,
            colorScheme: colorScheme,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [AssistantConversationListItem] = []

        func makeListView() -> List {
            let listView = List()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
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
            locale: Locale,
            colorScheme: ColorScheme,
            topInset: CGFloat,
            bottomInset: CGFloat
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            listView.topInset = topInset
            listView.bottomInset = bottomInset

            let oldIDs = content.map(\.id)
            let newIDs = items.map(\.id)
            if oldIDs == newIDs {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items, animated: !content.isEmpty)
            }
            content = items
        }

        private func configure(
            _ row: AssistantConversationHostingRow,
            item: AssistantConversationListItem
        ) {
            guard let renderer else { return }
            let content = renderer(item)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(id: item.id, rootView: AnyView(content))
        }
    }
}

@MainActor
private final class AssistantConversationListContainer: NSView {
    let listView: ListView<AssistantConversationListItem>
    var draggedID: UUID?
    var onMove: ((UUID, AssistantConversationDropTarget) -> Void)?

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
        insertionLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionLine.layer?.cornerRadius = 1
        insertionLine.isHidden = true
        addSubview(insertionLine)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

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
        guard updateTarget(sender), let draggedID, let target, let onMove else {
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
        guard draggedID != nil,
            sender.draggingPasteboard.availableType(from: [.string]) != nil
        else {
            clearTarget()
            return false
        }
        let point = listView.convert(sender.draggingLocation, from: nil)
        let items = listView.content
        let frames = items.indices.map { listView.rectForRow(at: $0) }
        guard let target = AssistantConversationDropResolver.target(
            items: items, rowFrames: frames, pointerY: point.y
        ) else {
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
    private var representedID: AssistantConversationListItem.ID?

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
        representedID = nil
        hostingView.rootView = AnyView(EmptyView())
    }

    func configure(id: AssistantConversationListItem.ID, rootView: AnyView) {
        representedID = id
        hostingView.rootView = rootView
    }
}

private struct AssistantArchiveView: View {
    let isCompact: Bool
    var onBack: (() -> Void)?
    let onOpen: (UUID) -> Void

    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
            archiveHeader

            AssistantConversationList(
                selectedID: nil,
                onOpen: onOpen,
                scope: .archived,
                archiveMaxWidth: isCompact ? nil : Metrics.Chat.contentMaxWidth
            )
            .overlay {
                if window.assistantLibrary.archivedConversations.isEmpty {
                    ContentUnavailableView(
                        "No Archived Chats",
                        systemImage: "archivebox",
                        description: Text("Chats you archive will appear here.")
                    )
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
                .background(.bar)
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
                .help(Text("Back to Chats"))
            }

            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            Text("Archived")
                .font(isCompact ? .headline : .title2.weight(.semibold))
            Text(window.assistantLibrary.archivedConversations.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.Space.s)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
            Spacer(minLength: 0)
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

private extension View {
    func compactAssistantHeader() -> some View {
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
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    @ViewBuilder
    var body: some View {
        if canDrag {
            row
                .onDrag {
                    window.dragging = .assistantConversation(conversation.id)
                    return NSItemProvider(object: conversation.id.uuidString as NSString)
                } preview: {
                    Label(conversation.derivedTitle, systemImage: "sparkles")
                        .lineLimit(1)
                        .padding(.horizontal, Metrics.Space.m)
                        .padding(.vertical, Metrics.Space.s)
                        .background(
                            .regularMaterial,
                            in: .rect(cornerRadius: Metrics.Radius.medium)
                        )
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
            .termindSidebarRowBackground(isSelected: isSelected)
            .onTapGesture {
                guard !isRenaming else { return }
                window.dragging = nil
                onOpen()
            }
            .onHover { hovering = $0 }
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onChange(of: isRenaming, initial: true) {
                if isRenaming {
                    DispatchQueue.main.async { titleFocused = true }
                }
            }
            .overlay {
                ConversationContextMenuHost(
                    isArchived: conversation.isArchived,
                    isPinned: conversation.isPinned,
                    managementDisabled: conversation.isStreaming || conversation.isCompacting,
                    onOpenFullScreen: { window.openAssistantFullScreen(conversation.id) },
                    onTogglePin: { window.toggleAssistantPin(conversation.id) },
                    onRename: onBeginRename,
                    onToggleArchive: {
                        window.setAssistantArchived(
                            conversation.id, archived: !conversation.isArchived
                        )
                    },
                    onDelete: onDelete
                )
                .accessibilityHidden(true)
            }
    }

    private var canDrag: Bool {
        !conversation.isArchived && !conversation.isStreaming && !conversation.isCompacting
            && !isRenaming
    }

    private var rowContent: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: conversation.isArchived ? "archivebox" : "sparkles")
                .foregroundStyle(.tint)
            if isRenaming {
                TextField("Conversation Name", text: $renameTitle)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
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
                }
                .buttonStyle(.plain)
                .help(Text(
                    conversation.isArchived
                        ? String(localized: "Unarchive") : String(localized: "Archive")
                ))
            }
        }
    }
}

/// SwiftUI's `contextMenu` paints a thick blue source outline on macOS even
/// when the row itself is not focusable. The menu is native either way, so host
/// it directly in AppKit: right clicks still get the standard menu while row
/// selection remains our quiet filled state rather than a second outlined one.
private struct ConversationContextMenuHost: NSViewRepresentable {
    let isArchived: Bool
    let isPinned: Bool
    let managementDisabled: Bool
    let onOpenFullScreen: () -> Void
    let onTogglePin: () -> Void
    let onRename: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> MenuView {
        MenuView()
    }

    func updateNSView(_ view: MenuView, context: Context) {
        view.isArchived = isArchived
        view.isPinned = isPinned
        view.managementDisabled = managementDisabled
        view.onOpenFullScreen = onOpenFullScreen
        view.onTogglePin = onTogglePin
        view.onRename = onRename
        view.onToggleArchive = onToggleArchive
        view.onDelete = onDelete
    }

    final class MenuView: NSView {
        var isArchived = false
        var isPinned = false
        var managementDisabled = false
        var onOpenFullScreen: () -> Void = {}
        var onTogglePin: () -> Void = {}
        var onRename: () -> Void = {}
        var onToggleArchive: () -> Void = {}
        var onDelete: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                event.type == .rightMouseDown || event.type == .rightMouseUp
            else { return nil }
            return self
        }

        override func rightMouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(item(
                String(localized: "Open Full Screen"), action: #selector(openFullScreen)
            ))
            menu.addItem(.separator())
            if !isArchived {
                menu.addItem(item(
                    isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    action: #selector(togglePin),
                    enabled: !managementDisabled
                ))
            }
            menu.addItem(item(String(localized: "Rename"), action: #selector(rename)))
            menu.addItem(item(
                isArchived ? String(localized: "Unarchive") : String(localized: "Archive"),
                action: #selector(toggleArchive),
                enabled: isArchived || !managementDisabled
            ))
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Delete"), action: #selector(deleteConversation)))
            return menu
        }

        private func item(
            _ title: String, action: Selector, enabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }

        @objc private func togglePin() { onTogglePin() }
        @objc private func openFullScreen() { onOpenFullScreen() }
        @objc private func rename() { onRename() }
        @objc private func toggleArchive() { onToggleArchive() }
        @objc private func deleteConversation() { onDelete() }
    }
}

/// The second pinned tab's main conversation surface.
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
                onOpen: { window.selectAssistant($0) }
            )
            .background(.background)
        } else if let conversation = window.assistantLibrary.selectedConversation {
            ConversationView(
                conversation: conversation,
                onNewChat: { window.openNewAssistantChat() }
            )
                .background(.background)
        } else {
            ConversationView(
                conversation: window.assistantLibrary.draftConversation,
                onSend: sendNewConversation
            )
            .background(.background)
        }
    }

    private func sendNewConversation() {
        guard let conversation = window.assistantLibrary.startDraftConversation()
        else { return }
        app.startAgentRun(conversation)
    }
}
