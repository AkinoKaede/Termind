@preconcurrency import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation

/// One window with one native Navigator column and one persistent detail deck.
///
/// Vault pages, dynamic Workspaces, and Assistant conversations are destinations
/// in the Navigator rather than a second horizontal workspace system. Workspace native
/// views stay mounted while another destination is in front, preserving terminal
/// grids, scrollback, and SFTP state.
struct RootView: View {
    @AppStorage(DesktopSettingsKey.showStatusBar) private var showsStatusBar = true
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let requestID: UUID?
    @State private var window: WindowModel
    @State private var layoutWidth = Metrics.Window.defaultWidth
    @State private var automaticQuickOpenReady = false
    @AppStorage(DesktopSettingsKey.statusBarExpanded) private var isStatusBarExpanded = true

    init(window: WindowModel = WindowModel(), requestID: UUID? = nil) {
        self.requestID = requestID
        _window = State(initialValue: window)
    }

    var body: some View {
        @Bindable var window = window
        @Bindable var presentations = window.presentations

        NavigationSplitView(columnVisibility: sidebarVisibility) {
            WindowSidebarView()
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: { width in
                    app.mainWindows.recordSidebarWidth(width, for: window)
                }
                .background {
                    // Modern split views supply the system sidebar material.
                    // An additional glass surface changes its tint and contrast.
                    if #unavailable(macOS 26.0) {
                        LegacySidebarMaterialBackground()
                            .ignoresSafeArea()
                    }
                }
                .navigationSplitViewColumnWidth(
                    min: Metrics.Sidebar.min,
                    ideal: min(window.sidebar.preferredWidth, sidebarMaxWidth),
                    max: sidebarMaxWidth
                )
        } detail: {
            detail
                // Floating over the pane rather than docked under it, so switching
                // to a Workspace no longer resizes the content area — and so the
                // bar reads as belonging to the session it describes.
                .overlay(alignment: .bottomTrailing) {
                    if case .workspace = window.selectedDestination, showsStatusBar {
                        StatusBarView()
                            .padding(Metrics.StatusBar.floatingInset)
                    }
                }
                .frame(
                    minWidth: Metrics.Window.detailMin,
                    maxWidth: .infinity,
                    minHeight: Metrics.Window.detailMinHeight,
                    maxHeight: .infinity
                )
                .navigationSplitViewColumnWidth(
                    min: Metrics.Window.detailMin,
                    ideal: Metrics.Chat.contentMaxWidth
                )
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: window.visibleAssistantConversationID, initial: true) { app.refreshAssistantReadState() }
        .id(window.sidebar.initialLayoutGeneration)
        .environment(\.singleLinePasteAction, { SingleLineFieldEditing.paste() })
        .background {
            WorkspaceNumberShortcuts(window: window)
            MainWindowRegistration(coordinator: app.mainWindows, model: window, requestID: requestID)
            WindowToolbarSearchHost()
            WindowActivityReader {
                app.onboarding.windowBecameActive(window)
                considerOnboarding()
            }
        }
        .overlay { ExternalAuthWindowPresenter() }
        .frame(
            minWidth: Metrics.Window.minWidth(showsSidebar: window.showsSidebar),
            maxWidth: .infinity,
            minHeight: Metrics.Window.minHeight,
            maxHeight: .infinity
        )
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            layoutWidth = $0
        }
        .onChange(of: window.showsSidebar) { _, _ in
            app.mainWindows.recordSidebarPresentation(for: window)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(
            WindowTitleCatalog.standard(hosts: app.hostLibrary)
                .title(in: window, locale: locale)
        )
        .toolbar(removing: window.showsCompactMetricsDetail ? .title : nil)
        // The window's only toolbar. Creation on the left, one Find on the
        // right, both following the content in front rather than the sidebar —
        // see `WindowToolbarLeadingActions` and `WindowModel.findKind`.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                WindowToolbarLeadingActions()
            }
            ToolbarItem(placement: .principal) {
                MetricsDetailPagePicker()
            }
            ToolbarItem(placement: .primaryAction) {
                WindowToolbarSearchSlot()
            }
        }
        .sheet(
            item: $presentations.hostChooser,
            onDismiss: {
                let ids = window.pendingMetricsHostIDs
                let editable = window.pendingMetricsEditableHostIDs
                window.pendingMetricsHostIDs = nil
                window.pendingMetricsEditableHostIDs = []
                guard let ids else { return }
                window.metricsHostID = nil
                app.serverMetrics.replaceHosts(selectedIDs: ids, editableHostIDs: editable)
            }
        ) { purpose in
            HostChooserView(purpose: purpose)
                .environment(app)
                .environment(window)
                .allowsApplicationTerminationWhenModal()
        }
        .sheet(item: $presentations.workspaceTemplateName) { presentation in
            WorkspaceTemplateNameSheet(presentation: presentation)
                .environment(window)
                .allowsApplicationTerminationWhenModal()
        }
        .overlay {
            if presentations.isQuickOpenPresented {
                QuickOpenOverlay {
                    presentations.isQuickOpenPresented = false
                }
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.985))
                )
            }
        }
        .overlay(alignment: onboardingAlignment) {
            if let onboardingPresentation {
                OnboardingCoachMark(
                    presentation: onboardingPresentation,
                    dismiss: { app.onboarding.dismissCurrent() },
                    performAction: performOnboardingAction
                )
                .padding(onboardingPadding)
                .zIndex(90)
            }
        }
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: app.onboarding.presentation
        )
        .animation(Motion.panel(reduceMotion: reduceMotion), value: presentations.route?.id)
        .alert(
            AppStrings.Assistant.conversationOperationFailed,
            isPresented: Binding(
                get: { window.assistantOperationError != nil },
                set: { if !$0 { window.assistantOperationError = nil } }
            )
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { window.assistantOperationError = nil }
        } message: {
            Text(window.assistantOperationError ?? "")
        }
        .alert(
            AppStrings.Workspace.workspaceTemplate,
            isPresented: Binding(
                get: { window.workspaceTemplateNotice != nil },
                set: { if !$0 { window.workspaceTemplateNotice = nil } }
            )
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { window.workspaceTemplateNotice = nil }
        } message: {
            Text(window.workspaceTemplateNotice ?? "")
        }
        .confirmationDialog(
            AppStrings.Connections.clearConnectionHistoryConfirmation,
            isPresented: $window.confirmsClearConnectionHistory, titleVisibility: .visible
        ) {
            Button(AppStrings.Common.clearHistory.swiftUIKey, role: .destructive) {
                app.clearConnectionHistory()
                window.historyOperationError = app.connectionHistory.storageError
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Workspace.clearHistoryWarning)
        }
        .alert(
            AppStrings.Common.operationFailed,
            isPresented: Binding(
                get: { window.historyOperationError != nil },
                set: { if !$0 { window.historyOperationError = nil } }
            )
        ) {
            Button(AppStrings.Common.ok.swiftUIKey) { window.historyOperationError = nil }
        } message: {
            Text(window.historyOperationError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            app.connectionHistory.refreshMenuDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            app.connectionHistory.refreshMenuDate()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.connectionHistory.refreshMenuDate()
        }
        // No ancestor drop target: pane and Navigator targets must own internal
        // layout drops without competing for the same text payload.
        .environment(window)
        .modifier(InitialNotificationAuthorization(model: app.notificationSettings, service: app.notifications))
        .modifier(AppReviewPresenter(window: window))
        .proPaywallPresenter(app: app, window: window)
        .focusedSceneValue(\.window, window)
        .onChange(of: window.selectedDestination) {
            window.refreshSessionContext()
            window.reconcileSidebarMode()
        }
        .onAppear { [weak app] in
            guard let app else { return }
            app.registerWindow(window)
            window.refreshSessionContext()
            window.reconcileSidebarMode()
            app.reconcileProAccess()
            app.onboarding.windowBecameActive(window)
            considerOnboarding()
        }
        .modifier(ExternalConnectionURLPresenter(app: app, window: window))
        .onChange(of: app.proAccess.status) { app.reconcileProAccess() }
        .onChange(of: onboardingContext) { considerOnboarding() }
        .onChange(of: app.onboarding.revision) { considerOnboarding() }
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            automaticQuickOpenReady = true
            considerOnboarding()
        }
    }

    private var onboardingPresentation: OnboardingPresentation? {
        guard let presentation = app.onboarding.presentation,
            presentation.windowID == ObjectIdentifier(window)
        else { return nil }
        return presentation
    }

    private var onboardingContext: OnboardingContext {
        _ = app.onboarding.revision
        return OnboardingContext(
            canPresentCoachMark: window.presentations.route == nil
                && app.proAccess.status != .loading,
            automaticQuickOpenReady: automaticQuickOpenReady,
            statusBarPath: onboardingPathContext,
            canGenerateCommand: window.focusedSSHSession?.canGenerateFromCurrentDraft == true
                && app.commandGenerator.isLocallyAvailable
        )
    }

    private var onboardingPathContext: OnboardingPathContext? {
        guard showsStatusBar, isStatusBarExpanded,
            let pane = window.selectedWorkspace?.focusedPane,
            let hostID = pane.hostID
        else { return nil }
        switch pane.content {
        case .sshSession(let session):
            guard app.hostLibrary.host(hostID) != nil, session.status.isLive,
                let path = session.workingDirectory, !path.isEmpty,
                session.displayedWorkingDirectory != nil
            else {
                return nil
            }
            return OnboardingPathContext(direction: .sshToSFTP, hostID: hostID, path: path)
        case .sftpChannel(let session):
            guard app.hostLibrary.host(hostID) != nil, session.status == .connected,
                !session.path.isEmpty, session.displayedPath != nil
            else { return nil }
            return OnboardingPathContext(
                direction: .sftpToSSH, hostID: hostID, path: session.path
            )
        case .telnetSession, .serialSession, .empty:
            return nil
        }
    }

    private var onboardingAlignment: Alignment {
        switch onboardingPresentation?.step {
        case .quickOpen: .topTrailing
        case .statusBarPath: .bottomTrailing
        case .commandGenerator: .bottomLeading
        case nil: .topTrailing
        }
    }

    private var onboardingPadding: EdgeInsets {
        switch onboardingPresentation?.step {
        case .statusBarPath:
            EdgeInsets(
                top: Metrics.Space.xl, leading: Metrics.Space.xl,
                bottom: Metrics.StatusBar.overlayClearance(isEnabled: showsStatusBar),
                trailing: Metrics.Space.xl
            )
        case .commandGenerator:
            EdgeInsets(
                top: Metrics.Space.xl, leading: Metrics.Space.xl,
                bottom: Metrics.StatusBar.overlayClearance(isEnabled: showsStatusBar),
                trailing: Metrics.Space.xl
            )
        case .quickOpen, nil:
            EdgeInsets(
                top: Metrics.Space.xl, leading: Metrics.Space.xl,
                bottom: Metrics.Space.xl, trailing: Metrics.Space.xl
            )
        }
    }

    private func considerOnboarding() {
        app.onboarding.consider(window: window, context: onboardingContext)
    }

    private func performOnboardingAction() {
        guard let presentation = onboardingPresentation else { return }
        switch presentation.step {
        case .quickOpen:
            app.onboarding.complete(.quickOpen)
            window.isQuickOpenPresented = true
        case .statusBarPath:
            guard let context = onboardingPathContext,
                let host = app.hostLibrary.host(context.hostID)
            else {
                app.onboarding.dismissCurrent()
                return
            }
            app.onboarding.complete(.statusBarPath)
            switch context.direction {
            case .sshToSFTP:
                window.openSFTPChannel(
                    host: host, initialPath: context.path, placement: .currentWorkspace
                )
            case .sftpToSSH:
                window.openSSHSession(
                    host: host, initialPath: context.path, placement: .currentWorkspace
                )
            }
        case .commandGenerator:
            app.onboarding.complete(.commandGenerator)
        }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { window.showsSidebar ? .all : .detailOnly },
            set: { window.showsSidebar = $0 != .detailOnly }
        )
    }

    private var sidebarMaxWidth: CGFloat {
        Metrics.Window.sidebarMaxWidth(for: layoutWidth)
    }

    private var vaultWorkspace: some View {
        VaultWorkspaceView()
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            PersistentWorkspaceDeckLayout {
                ForEach(window.workspaces) { workspace in
                    let isActive = workspace.id == window.displayedWorkspace?.id
                    WorkspaceContentView(workspace: workspace, isActive: isActive)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .accessibilityHidden(!isActive)
                        .disabled(!isActive)
                        .zIndex(isActive ? 1 : 0)
                        .persistentWorkspaceDeckValue(id: workspace.id, isActive: isActive)
                }
            }
            .clipped()

            switch window.selectedDestination {
            case .vault:
                vaultWorkspace
                    .background(TermindColor.windowSurface)
                    .zIndex(2)
            case .assistant:
                AssistantView()
                    .background(TermindColor.windowSurface)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            case .metrics:
                ServerMetricsView()
                    .background(TermindColor.windowSurface)
                    .zIndex(2)
            case .settings:
                SettingsPageView()
                    .background(TermindColor.windowSurface)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            case .workspace:
                if window.workspaces.isEmpty {
                    VaultView(pages: window.vaultPages)
                }
            }
        }
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: isAssistantFullScreen
        )
        .clipped()
    }

    private var isAssistantFullScreen: Bool {
        window.selectedDestination == .assistant
    }
}

