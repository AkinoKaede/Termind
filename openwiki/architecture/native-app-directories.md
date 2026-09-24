---
type: architecture directory guide
title: Native App Responsibilities
description: Ownership and entrypoints of the macOS TFM and iOS TFI apps, distinguishing native presentation and adapters from shared models, persistence, and remote services.
tags: [architecture, macos, ios, directories, navigation, lifecycle]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-24T14:20:08.561Z
sources:
  - id: openwiki-source-c4b6e224fdbea6dcd393344d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-60d390fe6fbfea55a2a8230a
    resource: repo://TFI/App/MobileFeatureRegistry.swift
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-83cf4f34941d19114f080a3a
    resource: repo://TFI/Application/Connections/MobileWorkspaceConnectionServices.swift
  - id: openwiki-source-deb061208994fd7d84d4f029
    resource: repo://TFI/Application/Transfers/MobileSFTPChannelModel.swift
  - id: openwiki-source-851edcded7143bb79a41f6c6
    resource: repo://TFI/Application/Workspaces/MobileConnectionHistory.swift
  - id: openwiki-source-0368ecce931d0fb26fe8f35f
    resource: repo://TFI/DesignSystem/MobileContentRegions.swift
  - id: openwiki-source-d43ef236ba4bbb23d8dab797
    resource: repo://TFI/Features/Assistant/MobileAssistantView.swift
  - id: openwiki-source-fc448263e4e5ce330b8cbda1
    resource: repo://TFI/Features/HostEditor/MobileHostEditor.swift
  - id: openwiki-source-ad662f2a7016a994d8522bf2
    resource: repo://TFI/Features/KnownHosts/MobileKnownHostsView.swift
  - id: openwiki-source-e21fae39ef7af76f86acbff6
    resource: repo://TFI/Features/Settings/MobileSettingsView.swift
  - id: openwiki-source-17e754ff6e9f61a92b68cb8a
    resource: repo://TFI/Features/Shell/MobileNavigation.swift
  - id: openwiki-source-3f37062f55fb57a9f2e97f35
    resource: repo://TFI/Features/Vault/MobileVaultView.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-350d4a794cfef67e406ddf9b
    resource: repo://TFI/Infrastructure/MobileWorkspaceStore.swift
  - id: openwiki-source-34542e0f07e1650e098824c7
    resource: repo://TFI/Platform/MobileBackgroundController.swift
  - id: openwiki-source-637644793f7e37cc057eb973
    resource: repo://TFI/Platform/MobileLiveActivityController.swift
  - id: openwiki-source-ce94d13059ea7e57a90adf59
    resource: repo://TFI/Platform/MobileSFTPOpenWithPresenter.swift
  - id: openwiki-source-ca0b3e6e839587396cdeaf54
    resource: repo://TFI/Platform/MobileTerminalSurface.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-c9618f94f83d3b529a9860e1
    resource: repo://TFITests/MobileBackgroundControllerTests.swift
  - id: openwiki-source-16ec96bd78162e7e62effd0e
    resource: repo://TFITests/MobileConnectionPickerTests.swift
  - id: openwiki-source-282855f9369e6dc0c3447dc8
    resource: repo://TFITests/MobileSettingsPortTests.swift
  - id: openwiki-source-b8fca76c89564e16eccfbb53
    resource: repo://TFM/App/MCPServerController.swift
  - id: openwiki-source-873894299539cce9a737a860
    resource: repo://TFM/App/RootView.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-8a6e94328a445c3566ef9d57
    resource: repo://TFM/Application/MCPServer/MCPDownloadCoordinator.swift
  - id: openwiki-source-76b1cdca4a02038756187f92
    resource: repo://TFM/Application/MCPServer/MCPServerTools.swift
  - id: openwiki-source-396f97a332870d48c065d7e9
    resource: repo://TFM/Application/MCPServer/MCPUploadCoordinator.swift
  - id: openwiki-source-1bc9e5a8d0e790c70a371d60
    resource: repo://TFM/Application/Serial/SerialPortService.swift
  - id: openwiki-source-d35453512ef488d0cacdc06e
    resource: repo://TFM/Features/Assistant/AssistantView.swift
  - id: openwiki-source-391dd36408ff1c7fc7c1c335
    resource: repo://TFM/Features/Settings/MCPSettings.swift
  - id: openwiki-source-cfe2a6b22338023c37a5b503
    resource: repo://TFM/Features/Settings/SettingsPageView.swift
  - id: openwiki-source-a93c339a06b550013d027e29
    resource: repo://TFM/Features/SFTP/SFTPChannelModel.swift
  - id: openwiki-source-07825e2cdc632a818b8c30ee
    resource: repo://TFM/Features/Shell/WindowRoute.swift
  - id: openwiki-source-0854be84b166268626a3cb08
    resource: repo://TFM/Features/Sidebar/WindowSidebarView.swift
  - id: openwiki-source-7e796927b780e67cc73f6a5b
    resource: repo://TFM/Features/Terminal/SSHSessionModel.swift
  - id: openwiki-source-507cd94a8ae82f840ac8591f
    resource: repo://TFM/Features/Vault/VaultView.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-3cccceaeda63a663e84b5bfa
    resource: repo://TFM/Infrastructure/MCP/MCPServerSession.swift
  - id: openwiki-source-9d465cf017037915bf209e49
    resource: repo://TFM/Infrastructure/Networking/LoopbackHTTPServer.swift
  - id: openwiki-source-a0f4f642e37695357bc9150d
    resource: repo://TFM/Infrastructure/Security/MCPServerTokenStore.swift
  - id: openwiki-source-68b5f4529ef349aac826b1d9
    resource: repo://TFM/Platform/MacDeviceName.swift
  - id: openwiki-source-28f740582e7f32c1d0099069
    resource: repo://TFM/Platform/MacOSSpeechAudioInput.swift
  - id: openwiki-source-22e92f96394f292a731fc6fb
    resource: repo://TFM/Platform/MainWindowCoordinator.swift
  - id: openwiki-source-824d6a1342361bda8b3634b7
    resource: repo://TFM/Platform/MetricsMenuBarController.swift
  - id: openwiki-source-f6a967b4f14bf50d1af51b8b
    resource: repo://TFM/UI/Managed/ManagedCardPage.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-47dc468698b2904f0004ee04
    resource: repo://TFMTests/MCPUploadTests.swift
  - id: openwiki-source-44cb7a6172854edbfc9b5ccb
    resource: repo://TFMTests/SettingsNavigationTests.swift
  - id: openwiki-source-ea148dc5de8cabfc00dc07ae
    resource: repo://TFMTests/WindowSidebarTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-24T14:20:08.561Z" }
