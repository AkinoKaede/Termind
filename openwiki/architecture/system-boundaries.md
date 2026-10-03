---
type: architecture boundaries
title: System boundaries and dependency direction
description: Target dependency direction, enforced import scopes, and ownership of shared ports, persistence, external packages, and native app composition in Termind.
tags: [architecture, modularity, dependencies, persistence, agentkit, swift]
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-3118dfa7dfade14baaccd202
    resource: repo://Frameworks/TermindApplication/FeatureModels/AIConfigurationModel.swift
  - id: openwiki-source-e09fb7bc8e7ca0579f6d446e
    resource: repo://Frameworks/TermindApplication/FeatureModels/DeviceDirectoryModel.swift
  - id: openwiki-source-9ee5ed32f6974f5906438e59
    resource: repo://Frameworks/TermindApplication/Repositories/ConnectionHistoryRepository.swift
  - id: openwiki-source-6f388236eaa573c3c2ba7706
    resource: repo://Frameworks/TermindApplication/Repositories/DeviceDirectoryRepository.swift
  - id: openwiki-source-9b6177e37e7dd97d0cb1adee
    resource: repo://Frameworks/TermindApplication/Terminal/TerminalFindController.swift
  - id: openwiki-source-e4f5ea9b30063cdc7d027956
    resource: repo://Frameworks/TermindDomain/Connections/ConnectionHistoryEntry.swift
  - id: openwiki-source-7367aa06bc3b7ce470e78113
    resource: repo://Frameworks/TermindDomain/DeviceRecord.swift
  - id: openwiki-source-82f1da82c84bec6e60959357
    resource: repo://Frameworks/TermindInfrastructure/Commerce/RevenueCatProPurchaseService.swift
  - id: openwiki-source-fe1dc993163bb9ff61397be7
    resource: repo://Frameworks/TermindPersistence/HostPersistence.swift
  - id: openwiki-source-303e34b5782a7a14e28cc9f8
    resource: repo://Frameworks/TermindPersistence/PersistentStoreLock.swift
  - id: openwiki-source-4217f56e034013cb8704d525
    resource: repo://Frameworks/TermindPersistence/SwiftDataConnectionHistoryRepository.swift
  - id: openwiki-source-0b6ab59ec6a684de8101ff8e
    resource: repo://Frameworks/TermindPersistence/SwiftDataDeviceDirectoryRepository.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-1c845e5af67c400566be83bd
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AssistantToolRegistry.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-0198125ac2a5c63e2b200fb9
    resource: repo://FrameworkTests/HistoryRenderingSnapshotTests.swift
  - id: openwiki-source-ad1a1eea0aea739f2004d93a
    resource: repo://FrameworkTests/PersistentStoreLockTests.swift
  - id: openwiki-source-e568ada11d31632da3ad26c7
    resource: repo://FrameworkTests/TerminalFindControllerTests.swift
  - id: openwiki-source-27d6a8d3b199ecf35f59fafb
    resource: repo://Scripts/swiftdata-repository-declarations.sh
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-dc9295278cc250ed20567540
    resource: repo://TFI/App/MobileAppDependencies.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-5b8c72c5373a41af34fa9fd4
    resource: repo://TFI/App/MobileStartupView.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-f7aa24af0100c1767226879a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceSearchModifier.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-c128ba4d61fc5b0e803b6ec1
    resource: repo://TFI/UI/Components/MobileToolbarSearch.swift
  - id: openwiki-source-a154b5d36ec59496392d45e4
    resource: repo://TFITests/MobileAssistantTests.swift
  - id: openwiki-source-a7d4f0957a52ddd59cd45344
    resource: repo://TFITests/MobileShortcutTests.swift
  - id: openwiki-source-c52cd56852d12b2dee153082
    resource: repo://TFM/App/AppDependencies.swift
  - id: openwiki-source-d5cca6ff91d9aaa5da323b40
    resource: repo://TFM/App/DatabaseStartupGuard.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-68b5f4529ef349aac826b1d9
    resource: repo://TFM/Platform/MacDeviceName.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-c15cd5bef4646aaf64df407e
    resource: repo://TFMTests/ConnectionHistoryTests.swift
