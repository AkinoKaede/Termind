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
                    Button("Conversations", systemImage: "clock") { history = true }
                    Button("Archived", systemImage: "archivebox") { archive = true }
                    Divider()
                    Button("Rename", systemImage: "pencil") {
                        title = model.conversation.derivedTitle
                        renaming = true
                    }
                    Button(model.conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                        Task { await model.move(model.conversation, pinned: !model.conversation.isPinned) }
                    }
                    .disabled(model.conversation.isEmpty || model.conversation.isArchived)
                    Button("Archive", systemImage: "archivebox") {
                        Task { await model.archive(model.conversation, archived: true) }
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
            model.select(conversation)
        } label: {
            Label(
                conversation.derivedTitle,
                systemImage: model.conversation.id == conversation.id
                    ? "checkmark" : (conversation.isStreaming ? "ellipsis.circle" : "bubble.left")
            )
        }
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
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var renaming: ConversationModel?
    @State private var title = ""
    @State private var deleting: ConversationModel?
    @State private var showingArchive = false

    var body: some View {
        MobileNativeList(
            items: listItems, estimatedRowHeight: 84,
            refreshID: libraryRefreshID,
            onSelect: selectItem
        ) { item in
            listRow(item)
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

    private var libraryRefreshID: String {
        values.map {
            "\($0.id.uuidString):\($0.derivedTitle):\($0.isPinned):\($0.isStreaming):\($0.updatedAt.timeIntervalSince1970)"
        }.joined(separator: "|") + ":\(model.conversation.id.uuidString):\(query)"
    }

    private var listItems: [MobileConversationListItem] {
        var items: [MobileConversationListItem] = []
        if !archived && query.isEmpty {
            items.append(.action(.new))
            items.append(.action(.archive(count: model.library.archivedConversations.count)))
        }
        let pinned = values.filter(\.isPinned)
        let conversations = values.filter { !$0.isPinned }
        if !pinned.isEmpty {
            items.append(.section(id: "pinned", title: String(localized: "Pinned")))
            items.append(contentsOf: pinned.map(MobileConversationListItem.conversation))
        }
        if !conversations.isEmpty {
            if !archived {
                items.append(.section(id: "conversations", title: String(localized: "Conversations")))
            }
            items.append(contentsOf: conversations.map(MobileConversationListItem.conversation))
        }
        if values.isEmpty {
            items.append(
                .empty(archived ? String(localized: "No Archived Chats") : String(localized: "No Conversations")))
        }
        return items
    }

    @ViewBuilder private func listRow(_ item: MobileConversationListItem) -> some View {
        switch item.kind {
        case .new:
            Label("New Conversation", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(.horizontal, 16)
        case .archive(let count):
            HStack {
                Label("Archived", systemImage: "archivebox")
                Spacer()
                Text(count, format: .number).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 64).padding(.horizontal, 16)
        case .section(let title):
            Text(verbatim: title).font(.headline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .bottomLeading)
                .padding(.horizontal, 16).padding(.bottom, 6)
        case .conversation(let id):
            if let conversation = model.library.conversation(id: id) {
                HStack(alignment: .center, spacing: 12) {
                    MobileCardIcon(symbol: conversation.isArchived ? "archivebox" : "bubble.left")
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
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(.rect)
                .contextMenu { actions(conversation) }
                .accessibilityAddTraits(model.conversation.id == conversation.id ? .isSelected : [])
            }
        case .empty(let title):
            ContentUnavailableView(title, systemImage: archived ? "archivebox" : "bubble.left")
                .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    private func selectItem(_ item: MobileConversationListItem) {
        switch item.kind {
        case .new:
            model.newConversation()
            selected()
        case .archive:
            showingArchive = true
        case .conversation(let id):
            guard let conversation = model.library.conversation(id: id) else { return }
            model.select(conversation)
            if archived { dismiss() }
            selected()
        case .section, .empty:
            break
        }
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
            .disabled(conversation.isStreaming || conversation.isCompacting || conversation.isHistoryChanging)
    }
}

nonisolated private struct MobileConversationListItem: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case new
        case archive(count: Int)
        case section(String)
        case conversation(UUID)
        case empty(String)
    }

    let id: String
    let kind: Kind

    static func action(_ action: Kind) -> Self {
        switch action {
        case .new: Self(id: "action-new", kind: action)
        case .archive: Self(id: "action-archive", kind: action)
        default: preconditionFailure("Only action rows can use action(_:)")
        }
    }

    static func section(id: String, title: String) -> Self {
        Self(id: "section-\(id)", kind: .section(title))
    }

    @MainActor static func conversation(_ conversation: ConversationModel) -> Self {
        Self(id: "conversation-\(conversation.id.uuidString)", kind: .conversation(conversation.id))
    }

    static func empty(_ title: String) -> Self { Self(id: "empty", kind: .empty(title)) }
}
