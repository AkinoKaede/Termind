---
type: architecture
title: Platform startup and runtime composition
description: How macOS and iOS compose shared storage and runtime services, gate scene creation on local consent, and manage window, session, background and shutdown lifetimes.
tags: [architecture, runtime, macos, ios, lifecycle, dependency-injection]
sources:
  - id: openwiki-source-875da2c4f1040409e53757af
    resource: repo://Frameworks/TermindApplication/Events/HostDeletionHandlers.swift
  - id: openwiki-source-162732a78d991992cfb9458d
    resource: repo://Frameworks/TermindApplication/FeatureModels/DiagnosisController.swift
  - id: openwiki-source-1d1f503a260f304a969fcee4
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncLifecycle.swift
  - id: openwiki-source-31cbaa9f7ceabda76ea07ba4
    resource: repo://Frameworks/TermindInfrastructure/Cloud/HistoryRecordSyncCoordinator.swift
  - id: openwiki-source-3effdff7f6b04e2a66d8f651
    resource: repo://Frameworks/TermindInfrastructure/Cloud/MetricsSyncCoordinator.swift
  - id: openwiki-source-04ef2b2f02773f8833db9a8b
    resource: repo://Frameworks/TermindInfrastructure/Cloud/SettingsSyncCoordinator.swift
  - id: openwiki-source-303e34b5782a7a14e28cc9f8
    resource: repo://Frameworks/TermindPersistence/PersistentStoreLock.swift
  - id: openwiki-source-63e25c47c9c7d38b354f4123
    resource: repo://Frameworks/TermindPersistence/SwiftDataHostRepository.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-f7f7803d6920f3e68b98385b
    resource: repo://Frameworks/TermindPresentation/CloudSyncSettingsContent.swift
  - id: openwiki-source-ecede91560d27caa3ae01d3e
    resource: repo://Frameworks/TermindPresentation/DiagnosisConsentView.swift
  - id: openwiki-source-ad1a1eea0aea739f2004d93a
    resource: repo://FrameworkTests/PersistentStoreLockTests.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-dc9295278cc250ed20567540
    resource: repo://TFI/App/MobileAppDependencies.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-5b8c72c5373a41af34fa9fd4
    resource: repo://TFI/App/MobileStartupView.swift
  - id: openwiki-source-c1f5a86747a33d4e8472672c
    resource: repo://TFI/App/MobileWorkspaceSessionModel.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-9c78befae6b387426c603305
    resource: repo://TFI/Application/Workspaces/MobileWorkspaceDescriptor.swift
  - id: openwiki-source-ccfded56a6676310f11a2981
    resource: repo://TFI/Features/Settings/MobileSyncSettingsView.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-350d4a794cfef67e406ddf9b
    resource: repo://TFI/Infrastructure/MobileWorkspaceStore.swift
  - id: openwiki-source-e74324c5f606995238d16c29
    resource: repo://TFI/Platform/MobileAppDelegate.swift
  - id: openwiki-source-34542e0f07e1650e098824c7
    resource: repo://TFI/Platform/MobileBackgroundController.swift
  - id: openwiki-source-d34ac3e852773901d0566033
    resource: repo://TFI/Platform/MobileHomeScreenQuickActions.swift
  - id: openwiki-source-de285e30d853611503042782
    resource: repo://TFI/Platform/MobileWorkspaceSceneRouting.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-c9618f94f83d3b529a9860e1
    resource: repo://TFITests/MobileBackgroundControllerTests.swift
  - id: openwiki-source-68ab6aaabd7a3499cfe23434
    resource: repo://TFITests/MobileHomeScreenQuickActionTests.swift
  - id: openwiki-source-b360f8803ec98b554faad9bb
    resource: repo://TFITests/MobileWorkspaceSessionTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-d5cca6ff91d9aaa5da323b40
    resource: repo://TFM/App/DatabaseStartupGuard.swift
  - id: openwiki-source-873894299539cce9a737a860
    resource: repo://TFM/App/RootView.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-6a1a95f7d01cc8e15a397f6b
    resource: repo://TFM/App/TermindCommands.swift
  - id: openwiki-source-0a0c39623be1c4e870d0f538
    resource: repo://TFM/Features/Settings/SyncSettings.swift
  - id: openwiki-source-ee09ece1fddff7d72a2b5cf4
    resource: repo://TFM/Features/Workspaces/Pane.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-68b5f4529ef349aac826b1d9
    resource: repo://TFM/Platform/MacDeviceName.swift
  - id: openwiki-source-22e92f96394f292a731fc6fb
    resource: repo://TFM/Platform/MainWindowCoordinator.swift
  - id: openwiki-source-73c75477db0674192248aa00
    resource: repo://TFMTests/AppTerminationTests.swift
  - id: openwiki-source-39248df19c48bb72235c6e8d
    resource: repo://TFMTests/AppTestHostTests.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-e6490dc6a3e86e39aa4323fc
    resource: repo://TFMTests/DatabaseStartupGuardTests.swift
  - id: openwiki-source-531f6567ecf96fd4b0c5e97a
    resource: repo://TFMTests/ExternalConnectionURLTests.swift
  - id: openwiki-source-32c251eb2f83ec0be2f1a0e8
    resource: repo://TFMTests/RepositoryOutboxTests.swift
  - id: openwiki-source-a08489338be00125d646c77e
    resource: repo://TFMTests/VisibleWindowTestTrait.swift
