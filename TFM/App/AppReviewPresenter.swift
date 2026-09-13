import StoreKit
import SwiftUI
import TermindApplication

struct AppReviewPresenter: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.requestReview) private var requestReview
    let window: WindowModel

    func body(content: Content) -> some View {
        content.background {
            if app.appReview.isEnabled {
                AppReviewWindowReader(
                    controller: app.appReview, location: Self.location(in: window),
                    isBlocked: app.onboarding.presentation != nil
                        || window.presentations.route != nil
                        || window.assistantOperationError != nil
                        || app.externalAuthentication.current != nil
                        || app.proAccess.isPaywallPresented || app.proAccess.isProcessing,
                    request: { requestReview() }
                )
            }
        }
    }

    static func location(in window: WindowModel) -> AppReviewController.Location {
        switch window.selectedDestination {
        case .workspace(let id):
            return .workspace(id)
        case .vault:
            guard window.vaultWorkRoute == nil, let page = window.vaultDestination.page,
                page != .welcome
            else { return .other }
            return .reviewPage("vault.\(page.rawValue)")
        case .settings:
            switch window.settingsRoute {
            case .index: return .reviewPage("settings")
            case .category(.app): return .reviewPage("settings.app")
            default: return .other
            }
        case .metrics, .assistant:
            return .other
        }
    }
}
