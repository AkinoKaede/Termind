import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation

enum MobileAssistantLibraryRoute: String, Identifiable, Hashable {
    case conversations
    case archived

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .conversations: AppStrings.Assistant.conversations
        case .archived: AppStrings.Assistant.archived
        }
    }
}

struct MobileAssistantView: View {
    let app: MobileAppModel
    let model: MobileAssistantSceneModel
    @Binding var libraryRoute: MobileAssistantLibraryRoute?
    @Environment(\.mobileToolbarLayout) private var toolbarLayout
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
            .navigationTitle(conversationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: usesConversationIcon ? .title : nil)
            .toolbar {
                if usesConversationIcon {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            conversationTitleMenu
                        } label: {
                            MobileNotificationMenuLabel(
                                title: String(localized: AppStrings.Assistant.conversations), symbol: "rectangle.stack",
                                hasUnread: app.unreadAssistantNotificationCount > 0, isToolbar: true)
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityValue(conversationTitle)
                        .disabled(!hasSelectableConversations)
                    }
                    .mobileProminentAction()
                } else if libraryRoute == nil && hasSelectableConversations {
                    ToolbarTitleMenu { conversationTitleMenu }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        AppStrings.Assistant.newConversation.swiftUIKey, systemImage: "plus.bubble",
                        action: newConversation
                    )
                    .labelStyle(.iconOnly)
                }
                .mobileProminentAction()
                MobileToolbarOverflow {
                    Button(AppStrings.Assistant.conversations.swiftUIKey, systemImage: "clock") {
                        showLibrary(.conversations)
                    }
                    Button(AppStrings.Assistant.archived.swiftUIKey, systemImage: "archivebox") {
                        showLibrary(.archived)
                    }
                    Divider()
                    Button(AppStrings.Common.rename.swiftUIKey, systemImage: "pencil") {
                        title = model.conversation.derivedTitle
                        renaming = model.conversation
                    }
                    .disabled(model.conversation.isEmpty)
                    Button(
                        model.conversation.isPinned
                            ? AppStrings.Assistant.unpin.swiftUIKey : AppStrings.Assistant.pin.swiftUIKey,
                        systemImage: "pin"
                    ) {
                        let conversation = model.conversation
                        Task { await model.move(conversation, pinned: !conversation.isPinned) }
                    }
                    .disabled(model.conversation.isEmpty || model.conversation.isArchived)
                    if model.conversation.isArchived {
                        Button(AppStrings.Assistant.unarchive.swiftUIKey, systemImage: "arrow.uturn.backward") {
                            let conversation = model.conversation
                            Task { await model.archive(conversation, archived: false) }
                        }
                        .disabled(!canChangeHistory)
                        Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            deleting = model.conversation
                        }
                        .disabled(!canChangeHistory)
                    } else {
                        Button(AppStrings.Assistant.archive.swiftUIKey, systemImage: "archivebox", role: .destructive) {
                            let conversation = model.conversation
                            Task { await model.archive(conversation, archived: true) }
                        }
                        .disabled(!canChangeHistory)
                    }
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
                AppStrings.Common.rename,
                isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
            ) {
                TextField(
                    AppStrings.Assistant.conversationName.swiftUIKey, text: $title.singleLineText, axis: .horizontal
                ).singleLinePaste()
                    .lineLimit(1)
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { renaming = nil }
                Button(AppStrings.Common.save.swiftUIKey) {
                    if let renaming { Task { await model.rename(renaming, title: title) } }
                    renaming = nil
                }
            }
            .operationConfirmation(
                .init(AppStrings.Assistant.deleteConversation),
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                placement: .centered,
                actions: [
                    .init(AppStrings.Common.delete, role: .destructive) {
                        if let deleting { Task { await model.delete(deleting) } }
                        deleting = nil
                    },
                    .init(AppStrings.Common.cancel, role: .cancel) { deleting = nil },
                ],
                message: .init(AppStrings.Assistant.deleteStagedConversationWarning)
            )
            .task { await model.load() }
            .alert(
                AppStrings.Common.operationFailed,
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button(AppStrings.Common.ok.swiftUIKey) { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }

    private var conversationTitle: String {
        model.conversation.isEmpty
            ? String(localized: AppStrings.Navigation.assistant) : model.conversation.derivedTitle
    }

    private var usesConversationIcon: Bool {
        toolbarLayout.usesIconSwitcher && libraryRoute == nil
    }

    private var hasSelectableConversations: Bool {
        !model.library.pinnedConversations.isEmpty || !model.library.activeConversations.isEmpty
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
            Section(AppStrings.Assistant.pinned.swiftUIKey) {
                ForEach(model.library.pinnedConversations) { conversation in titleMenuButton(conversation) }
            }
        }
        if !model.library.activeConversations.isEmpty {
            Section(AppStrings.Assistant.conversations.swiftUIKey) {
                ForEach(model.library.activeConversations) { conversation in titleMenuButton(conversation) }
            }
        }
    }

    private func titleMenuButton(_ conversation: ConversationModel) -> some View {
        Button {
            select(conversation)
        } label: {
            MobileNotificationMenuLabel(
                title: conversation.derivedTitle,
                symbol: model.conversation.id == conversation.id
                    ? "checkmark" : (conversation.isStreaming ? "ellipsis.circle" : "sparkles"),
                hasUnread: conversation.unreadNotificationCount > 0
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
    let model: MobileAssistantSceneModel
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
                        Label(AppStrings.Assistant.newConversation.swiftUIKey, systemImage: "plus.bubble")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showArchived()
                    } label: {
                        HStack {
                            Label(AppStrings.Assistant.archived.swiftUIKey, systemImage: "archivebox")
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
                Section(AppStrings.Assistant.pinned.swiftUIKey) {
                    ForEach(pinnedConversations) { conversationRow($0) }
                }
            }

            if archived {
                ForEach(ordinaryConversations) { conversationRow($0) }
            } else if !ordinaryConversations.isEmpty {
                Section(String(localized: AppStrings.Assistant.conversations)) {
                    ForEach(ordinaryConversations) { conversationRow($0) }
                }
            }

            if values.isEmpty {
                ContentUnavailableView(
                    archived
                        ? AppStrings.Assistant.noArchivedChats.swiftUIKey
                        : AppStrings.Assistant.noConversations.swiftUIKey,
                    systemImage: archived ? "archivebox" : "sparkles"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query.singleLineText, prompt: AppStrings.Common.search.swiftUIKey)
        .alert(
            AppStrings.Common.rename,
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
        ) {
            TextField(AppStrings.Assistant.conversationName.swiftUIKey, text: $title.singleLineText, axis: .horizontal)
                .singleLinePaste().lineLimit(
                    1)
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { renaming = nil }
            Button(AppStrings.Common.save.swiftUIKey) {
                if let renaming { Task { await model.rename(renaming, title: title) } }
                renaming = nil
            }
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
                        Text(AppStrings.Assistant.workingProgress).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if conversation.unreadNotificationCount > 0 { NotificationUnreadDot() }
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
                Button(AppStrings.Assistant.unarchive.swiftUIKey, systemImage: "arrow.uturn.backward") {
                    Task { await model.archive(conversation, archived: false) }
                }
                .tint(.accentColor)
                .disabled(!canChangeHistory(conversation))
            } else {
                Button(AppStrings.Assistant.archive.swiftUIKey, systemImage: "archivebox", role: .destructive) {
                    Task { await model.archive(conversation, archived: true) }
                }
                .disabled(!canChangeHistory(conversation))
            }
        }
        .contextMenu { actions(conversation) }
        .accessibilityValue(
            conversation.unreadNotificationCount > 0
                ? String(localized: AppStrings.Notifications.unread(conversation.unreadNotificationCount)) : ""
        )
        .accessibilityAddTraits(model.conversation.id == conversation.id ? .isSelected : [])
        .operationConfirmation(
            .init(AppStrings.Assistant.deleteConversation),
            isPresented: $deleting.isPresenting { $0.id == conversation.id },
            actions: [
                .init(AppStrings.Common.delete, role: .destructive) {
                    if let deleting { Task { await model.delete(deleting) } }
                    deleting = nil
                },
                .init(AppStrings.Common.cancel, role: .cancel) { deleting = nil },
            ],
            message: .init(AppStrings.Assistant.deleteStagedConversationWarning)
        )
    }

    private func select(_ conversation: ConversationModel) {
        model.select(conversation)
        selected()
    }

    @ViewBuilder private func actions(_ conversation: ConversationModel) -> some View {
        let hasUnread = conversation.unreadNotificationCount > 0
        Button(AppStrings.Common.rename.swiftUIKey, systemImage: "pencil") {
            title = conversation.derivedTitle
            renaming = conversation
        }
        Button(
            hasUnread ? AppStrings.Notifications.markRead : AppStrings.Notifications.markUnread,
            systemImage: hasUnread ? "circle" : "circle.fill"
        ) {
            if hasUnread { conversation.markNotificationsRead() } else { conversation.markNotificationsUnread() }
        }
        if !conversation.isArchived {
            Button(
                conversation.isPinned ? AppStrings.Assistant.unpin.swiftUIKey : AppStrings.Assistant.pin.swiftUIKey,
                systemImage: conversation.isPinned ? "pin.slash" : "pin"
            ) {
                Task { await model.move(conversation, pinned: !conversation.isPinned) }
            }.disabled(conversation.isStreaming || conversation.isCompacting || conversation.isHistoryChanging)
        }
        if conversation.isArchived {
            Button(AppStrings.Assistant.unarchive.swiftUIKey, systemImage: "arrow.uturn.backward") {
                Task { await model.archive(conversation, archived: false) }
            }
            .disabled(!canChangeHistory(conversation))
            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                deleting = conversation
            }
            .disabled(!canChangeHistory(conversation))
        } else {
            Button(AppStrings.Assistant.archive.swiftUIKey, systemImage: "archivebox", role: .destructive) {
                Task { await model.archive(conversation, archived: true) }
            }
            .disabled(!canChangeHistory(conversation))
        }
    }

    private func canChangeHistory(_ conversation: ConversationModel) -> Bool {
        !conversation.isStreaming && !conversation.isCompacting && !conversation.isHistoryChanging
    }
}
