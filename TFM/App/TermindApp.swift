import AgentKitScrubber
import SwiftData
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure

#if canImport(AppKit)
    import AppKit
#endif

@main
struct TermindApp: App {
    static let isRunningTests: Bool = {
        #if DEBUG
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
            false
        #endif
    }()

    static var suppressesAutomaticTestWindows: Bool {
        #if DEBUG
            guard isRunningTests, ProcessInfo.processInfo.environment["TERMIND_WINDOW_TESTS"] != "1" else {
                return false
            }
            return ScreenshotDemoConfiguration.active == nil
        #else
            return false
        #endif
    }

    /// Hosts metadata is stored in SwiftData; secrets stay behind Keychain
    /// references held by the value-type projections used throughout the UI.
    private let modelContainer: ModelContainer
    @State private var app: AppModel
    private let launchLanguage: AppLanguage
    #if DEBUG
        @State private var screenshotWindow: WindowModel?
    #endif

    init() {
        ScrubberWebClient.setup()
        #if DEBUG
            let screenshotDemo = ScreenshotDemoConfiguration.active
            launchLanguage = screenshotDemo?.language ?? AppLanguage.stored()
        #else
            launchLanguage = AppLanguage.stored()
        #endif
        do {
            let isRunningTests = Self.isRunningTests
            #if DEBUG
                let usesInMemoryStore = isRunningTests || screenshotDemo != nil
            #else
                let usesInMemoryStore = isRunningTests
            #endif
            if !usesInMemoryStore { try DatabaseStartupGuard.checkRunningApplications() }
            let container = try TermindPersistence.makeContainer(inMemory: usesInMemoryStore)
            ContextAttachmentOpener.cleanPreviousSession()
            modelContainer = container
            #if DEBUG
                if let screenshotDemo {
                    let hosts = screenshotDemo.makeHostLibrary()
                    let app = AppModel(
                        hosts: hosts, ai: .demo(), proAccess: .unrestrictedForTesting(),
                        onboarding: OnboardingController(automaticPresentationEnabled: false),
                        serverMetrics: screenshotDemo.makeMetricsModel(hosts: hosts)
                    )
                    _app = State(initialValue: app)
                    _screenshotWindow = State(initialValue: screenshotDemo.makeWindow(hosts: hosts))
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
            let metricsDefaults =
                isRunningTests ? UserDefaults(suiteName: "termind.metrics.tests.\(UUID().uuidString)")! : .standard
            let metricsPersistence = MetricsSyncPersistence(
                context: container.mainContext, defaults: metricsDefaults)
            try metricsPersistence.prepare()
            let aiSecrets = AISecretStore(context: container.mainContext, keychain: secrets, defaults: .standard)
            let settingsSync: SettingsSyncCoordinator? =
                isRunningTests
                ? nil
                : SettingsSyncCoordinator(persistence: settingsPersistence, secrets: aiSecrets)
            let metricsSync: MetricsSyncCoordinator? =
                isRunningTests ? nil : MetricsSyncCoordinator(persistence: metricsPersistence)
            let hosts = HostLibraryModel(
                modelContext: container.mainContext, secrets: secrets,
                localDefaults: isRunningTests ? nil : .standard
            )
            if !isRunningTests { try? hosts.migrateCustomPasswordsToICloud() }
            let repository = SwiftDataHostRepository(context: container.mainContext)
            let outboxStore = SwiftDataOutboxStore(context: container.mainContext)
            let outboxRunner = OutboxRunner(store: outboxStore)
            let vaultSync: VaultSyncCoordinator? =
                isRunningTests
                ? nil
                : VaultSyncCoordinator(context: container.mainContext)
            vaultSync?.beforeSend = { [weak hosts] in try hosts?.migrateCustomPasswordsToICloud() }
            let historyPersistence = HistorySyncPersistence(context: container.mainContext)
            try historyPersistence.prepare()
            let connectionHistorySync: ConnectionHistorySyncCoordinator? =
                isRunningTests ? nil : ConnectionHistorySyncCoordinator(persistence: historyPersistence)
            let deviceSync: DeviceSyncCoordinator? =
                isRunningTests ? nil : DeviceSyncCoordinator(persistence: historyPersistence)
            let connectionHistoryRepository = SwiftDataConnectionHistoryRepository(
                context: container.mainContext)
            let deviceDirectoryRepository = SwiftDataDeviceDirectoryRepository(
                context: container.mainContext)
            let connectionHistoryDeviceID = try VaultSyncJournal(context: container.mainContext).state().installationID
            connectionHistoryRepository.didRecordHistoryChanges = { [weak connectionHistorySync] in
                connectionHistorySync?.noteLocalChanges($0)
            }
            deviceDirectoryRepository.didRecordHistoryChanges = { [weak deviceSync] in
                deviceSync?.noteLocalChanges($0)
            }
            let devices = DeviceDirectoryModel(
                repository: deviceDirectoryRepository,
                currentDeviceID: connectionHistoryDeviceID,
                currentDeviceName: Self.computerName)
            let externalToolCalls = ToolAuditModel(
                repository: SwiftDataToolAuditRepository(context: container.mainContext),
                hostName: { [weak hosts] id in hosts?.host(id)?.name }
            )
            let proAccess: ProAccessController =
                isRunningTests
                ? .unrestrictedForTesting()
                : .live()
            let logging: any ApplicationLogManaging =
                isRunningTests ? DisabledApplicationLogManager.shared : LaunchFileLogService()
            vaultSync?.configureLogging(logging)
            connectionHistorySync?.configureLogging(logging)
            deviceSync?.configureLogging(logging)
            settingsSync?.configureLogging(logging)
            metricsSync?.configureLogging(logging)
            let connectionCoordinator = RemoteConnectionCoordinator(
                logger: logging.makeLogger(label: "termind.remote-connection"))
            _app = State(
                initialValue: AppModel(
                    hosts: hosts,
                    ai: AIConfigurationModel(
                        persistence: SyncedAIConfigurationPersistence(settingsPersistence), secrets: secrets,
                        permissionDefaults: .standard, aiSecrets: aiSecrets, webSearchPersistence: settingsPersistence,
                        mcpSecrets: isRunningTests
                            ? InMemoryMCPAuthorizationStore()
                            : MCPKeychainCredentialStore(accessGroup: ApplicationIdentity.keychainAccessGroup)
                    ),
                    skills: SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(settingsPersistence)),
                    memory: isRunningTests
                        ? MemoryModel()
                        : MemoryModel(
                            storage: GRDBMemoryStore(directory: GRDBMemoryStore.defaultDirectory), defaults: .standard),
                    terminalSettings: TerminalSettingsModel(persistence: settingsPersistence),
                    notificationSettings: NotificationSettingsModel(persistence: settingsPersistence),
                    sshSettings: SSHSettingsModel(persistence: settingsPersistence),
                    sftpSettings: SFTPSettingsModel(persistence: settingsPersistence),
                    workspaceSettings: WorkspaceSettingsModel(persistence: settingsPersistence),
                    commandHistory: CommandHistoryModel(modelContext: container.mainContext),
                    sftpHistory: SFTPHistoryModel(
                        repository: SwiftDataSFTPHistoryRepository(context: container.mainContext)
                    ),
                    connectionHistory: ConnectionHistoryModel(
                        repository: connectionHistoryRepository,
                        sourceDeviceID: connectionHistoryDeviceID
                    ),
                    devices: devices,
                    externalToolCalls: externalToolCalls,
                    dependencies: AppDependencies(
                        hostRepository: repository,
                        outboxRunner: outboxRunner,
                        connectionCoordinator: connectionCoordinator,
                        agentRunRepository: SwiftDataAgentRunRepository(
                            context: container.mainContext
                        ),
                        assistantModelSelectionStore: SwiftDataAssistantModelSelectionStore(
                            context: container.mainContext
                        ),
                        assistantChatCollaborationStore: SwiftDataAssistantChatCollaborationStore(
                            context: container.mainContext
                        ),
                        vaultSync: vaultSync, connectionHistorySync: connectionHistorySync, deviceSync: deviceSync,
                        settingsSync: settingsSync,
                        metricsSync: metricsSync, metricsPreferences: metricsPersistence,
                        mcpServerSecrets: secrets,
                        logging: logging,
                        settingsDefaults: .standard
                    ),
                    proAccess: proAccess,
                    appReview: .live(),
                    windowSizeStore: MainWindowSizeStore(defaults: isRunningTests ? nil : .standard)
                )
            )
        } catch PersistentStoreAccessError.inUse {
            DatabaseStartupGuard.presentDatabaseInUseAndExit()
        } catch {
            fatalError("Unable to open Termind's local database: \(error.localizedDescription)")
        }
    }

