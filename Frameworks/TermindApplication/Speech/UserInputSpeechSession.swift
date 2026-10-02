import Foundation

/// A question surface owns one session, including while its adaptive layout
/// measures multiple copies of the answer field.
@Observable
@MainActor
public final class UserInputSpeechSession {
    public let ownerID = UUID()
    private var coordinator: SpeechTranscriptionCoordinator?
    private var startTask: Task<Void, Never>?
    private var token: UUID?

    public init() {}

    public var isActive: Bool {
        startTask != nil || coordinator?.isOwned(by: ownerID) == true
    }

    public var isRecording: Bool {
        coordinator?.isOwned(by: ownerID) == true && coordinator?.phase == .recording
    }

    public var error: SpeechTranscriptionFailure? {
        coordinator?.errorOwnerID == ownerID ? coordinator?.error : nil
    }

    public func start(
        coordinator: SpeechTranscriptionCoordinator,
        conversation: ConversationModel,
        onApplied: @escaping @MainActor () -> Void
    ) {
        guard !isActive, coordinator.canStart(for: ownerID),
            let requestID = conversation.pendingUserInput?.id,
            let questionID = conversation.currentUserInputQuestion?.id,
            conversation.acceptsUserInputTranscription(requestID: requestID, questionID: questionID)
        else { return }

        self.coordinator = coordinator
        let token = UUID()
        self.token = token
        startTask = Task { [weak self, weak conversation] in
            guard let self else { return }
            defer { if self.token == token { self.startTask = nil } }
            guard let conversation, !Task.isCancelled, self.token == token,
                conversation.acceptsUserInputTranscription(requestID: requestID, questionID: questionID)
            else { return }
            await coordinator.start(ownerID: ownerID) { [weak self, weak conversation] transcript, _ in
                guard let self, self.token == token,
                    conversation?.applyUserInputTranscription(
                        transcript, requestID: requestID, questionID: questionID) == true
                else { return }
                onApplied()
            }
        }
    }

    public func stop() {
        coordinator?.stop(ownerID: ownerID)
    }

    public func cancel() {
        token = nil
        startTask?.cancel()
        startTask = nil
        coordinator?.cancel(ownerID: ownerID)
        dismissError()
    }

    public func dismissError() {
        coordinator?.dismissError(ownerID: ownerID)
    }
}
