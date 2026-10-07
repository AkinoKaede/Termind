---
type: engineering quickstart
title: Termind Engineering Quickstart
description: Route Termind coding tasks to system owners, focused workflows, and safe validation commands. Start with the changed boundary, then follow its guide to authoritative source and behavioral tests.
tags: [engineering, architecture, routing, testing, macos, ios]
sources:
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-54a517e25bf7220eb9067177
    resource: repo://com.akinokaede.termind/assets/README.md
  - id: openwiki-source-fcca55af6fa67b76822099ae
    resource: repo://com.akinokaede.termind/README.md
  - id: openwiki-source-7af97a29763d6f133e4b4851
    resource: repo://fastlane/Fastfile
  - id: openwiki-source-1635d0be12e44ef9134ffabc
    resource: repo://Frameworks/TermindApplication/Connections/ConnectionJourney.swift
  - id: openwiki-source-9b6177e37e7dd97d0cb1adee
    resource: repo://Frameworks/TermindApplication/Terminal/TerminalFindController.swift
  - id: openwiki-source-e08ad235d9d92a20cf09290b
    resource: repo://Frameworks/TermindDomain/Vault/SyncRecordFormats.swift
  - id: openwiki-source-1d1f503a260f304a969fcee4
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncLifecycle.swift
  - id: openwiki-source-37bc639f87948ef96358b680
    resource: repo://Frameworks/TermindInfrastructure/RecentlyClosedStore.swift
  - id: openwiki-source-fe1dc993163bb9ff61397be7
    resource: repo://Frameworks/TermindPersistence/HostPersistence.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-131881b779429a1d1d605e52
    resource: repo://Frameworks/TermindPresentation/ConnectionJourneyRouteView.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-bf7a64e7c819eb9279e2f9e4
    resource: repo://FrameworkTests/CloudSyncLifecycleTests.swift
  - id: openwiki-source-01fd62d857f198c9f92cb8a5
    resource: repo://FrameworkTests/RetiredTerminalHighlightingTests.swift
  - id: openwiki-source-3b1e8e4540cb99cbbd7863f5
    resource: repo://FrameworkTests/SnippetColorTests.swift
  - id: openwiki-source-db40aa993661b07f1a9aff6d
    resource: repo://FrameworkTests/SSHInteractionPolicyTests.swift
  - id: openwiki-source-e568ada11d31632da3ad26c7
    resource: repo://FrameworkTests/TerminalFindControllerTests.swift
  - id: openwiki-source-eaed8c88a9a3f24e3feb1f9c
    resource: repo://FrameworkTests/WebAuthnVaultMetadataTests.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-45335a7ce5c8b0e4f813ae69
    resource: repo://TFI/App/MobileRecentlyClosedWorkspaces.swift
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
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-f7aa24af0100c1767226879a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceSearchModifier.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-ca0b3e6e839587396cdeaf54
    resource: repo://TFI/Platform/MobileTerminalSurface.swift
  - id: openwiki-source-707053bb7defcfbf9343584b
    resource: repo://TFI/UI/Components/MobileConnectionJourneyView.swift
  - id: openwiki-source-c128ba4d61fc5b0e803b6ec1
    resource: repo://TFI/UI/Components/MobileToolbarSearch.swift
  - id: openwiki-source-5147eea728b12cb304c33011
    resource: repo://TFITests/KeyWindowTestTrait.swift
  - id: openwiki-source-fffc181d864b6caea779a6f5
    resource: repo://TFITests/MobileAdaptiveLayoutTests.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-7341d7b266d976d7aac5d161
    resource: repo://TFITests/MobileEditorToolbarTests.swift
  - id: openwiki-source-2c7245a9a1462a5a8d09b739
    resource: repo://TFITests/MobileMetricsJourneyTests.swift
  - id: openwiki-source-b6fae59344747785dee252f3
    resource: repo://TFITests/MobileTerminalSearchTests.swift
  - id: openwiki-source-4be25dd014939527fac996f5
    resource: repo://TFITests/MobileTerminalUploadMenuTests.swift
  - id: openwiki-source-b360f8803ec98b554faad9bb
    resource: repo://TFITests/MobileWorkspaceSessionTests.swift
  - id: openwiki-source-cc27a76170a8c672a70e388a
    resource: repo://TFITests/Screenshots/MobileConnectionJourneyRenderingTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-e23b71e7deab33832fd92796
    resource: repo://TFM/App/RecentlyClosedWorkspaces.swift
  - id: openwiki-source-873894299539cce9a737a860
    resource: repo://TFM/App/RootView.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-fe5539ed6f675410b82b41c4
    resource: repo://TFM/Features/Terminal/PersistentTerminalSurfaceView.swift
  - id: openwiki-source-dc041600497a72c229d5eef4
    resource: repo://TFM/UI/Components/ConnectionJourneyView.swift
  - id: openwiki-source-73c75477db0674192248aa00
    resource: repo://TFMTests/AppTerminationTests.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-85c3f954351f96433cb1fb4b
    resource: repo://TFMTests/ConnectionJourneyTests.swift
  - id: openwiki-source-c7d015a20982da4e8b0599d1
    resource: repo://TFMTests/MetricsJourneyRenderingTests.swift
  - id: openwiki-source-a08489338be00125d646c77e
    resource: repo://TFMTests/VisibleWindowTestTrait.swift
  - id: openwiki-source-402244fee941f965f41388e4
    resource: repo://TFMTests/WebAuthnSSHTests.swift
