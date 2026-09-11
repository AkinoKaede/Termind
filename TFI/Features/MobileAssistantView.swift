import AgentKit
import SwiftUI

struct MobileAssistantView: View {
    let app: MobileAppModel
    @Bindable var model: MobileAssistantModel
    @State private var history = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.messages.filter { $0.role != .tool }) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.role == .user ? String(localized: "You") : String(localized: "Assistant"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(.init(message.text)).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                }.padding()
            }
            .onChange(of: model.messages.count) { _, _ in
                if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("Message", text: $model.draft, axis: .vertical).lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                if model.isRunning {
                    Button("Stop", systemImage: "stop.fill") { model.stop() }.labelStyle(.iconOnly)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        if app.pro.require(.assistant) { model.send() }
                    }.labelStyle(.iconOnly).disabled(
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding().background(.bar)
        }
        .navigationTitle("Assistant")
        .toolbar {
            Menu {
                Picker("Model", selection: Binding(get: { model.selectedModel }, set: { model.selectModel($0) })) {
                    Text("Automatic").tag(nil as AIModelRef?)
                    ForEach(app.ai.enabledModelProviders) { provider in
                        ForEach(provider.assistantModels) { item in
                            Text("\(provider.name) · \(item.id)")
                                .tag(AIModelRef(modelProviderID: provider.id, modelID: item.id) as AIModelRef?)
                        }
                    }
                }
            } label: {
                Label("Model", systemImage: "cube")
            }
            .disabled(model.isRunning)

            Button("Conversations", systemImage: "clock") { history = true }.disabled(model.isRunning)
            Button("New Conversation", systemImage: "square.and.pencil") { model.newConversation() }.disabled(
                model.isRunning)
        }
        .sheet(isPresented: $history) {
            NavigationStack {
                List(model.conversations, id: \.id) { conversation in
                    Button(
                        conversation.title.isEmpty
                            ? String(conversation.messages.first?.text.prefix(80) ?? "") : conversation.title
                    ) {
                        model.select(conversation)
                        history = false
                    }
                }
                .navigationTitle("Conversations")
                .toolbar { Button("Done") { history = false } }
            }.presentationDetents([.medium, .large])
        }
        .task { await model.load() }
    }
}