private struct ExternalConnectionURLPresenter: ViewModifier {
    let app: AppModel
    let window: WindowModel

    func body(content: Content) -> some View {
        content
            .onOpenURL { app.openExternalConnection($0, in: window) }
            .alert(
                AppStrings.Workspace.openTelnetConnectionConfirmation,
                isPresented: Binding(
                    get: { window.pendingExternalConnection != nil },
                    set: { if !$0 { window.pendingExternalConnection = nil } }
                )
            ) {
                Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { window.pendingExternalConnection = nil }
                Button(AppStrings.Common.continue.swiftUIKey) { app.confirmExternalConnection(in: window) }
            } message: {
                Text(AppStrings.Workspace.advisoryTelnetPassword)
            }
            .alert(
                AppStrings.Workspace.connectionLinkFailed,
                isPresented: Binding(
                    get: { window.externalConnectionError != nil },
                    set: { if !$0 { window.externalConnectionError = nil } }
                )
            ) {
                Button(AppStrings.Common.ok.swiftUIKey) { window.externalConnectionError = nil }
            } message: {
                Text(window.externalConnectionError ?? "")
            }
    }
}

/// Notifies onboarding when this window becomes active.
private struct WindowActivityReader: NSViewRepresentable {
    let becameKey: () -> Void

    func makeNSView(context _: Context) -> WindowActivityBridgeView {
        WindowActivityBridgeView(becameKey: becameKey)
    }

    func updateNSView(_ view: WindowActivityBridgeView, context _: Context) {
        view.becameKey = becameKey
        view.observeWindow()
    }
}

private final class WindowActivityBridgeView: NSView {
    var becameKey: () -> Void
    private var observer: (any NSObjectProtocol)?
    private weak var observedWindow: NSWindow?

    init(becameKey: @escaping () -> Void) {
        self.becameKey = becameKey
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
    }

    func observeWindow() {
        guard observedWindow !== window else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observedWindow = window
        guard let window else {
            observer = nil
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.becameKey()
            }
        }
        if window.isKeyWindow { becameKey() }
    }
}