---

# Native App Responsibilities

`TFM` is the macOS app and `TFI` is the iPhone/iPad app. Both compose the [shared frameworks](shared-module-directories.md), but their directories own platform-specific interaction and lifetime decisions. A directory named `Features` is **not** necessarily views only: desktop sessions live under `Features/Terminal` and window workspaces under `Features/Workspaces`, while mobile live workspaces live under `Features/Workspaces`. By contrast, `Features/Shell` defines navigation values, not remote shell execution. Paths below are relative to the respective app root.

## Entrypoints and state ownership

| Boundary | macOS (`TFM`) | iOS/iPadOS (`TFI`) |
| --- | --- | --- |
| `App` entry | `TermindApp` assembles one `AppModel` and SwiftData container, mounts a `WindowGroup` with a fresh `WindowModel` for each `RootView`, plus a separate external-authentication window and app commands. | `TermindIOSApp` creates one `MobileAppModel` for its `WindowGroup`; `MobileRootView` retains a `MobileSceneModel` per scene, with a `NavigationStack` per registered tab (Vault, Metrics, Workspaces, Assistant and Settings). |
| Shared versus local state | `AppModel` holds shared libraries and services; `WindowModel` owns workspace/pane collection, selection, sidebar, Settings route, queries and window presentation. | `MobileAppModel` owns shared libraries, sync, transfers, Assistant execution and live `MobileWorkspace` objects. `MobileSceneModel` owns destination, selected workspace, Assistant scene model and editor/connection presentations. |
| Startup failure | Opening the local container can terminate startup with a fatal error; tests and screenshot demos use in-memory composition. | Failure to construct `MobileAppModel` presents an unavailable-data-store screen instead of mounting a normal root; test composition uses testing dependencies. |

