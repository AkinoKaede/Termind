@preconcurrency import AppKit
import SwiftUI

/// One window with one native Navigator column and one persistent detail deck.
///
/// Vault pages, dynamic Workspaces, and Assistant conversations are destinations
/// in the Navigator rather than a second horizontal workspace system. Workspace native
/// views stay mounted while another destination is in front, preserving terminal
/// grids, scrollback, and SFTP state.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var window: WindowModel
    @State private var layoutWidth = Metrics.Window.defaultWidth
    @State private var automaticQuickOpenReady = false
    @AppStorage(SettingsKey.statusBarExpanded) private var isStatusBarExpanded = true
    @AppStorage(SettingsKey.remoteWindowTitleInMenuBar) private var showsRemoteWindowTitle =
        SettingsKey.defaultRemoteWindowTitleInMenuBarEnabled

    init(window: WindowModel = WindowModel()) {
        _window = State(initialValue: window)
    }

    var body: some View {
        @Bindable var window = window
        @Bindable var presentations = window.presentations

        NavigationSplitView(columnVisibility: sidebarVisibility) {
            ZStack {
                SidebarGlassBackground()
                    .ignoresSafeArea()
                WindowSidebarView()
            }
            .navigationSplitViewColumnWidth(
                min: Metrics.Sidebar.min,
                ideal: min(Metrics.Sidebar.ideal, sidebarMaxWidth),
                max: sidebarMaxWidth
            )
        } detail: {
            detail
                // Floating over the pane rather than docked under it, so switching
                // to a Workspace no longer resizes the content area — and so the
                // bar reads as belonging to the session it describes.
                .overlay(alignment: .bottomTrailing) {
                    if case .workspace = window.selectedDestination {
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
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            WindowToolbarSearchHost()
            WindowActivityReader(
                windowModel: window,
                showsRemoteTitle: showsRemoteWindowTitle
            ) {
                app.onboarding.windowBecameActive(window)
                considerOnboarding()
            }
        }
        .overlay { ExternalAuthWindowPresenter() }
        .frame(
            minWidth: Metrics.Window.minWidth,
            maxWidth: .infinity,
            minHeight: Metrics.Window.minHeight,
            maxHeight: .infinity
        )
        .background { FullHeightWindowContent() }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            layoutWidth = $0
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(
            WindowTitleCatalog.standard(hosts: app.hostLibrary)
                .title(in: window, locale: locale)
        )
        // The window's only toolbar. Creation on the left, one Find on the
        // right, both following the content in front rather than the sidebar —
        // see `WindowToolbarLeadingActions` and `WindowModel.findKind`.
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                WindowToolbarLeadingActions()
            }
            ToolbarItem(placement: .primaryAction) {
                WindowToolbarSearchSlot()
            }
        }
        .sheet(item: $presentations.hostChooser) { purpose in
            HostChooserView(purpose: purpose)
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
            "Conversation Operation Failed",
            isPresented: Binding(
                get: { window.assistantOperationError != nil },
                set: { if !$0 { window.assistantOperationError = nil } }
            )
        ) {
            Button("OK") { window.assistantOperationError = nil }
        } message: {
            Text(window.assistantOperationError ?? "")
        }
        // No ancestor drop target: pane and Navigator targets must own internal
        // layout drops without competing for the same text payload.
        .environment(window)
        .focusedSceneValue(\.window, window)
        .onChange(of: window.selectedDestination) {
            window.refreshSessionContext()
            window.reconcileSidebarMode()
        }
        .onAppear {
            window.proAccess = app.proAccess
            window.connectionCoordinator = app.connections
            window.hostStore = app.hostLibrary
            app.registerWindow(window)
            window.refreshSessionContext()
            window.reconcileSidebarMode()
            app.reconcileProAccess()
            app.onboarding.windowBecameActive(window)
            considerOnboarding()
        }
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
        guard isStatusBarExpanded, let pane = window.selectedWorkspace?.focusedPane,
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
        case .sftpSession(let session):
            guard app.hostLibrary.host(hostID) != nil, session.status == .connected,
                !session.path.isEmpty, session.displayedPath != nil
            else { return nil }
            return OnboardingPathContext(
                direction: .sftpToSSH, hostID: hostID, path: session.path
            )
        case .serialSession, .empty:
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
                bottom: Metrics.StatusBar.overlayClearance, trailing: Metrics.Space.xl
            )
        case .commandGenerator:
            EdgeInsets(
                top: Metrics.Space.xl, leading: Metrics.Space.xl,
                bottom: Metrics.StatusBar.overlayClearance, trailing: Metrics.Space.xl
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
                window.openSFTPSession(
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
        let showsWorkDetail = window.vaultWorkRoute != nil

        return HStack(spacing: 0) {
            VaultView(pages: window.vaultPages)
                .frame(
                    minWidth: Metrics.VaultContent.min,
                    idealWidth: Metrics.VaultContent.ideal,
                    maxWidth: .infinity
                )
                .layoutPriority(1)

            Divider()
                .frame(width: showsWorkDetail ? 1 : 0)
                .opacity(showsWorkDetail ? 1 : 0)

            ZStack {
                if let route = window.vaultWorkRoute {
                    VaultWorkDetailView(route: route)
                        .id(route)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(
                minWidth: showsWorkDetail ? Metrics.VaultDetail.min : 0,
                idealWidth: showsWorkDetail ? Metrics.VaultDetail.ideal : 0,
                maxWidth: showsWorkDetail ? Metrics.VaultDetail.max : 0
            )
            .clipped()
            .opacity(showsWorkDetail ? 1 : 0)
            .allowsHitTesting(showsWorkDetail)
            .accessibilityHidden(!showsWorkDetail)
        }
        .animation(
            Motion.panel(reduceMotion: reduceMotion),
            value: window.vaultWorkRoute
        )
        .frame(
            minWidth: Metrics.VaultContent.min,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
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

/// Extends the split view's material behind the titlebar while retaining the
/// native toolbar chrome.
private struct FullHeightWindowContent: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowContentBridgeView {
        WindowContentBridgeView()
    }

    func updateNSView(_ view: WindowContentBridgeView, context: Context) {
        view.configureWindow()
    }
}

/// Owns window-scoped AppKit integration: key-window onboarding and the remote
/// title report. Keeping both on this persistent bridge avoids routing title
/// changes through whichever Workspace or pane SwiftUI currently renders.
private struct WindowActivityReader: NSViewRepresentable {
    let windowModel: WindowModel
    let showsRemoteTitle: Bool
    let becameKey: () -> Void

    func makeNSView(context _: Context) -> WindowActivityBridgeView {
        WindowActivityBridgeView(
            windowModel: windowModel, showsRemoteTitle: showsRemoteTitle,
            becameKey: becameKey
        )
    }

    func updateNSView(_ view: WindowActivityBridgeView, context _: Context) {
        view.windowModel = windowModel
        view.showsRemoteTitle = showsRemoteTitle
        view.becameKey = becameKey
        view.observeWindow()
        view.reportCurrentRemoteTitle()
    }

    static func dismantleNSView(_ view: WindowActivityBridgeView, coordinator _: ()) {
        if view.windowModel?.remoteWindowTitleSink === view {
            view.windowModel?.remoteWindowTitleSink = nil
        }
        RemoteWindowTitleMenuCoordinator.shared.withdraw(token: view.titleReportToken)
    }
}

private final class WindowActivityBridgeView: NSView, WindowRemoteTitleSink {
    let titleReportToken = UUID()
    weak var windowModel: WindowModel? {
        didSet {
            guard windowModel !== oldValue else { return }
            if oldValue?.remoteWindowTitleSink === self {
                oldValue?.remoteWindowTitleSink = nil
            }
            windowModel?.remoteWindowTitleSink = self
        }
    }
    var showsRemoteTitle: Bool
    var becameKey: () -> Void
    private var observer: (any NSObjectProtocol)?
    private weak var observedWindow: NSWindow?
    private var pendingRemoteTitleReport: Task<Void, Never>?

    init(
        windowModel: WindowModel, showsRemoteTitle: Bool,
        becameKey: @escaping () -> Void
    ) {
        self.windowModel = windowModel
        self.showsRemoteTitle = showsRemoteTitle
        self.becameKey = becameKey
        super.init(frame: .zero)
        windowModel.remoteWindowTitleSink = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    deinit {
        pendingRemoteTitleReport?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        reportCurrentRemoteTitle()
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
                self?.reportCurrentRemoteTitle()
            }
        }
        if window.isKeyWindow { becameKey() }
    }

    private func reportRemoteTitle(_ title: String?) {
        guard let observedWindow else { return }
        RemoteWindowTitleMenuCoordinator.shared.report(
            title: title, for: observedWindow, token: titleReportToken
        )
    }

    func reportCurrentRemoteTitle() {
        reportRemoteTitle(
            showsRemoteTitle ? windowModel?.focusedSSHSession?.menuBarWindowTitle : nil
        )
    }

    func windowRemoteTitleDidChange(_ title: String?) {
        pendingRemoteTitleReport?.cancel()
        pendingRemoteTitleReport = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.reportRemoteTitle(self.showsRemoteTitle ? title : nil)
        }
    }
}

private final class WindowContentBridgeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
    }
}
