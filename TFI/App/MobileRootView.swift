import SwiftUI
import TermindPresentation

/// A window retains its feature stacks while the system adapts tabs into a sidebar.
struct MobileRootView: View {
    let app: MobileAppModel
    private let features: MobileFeatureRegistry
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var scene: MobileSceneModel
    private let pendingQuickAction: MobileHomeScreenQuickAction?
    private let consumePendingQuickAction: () -> MobileHomeScreenQuickAction?

    init(
        app: MobileAppModel,
        scene: MobileSceneModel? = nil,
        features: MobileFeatureRegistry = .standard(),
        pendingQuickAction: MobileHomeScreenQuickAction? = nil,
        consumePendingQuickAction: @escaping () -> MobileHomeScreenQuickAction? = { nil }
    ) {
        self.app = app
        self.features = features
        self.pendingQuickAction = pendingQuickAction
        self.consumePendingQuickAction = consumePendingQuickAction
        _scene = State(initialValue: scene ?? MobileSceneModel(app: app))
    }

    var body: some View {
        TabView(selection: selection) {
            ForEach(features.registrations) { feature in
                Tab(feature.title.swiftUIKey, systemImage: feature.symbol, value: feature.id) {
                    NavigationStack {
                        feature.makeView(app: app, scene: scene)
                    }
                    .mobileToolbarEnvironment()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.singleLineInputAdapter, { AnyView(MobileSingleLineFieldInput()) })
        .sheet(isPresented: Binding(get: { app.pro.isPaywallPresented }, set: { app.pro.isPaywallPresented = $0 })) {
            MobileProView(pro: app.pro)
        }
        .sheet(item: $scene.renamingWorkspace) { descriptor in
            MobileWorkspaceRenameView(descriptor: descriptor) { title in
                app.renameWorkspace(descriptor.id, to: title)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            app.sceneChanged(scene.id, phase: phase)
            MobileHomeScreenQuickActions.refresh(app: app)
        }
        .onChange(of: app.connectionHistory.revision, initial: true) { _, _ in
            MobileHomeScreenQuickActions.refresh(app: app)
        }
        .onChange(of: app.library.hosts) { _, _ in
            MobileHomeScreenQuickActions.refresh(app: app)
        }
        .onChange(of: app.library.identities) { _, _ in
            MobileHomeScreenQuickActions.refresh(app: app)
        }
        .onChange(of: pendingQuickAction, initial: true) { _, action in
            guard action != nil, let action = consumePendingQuickAction() else { return }
            _ = scene.perform(action)
        }
        .onChange(of: app.pro.hasProAccess) { _, _ in app.reconcileSync() }
        .onChange(of: app.workspaces.map(\.id)) { _, workspaceIDs in
            scene.reconcileWorkspaceIDs(workspaceIDs)
        }
        .onDisappear { app.removeScene(scene.id) }
        .onOpenURL(perform: scene.open)
        .focusedSceneValue(\.mobileScene, scene)
        .alert(
            AppStrings.Workspace.openTelnetConnectionConfirmation,
            isPresented: Binding(
                get: { scene.pendingExternalConnection != nil },
                set: { if !$0 { scene.pendingExternalConnection = nil } }
            )
        ) {
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { scene.pendingExternalConnection = nil }
            Button(AppStrings.Common.continue.swiftUIKey) { scene.confirmExternalConnection() }
        } message: {
            Text(AppStrings.Workspace.advisoryTelnetPassword)
        }
        .alert(
            scene.isWorkspaceUnavailable
                ? String(localized: AppStrings.Workspace.workspaceUnavailable)
                : String(localized: AppStrings.Common.operationFailed),
            isPresented: Binding(
                get: { scene.isWorkspaceUnavailable || app.error != nil },
                set: {
                    if !$0 {
                        scene.isWorkspaceUnavailable = false
                        app.error = nil
                    }
                })
        ) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) {
                scene.isWorkspaceUnavailable = false
                app.error = nil
            }
        } message: {
            Text(
                scene.isWorkspaceUnavailable
                    ? String(
                        localized:
                            AppStrings.Workspace.unavailableWorkspaceExplanation
                    ) : app.error ?? "")
        }
        .modifier(MobileAppReviewPresenter(app: app, scene: scene, scenePhase: scenePhase))
        .environment(\.mobileLayout, MobileLayout(sizeClass: sizeClass))
    }

    private var selection: Binding<MobileDestination> {
        Binding(
            get: { scene.selectedDestination ?? .vault },
            set: { scene.selectedDestination = $0 }
        )
    }
}
