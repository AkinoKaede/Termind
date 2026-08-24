import SwiftUI

/// The second, pinned top-level tab. The left column navigates conversations;
/// chats are intentionally not Workspace panes or closable top-level tabs.
struct ChatView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                chatList
                Divider()
                Button {
                    window.openChat()
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(Metrics.Space.m)
            }
            .navigationSplitViewColumnWidth(
                min: Metrics.Sidebar.min,
                ideal: Metrics.Sidebar.ideal,
                max: Metrics.Sidebar.max
            )
        } detail: {
            if let conversation = window.chatLibrary.selectedConversation {
                ConversationView(conversation: conversation)
                    .background(.background)
            } else {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a chat for questions that are not tied to one Workspace.")
                } actions: {
                    Button("New Chat") { window.openChat() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var chatList: some View {
        List {
            Section("Chats") {
                ForEach(window.chatLibrary.conversations) { conversation in
                    Button {
                        window.selectChat(conversation.id)
                    } label: {
                        Label(conversation.derivedTitle, systemImage: "sparkles")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        window.chatLibrary.selectedConversationID == conversation.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear
                    )
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            window.chatLibrary.delete(conversation.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