    fileprivate static var computerName: String {
        MacDeviceName.current
    }

    #if canImport(AppKit)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    private func makeWindow(requestID: UUID?) -> WindowModel {
        #if DEBUG
            if requestID == nil, let screenshotWindow {
                return screenshotWindow
            }
        #endif
        let window = WindowModel()
        app.mainWindows.configure(window, for: requestID)
        return window
    }

    /// Workspace windows share app data, while each keeps its own Navigator
    /// destinations and dynamic Workspaces.
    var body: some Scene {
        WindowGroup(id: "main", for: UUID.self) { $requestID in
            RootView(window: makeWindow(requestID: requestID), requestID: requestID)
                .environment(app)
                .environment(\.locale, launchLanguage.locale)
                .modelContainer(modelContainer)
                #if canImport(AppKit)
                    .onAppear { delegate.app = app }
                #endif
        }
        #if DEBUG
            // XCTest launches the real app. Gating individual tests does not stop
            // SwiftUI from opening or restoring the host's own main window.
            .defaultLaunchBehavior(Self.suppressesAutomaticTestWindows ? .suppressed : .automatic)
            .restorationBehavior(
                Self.isRunningTests || ScreenshotDemoConfiguration.active != nil ? .disabled : .automatic)
        #endif
        .defaultSize(app.windowSizeStore.defaultSize)
        // All main pages share one content floor. Opening the sidebar lets
        // the native split view grow a window that cannot fit both columns.
        .windowResizability(.contentMinSize)
        .commands { TermindCommands(app: app) }

        Window(AppStrings.Connections.authenticationRequest.swiftUIKey, id: ExternalAuthWindowPresenter.sceneID) {
            ExternalAuthWindow()
                .environment(app)
                .environment(\.locale, launchLanguage.locale)
                .modelContainer(modelContainer)
        }
        #if DEBUG
            .defaultLaunchBehavior(Self.suppressesAutomaticTestWindows ? .suppressed : .automatic)
            .restorationBehavior(Self.isRunningTests ? .disabled : .automatic)
        #endif
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
    @MainActor
    final class AppTerminationReplyCoordinator {
        typealias Sleep = @Sendable (Duration) async throws -> Void

        private var replied = false

        func begin(
            cleanup: Task<Void, Never>, timeout: Duration = .seconds(3),
            sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
            reply: @escaping @MainActor () -> Void
        ) {
            Task { @MainActor [weak self] in
                await cleanup.value
                self?.finish(reply)
            }
            Task { @MainActor [weak self] in
                try? await sleep(timeout)
                self?.finish(reply)
            }
        }

        private func finish(_ reply: @MainActor () -> Void) {
            guard !replied else { return }
            replied = true
            reply()
        }
    }

    /// Owns native application lifecycle; window and pane commands live in `TermindCommands`.
    final class AppDelegate: NSObject, NSApplicationDelegate {
        weak var app: AppModel? {
            didSet {
                guard let app else { return }
                #if DEBUG
                    guard !TermindApp.isRunningTests else { return }
                #endif
                app.serverMetrics.start()
                metricsActivity.start(app.serverMetrics)
                metricsMenu.openMainWindow = { [weak app] in app?.mainWindows.openMetrics() }
                metricsMenu.openDetails = { [weak app] hostID in app?.mainWindows.openMetrics(hostID: hostID) }
                metricsMenu.start(app.serverMetrics)
            }
        }
        private let metricsActivity = MetricsActivityObserver()
        private let metricsMenu = MetricsMenuBarController()
        private var awaitingTermination = false
        private let terminationReply = AppTerminationReplyCoordinator()
        private var quietLaunchObserver: (any NSObjectProtocol)?
        private let appearanceController = AppAppearanceController()

        /// The launch Apple Event is readable only while it is being handled.
        func applicationWillFinishLaunching(_ notification: Notification) {
            appearanceController.start()
            MenuImageVisibilityController.shared.start()
            LoginLaunch.capture()
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            appearanceController.start()
            // Asked for again in case SwiftUI installed this delegate too late
            // for the call above; `capture()` only ever latches a `true`.
            LoginLaunch.capture()
            openHiddenIfLaunchedAtLogin()
            AppShortcutRegistry.shared.register(AppShortcutRegistration("q"))

            // Product screenshots must not inherit a developer's last window
            // frame from macOS state restoration. Each demo owns its capture
            // size so tightly focused scenes do not inherit the larger
            // workspace composition.
            #if DEBUG
                if let screenshotDemo = ScreenshotDemoConfiguration.active {
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
                                let titlebarHeight = window.frame.height - window.contentLayoutRect.height
                                let state =
                                    "TERMIND_DEMO_READY window=\(window.windowNumber) "
                                    + "active=\(NSApp.isActive) key=\(window.isKeyWindow) neutral=\(neutralFocus) "
                                    + "titlebar=\(titlebarHeight) scale=\(window.backingScaleFactor)\n"
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
            app?.devices.updateCurrentDeviceName(TermindApp.computerName)
            Task { [weak self] in await self?.app?.proAccess.refresh() }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            #if DEBUG
                // Closing an offscreen fixture must not terminate the test runner.
                guard !TermindApp.isRunningTests else { return false }
            #endif
            let menuEnabled =
                UserDefaults.standard.object(forKey: DesktopSettingsKey.showMetricsInMenuBar) as? Bool ?? true
            return !menuEnabled && app?.serverMetrics.keepsRunning != true
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            #if DEBUG
                guard !TermindApp.suppressesAutomaticTestWindows else { return false }
            #endif
            guard !flag else { return true }
            return app?.mainWindows.handleReopen() ?? true
        }

        func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let item = NSMenuItem(
                title: String(localized: AppStrings.Workspace.newWindow), action: #selector(newWindowFromDock(_:)),
                keyEquivalent: "")
            item.target = self
            item.isEnabled = app?.mainWindows.createScene != nil
            menu.addItem(item)
            return menu
        }

        @objc private func newWindowFromDock(_ sender: NSMenuItem) {
            guard app?.mainWindows.newWindow() != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
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
            guard LoginLaunch.wasLaunchedAtLogin, DesktopSettingsKey.opensAtLoginQuietly else { return }
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

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard let app else { return .terminateNow }
            if awaitingTermination { return .terminateLater }
            awaitingTermination = true
            Task { @MainActor [weak self] in
                await app.sftpEdits.recheck()
                if app.sftpEdits.model.hasPendingChanges {
                    let alert = NSAlert()
                    alert.messageText = String(localized: AppStrings.SFTP.quitWithUnuploadedChangesConfirmation)
                    alert.informativeText = String(
                        localized:
                            AppStrings.SFTP.pendingEditedFilesWarning
                    )
                    alert.addButton(withTitle: String(localized: AppStrings.Common.cancel))
                    alert.addButton(withTitle: String(localized: AppStrings.Common.quitAnyway))
                    guard alert.runModal() == .alertSecondButtonReturn else {
                        self?.awaitingTermination = false
                        NSApp.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
                self?.beginTermination(app)
            }
            return .terminateLater
        }

        private func beginTermination(_ app: AppModel) {
            app.mainWindows.saveSizeForTermination()
            let cleanup = app.shutdownForTermination()
            terminationReply.begin(cleanup: cleanup) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }

        func applicationWillTerminate(_ notification: Notification) {
            metricsActivity.stop()
            metricsMenu.stop()
            appearanceController.stop()
            app?.shutdownForTermination()
        }
    }
#endif