generated: { by: "codex", at: "2026-10-02T08:42:40.505Z" }
verified:
  - by: openwiki/0.6.0
    at: 2026-10-02T08:42:40.505Z
---

# Platform startup and runtime composition

Both production entrypoints assemble a local diagnosis controller with installation-local consent and a reporter initially enabled **only** if consent was already granted. An unset choice gates the normal root UI, not container construction: the desktop `WindowGroup` shows `DiagnosisConsentView` instead of constructing `RootView`/`WindowModel`, and `MobileStartupView` shows that view instead of binding a scene session. Screenshots and default test assemblies use an inert controller without defaults or reporter, so they do not require a consent choice. On iOS, a failed model construction still takes the unavailable-store branch rather than showing consent. See [Persistence and Secrets](/openwiki/concepts/persistence-and-secrets.md) for storage details.

```mermaid
flowchart TD
    DLaunch["Desktop entrypoint"] --> DMode{"Memory launch"}
    DMode -->|"No"| DGuard["Other instance preflight and store lock"]
    DMode -->|"Yes"| DStore["In-memory container"]
    DGuard -->|"In use"| DAlert["Database in use alert then exit"]
    DGuard -->|"Available"| DOpen["Open disk container"]
    DOpen -->|"Other error"| DFatal["Fatal startup error"]
    DStore --> DApp["Build app runtime"]
    DOpen --> DApp
    DApp --> DConsent{"Consent needed"}
    DConsent -->|"Yes"| DChoice["Consent view"]
    DConsent -->|"No"| DWindow["Per-window root and model"]
    MLaunch["Mobile entrypoint"] --> MResult["Build startup Result"]
    MResult -->|"Failure"| MUnavailable["Store unavailable view"]
    MResult -->|"Success"| MConsent{"Consent needed"}
    MConsent -->|"Yes"| MChoice["Consent view"]
    MConsent -->|"No"| MScene["Bind UIKit scene session"]
```

Startup creates the shared runtime before asking for diagnostics consent; only successful, consent-cleared scene content constructs normal window or scene state.

Termind has separate native application targets—`TFM` for macOS and `TFI` for iOS/iPadOS—but both compose the same layered frameworks into a platform-owned runtime. The application target owns startup, native lifecycle hooks, dependency assembly, platform UI, and the boundary between durable app data and live UI/session state. Shared frameworks do not import either app target.

The most important lifetime rule is: **stores, coordinators, and durable-data services are app-wide; desktop workspaces belong to a window, mobile workspaces belong to a persistent UIKit scene session (managed by the app), and navigation/presentation belongs to the individual SwiftUI scene.** Live transports belong to those workspaces, not to an app-wide interchangeable workspace pool.

## UI structure and design guides

This page explains runtime composition and lifetime boundaries. For the component trees and user-facing presentation rules, continue with:

- [TFM Desktop UI Architecture](/openwiki/architecture/desktop-ui.md): window shell, persistent workspace deck, split panes, Vault list/detail, managed cards and native transcript ownership.
- [TFI Mobile UI Architecture](/openwiki/architecture/mobile-ui.md): registered feature stacks, scene-local routes, shared workspaces, usable-region layout, mobile toolbars and native input continuity.
- [UI Design Principles and Shared Presentation Boundaries](/openwiki/concepts/ui-design-principles.md): what the platforms share, where their visual/input policies intentionally differ, and how to extend them without merging runtime ownership.

## Lifetime map

