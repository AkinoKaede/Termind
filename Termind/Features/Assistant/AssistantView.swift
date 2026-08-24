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
                            window.assistantLibrary.delete(conversation.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The second pinned tab's main conversation surface.
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
