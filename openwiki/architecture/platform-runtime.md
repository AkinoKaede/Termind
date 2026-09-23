---
type: architecture
title: Platform Runtime, App Composition, and Lifetimes
description: How Termind composes shared services and persistence on macOS and iOS, and where app-wide, window-local, scene-local, and session state begin and end.
tags: [architecture, runtime, macos, ios, lifecycle, dependency-injection]
sources:
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-160f180df5d3cb1457febfee
    resource: repo://Frameworks/TermindApplication/Agent/AssistantLibraryModel.swift
  - id: openwiki-source-1c48f72c0c7a3164d7d5c715
    resource: repo://Frameworks/TermindApplication/Agent/ConversationModel.swift
  - id: openwiki-source-7397a04f40a393c81b0ca52d
    resource: repo://Frameworks/TermindApplication/FeatureModels/MemoryModel.swift
  - id: openwiki-source-ee4e94c8b189e0881ec4fd15
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentBackgroundCommands.swift
  - id: openwiki-source-0c82bf45bc197f879a54fd3a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift
  - id: openwiki-source-256e2b134a8446ea63b15585
    resource: repo://FrameworkTests/HermesMemoryTests.swift
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
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-d44869be46c03fbd0ce9c64c
    resource: repo://TFI/Application/Agent/MobileAssistantModel.swift
  - id: openwiki-source-9c78befae6b387426c603305
    resource: repo://TFI/Application/Workspaces/MobileWorkspaceDescriptor.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-34542e0f07e1650e098824c7
    resource: repo://TFI/Platform/MobileBackgroundController.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-a154b5d36ec59496392d45e4
    resource: repo://TFITests/MobileAssistantTests.swift
  - id: openwiki-source-c9618f94f83d3b529a9860e1
    resource: repo://TFITests/MobileBackgroundControllerTests.swift
  - id: openwiki-source-2c8d92432bb6dac7ede21141
    resource: repo://TFITests/MobileForwardingLifecycleTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-873894299539cce9a737a860
    resource: repo://TFM/App/RootView.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
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
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-531f6567ecf96fd4b0c5e97a
    resource: repo://TFMTests/ExternalConnectionURLTests.swift
