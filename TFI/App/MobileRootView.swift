import SwiftUI
import TermindPresentation

/// Each window uses native tabs or a native sidebar according to its available width.
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
        ZStack {
            if (scene.layout ?? windowLayout) == .compact {
                TabView(selection: tabSelection) {
                    ForEach(features.registrations(on: .compactTab)) { feature in
                        NavigationStack {
                            feature.makeView(app: app, scene: scene, surface: .compactTab)
                        }
                        .tabItem { Label(feature.title, systemImage: feature.symbol) }
                        .tag(feature.id)
                    }
                }
            } else {
                NavigationSplitView {
                    List(selection: sidebarSelection) {
                        ForEach(features.registrations(on: .regularSidebar)) { feature in
                            NavigationLink(value: feature.id) {
                                Label(feature.title, systemImage: feature.symbol)
                            }
                            .accessibilityIdentifier("mobile.sidebar.\(feature.id.rawValue)")
                        }
                    }
                    .listStyle(.sidebar)
                    .accessibilityIdentifier("mobile.sidebar")
                } detail: {
                    NavigationStack {
                        selectedFeature.makeView(app: app, scene: scene, surface: .regularSidebar)
                    }
                    .id(selectedFeature.id)
                }
            }
        }
        .environment(\.singleLineInputAdapter, { AnyView(MobileSingleLineFieldInput()) })
        .sheet(isPresented: Binding(get: { app.pro.isPaywallPresented }, set: { app.pro.isPaywallPresented = $0 })) {
            MobileProView(pro: app.pro)
        }
        .sheet(item: $scene.renamingWorkspace) { workspace in
            MobileWorkspaceRenameView(workspace: workspace) { title in
                app.renameWorkspace(workspace.id, to: title)
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
        .modifier(MobileAppReviewPresenter(app: app, scene: scene, scenePhase: scenePhase))
        .onChange(of: windowLayout, initial: true) { _, layout in scene.updateLayout(layout) }
        .onChange(of: scene.layoutTransition.isBlocked) { _, blocked in
            if !blocked { scene.updateLayout(windowLayout) }
        }
        .environment(\.mobileLayout, windowLayout)
        .environment(\.mobileLayoutTransition, scene.layoutTransition)

    }

    private var windowLayout: MobileLayout { MobileLayout(sizeClass: sizeClass) }

    private var tabSelection: Binding<MobileDestination> {
        let revision = scene.layoutRevision
        return Binding(
            get: { scene.selectedTab },
            set: { destination in
                guard scene.layoutRevision == revision else { return }
                scene.selectedTab = destination
            }
        )
    }

    private var sidebarSelection: Binding<MobileDestination?> {
        let revision = scene.layoutRevision
        return Binding(
            get: { scene.selectedDestination },
            set: { destination in
                guard scene.layoutRevision == revision, let destination else { return }
                scene.selectedDestination = destination
            }
        )
    }

    private var selectedFeature: MobileFeatureRegistration {
        features.registration(for: scene.selectedDestination ?? .vault)
            ?? features.registration(for: .vault)!
    }

}