| Scope | macOS | iOS/iPadOS | Examples |
| --- | --- | --- | --- |
| Process / app model | One `AppModel`, retained in `TermindApp` state | One `MobileAppModel`, created before the `WindowGroup` | SwiftData container, host library, settings and sync coordinators, shared remote coordinator, histories, transfer and forwarding services, entitlement/review state |
| Native window / scene | `WindowModel` per main window | `MobileSceneModel` per SwiftUI scene, bound to an app-managed `MobileWorkspaceSessionModel` by UIKit session ID | destination, selection, sheets, navigation routes, focused-value command routing, scene-local assistant navigation |
| Workspace and session | Desktop `Workspace` and panes are owned by one `WindowModel` | Each `MobileWorkspaceSessionModel` owns its own ordered descriptors and live `MobileWorkspace`s; `MobileAppModel` coordinates all sessions | terminal or SFTP UI, connection journey, transport, terminal state, workspace-specific operations |
| Durable state | SwiftData, Keychain, supported UserDefaults and sync stores | Same categories, plus an app-written `MobileWorkspaceStore` snapshot keyed by persistent UIKit session ID | Hosts and settings, secret references, histories, mobile per-window workspace descriptors |
| Ephemeral runtime state | Never restored as a live connection | Never restored as a live connection | SSH/SFTP transports, authentication journeys, one-shot URL credentials, in-flight runs/transfers |

A useful consequence is that sharing a desktop `AppModel` does **not** make its `WindowModel`s share selection, sidebar/search state, or workspaces. On mobile, two native windows opening the same Host create independent workspaces and transports. A workspace link received in another window activates the descriptor's existing native owner rather than copying or opening it there. Repeated selection *within the owner* reuses the published workspace and its initial connection attempt.

## macOS composition

`TermindPersistence.makeContainer` fixes the shared versioned SwiftData schema and migration plan for both platforms; the entrypoint chooses whether the container is memory-backed or file-backed and retains it, rather than defining separate platform model sets. `TermindApp.init()` is the desktop composition root. It sets up the scrubber web client and chooses the stored launch language (or a screenshot-demo language), then, **before opening the disk-backed store**, checks for another nonterminated app with the same bundle identifier. This protects against older installed versions that do not implement store locking. `TermindPersistence.makeContainer` independently acquires an exclusive, nonblocking `.lock` file lease **before SwiftData opens or migrates** the store. The container retains that lease for its lifetime; same-process containers for the canonical URL share it, and the lock file is not unlinked on close. Both an older running instance and a competing lock raise `PersistentStoreAccessError.inUse`: the app presents a database-in-use alert and exits after acknowledgment. Other container or preparation failures call `fatalError` instead of replacing production data with an empty store. The macOS guard and lock are skipped for in-memory launches; the iOS entrypoint instead captures startup failures as a `Result` and displays an unavailable-data screen.

After the container opens, the desktop entrypoint cleans previous context attachments, prepares settings and metrics persistence, makes the Keychain-backed secret store, and assembles `AppModel` with repositories, sync coordinators, logging, histories, the device directory, and a common `RemoteConnectionCoordinator`. The directory uses the Vault journal's stable installation ID and `MacDeviceName.current`: the trimmed `kern.hostname`, falling back to DeviceKit's `Device.current.safeDescription` when unavailable or empty.

**Debug test and screenshot launches still run the real app entrypoint, but not the normal disk-backed runtime.** XCTest detection uses `XCTestConfigurationFilePath` in DEBUG; it selects an in-memory container, a private metrics defaults suite, disabled file logging, unrestricted test Pro access, no Vault/History/Device/Metrics/Settings cloud coordinators, no local host defaults or production memory store, and a window size store without persisted defaults. A screenshot-demo configuration also uses an in-memory container but returns early with demo hosts, AI, metrics and onboarding instead of constructing the normal production services. Neither path is a fallback for a failed production database open: construction errors still fail startup.

```mermaid
flowchart TD
    Launch["TermindApp init"] --> Guard["Disk launch checks other running instances"]
    Guard --> Lock["Container acquires disk store lease before open"]
    Lock --> Store["TermindPersistence makeContainer"]
    Launch --> Memory["Test or screenshot uses memory container"]
    Memory --> Store
    Guard -->|"Store in use"| Alert["Alert then exit"]
    Lock -->|"Store in use"| Alert
    Store -->|"Screenshot mode"| Demo["Isolated demo AppModel"]
    Store -->|"Normal or XCTest"| Persistence["Settings and metrics persistence"]
    Store --> Hosts["HostLibraryModel and SwiftData repositories"]
    Launch --> Secrets["KeychainSecretStore"]
    Launch --> Logging["LaunchFileLogService"]
    Launch --> Remote["RemoteConnectionCoordinator"]
    Persistence --> Sync["Vault History Device Metrics and Settings sync coordinators"]
    Hosts --> App["AppModel app-wide runtime"]
    Secrets --> App
    Logging --> App
    Remote --> App
    Sync --> App
    Demo --> Group["WindowGroup main"]
    App --> Group
    Group --> Consent["Consent view when needed"]
    Group -->|"Consent resolved"| Window["WindowModel per window"]
    Window --> Root["RootView retains window"]
    App --> Root
    Window --> Workspace["Window-owned Workspaces and panes"]
    App --> AuthWindow["External authentication Window"]
```