The `App` composition roots also supply the shared device directory with platform naming. `MacDeviceName` reads trimmed `kern.hostname` with `Device.current.safeDescription` fallback, refreshed on macOS application activation. Mobile uses `Device.current.safeDescription`, refreshed on active scene transition. `DeviceRecord`, directory policy and repositories remain shared, rather than becoming native-app schema types.

```mermaid
flowchart TB
    subgraph Mac["TFM desktop"]
        DesktopApp["TermindApp shared AppModel"] --> Window["WindowModel per RootView"]
        Window --> Deck["Workspace deck and native sessions"]
        Window --> Sidebar["Sidebar and Settings routes"]
    end
    subgraph IOS["TFI mobile"]
        IOSApp["TermindIOSApp shared MobileAppModel"] --> Runtimes["Live MobileWorkspace instances"]
        IOSApp --> Scene["MobileSceneModel per MobileRootView"]
        Scene -.->|selects| Runtimes
    end
```

App-level services outlive a window or scene's navigation selection; only desktop windows own their workspace collections.

### Desktop navigation and termination

`RootView` mounts `WindowSidebarView` beside a persistent workspace deck. Switching to Vault, Assistant, Metrics or Settings covers rather than destroys the deck and its session views. The window-local sidebar offers Navigator, compact Assistant, Snippets and History. History uses command history when an SSH pane is focused, SFTP browse history for an SFTP pane, and connection history otherwise. Serial/Telnet focus disables History and reconciles an invalid History selection to Snippets. Activating the Assistant mode outside a workspace also opens the full Assistant destination; activating Navigator from Assistant restores its remembered destination. Programmatically setting the sidebar mode is presentation-only.

Settings is a **window destination**, not a separate shared-service owner. `WindowModel.settingsRoute` remembers the destination it replaced, moves Back to a parent route before closing, then resets to index and returns to the old destination (or Vault if a workspace was removed). `SettingsPageView` assembles forms over app-owned settings: remote MCP editing is Pro-gated and a separate local MCP server route configures the app's server controller, not the HTTP listener. Leaving an editor discards qualifying empty provider, MCP and skill drafts; substantive skill drafts survive, and a new MCP server must lock a unique namespace. This makes a route change different from shutting down sync, transfers or the local server.

`AppDelegate` handles application activation, reopening, quiet login launch and termination. On quit it rechecks pending SFTP edits, can cancel termination if the user refuses to discard them, then saves window size and begins shutdown. Its reply is sent once after cleanup or a three-second timeout. `TFMTests/SettingsNavigationTests.swift` tests route return, missing-workspace fallback and draft handling; `TFMTests/WindowSidebarTests.swift` tests window isolation and the serial-pane fallback.

### Mobile navigation, restoration and lifecycle

`MobileFeatureRegistry` passes scene callbacks into Vault: tapping a host selects a recent preferred SSH/Telnet workspace or opens one; explicit SSH, Telnet and SFTP menu actions create connections. `MobileSceneModel.selectWorkspace` asks the app to materialize a saved descriptor, then selects the resulting runtime. `MobileAppModel.openWorkspace` first checks for an existing runtime and removes stale descriptors whose host is missing. `addWorkspaces` publishes the runtime and its descriptor **before** `connect()`, so two scenes selecting a restored descriptor share the same first attempt. An explicit close disconnects the workspace and removes its saved descriptor. Device-local `Infrastructure/MobileWorkspaceStore` stores connection intent only, never credentials, commands or live sessions; unreadable snapshots are not overwritten with an empty list. A failed restore/save sets an app error for presentation rather than silently erasing the snapshot.

