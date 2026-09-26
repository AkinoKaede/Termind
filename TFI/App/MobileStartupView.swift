import SwiftData
import SwiftUI
import TermindPresentation

struct MobileStartupView: View {
    let startup: Result<MobileAppModel, any Error>
    @AppStorage("mobile.appearance") private var appearance = "system"

    nonisolated init(startup: Result<MobileAppModel, any Error>) {
        self.startup = startup
    }

    // SwiftUI's LazyView can invoke WindowGroup content on AsyncRenderer.
    // Only carry the startup result here; access app state in the View body,
    // where SwiftUI tracks the main-actor requirement.
    nonisolated static func sceneContent(
        for startup: Result<MobileAppModel, any Error>
    ) -> @Sendable () -> MobileStartupView {
        { MobileStartupView(startup: startup) }
    }

    var body: some View {
        switch startup {
        case .success(let app):
            MobileQuickActionSceneRoot(app: app)
                .modelContainer(app.container)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        case .failure:
            ContentUnavailableView(
                AppStrings.Common.unableToOpenTermind.swiftUIKey, systemImage: "exclamationmark.triangle",
                description: Text(AppStrings.Common.openDataStoreFailure))
        }
    }
}

private struct MobileQuickActionSceneRoot: View {
    let app: MobileAppModel
    @EnvironmentObject private var sceneDelegate: MobileSceneDelegate

    var body: some View {
        if let sessionID = sceneDelegate.sessionID {
            MobileBoundSceneRoot(app: app, sessionID: sessionID, delegate: sceneDelegate)
                .id(sessionID)
        }
    }
}

private struct MobileBoundSceneRoot: View {
    let app: MobileAppModel
    @ObservedObject var delegate: MobileSceneDelegate
    @State private var scene: MobileSceneModel

    init(app: MobileAppModel, sessionID: String, delegate: MobileSceneDelegate) {
        self.app = app
        self.delegate = delegate
        _scene = State(initialValue: MobileSceneModel(app: app, sessionID: sessionID))
    }

    var body: some View {
        MobileRootView(
            app: app,
            scene: scene,
            pendingQuickAction: delegate.pendingQuickAction,
            consumePendingQuickAction: delegate.consumePendingQuickAction
        )
        .onAppear { delegate.bind(to: app) }
        .onChange(of: delegate.pendingWorkspaceID, initial: true) { _, id in
            guard id != nil, let id = delegate.consumePendingWorkspaceID() else { return }
            MobileWorkspaceSceneRouting.reconcile(app: app, activeSessionID: scene.workspaceSession.id)
            scene.open(WorkspaceActivityAttributes.destinationURL(for: id))
        }
    }
}
