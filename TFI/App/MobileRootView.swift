import SwiftUI

/// iPhone has four destinations. iPad retains the sidebar with individual library routes.
struct MobileRootView: View {
    let app: MobileAppModel
    private let features = MobileFeatureRegistry.standard()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.mobileInterfaceIdiom) private var interfaceIdiom
    @State private var scene: MobileSceneModel

    init(app: MobileAppModel, scene: MobileSceneModel? = nil) {
        self.app = app
        _scene = State(initialValue: scene ?? MobileSceneModel(app: app))
    }

    var body: some View {
        Group {
            if interfaceIdiom != .pad {
                TabView(selection: $scene.selectedTab) {
                    ForEach(features.registrations(on: .phoneTab)) { feature in
                        NavigationStack {
                            feature.makeView(app: app, scene: scene, surface: .phoneTab)
                        }
                        .tabItem { Label(feature.title, systemImage: feature.symbol) }
                        .tag(feature.id)
                    }
                }
            } else {
                NavigationSplitView {
                    List(selection: $scene.selectedDestination) {
                        ForEach(features.registrations(on: .padSidebar)) { feature in
                            NavigationLink(value: feature.id) {
                                Label(feature.title, systemImage: feature.symbol)
                            }
                        }
                    }
                } detail: {
                    NavigationStack {
                        selectedFeature.makeView(app: app, scene: scene, surface: .padSidebar)
                    }
                }
                .id(scene.selectedDestination ?? .vault)
            }
        }
        .sheet(isPresented: Binding(get: { app.pro.isPaywallPresented }, set: { app.pro.isPaywallPresented = $0 })) {
            MobileProView(pro: app.pro)
        }
        .sheet(item: $scene.renamingWorkspace) { workspace in
            MobileWorkspaceRenameView(workspace: workspace) { title in
                app.renameWorkspace(workspace.id, to: title)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in app.sceneChanged(scene.id, phase: phase) }
        .onChange(of: app.pro.hasProAccess) { _, _ in app.reconcileSync() }
        .onChange(of: app.workspaces.map(\.id)) { _, workspaceIDs in
            scene.reconcileWorkspaceIDs(workspaceIDs)
        }
        .onDisappear { app.removeScene(scene.id) }
        .onOpenURL(perform: scene.open)
        .focusedSceneValue(\.mobileScene, scene)
        .alert(
            scene.isWorkspaceUnavailable
                ? String(localized: "Workspace Unavailable") : String(localized: "Operation Failed"),
            isPresented: Binding(
                get: { scene.isWorkspaceUnavailable || app.error != nil },
                set: {
                    if !$0 {
                        scene.isWorkspaceUnavailable = false
                        app.error = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {
                scene.isWorkspaceUnavailable = false
                app.error = nil
            }
        } message: {
            Text(
                scene.isWorkspaceUnavailable
                    ? String(localized: "This workspace was closed or its host was removed.") : app.error ?? "")
        }

    }

    private var selectedFeature: MobileFeatureRegistration {
        features.registration(for: scene.selectedDestination ?? .vault)
            ?? features.registration(for: .vault)!
    }

}
