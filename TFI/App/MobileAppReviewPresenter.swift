import StoreKit
import SwiftUI
import TermindApplication

struct MobileAppReviewPresenter: ViewModifier {
    static let reviewPages: Set<String> = [
        "vault.hosts", "vault.keychain", "vault.snippets", "vault.knownHosts",
        "settings", "settings.app",
    ]

    @Environment(\.requestReview) private var requestReview
    let app: MobileAppModel
    @Bindable var scene: MobileSceneModel
    let scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content.background {
            if app.appReview.isEnabled {
                MobileAppReviewWindowReader(
                    controller: app.appReview,
                    surfaceID: scene.id,
                    location: Self.location(in: scene),
                    sceneIsActive: scenePhase == .active,
                    isBlocked: scene.isConnectionPickerPresented
                        || scene.editingHost != nil
                        || scene.renamingWorkspace != nil
                        || scene.isWorkspaceUnavailable
                        || app.error != nil
                        || app.keyboardAuthentication.current != nil
                        || app.pro.isPaywallPresented
                        || app.pro.isProcessing,
                    request: { requestReview() }
                )
            }
        }
    }

    static func location(in scene: MobileSceneModel) -> AppReviewController.Location {
        if let workspace = scene.activeWorkspace { return .workspace(workspace.id) }
        guard let page = scene.reviewPageID, reviewPages.contains(page) else { return .other }
        switch scene.selectedDestination {
        case .vault where page.hasPrefix("vault."):
            return .reviewPage(page)
        case .settings where page == "settings" || page.hasPrefix("settings."):
            return .reviewPage(page)
        default:
            return .other
        }
    }
}

private struct MobileReviewPageModifier: ViewModifier {
    let id: String
    let scene: MobileSceneModel?

    func body(content: Content) -> some View {
        content
            .onAppear { scene?.enterReviewPage(id) }
            .onDisappear { scene?.leaveReviewPage(id) }
    }
}

extension View {
    func mobileReviewPage(_ id: String, scene: MobileSceneModel?) -> some View {
        modifier(MobileReviewPageModifier(id: id, scene: scene))
    }
}
