import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite
@MainActor
struct MobileAppReviewTests {
    @Test
    func presenterAllowsOnlyMobileEquivalentsOfDesktopReviewPages() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "test")

        for page in ["vault.hosts", "vault.keychain", "vault.snippets", "vault.knownHosts"] {
            scene.selectedDestination = .vault
            scene.enterReviewPage(page)
            #expect(MobileAppReviewPresenter.location(in: scene) == .reviewPage(page))
        }
        for page in ["settings", "settings.app"] {
            scene.selectedDestination = .settings
            scene.enterReviewPage(page)
            #expect(MobileAppReviewPresenter.location(in: scene) == .reviewPage(page))
        }

        scene.selectedDestination = .vault
        scene.enterReviewPage("vault.metrics")
        #expect(MobileAppReviewPresenter.location(in: scene) == .other)
        scene.enterReviewPage("settings.app")
        #expect(MobileAppReviewPresenter.location(in: scene) == .other)
        scene.selectedDestination = .assistant
        #expect(MobileAppReviewPresenter.location(in: scene) == .other)
    }

    @Test
    func workspaceDetailWinsOverAStaleReviewPage() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = Host(name: "Review Test", host: "127.0.0.1")
        app.library.upsert(host)
        let workspaceID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        defer { app.testWorkspaceSession.closeAll() }
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.enterReviewPage("vault.hosts")
        scene.selectedDestination = .workspaces
        scene.workspaceID = workspaceID

        #expect(MobileAppReviewPresenter.location(in: scene) == .workspace(workspaceID))
    }

    @Test
    func pageLifecycleDoesNotLetAnOutgoingPageClearItsReplacement() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.enterReviewPage("vault.hosts")
        scene.enterReviewPage("vault.keychain")
        scene.leaveReviewPage("vault.hosts")
        #expect(scene.reviewPageID == "vault.keychain")
        scene.leaveReviewPage("vault.keychain")
        #expect(scene.reviewPageID == nil)
    }

    @Test
    func testModelsDisableReviewRequestsAndAcceptAnInjectedController() throws {
        let disabled = try MobileAppModel(inMemory: true)
        #expect(!disabled.appReview.isEnabled)

        let injected = AppReviewController(defaults: nil, version: "1.0", isEnabled: true)
        let app = try MobileAppModel(inMemory: true, appReview: injected)
        #expect(app.appReview === injected)
    }

    @Test
    func nativeInputObserversDoNotPreventApplicationGestures() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let view = MobileReviewActivityView(controller: AppReviewController(), surfaceID: UUID())
        window.addSubview(view)
        let installed = (window.gestureRecognizers ?? []).filter { $0.delegate === view }

        #expect(installed.count == 2)
        #expect(installed.allSatisfy { !$0.cancelsTouchesInView })
        let input = installed.first { !($0 is UIHoverGestureRecognizer) }
        #expect(input?.canPrevent(UITapGestureRecognizer()) == false)

        view.removeFromSuperview()
        #expect((window.gestureRecognizers ?? []).allSatisfy { $0.delegate !== view })
    }
}
