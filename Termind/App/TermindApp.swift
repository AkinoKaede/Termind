import AgentKitScrubber
import SwiftData
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

@main
struct TermindApp: App {
    /// Hosts metadata is stored in SwiftData; secrets stay behind Keychain
    /// references held by the value-type projections used throughout the UI.
    private let modelContainer: ModelContainer
    @State private var app: AppModel
    private let launchLanguage: AppLanguage
    private let launchWindow: WindowModel?

    init() {
        ContextAttachmentOpener.cleanPreviousSession()
        ScrubberWebClient.setup()
        #if DEBUG
            let screenshotDemo = ScreenshotDemoConfiguration.active
            launchLanguage = screenshotDemo?.language ?? AppLanguage.stored()
        #else
            launchLanguage = AppLanguage.stored()
        #endif
        do {
            let isRunningTests =
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            #if DEBUG
                let usesInMemoryStore = isRunningTests || screenshotDemo != nil
            #else
                let usesInMemoryStore = isRunningTests
            #endif
            let configuration = ModelConfiguration(
                "Termind", schema: HostPersistence.schema,
                isStoredInMemoryOnly: usesInMemoryStore,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(
                for: HostPersistence.schema,
                migrationPlan: TermindMigrationPlan.self,
                configurations: [configuration]
            )
            modelContainer = container
            #if DEBUG
                if let screenshotDemo {
                    let hosts = HostLibraryModel.demo(language: screenshotDemo.language)
                    let app = AppModel(
                        hosts: hosts, ai: .demo(), proAccess: .unrestrictedForTesting(),
                        onboarding: OnboardingController(automaticPresentationEnabled: false),
                        serverMetrics: screenshotDemo.makeMetricsModel(hosts: hosts)
                    )
                    _app = State(initialValue: app)
                    let window = screenshotDemo.makeWindow(hosts: hosts)
                    launchWindow = window
                    ScreenshotDemoWindow.configure(
                        app: app, windowModel: window, container: container, locale: screenshotDemo.language.locale)
                    return
                }
            #endif
            let secrets = KeychainSecretStore()
            LegacyWebSearchSettings.remove { reference in
                try secrets.setString(nil, for: reference, storage: .thisDevice)
            }
            SettingsKey.migrateSyncPreferences()
            let settingsPersistence = SettingsSyncPersistence(context: container.mainContext)
            try settingsPersistence.prepare()
            let aiSecrets = AISecretStore(context: container.mainContext, keychain: secrets)
            let settingsSync: SettingsSyncCoordinator? =
                isRunningTests
                ? nil
                : SettingsSyncCoordinator(persistence: settingsPersistence, secrets: aiSecrets)
            let hosts = HostLibraryModel(
                modelContext: container.mainContext, secrets: secrets
            )
            let repository = SwiftDataHostRepository(context: container.mainContext)
            let outboxStore = SwiftDataOutboxStore(context: container.mainContext)
            let outboxRunner = OutboxRunner(store: outboxStore)
            let vaultSync: VaultSyncCoordinator? =
                isRunningTests
                ? nil
                : VaultSyncCoordinator(context: container.mainContext)
            let externalToolCalls = ToolAuditModel(
                modelContext: container.mainContext,
                hostName: { [weak hosts] id in hosts?.host(id)?.name }
            )
            let proAccess: ProAccessController =
                isRunningTests
                ? .unrestrictedForTesting()
                : .live()
            _app = State(
                initialValue: AppModel(
                    hosts: hosts,
                    ai: AIConfigurationModel(
                        persistence: SyncedAIConfigurationPersistence(settingsPersistence), secrets: secrets,
                        permissionDefaults: .standard, aiSecrets: aiSecrets, webSearchPersistence: settingsPersistence
                    ),
                    skills: SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(settingsPersistence)),
                    terminalSettings: TerminalSettingsModel(persistence: settingsPersistence),
                    commandHistory: CommandHistoryModel(modelContext: container.mainContext),
                    sftpHistory: SFTPHistoryModel(modelContext: container.mainContext),
                    connectionHistory: ConnectionHistoryModel(
                        modelContext: container.mainContext
                    ),
                    externalToolCalls: externalToolCalls,
                    dependencies: AppDependencies(
                        hostRepository: repository,
                        outboxRunner: outboxRunner,
                        agentRunRepository: SwiftDataAgentRunRepository(
                            context: container.mainContext
                        ),
                        vaultSync: vaultSync, settingsSync: settingsSync
                    ),
                    proAccess: proAccess
                )
            )
            launchWindow = nil
        } catch {
            fatalError("Unable to open Termind's local database: \(error.localizedDescription)")
        }
    }