This diagram shows the desktop composition root and the split between one app runtime and per-window workspace ownership.

### Shared desktop runtime

`AppModel` is the cross-window coordinator and service owner. It owns the host and credential projections, known-hosts/snippet/forwarding/transfer libraries, terminal and SSH/SFTP settings, histories, AI/skills/memory, metrics, entitlement and review controllers, remote connection coordination, SFTP edit/transfer services, forwarding, MCP services, and sync/outbox integration. It also owns the global conversation store and one speech transcription coordinator, avoiding duplicate conversation state and competing audio taps across windows.

The model keeps only weak registrations for open `WindowModel`s. Registration injects shared stores and coordinators into a window and attaches that window's assistant library to the process-wide conversation store. Fan-out operations—such as a host route change or deletion—find registered windows and disconnect or close the affected window-owned workspaces. A desktop deletion request first persists the repository marker/outbox jobs, clears local histories and projects the Host away; the registered outbox handlers close panes across windows, cancel transfers, stop forwarding and finalize repository cleanup. A failed request reports a storage error instead of projecting the removal. This is coordination, not ownership transfer: the window remains responsible for its own UI and workspaces.

`TermindApp` creates a `WindowGroup(id: "main", for: UUID.self)`. Once diagnosis consent is resolved, each scene receives a fresh `WindowModel` (except a request-less debug screenshot scene, which can receive demo window state), places it in `RootView`, and injects the same `AppModel` and SwiftData container through the SwiftUI environment. Until then, it shows the consent view without creating a window model. `RootView` retains that model in `@State`, registers it on appearance, and exposes it via the environment and focused scene value. The independent `Authentication Request` window shares app dependencies but is reserved for external authentication presentation; `.commandsRemoved()` prevents normal Window-menu creation.

