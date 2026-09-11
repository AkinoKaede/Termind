import AgentKit
import Foundation
import Observation
import TermindApplication

/// Independent mobile Assistant; no terminal surface or workspace owns this model.
@MainActor
@Observable
final class MobileAssistantModel {
    private(set) var conversations: [StoredAgentConversation] = []
    private(set) var messages: [AgentTranscriptMessage] = []
    private(set) var isRunning = false
    var selectedID = UUID()
    var draft = ""
    var error: String?
    private var runtime: AgentRuntime?
    private var task: Task<Void, Never>?
    private let repository: any AgentRunPersisting
    private let configuration: AIConfigurationModel

    init(configuration: AIConfigurationModel, repository: any AgentRunPersisting) {
        self.configuration = configuration
        self.repository = repository
    }

    func load() async {
        do { conversations = try await repository.loadConversations() } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ conversation: StoredAgentConversation) {
        guard !isRunning else { return }
        selectedID = conversation.id
        messages = conversation.modelTranscript ?? conversation.messages
    }

    func newConversation() {
        guard !isRunning else { return }
        selectedID = UUID()
        messages = []
    }

    func send() {
        guard !isRunning, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let resolved = configuration.resolve(conversation: configuration.lastSelectedModel),
            let secret = configuration.secret(for: resolved.provider.effectiveCredentialRef), !secret.isEmpty
        else {
            error = String(localized: "Configure a model and its API key in Settings before sending a message.")
            return
        }
        let prompt = draft
        let prior = messages
        let message = AgentTranscriptMessage(role: .user, text: prompt)
        messages.append(message)
        draft = ""
        error = nil
        isRunning = true
        let client = AgentProviderClient(provider: resolved.provider, model: resolved.model, secret: secret)
        // Until a tool is registered it is absent from the model's capabilities, not silently skipped.
        let approval = AgentApprovalBroker(
            reviewer: nil, manualApproval: { _ in .deny("No approval presenter is available.") })
        let runtime = AgentRuntime(model: client, tools: [], approval: approval, repository: repository)
        self.runtime = runtime
        let request = AgentRunRequest(
            conversationID: selectedID, promptID: message.id, prompt: prompt,
            permissionMode: .askForApproval, priorMessages: prior)
        task = Task { [weak self] in
            let events = await runtime.start(request)
            for await event in events {
                guard let self else {
                    await runtime.cancel()
                    return
                }
                switch event {
                case .messageStarted(let value), .messageFinished(let value), .steeringDelivered(let value):
                    if let index = messages.firstIndex(where: { $0.id == value.id }) {
                        messages[index] = value
                    } else {
                        messages.append(value)
                    }
                case .messageDelta(let id, let text):
                    if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text += text }
                case .failed(let message): error = message
                default: break
                }
            }
            self?.isRunning = false
            self?.runtime = nil
            await self?.load()
        }
    }

    func stop() {
        guard let runtime else { return }
        Task { await runtime.cancel() }
    }
}
