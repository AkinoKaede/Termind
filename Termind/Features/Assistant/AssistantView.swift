import AppKit
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
                        .frame(
                            maxWidth: .infinity,
                            minHeight: Metrics.Sidebar.navigationRowHeight,
                            alignment: .leading
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    window.showAssistantArchive()
                } label: {
                    Image(systemName: "archivebox")
                        .frame(
                            width: Metrics.Sidebar.navigationRowHeight,
                            height: Metrics.Sidebar.navigationRowHeight
                        )
                        .background(
                            window.isAssistantArchivePresented
                                ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: .rect(cornerRadius: Metrics.Radius.small)
                        )
                }
                .buttonStyle(.plain)
                .help(Text("Archived"))
                .accessibilityLabel(Text("Archived"))
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
            if window.sidebar.isAssistantArchivePresented {
                AssistantArchiveView(
                    isCompact: true,
                    onBack: { window.closeAssistantInSidebar() },
                    onOpen: { window.openAssistantInSidebar($0) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let conversation = window.sidebarAssistantConversation {
                conversationDetail(conversation)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                landing
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(
            Motion.tabSwitch,
            value: window.sidebar.assistantConversationID
        )
        .animation(
            Motion.tabSwitch,
            value: window.sidebar.isAssistantArchivePresented
        )
    }

    private var landing: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer(minLength: 0)
                Button {
                    window.showAssistantArchiveInSidebar()
                } label: {
                    Label("Archived", systemImage: "archivebox")
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
            }
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
            .background(.bar)

            Divider()
            ConversationView(
                conversation: conversation, isCompact: true,
                sessionContext: window.sidebar.sessionContext,
                showsTerminalActions: true,
                onNewChat: { window.closeAssistantInSidebar() }
            )
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

    var body: some View {
        content
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !window.assistantLibrary.pinnedConversations.isEmpty {
                    sectionTitle("Pinned")
                    rows(window.assistantLibrary.pinnedConversations)
                }
                if !window.assistantLibrary.activeConversations.isEmpty {
                    sectionTitle("Chats")
                    rows(window.assistantLibrary.activeConversations)
                }
            }
        }
        .background(Color.clear)
    }

    private var archivedList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                rows(window.assistantLibrary.archivedConversations)
            }
            .frame(maxWidth: archiveMaxWidth ?? .infinity)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(
                .horizontal,
                archiveMaxWidth == nil ? 0 : Metrics.Space.xl
            )
            .padding(.vertical, Metrics.Space.m)
        }
        .background(Color.clear)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .padding(.top, Metrics.Space.m)
            .padding(.bottom, Metrics.Space.xs)
    }

    @ViewBuilder
    private func rows(_ conversations: [ConversationModel]) -> some View {
        ForEach(conversations) { conversation in
            AssistantConversationRow(
                conversation: conversation,
                isSelected: selectedID == conversation.id,
                onOpen: { onOpen(conversation.id) },
                onDelete: { deleteTarget = conversation }
            )
        }
    }
}

private struct AssistantArchiveView: View {
    let isCompact: Bool
    var onBack: (() -> Void)?
    let onOpen: (UUID) -> Void

    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(.horizontal, isCompact ? Metrics.Space.m : Metrics.Space.xl)
            .padding(.vertical, isCompact ? Metrics.Space.s : Metrics.Space.l)
            .background(.bar)

            Divider()

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
        .background(.background)
    }
}

private struct AssistantConversationRow: View {
    let conversation: ConversationModel
    let isSelected: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(WindowModel.self) private var window
    @State private var hovering = false
    @State private var renaming = false
    @State private var title = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : hovering
                            ? Color.primary.opacity(0.055)
                            : Color.clear
                )

            rowContent
                .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.Sidebar.navigationRowHeight)
        .contentShape(.rect)
        .onTapGesture { if !renaming { onOpen() } }
        .onHover { hovering = $0 }
        .focusable(false)
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay {
            ConversationContextMenuHost(
                isArchived: conversation.isArchived,
                isPinned: conversation.isPinned,
                managementDisabled: conversation.isStreaming || conversation.isCompacting,
                onTogglePin: { window.toggleAssistantPin(conversation.id) },
                onRename: beginRename,
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

    private var rowContent: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: conversation.isArchived ? "archivebox" : "sparkles")
                .foregroundStyle(.tint)
            if renaming {
                TextField("Conversation Name", text: $title)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
            } else {
                Text(conversation.derivedTitle).lineLimit(1)
            }
            Spacer(minLength: Metrics.Space.xs)
            if hovering, !renaming, !conversation.isStreaming, !conversation.isCompacting {
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

    private func beginRename() {
        title = conversation.derivedTitle
        renaming = true
        titleFocused = true
    }

    private func commitRename() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        window.renameAssistantConversation(conversation.id, to: value)
        renaming = false
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
        view.onTogglePin = onTogglePin
        view.onRename = onRename
        view.onToggleArchive = onToggleArchive
        view.onDelete = onDelete
    }

    final class MenuView: NSView {
        var isArchived = false
        var isPinned = false
        var managementDisabled = false
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