generated: { by: "openwiki/0.7.0", at: "2026-10-03T22:38:13.888Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-03T22:38:13.888Z
---

# System boundaries and dependency direction

Termind is built as two native applications around six shared static frameworks. The boundary is intentional: reusable layers model policy and ports, infrastructure implements those ports, and `TFM` (macOS) and `TFI` (iOS/iPadOS) compose the result with native lifecycle and UI. A safe change starts by placing the responsibility with its owner rather than importing a convenient concrete dependency into a lower layer.

```mermaid
flowchart TD
    TFM["TFM macOS app composition and UI"] --> Shared["Six shared frameworks"]
    TFI["TFI iOS app composition and UI"] --> Shared
    Presentation["TermindPresentation reusable SwiftUI policy"] --> Application["TermindApplication ports and use cases"]
    Presentation --> Domain["TermindDomain values and rules"]
    Remote["TermindRemoteInfrastructure SSH SFTP Telnet"] --> Infrastructure["TermindInfrastructure general implementations"]
    Remote --> Application
    Remote --> Domain
    Infrastructure --> Persistence["TermindPersistence SwiftData schemas and stores"]
    Infrastructure --> Application
    Infrastructure --> Domain
    Persistence --> Application
    Persistence --> Domain
    Application --> Domain
    Package["Resolved AgentKit package"] -.-> Shared
```

The diagram shows consumer-to-dependency arrows for explicit shared-framework Xcode target dependencies; the dotted package arrow groups external consumers rather than implying every framework links AgentKit. Both apps depend on all six frameworks; no framework depends on an app. See the [Module and Directory Architecture Map](module-map.md) for the directory-oriented view.

## Layer responsibilities

| Owner | Put here | Keep out |
| --- | --- | --- |
| `TermindDomain` | Portable values, domain rules, records, and protocol-neutral concepts. | UI, persistence APIs, security/network frameworks, CloudKit, StoreKit, SSH C libraries, and terminal implementations. |
| `TermindApplication` | Use cases, feature models, repository and service ports, connection/import policy, and cross-feature policy. | Platform UI, SwiftData/GRDB, transport imports, concrete infrastructure construction, and dependencies on Infrastructure or Persistence. |
| `TermindInfrastructure` | General implementations such as in-memory repositories, CloudKit-backed sync, metrics parsers, logging, RevenueCat commerce integration, and settings/Vault services. | Native app targets and platform UI. It may depend on Application, Domain, and Persistence. |
| `TermindRemoteInfrastructure` | SSH, SFTP, Telnet, Keychain-backed remote credentials, host-key/authentication mechanics, transfers, forwarding, and Termind-specific agent tools. | App targets and their UI; features should use injected services rather than construct remote transports themselves. |
| `TermindPersistence` | SwiftData `@Model` declarations, versioned schemas, migration plan, SwiftData repository/store implementations, `ModelContainer` factory, and GRDB-backed memory store. | Application-infrastructure implementation dependencies, remote infrastructure, and app targets. |
| `TermindPresentation` | Reusable SwiftUI presentation policy and content: formatting, forms, summaries, transcript/tool-card rendering, and terminal presentation helpers. | AppKit/UIKit, SwiftData/GRDB/Persistence, Infrastructure/Remote Infrastructure, StoreKit, and app targets. |
| `TFM` / `TFI` | Native UI, platform adapters, dependency assembly, lifecycle, window/scene ownership, and platform-specific resources. | Shared implementation that should be portable; no shared framework may import an app target. |

`Frameworks/Resources/` is compiled into both application bundles for shared resources such as localization catalogs; app-owned icons, metadata, signing, native adapters, and platform behavior remain in `TFM` or `TFI`.

### Dependency rules that are enforced

`ArchitectureBoundaryTests` checks **specific forbidden import sets per root**, not a blanket prohibition on platform APIs or concrete dependencies. The Xcode target graph expresses current build edges, while the source tests police selected imports and declarations; broader ownership guidance in this page is a convention unless a matching test or target constraint is identified. Its exact-line import scans currently enforce:

| Scanned source root | Imports rejected by the test |
| --- | --- |
| Shared `TermindDomain` | `SwiftUI`, `AppKit`, `UIKit`, `SwiftData`, `GRDB`, `Security`, `Network`, `StoreKit`, `CloudKit`, `CSSH2`, `OpenSSL`, `GhosttyTerminal`, `GhosttyTheme`, `RevenueCat`, `RevenueCatUI`; also the shared non-presentation and diagnosis rules below. |
| Shared `TermindApplication` | `TermindInfrastructure`, `TermindPersistence`, `SwiftData`, `RevenueCat`, `RevenueCatUI`; also the shared non-presentation and diagnosis rules below. Unlike desktop `TFM/Application`, this root has no separate UI/transport import list, but does have the concrete-symbol guard. |
| Shared `TermindInfrastructure` and `TermindRemoteInfrastructure` | The shared non-presentation rule below; Infrastructure's `Commerce` directory additionally rejects `StoreKit` (transactions are handled by RevenueCat), while Remote Infrastructure may use transport libraries. |
| Shared `TermindPersistence` | `TermindInfrastructure`, `TermindRemoteInfrastructure`; also the shared non-presentation and diagnosis rules below. |
| **Shared `TermindPresentation`** | Its **separate** rule rejects `Termind`, `TermindIOS`, `UIKit`, `AppKit`, `SwiftData`, `GRDB`, `TermindPersistence`, `TermindRemoteInfrastructure`, `TermindInfrastructure`, `StoreKit`, `RevenueCat`, `RevenueCatUI`. It intentionally can import `SwiftUI`; it is not covered by the other five-framework rule. The diagnosis rule also applies. |
| Desktop `TFM/Application` | `SwiftUI`, `AppKit`, `UIKit`, `AuthenticationServices`, `SwiftData`, `GRDB`, `Security`, `Network`, `CSSH2`, `OpenSSL`, `GhosttyTerminal`, `GhosttyTheme`, plus the concrete-symbol guard. |
| Desktop `TFM/Features` | `SwiftData`, `GRDB`, `Security`, `Network`, `CSSH2`, `OpenSSL`, plus the concrete-symbol guard. |
| Mobile `TFI/Application` | `SwiftUI`, `UIKit`, `SwiftData`, `GRDB`, `TermindPersistence`. |
| Mobile `TFI/UI` | `SwiftData`, `GRDB`, `TermindPersistence`, `TermindRemoteInfrastructure`. Mobile `TFI/Features` gets only the concrete-symbol guard. |

The shared non-presentation rule (Domain, Application, Infrastructure, Remote Infrastructure, Persistence) rejects `Termind`, `TermindIOS`, `AppKit`, `UIKit`, `IOKit`, and `ServiceManagement`. A separate embedded-Tailscale rule rejects `TailscaleKit` and `CTailscale` in Domain, Application, Presentation, and Persistence; it does not scan Infrastructure or either app. A separate diagnosis rule rejects `FirebaseCore`, `FirebaseCrashlytics`, and `FirebaseAnalytics` in Domain, Application, Presentation, and Persistence (but not Infrastructure or Remote Infrastructure), and checks both app plists default crash/analytics collection off. Separate tests reject app-local `AppStrings` definitions and constrain imports in Presentation's `Strings` directory. The concrete-symbol guard on shared Application, desktop Application/Features, and mobile Features looks for `ModelContext`, `FetchDescriptor`, `KeychainSecretStore`, `SFTPClient()`, `SSHConnection()`, and `URLSession(`; it does **not** run on mobile Application or UI. These are **source-root checks**, not blanket rules for all of `TFM` or `TFI`: desktop `App/TermindApp.swift` and mobile `App/MobileAppModel.swift` composition files can import SwiftData and concrete frameworks. The import check matches literal `import Module` lines and the token check scans a fixed list after stripping `//` suffixes; neither proves an exhaustive compiler-enforced boundary or bans all concrete code. Use injected ports across a boundary rather than a re-export, forwarding alias, generic “Core” module, or framework-to-app reference.

## Persistence is a single-owner boundary

`TermindPersistence` exports the current schema (`TermindSchemaV50`) and builds a `ModelContainer` using `TermindMigrationPlan`. V39 added persistent assistant model selection; V40 removed retired per-category quarantine tables while keeping scoped quarantine; V41 added shared notification preferences; V42 adds agent-message provenance, chat creation relations, and durable collaboration delivery receipts without changing historical model shapes. V43 adds public MCP OAuth configuration, V44 replaces the Host model, and V45 replaces the SSH key model with Security Key reference metadata, and V46 adds terminal keyword-highlight preferences. The migration plan contains lightweight stages through V50, including V47/V48 Tailscale data, V49 history-model removal and V50 profile cleanup. The factory rejects an in-memory request that also supplies a file URL and configures the store with CloudKit disabled. On macOS, before opening or migrating a disk store, it takes a nonblocking exclusive `flock` on a stable `.lock` file keyed by the canonical store URL; same-process containers share the lease and the container retains it until its lifetime ends. An in-memory container skips this lock. Platform composition roots choose *where* the store lives and retain the container, but do not define the model set or construct a substitute container.

Connection history follows the same boundary: Domain owns the portable event value, Application owns the observable model and repository protocol, and Persistence owns its SwiftData shape and independent History-journal transaction. The reusable ID-to-name mapping is deliberately separate: Domain owns `DeviceRecord`, Application owns `DeviceDirectoryModel` and `DeviceDirectoryRepository`, and Persistence owns `PersistentDeviceRecord` plus the SwiftData adapter. A history event merely references `sourceDeviceID`; it does not own or capture the device name. Platform apps inject connection lifecycles, acquire their native system display name, and choose local versus all-device presentation; they do not declare stored models. `DeviceDirectoryModel` registers the current installation at initialization and resolves names by ID from its cached repository snapshot, falling back to the supplied local name for the current device. The constructor defaults to an in-memory directory when no repository is supplied. Registration failure records `storageError` but still attempts a read, so already-saved names may remain visible; `reload()` clears the snapshot on read failure, records `storageError`, and increments `revision` even on failure. Explicit renaming calls `upsert` and updates the local name only after the write succeeds, then reloads the snapshot; a failed rename retains the previous local name and records the error. The SwiftData adapter's launch-time `registerIfNeeded` deliberately leaves a remotely deleted directory entry deleted, whereas an explicit `upsert` commits a changed name or new record with the History journal snapshot and notifies the injected device-sync callback after a successful mutation.

```mermaid
sequenceDiagram
    participant App as Native app
    participant Model as DeviceDirectoryModel
    participant Port as DeviceDirectoryRepository
    participant Store as SwiftData directory adapter
    participant Journal as HistorySyncJournal
    App->>Model: Initialize with installation ID and native name
    Model->>Port: registerIfNeeded device
    Port->>Store: registerIfNeeded device
    Store->>Journal: Check deleted envelope
    alt Remotely deleted
        Store-->>Model: Leave deleted entry untouched
    else Not deleted
        Store->>Journal: Commit changed snapshot
        Store-->>Model: Notify device sync on mutation
    end
```

The registration path crosses the app naming, Application port, and Persistence journal boundaries; the explicit rename path can recreate an entry that launch registration will not.

This separation matters for migrations: all SwiftData models, frozen historical schemas, migration plans, and container construction stay together in Persistence. The boundary test rejects `@Model` declarations in scanned desktop, mobile, Domain, Application, and Infrastructure roots and requires Persistence to contain Swift files; the `@Model` scan does not currently include Remote Infrastructure or Presentation. That scan asserts absence of declarations in those roots, not that all models in the repository are discovered or that every historical schema is correct. A separate SwiftData-repository-declaration check covers those two roots as well as both apps, the other shared frameworks, bridge, benchmark, widget, and workspace-activity support targets; it uses a Swift declaration parser and requires at least one such declaration in Persistence. These checks still do not constitute an exhaustive ownership proof. A new persisted SwiftData entity therefore requires a Persistence schema/migration decision—not a model embedded in a feature, app, or general infrastructure module.

Desktop calls `TermindPersistence.makeContainer` with in-memory storage for tests and screenshot demos. Before live container creation it checks for another running app with the same bundle identifier (including older releases without store locks); a detected second instance or a lock contention presents a database-in-use alert and exits. Other database-open or preparation errors cause a startup `fatalError`, rather than silent replacement with an empty store. Mobile `MobileAppModel` uses an injected container when provided, otherwise calls the same factory with a file under Application Support for live storage or in-memory storage for tests/injected host repositories; it creates the directory for a live store and prepares host, settings, metrics and history persistence before wiring dependent feature models. `TermindIOSApp` builds the model once during startup and `MobileStartupView` displays an unavailable-data screen when composition fails. See [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) for the app/window/scene lifetime split and platform-specific failure handling.

## Composition, resource, and state ownership

The app targets are composition roots. `TermindApp` creates the desktop `ModelContainer`, keychain store, sync persistence/coordinators, repositories, connection coordinator, logging, and app-wide `AppModel`; it also supplies `MacDeviceName.current` to the shared device-directory port (trimmed `kern.hostname`, with DeviceKit's `Device.current.safeDescription` as fallback). It injects the shared model and container into its window scenes. `AppDependencies` packages repository, connection, sync, logging, and optional shutdown services for the desktop model and provides an in-memory host repository for tests. On mobile, `MobileAppDependencies.live()` wires logging and one connection coordinator into workspace and metrics services; `testing()` defaults to in-memory storage and replaceable dependencies. `TermindIOSApp` selects one of these at startup and creates one `MobileAppModel`; on success `MobileStartupView` attaches its container to the scene content. The mobile composition uses DeviceKit's description directly for the device-directory port. This is where a concrete implementation or platform value becomes a port supplied to shared feature code.

Do not use this as permission to move live state into the app-wide layer. Durable stores and cross-window coordinators are app-wide; desktop navigation and workspaces are window-owned; mobile navigation is scene-owned; live SSH/SFTP transports remain with the workspace/session that opened them. Refer to [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) for the detailed ownership map.

### Mobile Find: policy, presentation, and feature binding

The mobile Find path illustrates the same boundary without moving UIKit into shared code:

- **Shared Application owns query/action policy.** `TerminalFindController` holds the query and logical presentation state and emits `TerminalFindBinding` actions through an injected closure. Query changes trigger search; navigation requires a presented, nonempty query. Dismissal ends search but retains the query so reopening restarts it. Its default dismissal restores terminal focus, while `dismiss(restoringFocus: false)` lets native UI own the responder transition.
- **Mobile feature composition owns the workspace binding.** `MobileWorkspace` injects its terminal's action and focus callbacks. `MobileWorkspaceView` applies `MobileWorkspaceSearchModifier`, which binds SSH/Telnet search to `workspace.find`, submits `.previous`, and dismisses without requesting terminal focus. For SFTP the same modifier binds to `sftpChannel.query` instead of terminal Find.
- **Mobile UI owns UIKit presentation.** `MobileToolbarSearch` accepts bindings and a submit callback, installs a `UISearchController` on the navigation owner, and synchronizes delegate changes back through those bindings. It defers synchronization from SwiftUI updates and blocks synchronization, edits, and submission during dismissal to avoid reopening the native search UI mid-transition. On disconnection it removes its search controller and restores the owner's prior presentation-context setting. The bridge imports only `SwiftUI`, `TermindPresentation`, and `UIKit`—neither transport nor persistence implementations. This is a concrete example of the `TFI/UI` import restriction, not a new universal ban on UIKit or a claim that mobile Features cannot import infrastructure.

```mermaid
sequenceDiagram
    participant UI as MobileToolbarSearch UIKit bridge
    participant Feature as MobileWorkspaceSearchModifier
    participant Policy as TerminalFindController
    participant Terminal as Workspace terminal
    UI->>Feature: Query binding changes
    Feature->>Policy: updateQuery
    Policy->>Terminal: Injected search action
    UI->>Feature: Publish dismissal
    Feature->>Policy: dismiss restoringFocus false
    Policy->>Terminal: Injected end-search action
```

The feature binds native search presentation to shared policy; UIKit retains keyboard-dismissal ownership. See [Mobile UI Architecture](mobile-ui.md) and [Ghostty Terminal Integration](../concepts/ghostty-terminal-integration.md) for platform details.

`FrameworkTests/TerminalFindControllerTests.swift` covers retained-query restart, navigation without a query, default focus restoration, and idempotent native dismissal without terminal focus. `TFITests/MobileShortcutTests.swift` checks mobile F3 direction and Escape routing through that shared controller. These tests verify the policy and shortcut paths; they are not proof of every UIKit search-controller transition.

## AgentKit is an external, host-neutral boundary

`AgentKit` is a separately developed remote Swift Package dependency at `https://github.com/AkinoKaede/AgentKit.git`. The project declares `upToNextMajorVersion` from `0.18.1`, and the committed `Package.resolved` file pins the Xcode build. Xcode builds that resolved remote package, **not** a sibling `../AgentKit` working tree; an uncommitted sibling change cannot affect Termind.

AgentKit owns the host-neutral agent runtime: its loop, approval gate, provider adapters, MCP client, built-in tools, and their core types. Do not redefine AgentKit-owned runtime types in Termind, and do not edit AgentKit to add the Termind name, SSH, SFTP, app UI, or other host-specific behavior. A cross-repository change must be released and tested in AgentKit first, then consumed by bumping the project dependency and resolving `Package.resolved` in the same Termind change.

Termind owns host-aware behavior on its side of the boundary. `TermindRemoteInfrastructure` defines `TermindAgentToolEnvironment` with injected host resolution, connection pools, authentication, metrics, background commands, optional pane access, and optional scratch workspace. `AssistantToolRegistry` returns an empty registry when a model lacks tool-call ability. Otherwise it creates a conversation-scoped scratch workspace shared by AgentKit's scratch tools and Termind's host-facing pull/push tools, records plans through the run's ordered event channel, passes usable MCP servers with credentials resolved from their references plus the MCP authorization client to AgentKit's built-in catalog, and registers `TermindAgentTools` as additional tools. Task management is supplied by the built-in catalog rather than a separate task callback in this registry. The registry marks `ssh_exec` as a secret consumer; host login is handled through injected authentication, not by asking the user-secret tool for SSH credentials. The Termind catalog constructs host listing, SSH/SFTP, metrics, pane and host-facing scratch tools from narrowly injected services; its presenter registry also combines built-in and Termind tool presenters for historical transcript rendering. The local registry resolves built-ins before additional tools and discovered MCP definitions, preventing host or MCP names from shadowing built-ins. See [Agent Runtime and Assistant](../concepts/agent-runtime-and-assistant.md) for run-level behavior.

## How to make a dependency-safe change

1. **Classify the responsibility.** Put stable values and rules in Domain; an abstract use case or port in Application; a concrete general service in Infrastructure; a remote transport/security implementation in Remote Infrastructure; schemas and SwiftData stores in Persistence; reusable view policy in Presentation; native assembly or lifecycle in the appropriate app.
2. **Make dependencies point inward through a port.** If an Application or feature model needs persistence, keychain, SSH, or network work, extend or inject an existing protocol/service rather than import and construct its concrete implementation.
3. **Keep persistence changes atomic.** Add models, schemas, migration behavior, and container-facing repositories under `TermindPersistence`; preserve historical schemas and do not create an independent app-level container.
4. **Keep host behavior out of AgentKit.** Add SSH/SFTP or Termind-specific agent functionality through `TermindAgentTools` and injected Remote Infrastructure services. Release AgentKit separately only for genuinely host-neutral runtime behavior.
5. **Validate the boundary, not only the feature.** Run the architecture tests after a dependency or ownership change, alongside the affected feature tests. Their source scans deliberately fail when a forbidden import or concrete construction crosses a layer.

The most common failure modes are a UI feature importing Persistence “just to fetch,” Application importing a concrete transport “just to connect,” a shared framework importing an app target for a native helper, and putting host-specific behavior in AgentKit. Each creates a reverse dependency or duplicates an owner; use injection at the existing boundary instead.

## Focused verification

`TFMTests/ArchitectureBoundaryTests.swift` is the focused regression suite for these constraints. In addition to layer imports and SwiftData ownership, it checks that AgentKit runtime type names are not redefined locally, limits `ListViewKit` to an explicit native-list allowlist, checks selected forwarding/mobile authentication boundaries and additional-connection references, and ensures the forwarding benchmark is independent of app and test targets. It also checks RevenueCat's commerce ownership, diagnosis SDK isolation and disabled-by-default collection, shared CloudKit upload/quarantine gates, and selected localization ownership rules. The checks fail closed if an expected production root is missing or contains no Swift files, so relocating source cannot silently disable the safeguards. `FrameworkTests/PersistentStoreLockTests.swift` exercises pre-open contention, container-lifetime and same-process leases, forced-exit recovery, and independent/in-memory stores; `TFITests/MobileAssistantTests.swift` checks built-in and remote tool presence only for tool-capable models. For the device-directory boundary, `FrameworkTests/HistoryRenderingSnapshotTests.swift` checks that a failed registration still leaves readable names visible, rendering reads do not fetch or publish changes, and reload recovers from a failed read; `TFMTests/ConnectionHistoryTests.swift` checks stable device IDs and rename projection for existing history events.

For normal project validation, use the resolved dependency graph rather than allowing a fresh resolution:

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
```

Use the corresponding `TFI` build/test command when a change affects the mobile target. See [Build, Test, and Release](../operations/build-test-and-release.md) for the full command set.