    #if canImport(AppKit)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    /// Workspace windows share app data, while each keeps its own Navigator
    /// destinations and dynamic Workspaces.
    var body: some Scene {
        WindowGroup(id: "main") {
            RootView(window: launchWindow ?? WindowModel())
                .environment(app)
                .environment(\.locale, launchLanguage.locale)
                .modelContainer(modelContainer)
                .proPaywallPresenter(app: app)
                #if canImport(AppKit)
                    .onAppear { delegate.app = app }
                #endif
        }
        #if DEBUG
            .defaultLaunchBehavior(ScreenshotDemoConfiguration.active == nil ? .automatic : .suppressed)
            .restorationBehavior(ScreenshotDemoConfiguration.active == nil ? .automatic : .disabled)
        #endif
        .defaultSize(width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
        // RootView publishes the calculated two-column floor. Active optional
        // panes may raise it, but the window can never shrink below the base UI.
        .windowResizability(.contentMinSize)
        .commands { TermindCommands(app: app) }

        Window("Authentication Request", id: ExternalAuthWindowPresenter.sceneID) {
            ExternalAuthWindow()
                .environment(app)
                .environment(\.locale, launchLanguage.locale)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 560, height: 240)
        .windowResizability(.contentSize)
        // SwiftUI lists every `Window` scene in the Window menu so people can
        // open it themselves. This one is only ever raised by
        // `ExternalAuthWindowPresenter` when an external client asks for a
        // credential, so opening it by hand shows an empty window that closes
        // itself a moment later. Take the item away.
        .commandsRemoved()
    }
}

#if canImport(AppKit)
    /// Exists for one reason: ⌘W.
    ///
    /// AppKit installs "Close" ⌘W in the File menu, which closes the whole *window*.
    /// Here that is the wrong default — ⌘W should close the active Workspace, and
    /// people lose a screen of work discovering otherwise. SwiftUI has no placement
    /// for that item, so we retarget it here to ⇧⌘W and leave ⌘W to `TermindCommands`.
    final class AppDelegate: NSObject, NSApplicationDelegate {
        weak var app: AppModel? {
            didSet {
                guard let app else { return }
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                app.serverMetrics.start()
                metricsSleep.start(app.serverMetrics)
                metricsMenu.start(app.serverMetrics)
            }
        }
        private let metricsSleep = MetricsSleepObserver()
        private let metricsMenu = MetricsMenuBarController()
        private var quietLaunchObserver: (any NSObjectProtocol)?
        private let appearanceController = AppAppearanceController()

        /// The launch Apple Event is readable only while it is being handled.
        func applicationWillFinishLaunching(_ notification: Notification) {
            appearanceController.start()
            LoginLaunch.capture()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            appearanceController.start()
            // Asked for again in case SwiftUI installed this delegate too late
            // for the call above; `capture()` only ever latches a `true`.
            LoginLaunch.capture()
            openHiddenIfLaunchedAtLogin()
            AppShortcutRegistry.shared.register(AppShortcutRegistration("q"))
            if let items = NSApp.mainMenu?.items {
                for menuItem in items {
                    guard let submenu = menuItem.submenu else { continue }
                    for item in submenu.items
                    where item.action == #selector(NSWindow.performClose(_:)) {
                        item.title = String(localized: "Close Window")
                        item.setTermindShortcut("w", modifiers: [.command, .shift])
                    }
                }
            }

            // Product screenshots must not inherit a developer's last window
            // frame from macOS state restoration. Each demo owns its capture
            // size so tightly focused scenes do not inherit the larger
            // workspace composition.
            #if DEBUG
                if let screenshotDemo = ScreenshotDemoConfiguration.active {
                    ScreenshotDemoWindow.present()
                    app = ScreenshotDemoWindow.model
                    Task { @MainActor in
                        for _ in 0..<100 {
                            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                                window.isRestorable = false
                                window.contentMinSize = .zero
                                window.setFrame(
                                    NSRect(origin: window.frame.origin, size: screenshotDemo.windowSize), display: true)
                                window.center()
                                window.appearance = NSAppearance(named: .aqua)
                                window.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                                try? await Task.sleep(for: .milliseconds(500))
                                if screenshotDemo.scene == .hosts {
                                    window.initialFirstResponder = nil
                                    window.makeFirstResponder(nil)
                                }
                                let neutralFocus = window.firstResponder == nil || window.firstResponder === window
                                let state =
                                    "TERMIND_DEMO_READY window=\(window.windowNumber) "
                                    + "active=\(NSApp.isActive) key=\(window.isKeyWindow) neutral=\(neutralFocus)\n"
                                FileHandle.standardOutput.write(Data(state.utf8))
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        FileHandle.standardError.write(Data("Screenshot window did not appear.\n".utf8))
                    }
                }
            #endif
        }

        func applicationDidBecomeActive(_ notification: Notification) {
            Task { [weak self] in await self?.app?.proAccess.refresh() }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            let menuEnabled = UserDefaults.standard.object(forKey: SettingsKey.showMetricsInMenuBar) as? Bool ?? true
            return !menuEnabled && app?.serverMetrics.keepsRunning != true
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            guard !flag else { return true }
            if !MetricsWindowPresenter.open() { MetricsWindowPresenter.reopen?() }
            return false
        }

        /// Opening at login is for having Termind *available*, not for taking the
        /// screen from whatever the user opened their Mac to do. Hidden rather
        /// than window-less: Termind quits with its last window, so the window is
        /// built as usual and simply never comes forward.
        ///
        /// The hide is armed twice because SwiftUI orders the `WindowGroup`
        /// window front after this runs, which unhides the app again. Whichever
        /// happens first wins, and the observer is torn down either way so a
        /// window the user opens later is never hidden out from under them.
        private func openHiddenIfLaunchedAtLogin() {
            guard LoginLaunch.wasLaunchedAtLogin, SettingsKey.opensAtLoginQuietly else { return }
            NSApp.hide(nil)
            quietLaunchObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSApp.hide(nil)
                    self?.endQuietLaunch()
                }
            }
            // A window that never becomes key — because the first hide already
            // took — would otherwise leave the observer armed for the session.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.endQuietLaunch()
            }
        }

        private func endQuietLaunch() {
            guard let observer = quietLaunchObserver else { return }
            NotificationCenter.default.removeObserver(observer)
            quietLaunchObserver = nil
        }

        func applicationWillTerminate(_ notification: Notification) {
            metricsSleep.stop()
            metricsMenu.stop()
            appearanceController.stop()
            app?.shutdownForTermination()
        }
    }
#endif
