// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
        scene: MobileSceneModel,
        features: MobileFeatureRegistry = .standard(),
        pendingQuickAction: MobileHomeScreenQuickAction? = nil,
        consumePendingQuickAction: @escaping () -> MobileHomeScreenQuickAction? = { nil }
    ) {
        self.app = app
        self.features = features
        self.pendingQuickAction = pendingQuickAction
        self.consumePendingQuickAction = consumePendingQuickAction
        _scene = State(initialValue: scene)
    }

    var body: some View {
        content
    }

    private var shouldKeepScreenAwake: Bool {
        MobileScreenAwakeController.wantsAwake(
            preferences: app.terminalExperienceSettings.preferences, isActive: scenePhase == .active,
            workspaceKind: scene.activeWorkspace?.descriptor.kind)
    }

    private var content: some View {
        featureTabs
            .background { MobileWorkspaceNumberShortcuts(scene: scene) }
            .modifier(InitialNotificationAuthorization(model: app.notificationSettings, service: app.notifications))
            .onChange(of: scene.visibleAssistantConversationID, initial: true) { app.refreshAssistantReadState() }
            .onChange(of: shouldKeepScreenAwake, initial: true) { _, value in
                app.screenAwake.update(sceneID: scene.id, wantsAwake: value)
            }
            .environment(\.singleLineInputAdapter, { AnyView(MobileSingleLineFieldInput()) })
            .sheet(isPresented: Bindable(app.pro).projectedValue.isPaywallPresented) {
                MobileProView(pro: app.pro)
            }
            .sheet(item: $scene.renamingWorkspace) { descriptor in
                MobileWorkspaceRenameView(descriptor: descriptor) { title in
                    scene.workspaceSession.renameWorkspace(descriptor.id, to: title)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { scene.agentForwarding.current != nil },
                    set: { if !$0 { scene.agentForwarding.cancelAll() } }
                )
            ) {
                if let challenge = scene.agentForwarding.current {
                    MobileAgentForwardingSheet(interaction: scene.agentForwarding, request: challenge)
                        .id(challenge.id)
                }
            }
            .onDisappear { scene.agentForwarding.isActive = false }
            .onChange(of: scenePhase, initial: true) { _, phase in
                scene.agentForwarding.isActive = phase != .background
                app.sceneChanged(scene.id, phase: phase, workspaceSessionID: scene.workspaceSession.id)
                if phase == .active { app.connectionHistory.refreshMenuDate() }
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
            .onChange(of: scene.workspaceSession.workspaces.map(\.id)) { _, workspaceIDs in
                scene.reconcileWorkspaceIDs(workspaceIDs)
            }
            .onDisappear { app.removeScene(scene.id) }
            .onOpenURL { url in
                MobileWorkspaceSceneRouting.reconcile(app: app, activeSessionID: scene.workspaceSession.id)
                scene.open(url)
            }
            .focusedSceneValue(\.mobileScene, scene)
            .modifier(MobileHistoryMenuPresentation(app: app, scene: scene))
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
            .environment(\.mobileLayout, MobileLayout(sizeClass: sizeClass))
    }

    private var featureTabs: some View {
        TabView(selection: selection) {
            ForEach(features.registrations) { feature in
                Tab(value: feature.id) {
                    featureNavigation(feature)
                        .mobileToolbarEnvironment()
                        .environment(
                            \.mobileConnectionFeedback,
                            MobileConnectionFeedbackContext(
                                isForeground: { [weak app = app, weak scene = scene] in
                                    guard let app, let scene else { return false }
                                    return scene.selectedDestination == feature.id
                                        && app.isNotificationSceneActive(scene)
                                },
                                succeeded: app.terminalEffects.connectionSucceeded))
                } label: {
                    Label(feature.title, systemImage: feature.symbol)
                }
                .badge(unreadCount(for: feature.id))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @ViewBuilder
    private func featureNavigation(_ feature: MobileFeatureRegistration) -> some View {
        if feature.id == .vault {
            NavigationStack(path: $scene.vaultNavigationPath) {
                feature.makeView(app: app, scene: scene)
                    .navigationDestination(for: MobileVaultRoute.self) { route in
                        switch route {
                        case .history:
                            MobileConnectionHistoryView(app: app, open: scene.open)
                        }
                    }
            }
            .id(scene.vaultNavigationID)
        } else {
            NavigationStack {
                feature.makeView(app: app, scene: scene)
            }
        }
    }

    private var selection: Binding<MobileDestination> {
        Binding(
            get: { scene.selectedDestination ?? .vault },
            set: { scene.selectedDestination = $0 }
        )
    }

    private func unreadCount(for destination: MobileDestination) -> Int {
        switch destination {
        case .workspaces: scene.workspaceSession.unreadCompletionCount
        case .assistant: app.unreadAssistantNotificationCount
        default: 0
        }
    }
}

private struct MobileHistoryMenuPresentation: ViewModifier {
    let app: MobileAppModel
    @Bindable var scene: MobileSceneModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                app.connectionHistory.refreshMenuDate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                app.connectionHistory.refreshMenuDate()
            }
            .operationConfirmation(
                .init(AppStrings.Connections.clearConnectionHistoryConfirmation),
                isPresented: $scene.confirmsClearConnectionHistory, placement: .centered,
                actions: [
                    .init(AppStrings.Common.clearHistory, role: .destructive) { scene.clearConnectionHistory() },
                    .init(AppStrings.Common.cancel, role: .cancel) {},
                ], message: .init(AppStrings.Workspace.clearHistoryWarning)
            )
    }
}
