import SwiftUI

/// Assistant's conversation navigator inside the window's shared sidebar.
struct AssistantSidebarView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        VStack(spacing: 0) {
            chatList
            Divider()
            Button {
                window.openAssistant()
            } label: {
                Label("New Chat", systemImage: "plus.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(Metrics.Space.m)
        }
    }

    private var chatList: some View {
        List {
            Section("Chats") {
                ForEach(window.assistantLibrary.conversations) { conversation in
                    Button {
                        window.selectAssistant(conversation.id)
                    } label: {
                        Label(conversation.derivedTitle, systemImage: "sparkles")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        window.assistantLibrary.selectedConversationID == conversation.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            window.deleteAssistantConversation(conversation.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
            if let conversation = window.sidebarAssistantConversation {
                conversationDetail(conversation)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                landing
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.tabSwitch, value: window.sidebar.assistantConversationID)
    }

    private var landing: some View {
        VStack(spacing: 0) {
            conversationList
            Divider()
            ComposerView(
                conversation: window.sidebar.assistantDraft,
                prompt: "Ask anything…",
                sessionContext: window.sidebar.sessionContext,
                onSend: {
                    if let conversation = window.sendAssistantSidebarDraft() {
                        app.startAgentRun(
                            conversation, context: window.sidebar.sessionContext
                        )
                    }
                }
            )
        }
    }

    private var conversationList: some View {
        List {
            Section("Chats") {
                ForEach(window.assistantLibrary.conversations) { conversation in
                    Button {
                        window.openAssistantInSidebar(conversation.id)
                    } label: {
                        HStack(spacing: Metrics.Space.s) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            Text(conversation.derivedTitle)
                                .lineLimit(1)
                            Spacer(minLength: Metrics.Space.xs)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            window.deleteAssistantConversation(conversation.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if window.assistantLibrary.conversations.isEmpty {
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
                sessionContext: window.sidebar.sessionContext
            )
        }
    }
}

/// The second pinned tab's main conversation surface.
///
/// It passes no session context, and that is the point: this tab is not attached
/// to a Workspace, so there is no focused pane whose host and directory it could
/// honestly claim to be sending.
struct AssistantView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        if let conversation = window.assistantLibrary.selectedConversation {
            ConversationView(conversation: conversation)
                .background(.background)
        } else {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Start a chat for questions that are not tied to one Workspace.")
            } actions: {
                Button("New Chat") { window.openAssistant() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
