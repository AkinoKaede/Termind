import Foundation

/// Coordinates one question surface without duplicating the conversation's answers or request queue.
@Observable
@MainActor
public final class UserInputInteractionModel {
    public let speech: UserInputSpeechSession

    public init(speech: UserInputSpeechSession = UserInputSpeechSession()) {
        self.speech = speech
    }

    public func canAdvance(in conversation: ConversationModel) -> Bool {
        conversation.canAdvanceUserInput && !speech.isActive
    }

    public func advance(in conversation: ConversationModel, questionID: String? = nil) {
        guard canAdvance(in: conversation),
            questionID == nil || conversation.currentUserInputQuestion?.id == questionID
        else { return }
        conversation.advanceUserInputQuestion()
    }

    public func selectOption(_ optionID: String, in questionID: String, conversation: ConversationModel) {
        guard !speech.isActive, conversation.currentUserInputQuestion?.id == questionID else { return }
        conversation.answerUserInputOption(optionID, in: questionID)
    }

    public func previous(in conversation: ConversationModel) {
        speech.cancel()
        conversation.previousUserInputQuestion()
    }

    public func skip(in conversation: ConversationModel) {
        speech.cancel()
        conversation.skipUserInputQuestion()
    }

    public func cancelRequest(in conversation: ConversationModel) {
        speech.cancel()
        conversation.cancelUserInput()
    }
}