`MobileRootView` reports phase, scene removal and Pro changes to the app. Only the first transition to **all registered scenes backgrounded** starts the background path: the app pauses monitoring, memory, metrics, outbox and sync, suspends Assistant recording, and acquires a UIKit background-task lease without immediately disconnecting healthy workspaces. Expiration suspends workspaces and stops forwarding, transfers and Assistant background work. Active reentry finishes the lease, resumes affected workspaces and services, rechecks SFTP edits, refreshes Pro, and reconciles sync. An empty scene registry does not enter background. `MobileBackgroundController` retires a lease at most once, ignores obsolete expiry callbacks and handles synchronous expiration or an invalid task ID without leaking a UIKit end call.

`MobileAppModel.reconcileSync` starts **five** coordinators (Vault, connection History, Device, Metrics and Settings) only with an active tracked scene and Pro vault-sync eligibility; otherwise it pauses them. In-memory composition omits live cloud coordinators. `setSyncEnabled` checks Pro before enabling, persists the selection, passes History selection to its coordinator, migrates custom passwords when the iCloud master is enabled and reconciles sync. Vault and Device follow the master switch; History, Metrics and Settings additionally honor their optional selections. An inactive scene is not active for this gate.

```mermaid
flowchart TD
    Phase["Scene phase or removal"] --> App["MobileAppModel tracks scene phases"]
    App --> Gate{"All registered scenes backgrounded"}
    Gate -->|"first transition"| Pause["Pause services and start UIKit lease"]
    Pause --> Expiry["Lease expiration suspends runtime work"]
    App -->|"active scene"| Resume["Finish lease and resume services"]
    Resume --> Sync["Reconcile sync"]
    App -->|"scene removed"| Sync
    Pro["Pro or sync selection changed"] --> Sync
    Sync --> Eligible{"Active scene and Pro eligible"}
    Eligible -->|yes| Start["Start five coordinators"]
    Eligible -->|no| Stop["Pause five coordinators"]
```

Scene registration and entitlement gate app-owned services independently of whichever tab is visible. `TFITests/MobileAppTests.swift` covers restoration across scenes, expiration/reentry and last-active-scene removal; `TFITests/MobileBackgroundControllerTests.swift` covers lease replacement, synchronous expiry and invalid IDs; `TFITests/MobileSettingsPortTests.swift` checks the in-memory cloud boundary and settings-to-transfer preference updates.

## Placement: policy, adapters and presentation

| Directory | Desktop example | Mobile example |
| --- | --- | --- |
| `Application` | Use cases and injectable ports, including quick-connect parsing, command identities, audit/transfer library models, `Serial` contracts and external `MCPServer` tools. | `Connections` injectable SSH/SFTP and terminal-write capabilities; `Agent` Assistant coordination; `FeatureModels` editor and picker state; `Metrics` sampling contracts; `Transfers` SFTP browser state; `Workspaces` descriptor/history policy. Not a shared-framework layer. |
| `Infrastructure` | Concrete wiring: `Database` convenience adapters over `TermindPersistence` repositories, repository factories, serial and SSH adapters, import adapters, loopback `Networking`, MCP sessions and security token storage. No second SwiftData schema. | `MobileWorkspaceStore` migration and intent persistence plus `SSH` implementations of mobile connection/metrics services. |
| `Platform` | AppKit window/menu-bar control, login/appearance, shortcuts, file handoff, audio and native device naming. | UIKit delegate/background allowance, quick actions, Live Activities, camera, document handoff, terminal surface/drop handling, speech and fonts. |
| `Design`, `DesignSystem`, `UI` | Tokens and layout helpers; reusable native components and managed card grids. Resource pages supply operations. | Tokens, available-content geometry and toolbar placement; reusable mobile cards, native lists, sheets, toolbars and input. |
| `Resources` | Desktop icon and asset catalog including menu-bar art. | Mobile app icon; shared catalog assets live in frameworks. |

`Application` expresses app-local policy and contracts, not the view hierarchy or the SwiftData schema. `ArchitectureBoundaryTests` prohibit UIKit/SwiftUI and persistence imports in mobile Application, concrete construction in both apps' Features and desktop Application, and direct persistence/transport imports in desktop Features. They also ensure `@Model` types and `SwiftData*Repository` declarations stay in `TermindPersistence`. `TFM/Infrastructure/Database` can provide constructors using those shared repositories without owning another schema. Native UI and platform adapters may consume shared `TermindPresentation` content, but focus, AppKit/UIKit mounting and drag/drop policy remain native.

