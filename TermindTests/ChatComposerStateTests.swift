import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct ChatComposerStateTests {
    @Test
    func reasoningEffortExposesTheFullScaleAndDefaultsToMedium() {
        #expect(
            ReasoningEffort.allCases
                == [.off, .minimal, .low, .medium, .high, .xHigh, .max]
        )
        #expect(ConversationModel().reasoningEffort == .medium)
        #expect(ReasoningEffort.xHigh.displayName == "Extra High")
    }

    @Test
    func reasoningEffortStaysScopedToItsConversation() {
        let first = ConversationModel()
        let second = ConversationModel()

        first.reasoningEffort = .max

        #expect(first.reasoningEffort == .max)
        #expect(second.reasoningEffort == .medium)
    }

    @Test
    func permissionModesHaveTheExpectedOrderAndSafeInitialDefault() {
        #expect(
            ChatPermissionMode.allCases
                == [.askForApproval, .approveForMe, .fullAccess]
        )

        let store = AIStore(persistsSecrets: false)
        #expect(store.resolve(conversation: nil as ChatPermissionMode?) == .askForApproval)
    }

    @Test
    func latestPermissionFeedsUnsetConversationsWhileExplicitChoiceWins() {
        let store = AIStore(persistsSecrets: false)
        let unset = ConversationModel()
        let explicit = ConversationModel()
        explicit.permissionMode = .askForApproval

        store.select(ChatPermissionMode.approveForMe)

        #expect(store.resolve(conversation: unset.permissionMode) == .approveForMe)
        #expect(store.resolve(conversation: explicit.permissionMode) == .askForApproval)

        store.select(ChatPermissionMode.fullAccess)

        #expect(store.resolve(conversation: unset.permissionMode) == .fullAccess)
        #expect(store.resolve(conversation: explicit.permissionMode) == .askForApproval)
    }

    @Test
    func permissionDefaultCanBeSeededForAnAppSession() {
        let store = AIStore(
            lastSelectedPermissionMode: .approveForMe,
            persistsSecrets: false
        )

        #expect(store.lastSelectedPermissionMode == .approveForMe)
        #expect(store.resolve(conversation: nil as ChatPermissionMode?) == .approveForMe)
    }

    @Test
    func modelSelectionStillFeedsUnsetConversationsWithoutOverridingExplicitOnes() {
        let firstModel = AIModel(id: "first")
        let secondModel = AIModel(id: "second")
        let provider = ModelProvider(
            name: "Test Provider",
            models: [firstModel, secondModel]
        )
        let store = AIStore(modelProviders: [provider], persistsSecrets: false)
        let firstRef = AIModelRef(modelProviderID: provider.id, modelID: firstModel.id)
        let secondRef = AIModelRef(modelProviderID: provider.id, modelID: secondModel.id)

        #expect(store.resolve(conversation: nil)?.model.id == firstModel.id)

        store.select(secondRef)

        #expect(store.resolve(conversation: nil)?.model.id == secondModel.id)
        #expect(store.resolve(conversation: firstRef)?.model.id == firstModel.id)
    }
}
