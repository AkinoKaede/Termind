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
            Group {
                if app.diagnosis.needsConsent {
                    DiagnosisConsentView(controller: app.diagnosis)
                } else {
                    MobileQuickActionSceneRoot(app: app)
                }
            }
            .mobileOperationConfirmations()
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

struct MobileBoundSceneRoot: View {
    let app: MobileAppModel
    let sessionID: String
    @ObservedObject var delegate: MobileSceneDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var scene: MobileSceneModel?

    var body: some View {
        Group {
            if let scene {
                MobileRootView(
                    app: app,
                    scene: scene,
                    pendingQuickAction: delegate.pendingQuickAction,
                    consumePendingQuickAction: delegate.consumePendingQuickAction
                )
                .onAppear { delegate.bind(to: app) }
                .task(id: scenePhase == .active ? delegate.pendingClosedWindowID : nil) {
                    guard scenePhase == .active, let id = delegate.consumePendingClosedWindowID() else { return }
                    if let workspaceID = app.restoreClosedWindow(id, into: scene.workspaceSession) {
                        scene.selectWorkspace(workspaceID)
                    }
                }
                .task(id: scenePhase == .active ? delegate.pendingWorkspaceID : nil) {
                    guard scenePhase == .active, delegate.pendingWorkspaceID != nil else { return }
                    await Task.yield()
                    guard !Task.isCancelled, let id = delegate.consumePendingWorkspaceID() else { return }
                    MobileWorkspaceSceneRouting.reconcile(app: app, activeSessionID: scene.workspaceSession.id)
                    scene.open(WorkspaceActivityAttributes.destinationURL(for: id))
                }
            } else {
                // WindowGroup needs a concrete loading child to start the scene's lifecycle work.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Creating a scene registers observable app state. Keep it out of view construction
            // and body evaluation, and retain the same scene when its parent updates.
            if scene == nil { scene = MobileSceneModel(app: app, sessionID: sessionID) }
        }
    }
}
