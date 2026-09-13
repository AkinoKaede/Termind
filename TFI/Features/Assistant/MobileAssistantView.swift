import AgentKit
import SwiftUI
import TermindApplication

enum MobileAssistantLibraryRoute: String, Identifiable, Hashable {
    case conversations
    case archived

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .conversations: "Conversations"
        case .archived: "Archived"
        }
    }
}

struct MobileAssistantView: View {
    let app: MobileAppModel
    @Bindable var model: MobileAssistantSceneModel
    @Binding var libraryRoute: MobileAssistantLibraryRoute?
    @State private var restoreComposerFocusAfterLibrary = false
    @State private var nextComposerFocusRequest = 0
    @State private var composerFocusRequest: Int?
    @State private var renaming: ConversationModel?
    @State private var title = ""
    @State private var deleting: ConversationModel?
    @FocusState private var composerFocused: Bool

    init(
        app: MobileAppModel,
        model: MobileAssistantSceneModel,
        libraryRoute: Binding<MobileAssistantLibraryRoute?>
    ) {
        self.app = app
        self.model = model
        _libraryRoute = libraryRoute
    }

    var body: some View {
        detail
            .navigationTitle(
                model.conversation.isEmpty ? String(localized: "Assistant") : model.conversation.derivedTitle
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { conversationTitleMenu }
            .toolbar {
                Button("New Conversation", systemImage: "plus.bubble", action: newConversation)
                    .labelStyle(.iconOnly)
                Menu {
                    Button("Conversations", systemImage: "clock") { showLibrary(.conversations) }
                    Button("Archived", systemImage: "archivebox") { showLibrary(.archived) }
                    Divider()
                    Button("Rename", systemImage: "pencil") {
                        title = model.conversation.derivedTitle
                        renaming = model.conversation
                    }
                    .disabled(model.conversation.isEmpty)
                    Button(model.conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                        let conversation = model.conversation
                        Task { await model.move(conversation, pinned: !conversation.isPinned) }
                    }
                    .disabled(model.conversation.isEmpty || model.conversation.isArchived)
                    if model.conversation.isArchived {
                        Button("Unarchive", systemImage: "arrow.uturn.backward") {
                            let conversation = model.conversation
                            Task { await model.archive(conversation, archived: false) }
                        }
                        .disabled(!canChangeHistory)
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleting = model.conversation
                        }
                        .disabled(!canChangeHistory)
                    } else {
                        Button("Archive", systemImage: "archivebox", role: .destructive) {
                            let conversation = model.conversation
                            Task { await model.archive(conversation, archived: true) }
                        }
                        .disabled(!canChangeHistory)
                    }
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
            .navigationDestination(item: $libraryRoute) { route in
                MobileAssistantLibrary(
                    model: model,
                    route: route,
                    selected: { libraryRoute = nil },
                    showArchived: { libraryRoute = .archived }
                )
                .navigationTitle(route.title)
            }
            .onChange(of: libraryRoute) { previous, current in
                guard previous != nil, current == nil else { return }
                requestComposerFocusIfNeeded(restoreComposerFocusAfterLibrary)
                restoreComposerFocusAfterLibrary = false
            }
            .alert(
                "Rename",
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField("Conversation Name", text: $title)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { Task { await model.rename(renaming, title: title) } }
                    renaming = nil
                }
            }
            .confirmationDialog(
                "Delete Conversation",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let deleting { Task { await model.delete(deleting) } }
                    deleting = nil
                }
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
        MobileAssistantConversation(
            app: app,
            model: model,
            conversation: model.conversation,
            composerFocus: $composerFocused,
            composerFocusRequest: composerFocusRequest,
            composerFocusRequestHandled: composerFocusRequestHandled
        )
        .id(model.conversation.id)
    }

    @ViewBuilder private var conversationTitleMenu: some View {
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
    }

    private func titleMenuButton(_ conversation: ConversationModel) -> some View {
        Button {
            select(conversation)
        } label: {
            Label(
                conversation.derivedTitle,
                systemImage: model.conversation.id == conversation.id
                    ? "checkmark" : (conversation.isStreaming ? "ellipsis.circle" : "sparkles")
            )
        }
    }

    private func newConversation() {
        libraryRoute = nil
        replaceConversation(preservingComposerFocus: model.newConversation)
    }

    private func select(_ conversation: ConversationModel) {
        guard model.conversation.id != conversation.id else { return }
        replaceConversation { model.select(conversation) }
    }

    private func showLibrary(_ route: MobileAssistantLibraryRoute) {
        if libraryRoute == nil { restoreComposerFocusAfterLibrary = composerFocused }
        libraryRoute = route
    }

    private func replaceConversation(preservingComposerFocus action: () -> Void) {
        let shouldRestoreFocus = composerFocused
        action()
        requestComposerFocusIfNeeded(shouldRestoreFocus)
    }

    private func requestComposerFocusIfNeeded(_ requested: Bool) {
        guard requested, canFocusComposer else { return }
        let conversationID = model.conversation.id
        Task { @MainActor in
            await Task.yield()
            guard model.conversation.id == conversationID, canFocusComposer else { return }
            nextComposerFocusRequest += 1
            composerFocusRequest = nextComposerFocusRequest
        }
    }

    private func composerFocusRequestHandled(_ request: Int) {
        if composerFocusRequest == request { composerFocusRequest = nil }
    }

    private var canFocusComposer: Bool {
        !model.conversation.isArchived
            && model.conversation.pendingApproval == nil
            && model.conversation.pendingUserInteraction == nil
    }

    private var canChangeHistory: Bool {
        !model.conversation.isEmpty && !model.conversation.isStreaming && !model.conversation.isCompacting
            && !model.conversation.isHistoryChanging
    }
}

struct MobileAssistantLibrary: View {
    @Bindable var model: MobileAssistantSceneModel
    let route: MobileAssistantLibraryRoute
    let selected: () -> Void
    let showArchived: () -> Void
    @State private var query = ""
    @State private var renaming: ConversationModel?
    @State private var title = ""
    @State private var deleting: ConversationModel?

