import SwiftUI
import TermindApplication

public struct AppReviewDeveloperSection: View {
    private let controller: AppReviewController

    public init(controller: AppReviewController) {
        self.controller = controller
    }

    public var body: some View {
        Section {
            Toggle(
                AppStrings.AppReview.showInvitation.swiftUIKey,
                isOn: Binding(get: { controller.isPreviewEnabled }, set: controller.setPreviewEnabled)
            )
            .accessibilityIdentifier("review.preview")
        } header: {
            Text(AppStrings.AppReview.previewTitle)
        } footer: {
            Text(AppStrings.AppReview.previewExplanation)
        }
    }
}
