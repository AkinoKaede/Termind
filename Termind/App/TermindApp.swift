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
                        onboarding: OnboardingController(automaticPresentationEnabled: false)
                    )
                    _app = State(initialValue: app)
                    launchWindow = screenshotDemo.makeWindow(hosts: hosts)
                    return
                }
            #endif
            let secrets = KeychainSecretStore()
            LegacyWebSearchSettings.remove { reference in
                try secrets.setString(nil, for: reference, storage: .thisDevice)
            }
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
                        modelContext: container.mainContext, secrets: secrets
                    ),
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
                        vaultSync: vaultSync
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
        WindowGroup {
            RootView(window: launchWindow ?? WindowModel())
                .environment(app)
                .environment(\.locale, launchLanguage.locale)
                .modelContainer(modelContainer)
                .proPaywallPresenter(app: app)
                #if canImport(AppKit)
                    .onAppear { delegate.app = app }
                #endif
        }
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
        weak var app: AppModel?

        func applicationDidFinishLaunching(_ notification: Notification) {
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                        window.isRestorable = false
                        window.contentMinSize = .zero
                        window.setFrame(
                            NSRect(
                                origin: window.frame.origin,
                                size: screenshotDemo.windowSize
                            ),
                            display: true
                        )
                        window.center()
                    }
                }
            #endif
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }

        func applicationWillTerminate(_ notification: Notification) {
            app?.shutdownForTermination()
        }
    }
#endif
