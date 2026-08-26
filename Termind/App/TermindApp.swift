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

    init() {
        do {
            let configuration = ModelConfiguration("Termind", schema: HostPersistence.schema)
            let container = try ModelContainer(
                for: HostPersistence.schema,
                migrationPlan: TermindMigrationPlan.self,
                configurations: [configuration]
            )
            modelContainer = container
            let secrets = KeychainSecretStore()
            let hosts = HostLibraryModel(
                modelContext: container.mainContext, secrets: secrets
            )
            let repository = SwiftDataHostRepository(context: container.mainContext)
            let outboxStore = SwiftDataOutboxStore(context: container.mainContext)
            let outboxRunner = OutboxRunner(store: outboxStore)
            let externalToolCalls = ToolAuditModel(
                modelContext: container.mainContext,
                hostName: { [weak hosts] id in hosts?.host(id)?.name }
            )
            _app = State(
                initialValue: AppModel(
                    hosts: hosts,
                    ai: AIConfigurationModel(
                        modelContext: container.mainContext, secrets: secrets
                    ),
                    commandHistory: CommandHistoryModel(modelContext: container.mainContext),
                    externalToolCalls: externalToolCalls,
                    dependencies: AppDependencies(
                        hostRepository: repository,
                        outboxRunner: outboxRunner,
                        agentRunRepository: SwiftDataAgentRunRepository(
                            context: container.mainContext
                        )
                    )
                )
            )
        } catch {
            fatalError("Unable to open Termind's local database: \(error.localizedDescription)")
        }
    }

    #if canImport(AppKit)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    /// Workspace windows share app data, while each keeps its own pinned
    /// Vault/Assistant navigation and dynamic Workspace tabs.
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .modelContainer(modelContainer)
                #if canImport(AppKit)
                    .onAppear { delegate.app = app }
                #endif
        }
        .defaultSize(width: Metrics.Window.defaultWidth, height: Metrics.Window.defaultHeight)
        // RootView publishes the calculated two-column floor. Active optional
        // panes may raise it, but the window can never shrink below the base UI.
        .windowResizability(.contentMinSize)
        .commands { TermindCommands(app: app) }

        Settings {
            SettingsPageView()
                .overlay { ExternalAuthWindowPresenter() }
                .environment(app)
                .modelContainer(modelContainer)
                .frame(minWidth: 920, minHeight: 640)
        }

        Window("Authentication Request", id: ExternalAuthWindowPresenter.sceneID) {
            ExternalAuthWindow()
                .environment(app)
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
    /// In a tabbed app that is the wrong default — ⌘W should close the front tab, and
    /// people lose a screen of work discovering otherwise. SwiftUI has no placement
    /// for that item, so we retarget it here to ⇧⌘W and leave ⌘W to `TermindCommands`.
    final class AppDelegate: NSObject, NSApplicationDelegate {
        weak var app: AppModel?

        func applicationDidFinishLaunching(_ notification: Notification) {
            guard let items = NSApp.mainMenu?.items else { return }
            for menuItem in items {
                guard let submenu = menuItem.submenu else { continue }
                for item in submenu.items where item.action == #selector(NSWindow.performClose(_:)) {
                    item.title = String(localized: "Close Window")
                    item.keyEquivalent = "w"
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
            }
        }

        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }

        func applicationWillTerminate(_ notification: Notification) {
            app?.shutdownForTermination()
        }
    }
#endif