**Scene policy is separate from store policy.** In DEBUG, a default XCTest host suppresses automatic launch of both the main and authentication scenes unless `TERMIND_WINDOW_TESTS=1` or screenshot-demo mode is active. Tests disable restoration for both scenes even when visible windows are opted in; screenshot mode disables main-scene restoration, while ordinary launches use automatic launch and restoration. The delegate also refuses Dock reopen while test-window suppression applies, refuses to quit the test host when its last fixture window closes, and skips starting metrics activity/menu in tests. Explicit window/focus tests use `.requiresVisibleWindow` and opt in with `TERMIND_WINDOW_TESTS=1` (or Xcode's `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` forwarding); suppression is not a ban on explicitly created offscreen test fixtures. The default test-host checks assert no visible windows and no reopen. To exercise a gated suite, use `TEST_RUNNER_TERMIND_WINDOW_TESTS=1 xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile -only-testing:TFMTests/<Suite> test`; the test host itself checks `TERMIND_WINDOW_TESTS=1`. Keep routine logic and offscreen tests on the default suppressed path.

### Window-local desktop state

`WindowModel` contains the state that may legitimately differ in another desktop window: navigator destination, dynamic workspaces and panes, sidebar and search behavior, workspace selection, local presentations, and window-specific assistant surfaces. `RootView` preserves mounted workspace-native views when a different destination becomes visible so terminal grids, scrollback, and SFTP UI state survive navigation.

A host-opening action is centralized in `AppModel`, which chooses the requested protocol, but it opens into the caller's `WindowModel`. That window assigns one connection-history event to each saved-host SSH, Telnet or SFTP pane. Closing the pane/workspace ends the event before disconnecting, while moving a live pane preserves it and reopening creates a new event. External temporary and Serial panes are not recorded; a crash may leave `endedAt` absent. A batch can deliberately create separate window-local workspaces or one workspace with several panes. External SSH/SFTP/Telnet URLs likewise create a temporary workspace in the target window without adding a saved Host; Telnet URLs containing an advisory password require explicit confirmation first.

`TermindCommands` registers SwiftUI's `openWindow(id: "main", value:)` factory with `MainWindowCoordinator`. The coordinator assigns a request UUID and keeps layout and optional move information until the new native window is registered. `RootView` installs a `MainWindowRegistration` bridge in its background; its `NSView` waits for its native `NSWindow`, applies the full-size content style, then registers the native window and per-scene model. Registration injects app services, consumes the matching request and transfers a live workspace or pane only after the destination window exists. A restored scene has no pending request, so it retains its system-restored frame instead of inheriting the shared size fallback or replaying a move. The coordinator records normal window sizing at appropriate boundaries and unregisters and closes the model when its native window closes. Restoring a window thus does not replay a moved workspace or reopen its live connection. The AppKit delegate handles Dock reopen/new-window behavior and may retain the process after the last window according to menu-bar metrics configuration.

### Desktop lifecycle and termination

The AppKit delegate starts native appearance/login handling and, outside tests, starts metrics activity and the metrics menu once `AppModel` is available. For quiet login launches it hides the normally constructed window rather than running window-less; a one-shot key-window observer and three-second disarm prevent a later user-opened window from being hidden. On app activation it refreshes both entitlement state and the current `DeviceRecord` display name from `MacDeviceName.current`; the synchronized directory can therefore update without rewriting connection events. TFI refreshes its name directly from DeviceKit's `Device.current.safeDescription` on active-scene transitions. On termination the desktop app first checks for pending external edits; after user confirmation, it saves window sizing and invokes `AppModel.shutdownForTermination()`.

Shutdown is deliberately idempotent and bounded by the delegate. `applicationShouldTerminate` returns `.terminateLater` while it rechecks external SFTP edits; if pending changes exist and the user cancels the alert, it replies `false`, clears the pending-termination flag and does **not** start cleanup. An accepted quit saves the ordinary window size before cleanup. `shutdownForTermination()` immediately fences assistant admission, cancels pending run preparation, stops the app-wide conversation store (including conversations no longer shown in a registered window) and awaits terminal saves; it also suspends memory and edit monitoring, shuts down metrics and speech, closes registered windows, and cancels SFTP work, external authentication, forwarding and the outbox. It concurrently awaits MCP and SFTP cancellation, then closes agent background commands and connection pools **after** the assistant drains. Repeated calls return the same cleanup task. The delegate replies `true` to macOS when cleanup finishes or after a once-only three-second fallback; that bound applies to the quit reply, **not** a guarantee that every asynchronous drain finished. `applicationWillTerminate` repeats cleanup safely.

```mermaid
sequenceDiagram
    participant Delegate as AppKit delegate
    participant Model as AppModel
    participant Assistant as Conversation store
    participant Services as Runtime services
    Delegate->>Delegate: Recheck pending external edits
    alt Quit cancelled
        Delegate-->>Delegate: Reply false without cleanup
    else Quit accepted
        Delegate->>Model: Save window size and start shutdown
        Model->>Assistant: Fence admission and cancel preparations
        Model->>Assistant: Stop stored conversations
        Model->>Services: Close windows and stop runtime work
        Model->>Assistant: Await terminal persistence
        Model->>Services: Await MCP and SFTP cancellation
        Model->>Services: Close agent commands then connection pools
        alt Cleanup completes first
            Model-->>Delegate: Cleanup task completes
        else Three second fallback wins
            Delegate-->>Delegate: Timeout reached
        end
        Delegate-->>Delegate: Reply true once
    end
```

Desktop termination orders assistant draining before agent connection teardown, but the native quit reply can precede completion of that drain.

## Mobile composition

`TermindIOSApp` runs language-preference migration and constructs one startup `Result<MobileAppModel, Error>`. It selects `.testing()` dependencies when XCTest is detected and `.live()` otherwise. The `WindowGroup` uses `MobileStartupView.sceneContent(for:)`, a `@Sendable` closure carrying only the result: SwiftUI can invoke lazy scene content off the main actor, so the view accesses main-actor app state only in `body`. A successful body injects the shared model container into scene content and shows the diagnosis consent view if needed before binding the UIKit session; construction failure instead displays an unavailable-data screen rather than terminating the process. `MobileAppDelegate` configures UIKit window scenes, registers for remote notifications outside tests, and queues native session discards received before the model is assigned.

```mermaid
flowchart TD
    Launch["TermindIOSApp init"] --> Deps["MobileAppDependencies live or testing"]
    Deps --> MobileApp["MobileAppModel app-wide runtime"]
    MobileApp --> Container["SwiftData ModelContainer"]
    MobileApp --> Services["Libraries sync transfer forwarding assistant metrics"]
    MobileApp --> Sessions["Workspace session registry keyed by UIKit session ID"]
    MobileApp --> Group["WindowGroup"]
    Group -->|"Startup failure"| Unavailable["Unavailable data store view"]
    Group --> Startup["MobileStartupView success or unavailable store"]
    Startup -->|"Needs consent"| Consent["Diagnosis consent view"]
    Startup -->|"Successful and consent resolved"| Bound["Bound scene root keyed by UIKit session ID"]
    Bound --> Scene["MobileSceneModel created in task per scene"]
    Scene --> Root["MobileRootView retains scene"]
    Scene --> Nav["Tab and navigation selection"]
    Scene --> Owner["Own UIKit workspace session"]
    Sessions --> Owner
    Owner --> Workspace["Session-owned MobileWorkspaces"]
    Workspace --> Transport["Workspace-owned connection"]
    Root --> Phase["scenePhase"]
    Phase --> MobileApp
    MobileApp --> Background["Aggregate phases then suspend or expire runtime work"]
```

This diagram shows app-managed mobile workspace sessions with distinct native-window ownership and scene-local navigation.

### Dependency assembly and test seams

`MobileAppDependencies` is the mobile assembly seam. Live dependencies create a launch file logger and a single `RemoteConnectionCoordinator`, which is passed to both mobile workspace connections and metrics; the same logger is passed to forwarding. Test dependencies use in-memory mode and permit replacement of the host repository, defaults, background-task manager, workspace connection services, metrics services, review controller, container, workspace store, live-activity controller, and forwarding factory.

`MobileAppModel` creates or receives its `ModelContainer`, then builds the host repository, outbox, Keychain or in-memory secret store, settings/metrics persistence and sync coordinators, host and credential libraries, AI/skills/memory, assistant, metrics, transfers and SFTP edits, forwarding, histories, the generic device directory, and live activities. The device directory and connection history use separate repositories on the same Vault context and share the stable installation ID; each repository journals its own payload kind transactionally. Session-owned workspace publication notifies the app to start an event and explicit close ends it. Production uses `Termind.store` under Application Support; tests or supplied repositories use an in-memory container and do not enable production live activities or sync coordinators.

The app model wires cross-service invalidation at construction. Local `deleteHost` first disconnects the assistant, closes saved descriptors and live workspaces for that Host, invalidates edits, cancels transfers, retires forwarding and metrics, then requests repository deletion, projects the removal, and starts the outbox; repository failure is reported in `error` rather than completing that projection. Earlier runtime cleanup is not rolled back. The deletion request commits a hidden-host marker and ordered outbox jobs together, so durable reference cleanup and final removal can resume after a crash. Outbox handlers also close workspaces and clear histories, cancel transfers, and remove forwarding rules. Host route edits disconnect matching live protocols rather than deleting descriptors. Remote sync application computes a change plan before replacing the local projection: changed routes invalidate edits, sessions, transfers and forwarding, while removed Hosts additionally close saved workspaces and clear histories/metrics. This keeps runtime work from using stale configuration.

### Scene-local navigation and native-window workspace ownership

`MobileSceneDelegate` supplies its UIKit session's persistent identifier. `MobileQuickActionSceneRoot` waits for that ID and keys `MobileBoundSceneRoot` by it; the bound root initially renders a loading child, then creates its `MobileSceneModel` in an asynchronous `.task` if absent and retains it in `@State`. This keeps registration of observable app state out of view construction and body evaluation. `MobileRootView` retains the resulting scene in `@State`, reports `scenePhase` to the shared app model and exposes a focused scene value. The root uses a sidebar-adaptable `TabView` with a `NavigationStack` per feature. The scene model owns destination and workspace selection, presentations and assistant navigation, but obtains its `MobileWorkspaceSessionModel` from the app by persistent session ID. Assistant conversation storage remains shared while scene-specific drafts and selection remain independent.

The UIKit `MobileSceneDelegate` holds a pending Home Screen quick action per scene; `MobileBoundSceneRoot` passes its action and one-shot consumer into `MobileRootView`. The root consumes it on change and asks its own `MobileSceneModel` to open the connection picker or open a recent Host using the Host's **current** preferred connection kind. Unknown shortcuts are rejected; a missing or unusable Host presents the workspace-unavailable alert instead of restoring a stale session. The shortcut list is refreshed from local connection history and host changes, limited to three openable recent Hosts.

`MobileAppModel` manages a registry of `MobileWorkspaceSessionModel`s, one for each persistent native scene ID. Each session owns its **own** live workspaces, ordered descriptors and open/close behavior; `app.workspaces` is an aggregate for global lifecycle and Host cleanup, not a shared pool from which scenes select. Creating a new workspace for the same Host in another window creates a distinct connection. A workspace URL resolves the owning session and asks UIKit to activate that window; if the owner is unavailable, the receiving scene shows an unavailable alert without opening a replacement. In its own session, `openWorkspace(_:)` reuses a live instance or validates a descriptor's Host, publishes the new workspace, then connects it. Repeated selection does not create another attempt, even after an initial connection failure; retry is explicit.

The app-owned `MobileWorkspaceStore` writes a complete snapshot of descriptor lists keyed by persistent UIKit session ID, preventing one window's save from overwriting another's. On cold launch `loadRecentWorkspaces()` reads and prunes descriptors whose Hosts are absent, publishes no live connection and clears leftover Live Activities. The first bound window consolidates unassigned and saved session descriptors into its session, preserving IDs and order even if old UIKit sessions were discarded at launch; later windows start independently. A descriptor contains only workspace ID, Host ID, title and connection kind, excluding commands, paths, credentials and transport state. Opening a saved descriptor connects on demand. Closing removes the live workspace and saved descriptor; external-link workspaces are not persisted. If a snapshot is malformed or unsupported, the store reports an error and fences subsequent saves instead of overwriting it with an empty snapshot.

**Disconnect is not discard.** UIKit may reclaim a scene while its session remains restorable: `sceneDidDisconnect` removes phase tracking but keeps its workspace owner. Reconciliation against `UIApplication.openSessions` transfers workspaces from truly missing sessions into an active session only after saving the new ownership snapshot; an unavailable save leaves them with their old owner and reports an error. A later explicit `didDiscardSceneSessions` closes that session's workspaces and descriptors, including transferred workspaces originally owned by the discarded session. The app delegate queues early discards until startup has assigned the model.

```mermaid
flowchart TD
    Store["App owned descriptor snapshot"] --> Bind["First UIKit session binds on cold launch"]
    Bind --> Owner["Window owned workspace session"]
    Owner --> Open["Publish workspace then connect on demand"]
    Owner --> Reclaim["Scene disconnects but session stays open"]
    Reclaim --> Owner
    Owner --> Missing["Native session no longer open"]
    Missing --> Save["Save transfer to active session"]
    Save --> Target["Active window session accepts live workspaces"]
    Target --> Discard["Explicit native session discard"]
    Owner --> Discard
    Discard --> Close["Close owner workspaces and descriptors"]
```

This mobile ownership flow distinguishes reconnect-free handoff of a truly missing native session from transient scene disconnection and explicit discard.

### Mobile foreground and background boundaries

Scene phases are aggregated by scene ID. The app only enters global background behavior when every tracked scene is backgrounded, so one backgrounded scene cannot suspend work still visible in another. Removing the last active scene can trigger that transition when other tracked scenes remain backgrounded; removing the last tracked scene does not. On that transition it stops edit monitoring, suspends memory and sync, pauses metrics and outbox work, suspends recording, and starts a finite platform background task. If the task expires, it asks each live workspace to handle background expiration, stops forwarding, pauses transfers, and expires assistant work. Expiration detaches active workspace transports, clears interactive authentication state and marks a foreground reconnect intent; returning before expiration does not force a reconnect. It updates Live Activities but does not use them to retain connections.

`MobileBackgroundController` owns one UIKit background-task lease. Beginning another lease finishes the old one; foreground `finish()` and expiration retire a valid identifier at most once. Expiration calls its cancellation callback synchronously before ending the task, even when UIKit expires during `begin`; a late callback for a retired lease is ignored. If UIKit returns `.invalid`, the controller expires immediately without trying to end an invalid identifier. Async disconnects started by the callback are best effort, not a guarantee that every drain completed before the lease ends.

When any scene becomes active, mobile refreshes its current device-directory record, reenables edit monitoring, finishes the background task, asks existing workspaces to resume, reconciles sync, restarts the outbox and metrics, refreshes entitlement asynchronously, and updates activities. `reconcileSync()` calls `start()` on Vault, History, Device, Metrics and Settings coordinators only if at least one tracked scene is `.active` **and** Pro permits Vault sync; otherwise it pauses all five. This is a foreground/entitlement gate, **not** an override of user sync choices: each coordinator's `CloudSyncLifecycle.start()` separately checks the global iCloud switch and any applicable optional preference and pauses if disabled. `setSyncEnabled(_:key:)` gates enabling on Pro, writes the selected preference, migrates custom passwords when enabling the global iCloud switch, then reconciles. `MobileRootView` also reconciles when Pro access changes. Desktop `AppModel` starts/reconciles those five coordinators against Pro access without a scene-phase gate, but their individual preferences still govern actual activation. Returning before expiration preserves healthy connections; after expiration, workspace recovery follows the workspace's reconnection journey. Expired forwarding and pending interactive authentication are stopped rather than silently restarted on foreground.

```mermaid
stateDiagram-v2
    [*] --> Tracked: Scene reports phase
    Tracked --> Foreground: Any tracked scene active
    Foreground --> Background: All tracked scenes backgrounded
    Background --> Foreground: A scene becomes active
    Background --> Expired: Background lease expires
    Expired --> Foreground: A scene becomes active
    Foreground --> Tracked: No tracked scene active
    Tracked --> Background: All tracked scenes backgrounded
```

Mobile phase aggregation controls a single background lease and foreground sync eligibility; expiration retires live runtime work, not persisted workspace descriptors. An empty scene registry is not treated as all-backgrounded.

## Ownership invariants and safe extension points

### Preserve these boundaries

- **Keep the consent gate at scene content, after successful runtime construction.** New normal-root setup should not run while `diagnosis.needsConsent` is true; do not treat the consent view as a replacement for failed container creation.
- **Do not make a window or scene the owner of app services.** Inject app-wide services into per-window/per-scene presentation models; use the central model for operations that must affect all live owners.
- **Do not make app-wide navigation or workspace state.** Desktop window workspaces and mobile persistent scene-session workspaces must remain independently mutable; the app aggregates the latter only to coordinate global lifecycle and cleanup.
- **Do not persist live connection state as restoration.** Mobile descriptors are intentionally limited; desktop state restoration must not reconnect active workspaces merely because a window returns.
- **Publish a mobile workspace in its owner session before `connect()`.** Changing this order risks duplicate initial attempts on repeated selection within that window; cross-window links should activate its owner rather than make a copy.
- **Retire runtime resources before replacing configuration.** Host deletion, route changes, and remote sync need to invalidate workspace sessions, transfers, edits, forwarding, and dependent services through their existing callbacks/change plans.
- **Keep test composition explicit.** Extend `MobileAppDependencies` or `AppDependencies` when a platform integration needs a substitute; do not add test-only global singletons to production code.

### Adding a shared service

For a service that must be unique across windows or scenes, construct it at the platform composition root, place it on `AppModel` or `MobileAppModel`, and provide narrow callbacks or accessors to local UI models. Decide its shutdown/suspension contract at the same time: macOS termination must include it in `shutdownForTermination()`, while mobile must define whether it pauses on all-scenes-background, expires with the background task, or safely survives foreground transitions.

For a service that represents navigation, focus, a sheet, an editor draft, a desktop workspace/pane, or a scene-specific command target, keep it in `WindowModel` or `MobileSceneModel`. For a connection or terminal/browser state, keep it on the workspace/session and ensure the app-level lifecycle only invokes its explicit suspend, resume, disconnect, or close APIs.

## Focused verification

Tests exercise the lifetime contracts rather than merely constructing views. For startup changes, check both the production consent gate and the test-only in-memory path: these are separate from error handling and from native scene launch suppression.

- `MobileAppTests` verifies saved descriptors reopen on demand without replaying commands or paths, links route to a descriptor's existing owner for a single initial connection, failed first opens require explicit retry, and Host deletion removes opened and unopened descriptors.
- `MobileWorkspaceSessionTests` verifies separate windows create independent workspaces, cold-launch descriptor consolidation, native session reclaim versus explicit discard, and ownership transfer without reconnecting or losing saved order.
- `MobileWorkspaceConnectionRecoveryTests` verifies background expiration disconnects affected mobile workspaces and foreground resumes them, while a quick foreground return preserves a healthy connection.
- `MobileForwardingLifecycleTests` verifies all-scenes background is required before expiration, and expired forwarding/authentication does not revive merely on foreground.
- `MobileBackgroundControllerTests` covers stale callbacks, exactly-once task retirement, synchronous expiration during lease acquisition and invalid UIKit identifiers; `MobileAppTests` covers scene removal and quick versus expired foreground returns.
- `MobileHomeScreenQuickActionTests` covers recent-host shortcut selection, payload decoding and one-shot consumption by the scene delegate.
- `DatabaseStartupGuardTests` checks that the macOS preflight permits the current process but refuses a second PID, including older versions without the lock. `PersistentStoreLockTests` checks refusal before open/migration, retention until all same-process containers close, release after forced exit without losing Vault data, and isolation of in-memory and separate stores.
- `AppTestHostTests` checks default test-host window suppression, Dock-reopen refusal and survival after the last fixture window closes; `.requiresVisibleWindow` gates tests that actually show windows or take focus.
- `AppTerminationTests` verifies shutdown cancels stored and preparing assistant work, joins even an unstored captured failure before closing agent resources, fences new work, and replies once whether cleanup or the three-second fallback wins.
- `RepositoryOutboxTests` verifies a Host deletion request commits the hiding marker and complete outbox atomically.
- `DockMenuTests` verifies Dock-created desktop windows receive distinct `WindowModel`s in the Welcome state and retain per-window UI state independently.
- `ExternalConnectionURLTests` verifies external desktop connections are temporary and unsaved, including the Telnet-password confirmation boundary.

See [System Boundaries](/openwiki/architecture/system-boundaries.md) for framework ownership, [Agent Runtime and Assistant](/openwiki/concepts/agent-runtime-and-assistant.md) for shared agent execution state, [Persistence and Secrets](/openwiki/concepts/persistence-and-secrets.md) for storage policy, and [SSH Session Lifecycle](/openwiki/workflows/ssh-session-lifecycle.md) for per-session connection behavior.

Vault and Device follow the master iCloud switch and Pro eligibility. History, Metrics and Settings retain optional selections. Both apps render shared `CloudSyncSettingsContent` with one aggregate status and the optional switches in History → Metrics → Settings order.