generated: { by: "pi", at: "2026-10-06T18:02:45.153Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-06T18:02:45.153Z
---

# Termind Engineering Quickstart

Termind is one Xcode project with native `TFM` (macOS) and `TFI` (iPhone/iPad) app targets over shared frameworks, plus separate test, widget, and macOS MCP bridge products. Platform UI and lifecycle remain app-owned; source and tests are authoritative. Before changing an ownership boundary, read [Engineering Invariants](architecture/engineering-invariants.md), then the narrowest guide below.

## 1. Find the owner

### Architecture and native UI

| Task | Guide and focused check |
| --- | --- |
| Module placement, imports, nested directories, shared resources | [Module and Product Map](architecture/module-map.md) → [System Boundaries](architecture/system-boundaries.md). For placement, use [Shared Module Ownership](architecture/shared-module-directories.md), [Native App Responsibilities](architecture/native-app-directories.md), or [Supporting Systems](architecture/supporting-system-directories.md). Run `ArchitectureBoundaryTests` for dependency changes. |
| Composition, startup failure, window/scene state, backgrounding, quit | [Platform Startup and Runtime Composition](architecture/platform-runtime.md); choose `AppTerminationTests`, `MobileAppTests`, `MobileWorkspaceSessionTests`, or `MobileForwardingLifecycleTests`. |
| Desktop Navigator, sidebar, workspaces, Vault, Assistant layout | [macOS UI and Workspace Ownership](architecture/desktop-ui.md); use the relevant window/navigation or layout tests. |
| Desktop Workspace/Pane sorting, merging, drag-out windows, Assistant reordering | [TFM Drag and Drop](workflows/desktop-drag-and-drop.md); preserve native Workspace List source and live receiver contracts. Start with `WorkspaceNavigatorDropTests`, `WorkspaceLayoutDropTests`, `WorkspaceWindowMoveTests`, or `AssistantConversationListDropTests`, then the guide's source/cancellation/animation suites. |
| Mobile tabs, scene routes, cards, editors, terminal continuity | [iOS and iPadOS UI and Scene Ownership](architecture/mobile-ui.md); use `MobileWorkspaceSessionTests` for window-owned connections/routes, `MobileAdaptiveLayoutTests` or `MobileNavigationParityTests` for UI, and `MobileMetricsJourneyTests` for metrics authentication/navigation. |
| Shared UI conventions, fields, tokens, accessibility | [UI Design and Shared Presentation](concepts/ui-design-principles.md); check platform renderings and `ArchitectureBoundaryTests`. |
| File drops, Assistant attachments, terminal/SFTP uploads, remote-file dragging, Key import | [File Drag and Drop](workflows/file-drag-and-drop.md); trace native routing, payload priority, staging and transfer lifetimes. Use `FileURLDropTargetTests`, `MobileDropTests`, and the guide's upload/attachment/import suites; it also locates shared Overlay UI. |

### Terminal, connection journeys, and remote services

| Task | Guide and focused check |
| --- | --- |
| **Mobile terminal Find, SFTP filtering, native search dismissal** | [Mobile UI](architecture/mobile-ui.md) and [Ghostty Terminal Integration](concepts/ghostty-terminal-integration.md). Start at `MobileWorkspaceSearchModifier` and `MobileToolbarSearch`; use `TerminalFindControllerTests` for shared Find policy and `MobileTerminalSearchIntegrationTests` in `TFITests/MobileTerminalSearchTests.swift` for repeated close/reopen, retained queries, empty queries, and native/programmatic dismissal. |
| **Connection-journey surface retention** | The same [Mobile UI](architecture/mobile-ui.md) and [Ghostty integration](concepts/ghostty-terminal-integration.md) guides: keep the search modifier outside journey-dependent content and hide, rather than replace, the terminal surface. `MobileTerminalSearchIntegrationTests.connectionJourneyKeepsSearchAndTheTerminalMounted` checks search-controller identity for SSH/SFTP and attached terminal identity for SSH. |
| Ghostty menus, touch selection, themes/local typography, native surface identity | [Ghostty Terminal Integration](concepts/ghostty-terminal-integration.md); Termind overrides separate iOS hooks and native macOS menus. Run `MobileTerminalUploadMenuTests` / `TerminalContextMenuTests`; package pointer/selection internals need the resolved upstream source/tests. App-owned keyword highlighting is retired in V52. |
| Ghostty dependency/API updates | [Ghostty Dependency Updates](operations/ghostty-fork-maintenance.md); align the direct `Lakr233/libghostty-spm` requirement and resolved pin, then validate both host adapters. No local Ghostty maintenance submodule/fork release or override workspace remains. |
| SSH/Telnet, credentials, routes, trust, session cleanup | [SSH, Telnet, Trust, and Workspace Session Lifecycle](workflows/ssh-session-lifecycle.md); select connection, trust, authentication and session tests. Shared journey state uses `ConnectionJourneyTests`; native mobile rendering uses `MobileConnectionJourneyRenderingTests`. For admission/backpressure, see [SSH Multiplexing and I/O Scheduling](concepts/ssh-multiplexing-and-scheduling.md). |
| SSH Security Key registration, FIDO2/WebAuthn, Vault metadata, forwarding restrictions | [SSH Security Key Authentication](concepts/ssh-security-key-authentication.md); use `WebAuthnVaultMetadataTests` for destination/jump metadata resolution without Keychain, V45/V2 metadata, compatibility normalization and rollback; `WebAuthnSSHTests` for registration/assertion parsing and SSH wire fields; `SSHInteractionPolicyTests` for silent-connection restrictions. These synthetic fixtures do not replace hardware-key/native-prompt checks. |
| Terminal services, metrics, forwards, shell hooks, forwarding pools | [Remote Services and Forwarding](concepts/remote-services-and-forwarding.md), [Shell Integration](concepts/shell-integration.md), and [Port Forwarding Dispatch](workflows/port-forwarding-pool-and-dispatch.md); choose service/pump tests. Metrics keyboard-auth presentation uses `MetricsJourneyRenderingTests` on desktop and `MobileMetricsJourneyTests` on mobile. |
| Tailscale groups, login/Save/logout, stable peer IDs, routing, SSH approval, profile cleanup | [Tailscale Groups, Embedded Nodes, and SSH](integrations/tailscale.md); trace `TailscaleModel`, group editor, group-scoped Host identity, native node and local profile store. Use group-editor, identity, integration, cleanup, Metrics and sync-safety tests. |
| SFTP browsing, scheduling, external edit | [SFTP Transfer, Scheduling, and External Edit](workflows/sftp-transfer-and-external-edit.md); select transfer, conflict or edit tests. Native filter presentation also follows the mobile search route above. |

### Data, Assistant, and product operations

| Task | Guide and focused check |
| --- | --- |
| Assistant turns, approvals, host tools, skills, memory | [Assistant and Agent Runtime](concepts/agent-runtime-and-assistant.md); target preparation, cancellation, persistence, tools or memory tests. |
| SwiftData, secrets, migrations, settings, CloudKit | [Persistent Data, Migrations, and Secrets](concepts/persistence-and-secrets.md), [Settings and Cloud Sync](workflows/settings-and-cloud-sync.md), and [CloudKit Release Readiness](operations/cloudkit-release-readiness.md). Select repository/migration tests or `CloudSyncLifecycleTests`, `CloudSyncSafetyTests` and coordinator tests for sync changes. |
| MCP server, external upload/download, stdio bridge | [MCP Server, Transfers, and Stdio Bridge](integrations/mcp-server-and-bridge.md); run token, server-session, transfer or bridge tests. |
| Commerce, localized copy, widgets, screenshots, website | [Commerce, Localization, and Product Surfaces](concepts/commerce-localization-and-product-surfaces.md), [Storefront Commerce Release Checks](operations/storefront-commerce-release.md), [Marketing Assets and App Icons](operations/marketing-assets-and-app-icons.md), and [Build, Test, and Release](operations/build-test-and-release.md). Choose bilingual catalog, app/language, screenshot, StoreKit or website checks. |
| **Asset production, scan capture, frameit, Figma and App Store exports** | [Marketing Assets and App Icons](operations/marketing-assets-and-app-icons.md) is the canonical workflow: exact native iPhone Pro/Duo/iPad/Mac pixels and postures, licensed frame templates/masks, 72 four-platform JPG boards, current website compositions and SSH-first submodule publication. Use `plan:true` and Ruby checks without opening app windows. |
| Deterministic fixture or test seam | [Behavioral Tests and Fixtures](testing/behavioral-boundaries-and-fixtures.md); run the narrow behavioral regression before the affected target suite. |

## 2. Preserve the changed boundary

These are routing reminders, not replacements for the detailed guides.

### Dependency direction and release source

- `TermindDomain` defines portable rules; `TermindApplication` owns ports/use cases; `TermindPersistence` owns SwiftData models, repositories and container construction; infrastructure implements services; `TermindPresentation` owns reusable SwiftUI content/copy. Apps assemble concrete dependencies and native UI.
- `ArchitectureBoundaryTests` enforces **root-specific** restrictions, not an all-UI-framework ban. Its five non-presentation shared-framework rule rejects app targets and `AppKit`, `UIKit`, `IOKit`, `ServiceManagement`. Presentation allows `SwiftUI` and contains existing conditional platform helpers; its selected source-pattern/import/construction rules reject app-target, storage, concrete-service and commerce coupling. Those checks are not a blanket compiler-enforced prohibition on every platform symbol. Shared Application cannot import Infrastructure, Persistence or SwiftData. Desktop Application/Features and mobile layers have their own checks; selected roots also guard concrete construction, AgentKit type duplication and SwiftData ownership. Fix the boundary rather than bypassing the test; see [System Boundaries](architecture/system-boundaries.md).
- AgentKit is a separately versioned, host-neutral remote package owning the loop, approvals, providers, MCP client and built-in tools. Termind owns SSH/SFTP tools and registers them additively. Xcode's requirement starts at `0.19.0` under `upToNextMajorVersion`; the sibling working tree is not the resolved build. Cross-repository work means test/release `../AgentKit`, update `minimumVersion` in `Termind.xcodeproj/project.pbxproj`, and re-resolve `Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` together.
- Ghostty comes directly from `Lakr233/libghostty-spm`, with an up-to-next-major requirement and resolved version `2.2.2026100501` at `7199bd7aa3c32d0a5edcab7fe87b3c1e76f76de9`. There is no local Ghostty maintenance submodule or Termind native-binary release prerequisite. Align requirement/resolution and validate both adapters; package internals require separate review. See [Ghostty Dependency Updates](operations/ghostty-fork-maintenance.md).

### Native lifetimes and presentation

- **Desktop:** `TermindApp` creates the container and shared `AppModel` at launch, using in-memory stores for XCTest/debug screenshot demos. Database-open failure fails startup instead of replacing the store. Each main `WindowGroup` owns a `WindowModel`; `RootView` registers the window, publishes its focused scene value and preserves mounted workspace views across destinations. The external-authentication `Window` shares the app environment/container but removes its manual Window-menu command; it is not another main workspace.
- **Mobile:** `TermindIOSApp` migrates language preferences and creates one live/testing `MobileAppModel`; `MobileStartupView` injects its container on success or shows unavailable data on failure. Startup waits for the native scene delegate's session ID; `MobileBoundSceneRoot` creates/retains `MobileSceneModel` in a task and binds the delegate on appearance. Scene-local navigation/Assistant presentation sits over a persistent UIKit-session-owned `MobileWorkspaceSessionModel`, not one interchangeable cross-window workspace pool. Workspace/Transfers destinations and Connection Picker/Batch Startup sheets each use mutually exclusive optional enums with derived accessors.
- **Restoration:** cold launch consolidates saved descriptors into the first bound mobile session without connecting; restore failure reports an error rather than letting another scene claim them. Selecting a descriptor publishes the owner's workspace before connecting and repeated selection reuses it. A link in another window activates the owner. Backgrounding/removal alone does not discard workspaces: reconciliation can transfer a disappeared session's live workspaces to an active session without reconnecting; explicit discard closes them. Descriptors must not persist transports, secrets, one-shot commands or initial paths. Desktop session/pane and mobile workspace owners end their connection-history entries on close. Follow [Mobile UI](architecture/mobile-ui.md) and [Session Lifecycle](workflows/ssh-session-lifecycle.md).
- **Recently closed:** each app owns a device-local 15-record store, retaining eligible Workspace/window metadata across launch and grouped-window selection. Closing disconnects transports; a move does not add close history and preserves live sessions. Restore consumes records only after a viable destination is available. See [Native App Responsibilities](architecture/native-app-directories.md); do not confuse this with synchronized connection history or cold descriptor restoration.
- **Search:** SSH/Telnet binds the workspace's `TerminalFindController` to Ghostty binding actions; SFTP binds search text to `sftpChannel.query`. `MobileToolbarSearch` gives UIKit ownership of search presentation and fences SwiftUI synchronization during dismissal. Native terminal-search dismissal ends Find without requesting terminal focus; queries survive closing and reopening. Resize temporarily suspends engine search without clearing UI state, and resumes only a still-presented nonempty latest query. Journey presentation retains the search attachment; the terminal remains mounted but hidden and noninteractive. See the focused tests above rather than replacing this native lifecycle with SwiftUI search-focus state.
- **Menus:** `MobileTerminalView` customizes both `touchMenuItems(for:)` and `touchSelectionMenuItems(for:)`, grouping/localizing editing actions before uploads and remaining system items. Desktop uses `selectionMenuPoint(at:)`, `selectionContextMenu()` and `menu(for:)`. The app adapters/tests establish these seams; package-owned indirect-pointer behavior needs separate package inspection.

### Shutdown, sync, and authentication safety

- Mobile phases aggregate across scenes: pause background services only when **all** registered scenes background. Expiration suspends workspaces, stops forwards, pauses transfers and expires Assistant work; an active scene resumes monitoring, memory, workspaces, eligible sync and metrics. Use [Platform Runtime](architecture/platform-runtime.md).
- Closing the last macOS window never terminates the Debug test host; otherwise menu-bar metrics preferences and running metrics decide. Quit rechecks unuploaded SFTP edits and permits cancellation. Confirmed termination fences new Assistant work, drains cancellation/persistence, stops transfers/MCP and closes agent resources. AppKit receives one reply after cleanup or a three-second fallback; the fallback bounds the reply, **not** asynchronous cleanup completion.
- `CloudSyncLifecycle` owns a separate engine/account scope per category: persist a recovery fence before automatic syncing, fetch before authorizing uploads, and reconcile pending changes against the durable journal. Pause, account changes and non-cancellation persistence failures retire/cancel the engine outside delegate context; late completions cannot update its replacement. A build is not a sync migration check: use [CloudKit Release Readiness](operations/cloudkit-release-readiness.md) and the lifecycle/safety/coordinator tests.
- Shared `ConnectionJourney` tracks route progress and authentication/host-key checkpoints; `ConnectionJourneyRouteView` draws the common route, while apps own prompts/navigation. Use shared state tests, then affected native rendering/metrics fixtures; rendering is not a live SSH test.
- Security Key references remain external Vault metadata with compatibility normalization; failed metadata writes/deletes roll back, and software keys cannot use external storage. A forbidden SSH interaction policy blocks destination/jump security-key credentials even with optional user presence. Keep silent auxiliary connections from triggering hardware prompts.

## 3. Validate narrowly, then validate the product

Keep `-onlyUsePackageVersionsFromResolvedFile` so ordinary builds cannot silently move the dependency graph:

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile build
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile build
xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge
Scripts/check-zh-localization.sh
```

Use an installed iPhone/iPad simulator for `TFI` tests. For the search integration regression, replace the destination below with one installed locally:

```sh
TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1 xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'platform=iOS Simulator,name=<installed simulator>' -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO -only-testing:TFITests/MobileTerminalSearchIntegrationTests test
```

### Native presentation gates

- Visible-window macOS tests require `.requiresVisibleWindow` and `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` (or `TERMIND_WINDOW_TESTS=1` in the Xcode test action), preferably with `-only-testing:TFMTests/<Suite>`. Debug XCTest still launches the real desktop app, but automatic main/external-auth windows and main-scene restoration are suppressed by default. The opt-in or an active screenshot demo lifts window suppression; demos also disable restoration. Host suppression complements, not replaces, the test trait.
- Mobile key-window integration suites require `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1`, `-parallel-testing-enabled NO`, and a narrow `-only-testing:TFITests/<Suite>`. `MobileAdaptiveLayoutTests` gates its native-window cases individually and leaves pure width logic enabled; `MobileMetricsJourneyTests` has a suite-level key-window gate. Use narrow nonparallel opt-in runs for those UIKit fixtures. Check each annotation—some older connection-picker toolbar fixtures remain ungated rather than assuming the policy covers every window-creating case. Keep presentation gates off for routine checks; offscreen tests remain enabled.
- Mobile journey screenshot export remains entirely opt-in under `TERMIND_JOURNEY_SCREENSHOTS`. Follow [Behavioral Tests and Fixtures](testing/behavioral-boundaries-and-fixtures.md) for fixture limits.

### Copy, web, and release checks

- Define app copy in shared `TermindPresentation/Strings`; new/changed English text needs finished `zh-Hans` and `zh-Hant` translations in `Frameworks/Resources/Localizable.xcstrings`. Catalogs are manually managed: after edits run `Scripts/normalize-string-catalogs.py --write`, `Scripts/check-appstrings.sh`, and `Scripts/check-zh-localization.sh` (requires `jq`). Run the Chinese check even without intended copy changes; use `AppLanguageTests` for language behavior.
- Website/asset work: initialize `com.akinokaede.termind` only when needed; `(cd com.akinokaede.termind && npm ci && npm run build)`, then inspect `/`, `/zh-hans/`, `/zh-hant/` and the `/zh/` redirect. Source assets live in the independent submodule; commit/push reviewed assets via SSH before updating the parent gitlink, keeping the public HTTPS clone URL.
- Screenshot tooling stays app-owned: fastlane scan captures native sources, frameit composes staged copies with licensed templates, and Figma final artwork/website frames are distinct derived deliverables. Do not invoke capture just to validate documentation.
- Before submitting, inspect the diff for secrets, generated artifacts, cross-layer imports and accidental `Package.resolved` churn. Use [Build, Test, and Release](operations/build-test-and-release.md) and the routed operations pages for CloudKit deployment, StoreKit/Sandbox validation, marketing assets and [forwarding benchmark measurement](operations/port-forwarding-benchmarks.md). Former StoreKit trial/catalog test files are removed; live purchases require Sandbox validation.

### Data reminders

Current local schema is V52: V51 adds Snippet colors over a frozen historical model, then V52 removes retired keyword-highlighting preferences. `SnippetColorTests` verifies V50 upgrade/color reopen; `RetiredTerminalHighlightingTests` verifies V46/V51 cleanup, inactive-upload retirement and malformed legacy-record isolation. Command/SFTP history is live-session memory; connection history remains durable and synchronized. Vault Host/Snippet write V2; HostGroup/SSHKey write V3; Metrics writes V2 and reads V1/V2. Keep metadata in persistence and secret values behind Keychain references. Assistant `read_pane` requires a captured explicit pane ID. Follow the data/Assistant guides for changes rather than using these reminders as migration or tool-policy specifications.