    init(
        model: MobileAssistantSceneModel,
        route: MobileAssistantLibraryRoute,
        selected: @escaping () -> Void,
        showArchived: @escaping () -> Void
    ) {
        self.model = model
        self.route = route
        self.selected = selected
        self.showArchived = showArchived
    }

    private var archived: Bool { route == .archived }

    var body: some View {
        List {
            if !archived && query.isEmpty {
                Section {
                    Button {
                        model.newConversation()
                        selected()
                    } label: {
                        Label("New Conversation", systemImage: "plus.bubble")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showArchived()
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
                    }
                    .foregroundStyle(.primary)
                }
            }

            if !pinnedConversations.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedConversations) { conversationRow($0) }
                }
            }

            if archived {
                ForEach(ordinaryConversations) { conversationRow($0) }
            } else if !ordinaryConversations.isEmpty {
                Section(String(localized: "Conversations")) {
                    ForEach(ordinaryConversations) { conversationRow($0) }
                }
            }

            if values.isEmpty {
                ContentUnavailableView(
                    archived ? "No Archived Chats" : "No Conversations",
                    systemImage: archived ? "archivebox" : "sparkles"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search")
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
            HStack(spacing: 12) {
                Image(systemName: conversation.isArchived ? "archivebox" : "sparkles")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.derivedTitle).foregroundStyle(.primary).lineLimit(1)
                    if conversation.isStreaming {
                        Text("Working…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.conversation.id == conversation.id {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if conversation.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    Task { await model.archive(conversation, archived: false) }
                }
                .tint(.accentColor)
                .disabled(!canChangeHistory(conversation))
            } else {
                Button("Archive", systemImage: "archivebox", role: .destructive) {
                    Task { await model.archive(conversation, archived: true) }
                }
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
        if conversation.isArchived {
            Button("Unarchive", systemImage: "arrow.uturn.backward") {
                Task { await model.archive(conversation, archived: false) }
            }
            .disabled(!canChangeHistory(conversation))
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
                .disabled(!canChangeHistory(conversation))
        } else {
            Button("Archive", systemImage: "archivebox", role: .destructive) {
                Task { await model.archive(conversation, archived: true) }
            }
            .disabled(!canChangeHistory(conversation))
        }
    }

    private func canChangeHistory(_ conversation: ConversationModel) -> Bool {
        !conversation.isStreaming && !conversation.isCompacting && !conversation.isHistoryChanging
    }
}