generated: { by: "codex", at: "2026-09-23T10:06:09.363Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T10:06:09.363Z
---

# Platform Runtime, App Composition, and Lifetimes

Termind has separate native application targets—`TFM` for macOS and `TFI` for iOS/iPadOS—but both compose the same layered frameworks into a platform-owned runtime. The application target owns startup, native lifecycle hooks, dependency assembly, platform UI, and the boundary between durable app data and live UI/session state. Shared frameworks do not import either app target.

The most important lifetime rule is: **stores, coordinators, and durable-data services are app-wide; navigation, presentation, and desktop workspace ownership are local to a window; mobile navigation is local to a scene; live transports belong to the workspace/session that opened them.** Do not move state across those boundaries merely to make a UI path convenient.

## UI structure and design guides

This page explains runtime composition and lifetime boundaries. For the component trees and user-facing presentation rules, continue with:

- [TFM Desktop UI Architecture](/openwiki/architecture/desktop-ui.md): window shell, persistent workspace deck, split panes, Vault list/detail, managed cards and native transcript ownership.
- [TFI Mobile UI Architecture](/openwiki/architecture/mobile-ui.md): registered feature stacks, scene-local routes, shared workspaces, usable-region layout, mobile toolbars and native input continuity.
- [UI Design Principles and Shared Presentation Boundaries](/openwiki/concepts/ui-design-principles.md): what the platforms share, where their visual/input policies intentionally differ, and how to extend them without merging runtime ownership.

## Lifetime map

| Scope | macOS | iOS/iPadOS | Examples |
| --- | --- | --- | --- |
| Process / app model | One `AppModel`, retained in `TermindApp` state | One `MobileAppModel`, created before the `WindowGroup` | SwiftData container, host library, settings and sync coordinators, shared remote coordinator, histories, transfer and forwarding services, entitlement/review state |
| Native window / scene | `WindowModel` per main window | `MobileSceneModel` per SwiftUI scene | destination, selection, sheets, navigation routes, focused-value command routing, scene-local assistant navigation |
| Workspace and session | Desktop `Workspace` and panes are owned by one `WindowModel` | `MobileWorkspace` instances are shared by `MobileAppModel`; a scene selects one | terminal or SFTP UI, connection journey, transport, terminal state, workspace-specific operations |
| Durable state | SwiftData, Keychain, supported UserDefaults and sync stores | Same categories, plus local `MobileWorkspaceStore` descriptors | Hosts and settings, secret references, histories, mobile recent workspace descriptors |
| Ephemeral runtime state | Never restored as a live connection | Never restored as a live connection | SSH/SFTP transports, authentication journeys, one-shot URL credentials, in-flight runs/transfers |

A useful consequence is that sharing a desktop `AppModel` does **not** make its `WindowModel`s share selection, sidebar/search state, or workspaces. Conversely, mobile scenes share the app's live workspace registry, so opening the same saved descriptor from multiple scenes reuses one workspace and one initial connection attempt; each scene still owns its selected destination and selected workspace ID.

## macOS composition

`TermindApp.init()` is the desktop composition root. It determines whether it is running tests or a debug screenshot demo, constructs one SwiftData `ModelContainer`, prepares settings and metrics persistence, makes the Keychain-backed secret store, and assembles `AppModel` with repositories, sync coordinators, logging, histories, the reusable device directory, and the common `RemoteConnectionCoordinator`. The directory uses the Vault journal's stable installation ID and `MacDeviceName.current`: the trimmed `kern.hostname`, falling back to DeviceKit's `Device.current.safeDescription` when unavailable or empty. Startup fails closed: an inability to open the local database calls `fatalError` rather than substituting an empty store.

```mermaid
flowchart TD
    Launch["TermindApp init"] --> Store["TermindPersistence makeContainer"]
    Store --> Persistence["Settings and metrics persistence"]
    Store --> Hosts["HostLibraryModel and SwiftData repositories"]
    Launch --> Secrets["KeychainSecretStore"]
    Launch --> Logging["LaunchFileLogService"]
    Launch --> Remote["RemoteConnectionCoordinator"]
    Persistence --> Sync["Vault Settings and Metrics sync coordinators"]
    Hosts --> App["AppModel app-wide runtime"]
    Secrets --> App
    Logging --> App
    Remote --> App
    Sync --> App
    App --> Group["WindowGroup main"]
    Group --> Root["RootView"]
    Root --> Window["WindowModel per window"]
    Window --> Workspace["Window-owned Workspaces and panes"]
    App --> AuthWindow["External authentication Window"]
```

This diagram shows the desktop composition root and the split between one app runtime and per-window workspace ownership.

### Shared desktop runtime

`AppModel` is the cross-window coordinator and service owner. It owns the host and credential projections, known-hosts/snippet/forwarding/transfer libraries, terminal and SSH/SFTP settings, histories, AI/skills/memory, metrics, entitlement and review controllers, remote connection coordination, SFTP edit/transfer services, forwarding, MCP services, and sync/outbox integration. It also owns the global conversation store and one speech transcription coordinator, avoiding duplicate conversation state and competing audio taps across windows.

The model keeps only weak registrations for open `WindowModel`s. Registration injects shared stores and coordinators into a window and attaches that window's assistant library to the process-wide conversation store. Fan-out operations—such as a host route change or deletion—find registered windows and disconnect or close the affected window-owned workspaces. This is coordination, not ownership transfer: the window remains responsible for its own UI and workspaces.

`TermindApp` creates a `WindowGroup(id: "main", for: UUID.self)`. Each scene receives a fresh `WindowModel`, places it in `RootView`, and injects the same `AppModel` and SwiftData container through the SwiftUI environment. `RootView` registers the window on appearance. The independent `Authentication Request` window is intentionally reserved for external authentication presentation rather than normal Window-menu creation.

### Window-local desktop state

`WindowModel` contains the state that may legitimately differ in another desktop window: navigator destination, dynamic workspaces and panes, sidebar and search behavior, workspace selection, local presentations, and window-specific assistant surfaces. `RootView` preserves mounted workspace-native views when a different destination becomes visible so terminal grids, scrollback, and SFTP UI state survive navigation.

A host-opening action is centralized in `AppModel`, which chooses the requested protocol, but it opens into the caller's `WindowModel`. That window assigns one connection-history event to each saved-host SSH, Telnet or SFTP pane. Closing the pane/workspace ends the event before disconnecting, while moving a live pane preserves it and reopening creates a new event. External temporary and Serial panes are not recorded; a crash may leave `endedAt` absent. A batch can deliberately create separate window-local workspaces or one workspace with several panes. External SSH/SFTP/Telnet URLs likewise create a temporary workspace in the target window without adding a saved Host; Telnet URLs containing an advisory password require explicit confirmation first.

`MainWindowCoordinator` binds native `NSWindow`s to `WindowModel`s. It processes new-window and workspace-move requests, preserves system-restored frames, saves normal window size only at appropriate boundaries, and unregisters then closes a model when its native window closes. The AppKit delegate handles Dock reopen/new-window behavior and may retain the process after the last window according to menu-bar metrics configuration.

### Desktop lifecycle and termination

The AppKit delegate starts native appearance/login handling and, outside tests, starts metrics activity and the metrics menu once `AppModel` is available. On app activation it refreshes both entitlement state and the current `DeviceRecord` display name from `MacDeviceName.current`; the synchronized directory can therefore update without rewriting connection events. TFI refreshes its name directly from DeviceKit's `Device.current.safeDescription` on active-scene transitions. On termination the desktop app first checks for pending external edits; after user confirmation, it saves window sizing and invokes `AppModel.shutdownForTermination()`.

Shutdown first sets a permanent desktop Assistant admission fence. The execution controller's shared authorization callback rejects new draft/text sends, first-conversation promotion, edits, plan implementation, explicit starts and compaction requests. It snapshots the app-wide conversation store, cancels captured preparations, and calls `stop()` on every stored conversation synchronously before window teardown or any await. This includes full-screen and sidebar conversations whose window was already closed or unregistered: closing a window does not remove them from the store.

The returned cleanup task separately joins the controller's captured preparation and failure-save attempts, plus each conversation's retained runtime consumers. The latter include queued, active and previously stopped owners still draining. Every cancellation request precedes these waits, so one blocked save cannot postpone stopping another conversation. MCP shutdown and SFTP cancellation run alongside the Assistant drains. Only after all those joins return does cleanup call `AgentBackgroundCommands.closeAll()`, then `AgentConnectionPool.closeAll()`.

The app publishes that one cleanup task before suspending memory/edit monitoring and stopping metrics, speech, window-owned workspaces, SFTP work, external authentication, forwarding and the outbox. Repeated calls return the same task. `AppTerminationReplyCoordinator` independently races cleanup completion against a three-second fallback and replies to AppKit once. The fallback can permit exit while persistence or resource cleanup is still pending; returning from a save attempt does not establish that it succeeded.

This is a captured-turn shutdown boundary, not a join of every Assistant task. Already-running manual compaction and title generation are outside it. `memory.suspend()` now establishes a persistent admission fence: it invalidates current access, ignores later history notifications, and reloads state plus backfills history only after resume. Shared SSH configuration and pool-opening work may still outlive one cancelled caller when other waiters remain; each waiter cancels independently, the final waiter cancels the underlying task, and explicit Host retirement cancels the whole opening. Background-command close itself requests cancellation rather than proving remote settlement. These limitations make the native fallback necessary; the iOS lifecycle remains separate.

## Mobile composition

`TermindIOSApp` runs language-preference migration and constructs exactly one startup `Result<MobileAppModel, Error>`. It selects `.testing()` dependencies when XCTest is detected and `.live()` otherwise. The `WindowGroup` either injects the shared model container into `MobileRootView` or presents an unavailable-data screen if construction failed; unlike macOS, failure is surfaced in the first window instead of terminating the process.

```mermaid
flowchart TD
    Launch["TermindIOSApp init"] --> Deps["MobileAppDependencies live or testing"]
    Deps --> MobileApp["MobileAppModel app-wide runtime"]
    MobileApp --> Container["SwiftData ModelContainer"]
    MobileApp --> Services["Libraries sync transfer forwarding assistant metrics"]
    MobileApp --> SharedWorkspaces["MobileWorkspace registry"]
    MobileApp --> Group["WindowGroup"]
    Group --> Root["MobileRootView per scene"]
    Root --> Scene["MobileSceneModel per scene"]
    Scene --> Nav["Tab and navigation selection"]
    Scene --> Selected["Select shared MobileWorkspace"]
    SharedWorkspaces --> Session["Workspace-owned SSH SFTP or Telnet session"]
    Root --> Phase["scenePhase"]
    Phase --> MobileApp
    Phase --> Background["Suspend or expire runtime work"]
```

This diagram shows that mobile scenes have independent navigation but select from app-wide live workspace instances.

### Dependency assembly and test seams

`MobileAppDependencies` is the mobile assembly seam. Live dependencies create a launch file logger and a single `RemoteConnectionCoordinator`, which is passed to both mobile workspace connections and metrics; the same logger is passed to forwarding. Test dependencies use in-memory mode and permit replacement of the host repository, defaults, background-task manager, workspace connection services, metrics services, review controller, container, workspace store, live-activity controller, and forwarding factory.

`MobileAppModel` creates or receives its `ModelContainer`, then builds the host repository, outbox, Keychain or in-memory secret store, settings/metrics persistence and sync coordinators, host and credential libraries, AI/skills/memory, assistant, metrics, transfers and SFTP edits, forwarding, histories, the generic device directory, and live activities. The device directory and connection history use separate repositories on the same Vault context and share the stable installation ID; each repository journals its own payload kind transactionally. Workspace publication starts an event and explicit close records its end. Production uses `Termind.store` under Application Support; tests or supplied repositories use an in-memory container and do not enable production live activities or sync coordinators.

The app model wires cross-service invalidation at construction. Host deletion and route changes invalidate edits, cancel transfers, stop/reconfigure forwarding, remove relevant metrics/history, and disconnect or close live workspaces as appropriate. Remote sync application similarly computes a change plan before replacing the local projection, so route-affecting changes retire affected runtime work rather than leaving it attached to stale configuration.

### Scene-local navigation, app-wide mobile workspaces

`MobileRootView` creates `@State` `MobileSceneModel` for its scene and reports `scenePhase` to the shared app model. It uses one sidebar-adaptable `TabView`, but each tab hosts its own `NavigationStack`; adapting the tab UI does not replace the feature tree. The scene model owns destination selection, selected/pending workspace IDs, connection-picker and editor presentation, external-link confirmation, local assistant-library route, review page, and recency used to choose an already-open workspace. Focused scene values route commands to that scene.

`MobileAppModel`, rather than a scene, owns `workspaces` and the persisted descriptor list. `openWorkspace(_:)` first returns an already-live workspace; otherwise it validates the saved descriptor's Host, constructs the workspace, publishes it, and then starts its connection. Publishing before connecting is an invariant: multiple scenes selecting the same descriptor share an instance and cannot trigger duplicate first connections. A scene only selects/presents that shared workspace.

Mobile persistence deliberately restores **descriptors, not sessions**. On cold launch `loadRecentWorkspaces()` reads descriptors, removes those whose Hosts are absent, and publishes no live workspace or connection; it also clears leftover Live Activities. A descriptor contains only workspace ID, Host ID, title, and connection kind, while initial commands, paths, connection secrets, and transports stay outside it. Opening a saved descriptor connects it on demand. Closing removes both the live instance and descriptor; externally linked temporary workspaces are not persisted.

### Mobile foreground and background boundaries

Scene phases are aggregated by scene ID. The app enters global background behavior only when a nonempty set of tracked scenes becomes entirely backgrounded. Both phase changes and scene removal check that transition: removing the sole active scene starts background handling for surviving background scenes, while repeated notifications/removals and removal of the final scene do not start another lease. On that transition it stops edit monitoring, suspends memory and sync, pauses metrics and outbox work, suspends recording, and starts a finite platform background task. If the task expires, it asks each live workspace to handle background expiration, stops forwarding, pauses transfers, and expires assistant work. It updates Live Activities but does not use them to retain connections.

`MobileBackgroundController` keeps one identity-bearing lease around the UIKit identifier. The expiration handler runs synchronously on the MainActor: it detaches the matching lease, invokes the app's cancellation callback, and ends that lease's valid identifier before returning. Finishing or replacing a lease makes its old callbacks inert. A denied acquisition immediately invokes expiration without ending an invalid identifier. If expiration reenters `begin`, the old lease cannot end or overwrite its replacement; if the platform calls expiration before returning an identifier, the outer acquisition retires the returned old identifier afterward. Each valid identifier is ended at most once.

The callback requests suspension; it does not await network teardown or persistence. Workspaces detach their sessions and start asynchronous disconnects. Assistant synchronously requests cancellation for every conversation before joining retained consumers, then closes background commands and connection pools. Those drains remain best effort under iOS suspension or termination, so an ended platform lease is not evidence that a save or remote cleanup completed. The Assistant admission fence remains set until its cleanup task returns—even if a scene becomes active meanwhile—and blocks send, edit, plan implementation and manual compaction rather than merely disabling the composer.

When any scene becomes active, mobile refreshes its current device-directory record, reenables edit monitoring, resumes memory (which reloads committed state and schedules history backfill), finishes the background task, asks existing workspaces to resume, reconciles sync according to foreground entitlement, restarts the outbox and metrics, refreshes entitlement asynchronously, and updates activities. Returning before expiration therefore preserves healthy connections; after expiration, workspace recovery follows the workspace's reconnection journey. Expired forwarding and pending interactive authentication are stopped rather than silently restarted on foreground, and an unfinished Assistant suspension drain keeps its own admission fence until cleanup completes.

## Ownership invariants and safe extension points

### Preserve these boundaries

- **Do not make a window or scene the owner of app services.** Inject app-wide services into per-window/per-scene presentation models; use the central model for operations that must affect all live owners.
- **Do not make app-wide navigation state.** Desktop window destination/workspace collections and mobile scene selection must remain independently mutable.
- **Do not persist live connection state as restoration.** Mobile descriptors are intentionally limited; desktop state restoration must not reconnect active workspaces merely because a window returns.
- **Publish shared mobile workspaces before `connect()`.** Changing this order risks duplicate live instances and duplicate connections across scenes.
- **Retire runtime resources before replacing configuration.** Host deletion, route changes, and remote sync need to invalidate workspace sessions, transfers, edits, forwarding, and dependent services through their existing callbacks/change plans.
- **Keep test composition explicit.** Extend `MobileAppDependencies` or `AppDependencies` when a platform integration needs a substitute; do not add test-only global singletons to production code.

### Adding a shared service

For a service that must be unique across windows or scenes, construct it at the platform composition root, place it on `AppModel` or `MobileAppModel`, and provide narrow callbacks or accessors to local UI models. Decide its shutdown/suspension contract at the same time: macOS termination must include it in `shutdownForTermination()`, while mobile must define whether it pauses on all-scenes-background, expires with the background task, or safely survives foreground transitions.

For a service that represents navigation, focus, a sheet, an editor draft, a desktop workspace/pane, or a scene-specific command target, keep it in `WindowModel` or `MobileSceneModel`. For a connection or terminal/browser state, keep it on the workspace/session and ensure the app-level lifecycle only invokes its explicit suspend, resume, disconnect, or close APIs.

## Focused verification

Tests exercise the lifetime contracts rather than merely constructing views:

- `AppTerminationTests` uses queued conversations retained after window unregistration, a blocked terminal save, an unstored captured failure, and eligible post-fence sends/edits to verify cancellation, admission and save-attempt-before-resource-close ordering. An injected clock gate checks both cleanup-first and fallback-first replies occur once; these are application ordering tests, not proof of successful disk persistence or production SSH authentication settlement.
- `MobileAppTests` verifies saved descriptors reopen on demand without replaying commands or paths, and that two scenes selecting one restored workspace create only one connection.
- `MobileWorkspaceConnectionRecoveryTests` verifies background expiration disconnects affected mobile workspaces and foreground resumes them, while a quick foreground return preserves a healthy connection. Scene-removal fixtures also check that removing the sole active scene starts one lease for surviving background scenes and that an empty scene set starts none.
- `MobileBackgroundControllerTests` checks synchronous callback/end ordering, stale and repeated callbacks, denied acquisition, and reentrant expiration during acquisition without losing or ending the replacement lease.
- `MobileAssistantTests` holds a first conversation's terminal save while expiring a second queued run: cancellation is immediate, the queued provider never starts, and suspension remains joinable until the save barrier releases. This verifies application ordering, not an operating-system guarantee of cleanup after suspension.
- `MobileForwardingLifecycleTests` verifies all-scenes background is required before expiration, and expired forwarding/authentication does not revive merely on foreground.
- `DockMenuTests` verifies Dock-created desktop windows receive distinct `WindowModel`s in the Welcome state and retain per-window UI state independently.
- `ExternalConnectionURLTests` verifies external desktop connections are temporary and unsaved, including the Telnet-password confirmation boundary.

See [System Boundaries](/openwiki/architecture/system-boundaries.md) for framework ownership, [Agent Runtime and Assistant](/openwiki/concepts/agent-runtime-and-assistant.md) for shared agent execution state, [Persistence and Secrets](/openwiki/concepts/persistence-and-secrets.md) for storage policy, and [SSH Session Lifecycle](/openwiki/workflows/ssh-session-lifecycle.md) for per-session connection behavior.