The desktop MCP path is a useful placement example: `App/MCPServerController` owns Pro gating, configuration, start/stop, port and token rotation; `Application/MCPServer/MCPServerTools` defines tool operations and upload/download policy. `Infrastructure/Networking` handles loopback HTTP bytes, `Infrastructure/MCP` handles protocol sessions and `Infrastructure/Security` stores tokens. An upload ticket is run-bound: `MCPUploadCoordinator.prepare` verifies origin, bearer upload token, method, headers, remaining length and acknowledged resume offset before claiming capacity or doing audit/transfer work. Interrupted or recoverable transfers may retry from the acknowledged offset; integrity failure, cancellation or expiry cannot. Commit follows remote streaming completion, and session/host revocation or server shutdown drains tickets. The Settings screen configures this service but does not own its lifetime; `TFMTests/MCPUploadTests.swift` exercises resume, digest, revocation, timeouts and early rejection. See [MCP Server and Bridge](../integrations/mcp-server-and-bridge.md).

## Where feature work belongs

- **`Features/AI`, `Assistant`, `Shell`:** `AI` holds reusable composer/transcript pieces; `Assistant` composes the full and contextual conversation destinations; `Shell` names app destinations and routes, not SSH transport. Desktop `Terminal` includes SSH/Telnet/serial session models and persistent terminal presentation; mobile `Terminal` includes keyboard/history interaction while `Workspaces` owns mobile live connections and `Platform` mounts the native terminal surface.
- **`Features/Vault` and specialist editors:** Desktop Vault routes to managers for hosts, keys, known hosts, snippets and forwarding. Mobile Vault renders grouped host cards and links to credentials, forwarding, snippets, known hosts and History. Local search, sheets and confirmations do not own the library or sessions. `MobileHostEditor` maintains host/custom-identity drafts and validates protocol, port, authentication and environment before saving via the host library. `MobileKnownHostsView` edits validated trust entries via `app.knownHosts` and surfaces save failures. Deleting a host through `MobileAppModel.deleteHost` closes matching workspaces, invalidates SFTP edits, cancels transfers, stops forwarding, removes metrics, requests deletion and starts the outbox; moving that into a card would omit lifecycle effects.
- **Vault History:** The SwiftUI History view is in `Features/Vault/MobileVaultView.swift`, but `Application/Workspaces/MobileConnectionHistory.swift` resolves rows against hosts and device names, filters search, limits results to 50 and permits opening only enabled host protocols. Delete and clear-all call `app.connectionHistory`. Vault search forwards queries into dedicated pushed resource screens, while Metrics results switch the top-level destination. `TFITests/MobileConnectionPickerTests.swift` covers History search/limit; mobile Vault feature tests cover menu protocol filtering and group/host operations.
- **`Features/Settings`, `SFTP`, `Transfers`:** Settings assembles app-owned capabilities rather than retaining synchronization or transfer lifetime. SFTP browser/channel models manage browsing and edit presentation; process-level `SFTPTransferCoordinator` lives in shared Remote Infrastructure and is retained by app composition. Mobile has a separate `Features/Transfers` queue surface; desktop transfer-library state is in `Application/FeatureModels`. Closing a screen must not cancel unrelated work.
- **`Features/Sidebar` and `Workspaces`:** Desktop Sidebar is a per-window column, not an app-global navigator. Desktop Workspaces manages window layout and panes; mobile Workspaces combines retained live runtime with list/detail navigation. Moving session ownership across those folders changes lifetime semantics, not just file organization.

The native `UI/Managed` grids and `UI/Components` interaction helpers do not acquire resource ownership merely by rendering a manager. For deeper behavior, see [Desktop UI](desktop-ui.md), [Mobile UI](mobile-ui.md), and [Platform Runtime](platform-runtime.md); return to the [Module Map](module-map.md) for dependencies.
