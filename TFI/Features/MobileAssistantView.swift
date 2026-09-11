import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain

struct MobileAssistantView: View {
    let app: MobileAppModel
    @Bindable var model: MobileAssistantModel
    @State private var history = false

    var body: some View {
        GeometryReader { geometry in
            if UIDevice.current.userInterfaceIdiom == .pad && geometry.size.width >= 760 {
                HStack(spacing: 0) {
                    MobileAssistantLibrary(model: model, selected: {})
                        .frame(width: 280)
                    Divider()
                    detail
                }
            } else {
                detail
            }
        }
        .navigationTitle("Assistant")
        .toolbar {
            Button("Conversations", systemImage: "clock") { history = true }.labelStyle(.iconOnly)
            Button("New Conversation", systemImage: "square.and.pencil") { model.newConversation() }.labelStyle(
                .iconOnly)
        }
        .navigationDestination(isPresented: $history) {
            MobileAssistantLibrary(model: model) { history = false }
                .navigationTitle("Conversations")
        }
        .task { await model.load() }
        .alert(
            "Operation Failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
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
    @State private var editMode = EditMode.inactive

    var body: some View {
        List {
            if !archived {
                Section {
                    Button("New Conversation", systemImage: "square.and.pencil") {
                        model.newConversation()
                        selected()
                    }
                    NavigationLink {
                        MobileAssistantLibrary(model: model, archived: true, selected: selected).navigationTitle(
                            "Archived")
                    } label: {
                        Label("Archived", systemImage: "archivebox")
                        Spacer()
                        Text(model.library.archivedConversations.count, format: .number).foregroundStyle(.secondary)
                    }
                }
                Section("Pinned") { rows(values.filter(\.isPinned)) }
                Section("Conversations") { rows(values.filter { !$0.isPinned }) }
            } else {
                rows(values)
            }
            if values.isEmpty { Text(archived ? "No Archived Chats" : "No Conversations").foregroundStyle(.secondary) }
        }
        .searchable(text: $query, prompt: "Search")
        .environment(\.editMode, $editMode)
        .toolbar {
            Button(editMode.isEditing ? "Done" : "Edit", systemImage: editMode.isEditing ? "checkmark" : "pencil") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }.labelStyle(.iconOnly)
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

    @ViewBuilder private func rows(_ values: [ConversationModel]) -> some View {
        ForEach(values) { conversation in
            MobileActionCard {
                model.select(conversation)
                if archived { dismiss() }
                selected()
            } content: {
                HStack(alignment: .top, spacing: 12) {
                    MobileCardIcon(symbol: conversation.isArchived ? "archivebox" : "bubble.left")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conversation.derivedTitle).font(.headline).foregroundStyle(.primary)
                        if conversation.isStreaming { Text("Working…").font(.caption).foregroundStyle(.secondary) }
                    }
                    if model.conversation.id == conversation.id {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                }
            } actions: {
                actions(conversation)
            }
            .accessibilityAddTraits(model.conversation.id == conversation.id ? .isSelected : [])
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            .swipeActions(edge: .trailing) {
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
        .onMove { indices, destination in
            guard query.isEmpty, !archived, let index = indices.first else { return }
            let value = values[index]
            var remaining = values
            remaining.remove(at: index)
            let target = min(max(0, destination - (destination > index ? 1 : 0)), remaining.count)
            let next = target < remaining.count ? remaining[target].id : nil
            Task { await model.move(value, pinned: value.isPinned, before: next) }
        }
        .moveDisabled(archived || !query.isEmpty)
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
