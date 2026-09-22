import TermindPresentation
import Testing

@Suite
struct DeletionConfirmationPolicyTests {
    @Test
    func alwaysConfirmsItemsAndCollectionClears() {
        #expect(DeletionConfirmationPolicy.always.requiresConfirmation(for: .item))
        #expect(DeletionConfirmationPolicy.always.requiresConfirmation(for: .clearCollection))
    }

    @Test
    func clearOnlyConfirmsCollectionClears() {
        #expect(!DeletionConfirmationPolicy.clearOnly.requiresConfirmation(for: .item))
        #expect(DeletionConfirmationPolicy.clearOnly.requiresConfirmation(for: .clearCollection))
    }

    @Test
    func neverSkipsEveryConfirmation() {
        #expect(!DeletionConfirmationPolicy.never.requiresConfirmation(for: .item))
        #expect(!DeletionConfirmationPolicy.never.requiresConfirmation(for: .clearCollection))
    }

    @Test
    func contentCategoriesMapToTheSharedProductPolicy() {
        #expect(DeletionContentCategory.protectedData.confirmationPolicy == .always)
        #expect(DeletionContentCategory.recordedContent.confirmationPolicy == .clearOnly)
        #expect(DeletionContentCategory.savedConfiguration.confirmationPolicy == .clearOnly)
        #expect(DeletionContentCategory.transient.confirmationPolicy == .never)
    }
}
