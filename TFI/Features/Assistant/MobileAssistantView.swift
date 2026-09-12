import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain

struct MobileAssistantView: View {
    let app: MobileAppModel
    @Bindable var model: MobileAssistantModel
    @State private var history = false
    @State private var archive = false
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false

    var body: some View {
        detail
            .navigationTitle(
                model.conversation.isEmpty ? String(localized: "Assistant") : model.conversation.derivedTitle
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { conversationTitleMenu }
            .toolbar {
                Button("New Conversation", systemImage: "square.and.pencil") { model.newConversation() }.labelStyle(
                    .iconOnly)
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        title = model.conversation.derivedTitle
                        renaming = true
                    }
                    .disabled(model.conversation.isEmpty)
                    Button(model.conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                        Task { await model.move(model.conversation, pinned: !model.conversation.isPinned) }
                    }
                    .disabled(model.conversation.isEmpty || model.conversation.isArchived)
                    Button(
                        model.conversation.isArchived ? "Unarchive" : "Archive",
                        systemImage: model.conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
                    ) {
                        Task { await model.archive(model.conversation, archived: !model.conversation.isArchived) }
                    }
                    .disabled(!canChangeHistory)
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                        .disabled(!canChangeHistory)
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
            .navigationDestination(isPresented: $history) {
                MobileAssistantLibrary(model: model) { history = false }
                    .navigationTitle("Conversations")
            }
            .navigationDestination(isPresented: $archive) {
                MobileAssistantLibrary(model: model, archived: true) { archive = false }
                    .navigationTitle("Archived")
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Conversation Name", text: $title)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { await model.rename(model.conversation, title: title) } }
            }
            .confirmationDialog("Delete Conversation", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await model.delete(model.conversation) } }
            } message: {
                Text("Permanently delete this conversation and its staged files?")
            }
            .task { await model.load() }
            .alert(
                "Operation Failed",
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }

    private var detail: some View {
        MobileAssistantConversation(app: app, model: model, conversation: model.conversation)
            .id(model.conversation.id)
    }

    @ViewBuilder private var conversationTitleMenu: some View {
        Button("New Conversation", systemImage: model.conversation.isEmpty ? "checkmark" : "square.and.pencil") {
            model.newConversation()
        }
        if !model.library.pinnedConversations.isEmpty {
            Section("Pinned") {
                ForEach(model.library.pinnedConversations) { conversation in titleMenuButton(conversation) }
            }
        }
        if !model.library.activeConversations.isEmpty {
            Section("Conversations") {
                ForEach(model.library.activeConversations) { conversation in titleMenuButton(conversation) }
            }
        }
        Divider()
        Button("Conversations", systemImage: "clock") { history = true }
        Button("Archived", systemImage: "archivebox") { archive = true }
    }

    private func titleMenuButton(_ conversation: ConversationModel) -> some View {
        Button {
            select(conversation)
        } label: {
            Label(
                conversation.derivedTitle,
                systemImage: model.conversation.id == conversation.id
                    ? "checkmark" : (conversation.isStreaming ? "ellipsis.circle" : "bubble.left")
            )
        }
    }

    private func select(_ conversation: ConversationModel) {
        guard model.conversation.id != conversation.id else { return }
        model.select(conversation)
    }

    private var canChangeHistory: Bool {
        !model.conversation.isEmpty && !model.conversation.isStreaming && !model.conversation.isCompacting
            && !model.conversation.isHistoryChanging
    }
}

struct MobileAssistantLibrary: View {
    @Bindable var model: MobileAssistantModel
    var archived = false
    let selected: () -> Void
    @State private var query = ""
    @State private var renaming: ConversationModel?
    @State private var title = ""
    @State private var deleting: ConversationModel?
    @State private var showingArchive = false

    var body: some View {
        List {
            if !archived && query.isEmpty {
                Section {
                    Button {
                        model.newConversation()
                        selected()
                    } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showingArchive = true
                    } label: {
                        HStack {
                            Label("Archived", systemImage: "archivebox")
                            Spacer()
                            Text(model.library.archivedConversations.count, format: .number)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 48)
                    }
                    .foregroundStyle(.primary)
                }
            }

            if !pinnedConversations.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedConversations) { conversationRow($0) }
                }
            }

            if !ordinaryConversations.isEmpty {
                Section(archived ? "" : String(localized: "Conversations")) {
                    ForEach(ordinaryConversations) { conversationRow($0) }
                }
            }

            if values.isEmpty {
                ContentUnavailableView(
                    archived ? "No Archived Chats" : "No Conversations",
                    systemImage: archived ? "archivebox" : "bubble.left"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .searchable(text: $query, prompt: "Search")
        .navigationDestination(isPresented: $showingArchive) {
            MobileAssistantLibrary(model: model, archived: true, selected: selected)
                .navigationTitle("Archived")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Conversation Name", text: $title)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { Task { await model.rename(renaming, title: title) } }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete Conversation", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { Task { await model.delete(deleting) } }
                deleting = nil
            }
        } message: {
            Text("Permanently delete this conversation and its staged files?")
        }
    }

    private var values: [ConversationModel] { model.library.search(query, scope: archived ? .archived : .active) }
    private var pinnedConversations: [ConversationModel] { values.filter(\.isPinned) }
    private var ordinaryConversations: [ConversationModel] { values.filter { !$0.isPinned } }

    private func conversationRow(_ conversation: ConversationModel) -> some View {
        Button {
            select(conversation)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: conversation.isArchived ? "archivebox" : "bubble.left")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(conversation.derivedTitle).font(.headline).foregroundStyle(.primary).lineLimit(2)
                    if conversation.isStreaming {
                        Text("Working…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if model.conversation.id == conversation.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if conversation.isArchived {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    Task { await model.archive(conversation, archived: false) }
                }
                .tint(.accentColor)
                .disabled(!canChangeHistory(conversation))
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.archive(conversation, archived: true) }
                }
                .tint(.orange)
                .disabled(!canChangeHistory(conversation))
            }
        }
        .contextMenu { actions(conversation) }
        .accessibilityAddTraits(model.conversation.id == conversation.id ? .isSelected : [])
    }

    private func select(_ conversation: ConversationModel) {
        model.select(conversation)
        selected()
    }

    @ViewBuilder private func actions(_ conversation: ConversationModel) -> some View {
        Button("Rename", systemImage: "pencil") {
            title = conversation.derivedTitle
            renaming = conversation
        }
        if !conversation.isArchived {
            Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                Task { await model.move(conversation, pinned: !conversation.isPinned) }
            }.disabled(conversation.isStreaming || conversation.isCompacting || conversation.isHistoryChanging)
        }
        Button(
            conversation.isArchived ? "Unarchive" : "Archive",
            systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
        ) {
            Task { await model.archive(conversation, archived: !conversation.isArchived) }
        }.disabled(conversation.isStreaming || conversation.isCompacting || conversation.isHistoryChanging)
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
            .disabled(!canChangeHistory(conversation))
    }

    private func canChangeHistory(_ conversation: ConversationModel) -> Bool {
        !conversation.isStreaming && !conversation.isCompacting && !conversation.isHistoryChanging
    }
}
