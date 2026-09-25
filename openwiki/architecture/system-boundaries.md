---
type: architecture boundaries
title: Dependency and Ownership Boundaries
description: Enforced import scopes and ownership of shared application ports, persistence adapters, remote services, and native app composition in Termind.
tags: [architecture, modularity, dependencies, persistence, agentkit, swift]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-25T12:50:34.482Z
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-e09fb7bc8e7ca0579f6d446e
    resource: repo://Frameworks/TermindApplication/FeatureModels/DeviceDirectoryModel.swift
  - id: openwiki-source-9ee5ed32f6974f5906438e59
    resource: repo://Frameworks/TermindApplication/Repositories/ConnectionHistoryRepository.swift
  - id: openwiki-source-6f388236eaa573c3c2ba7706
    resource: repo://Frameworks/TermindApplication/Repositories/DeviceDirectoryRepository.swift
  - id: openwiki-source-e4f5ea9b30063cdc7d027956
    resource: repo://Frameworks/TermindDomain/Connections/ConnectionHistoryEntry.swift
  - id: openwiki-source-7367aa06bc3b7ce470e78113
    resource: repo://Frameworks/TermindDomain/DeviceRecord.swift
  - id: openwiki-source-fe1dc993163bb9ff61397be7
    resource: repo://Frameworks/TermindPersistence/HostPersistence.swift
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
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-c52cd56852d12b2dee153082
    resource: repo://TFM/App/AppDependencies.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-68b5f4529ef349aac826b1d9
    resource: repo://TFM/Platform/MacDeviceName.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-25T12:50:34.482Z" }
---

# Dependency and Ownership Boundaries

Termind is built as two native applications around shared static frameworks. The boundary is intentional: reusable layers model policy and ports, infrastructure implements those ports, and `TFM` (macOS) and `TFI` (iOS/iPadOS) compose the result with native lifecycle and UI. A safe change starts by placing the responsibility with its owner rather than importing a convenient concrete dependency into a lower layer.

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

Solid arrows point from consumer to dependency (the six-framework subgraph reflects explicit Xcode target dependencies); the dotted package arrow groups external consumers rather than implying every framework links AgentKit. Both apps depend on all six frameworks; no framework depends on an app.

For a directory-oriented view, start with the [Module and Directory Architecture Map](module-map.md). Its companion guides describe the shared frameworks, native apps, and supporting systems through their second-level functional directories; the build graph there uses explicit consumer-to-dependency arrows.

## Layer responsibilities

| Owner | Put here | Keep out |
| --- | --- | --- |
| `TermindDomain` | Portable values, domain rules, records, and protocol-neutral concepts. | UI, persistence APIs, security/network frameworks, CloudKit, StoreKit, SSH C libraries, and terminal implementations. |
| `TermindApplication` | Use cases, feature models, repository and service ports, connection/import policy, and cross-feature policy. | Platform UI, SwiftData/GRDB, transport imports, concrete infrastructure construction, and dependencies on Infrastructure or Persistence. |
| `TermindInfrastructure` | General implementations such as in-memory repositories, CloudKit-backed sync, metrics parsers, logging, StoreKit, and settings/Vault services. | Native app targets and platform UI. It may depend on Application, Domain, and Persistence. |
| `TermindRemoteInfrastructure` | SSH, SFTP, Telnet, Keychain-backed remote credentials, host-key/authentication mechanics, transfers, forwarding, and the Termind-specific agent tools. | App targets and their UI; a feature should use its injected services rather than construct remote transports itself. |
| `TermindPersistence` | Every SwiftData `@Model`, versioned schema, migration plan, SwiftData repository/store, `ModelContainer` factory, and GRDB-backed memory store. | Application-infrastructure implementation dependencies, remote infrastructure, and app targets. |
| `TermindPresentation` | Reusable SwiftUI presentation policy and content: formatting, forms, summaries, transcript/tool-card rendering, and terminal presentation helpers. | AppKit/UIKit, SwiftData/GRDB/Persistence, Infrastructure/Remote Infrastructure, StoreKit, and app targets. |
| `TFM` / `TFI` | Native UI, platform adapters, dependency assembly, lifecycle, window/scene ownership, and platform-specific resources. | Shared implementation that should be portable; no shared framework may import an app target. |

`Frameworks/Resources/` is compiled into both application bundles. It is the place for shared resources such as localization catalogs, while app-owned icons, metadata, signing, native adapters, and platform behavior remain in `TFM` or `TFI`.

### Dependency rules that are enforced

`ArchitectureBoundaryTests` checks **specific forbidden import sets per root**, not a blanket prohibition on platform APIs or concrete dependencies. Its exact-line import scans currently enforce:

| Scanned source root | Imports rejected by the test |
| --- | --- |
| Shared `TermindDomain` | `SwiftUI`, `AppKit`, `UIKit`, `SwiftData`, `GRDB`, `Security`, `Network`, `StoreKit`, `CloudKit`, `CSSH2`, `OpenSSL`, `GhosttyTerminal`, `GhosttyTheme`; also the shared non-presentation rule below. |
| Shared `TermindApplication` | `TermindInfrastructure`, `TermindPersistence`, `SwiftData`; also the shared non-presentation rule below. Unlike desktop `TFM/Application`, this root has no separate UI/transport import list, but does have the concrete-symbol guard. |
| Shared `TermindInfrastructure` and `TermindRemoteInfrastructure` | Only the shared non-presentation rule below; for example, Infrastructure can use StoreKit and Remote Infrastructure can use its transport libraries. |
| Shared `TermindPersistence` | `TermindInfrastructure`, `TermindRemoteInfrastructure`; also the shared non-presentation rule below. |
| **Shared `TermindPresentation`** | Its **separate** rule rejects `Termind`, `TermindIOS`, `UIKit`, `AppKit`, `SwiftData`, `GRDB`, `TermindPersistence`, `TermindRemoteInfrastructure`, `TermindInfrastructure`, `StoreKit`. It intentionally can import `SwiftUI`; it is not covered by the other five-framework rule. |
| Desktop `TFM/Application` | `SwiftUI`, `AppKit`, `UIKit`, `SwiftData`, `GRDB`, `Security`, `Network`, `CSSH2`, `OpenSSL`, `GhosttyTerminal`, `GhosttyTheme`, plus the concrete-symbol guard. |
| Desktop `TFM/Features` | `SwiftData`, `GRDB`, `Security`, `Network`, `CSSH2`, `OpenSSL`, plus the concrete-symbol guard. |
| Mobile `TFI/Application` | `SwiftUI`, `UIKit`, `SwiftData`, `GRDB`, `TermindPersistence`. |
| Mobile `TFI/UI` | `SwiftData`, `GRDB`, `TermindPersistence`, `TermindRemoteInfrastructure`. Mobile `TFI/Features` gets only the concrete-symbol guard. |

The shared non-presentation rule (Domain, Application, Infrastructure, Remote Infrastructure, Persistence) rejects `Termind`, `TermindIOS`, `AppKit`, `UIKit`, `IOKit`, and `ServiceManagement`. Separate tests reject app-local `AppStrings` definitions and constrain imports in Presentation's `Strings` directory. The concrete-symbol guard on shared Application, desktop Application/Features, and mobile Features looks for `ModelContext`, `FetchDescriptor`, `KeychainSecretStore`, `SFTPClient()`, `SSHConnection()`, and `URLSession(`; it does **not** run on mobile Application or UI. The import check matches literal `import Module` lines and the token check scans a fixed list after stripping `//` suffixes: these are regression checks, **not** proof of an exhaustive compiler-enforced boundary or a ban on all concrete code. Composition roots deliberately import SwiftData and concrete frameworks. Use injected ports across a boundary rather than a re-export, forwarding alias, generic “Core” module, or framework-to-app reference.

## Persistence is a single-owner boundary

`TermindPersistence` exports the complete current schema (`TermindSchemaV40`) and builds a `ModelContainer` using its migration plan. V39 added persistent assistant model selection; V40 removes retired per-category quarantine tables while keeping scoped quarantine, with lightweight stages from V38 through V40. Its factory rejects an in-memory request that also supplies a file URL and configures the store with CloudKit disabled; platform composition roots choose *where* the store lives and retain the container, but do not define the model set or construct a substitute container.

Connection history follows the same boundary: Domain owns the portable event value, Application owns the observable model and repository protocol, and Persistence owns its SwiftData shape and independent History-journal transaction. The reusable ID-to-name mapping is deliberately separate: Domain owns `DeviceRecord`, Application owns `DeviceDirectoryModel` and `DeviceDirectoryRepository`, and Persistence owns `PersistentDeviceRecord` plus the SwiftData adapter. A history event merely references `sourceDeviceID`; it does not own or capture the device name. Platform apps inject connection lifecycles, acquire their native system display name, and choose local versus all-device presentation; they do not declare stored models. `DeviceDirectoryModel` registers the current installation at initialization and resolves names by ID from its cached repository snapshot, falling back to the supplied local name for the current device. A failed load returns an empty list and records `storageError`; explicit renaming calls `upsert`, invalidates the cache, and increments `revision` only on success. The SwiftData adapter's launch-time `registerIfNeeded` deliberately leaves a remotely deleted directory entry deleted, whereas an explicit `upsert` commits a changed name or new record with the History journal snapshot and notifies the injected device-sync callback after a successful mutation.

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

Desktop calls `TermindPersistence.makeContainer` with in-memory storage for tests and screenshot demos; an unavailable local database causes a startup `fatalError`, rather than silent replacement with an empty store. Mobile `MobileAppModel` uses an injected container when provided, otherwise calls the same factory with a file under Application Support for live storage or in-memory storage for tests/injected hosts. `TermindIOSApp` builds the model once during startup and displays an unavailable-data screen when composition fails. See [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) for the app/window/scene lifetime split and platform-specific failure handling.

## Composition, resource, and state ownership

The app targets are composition roots. `TermindApp` creates the desktop `ModelContainer`, keychain store, sync persistence/coordinators, repositories, connection coordinator, logging, and app-wide `AppModel`; it also supplies `MacDeviceName.current` to the shared device-directory port (trimmed `kern.hostname`, with DeviceKit's `Device.current.safeDescription` as fallback). It injects the shared model and container into its window scenes. `AppDependencies` packages repository, connection, sync, logging, and optional shutdown services for the desktop model and provides an in-memory host repository for tests. On mobile, `MobileAppDependencies.live()` wires logging and one connection coordinator into workspace and metrics services; `testing()` defaults to in-memory storage and replaceable dependencies. `TermindIOSApp` selects one of these at startup, creates one `MobileAppModel`, and injects its container into the `WindowGroup`; the mobile composition uses DeviceKit's description directly for the device-directory port. This is where a concrete implementation or platform value becomes a port supplied to shared feature code.

Do not use this as permission to move live state into the app-wide layer. Durable stores and cross-window coordinators are app-wide; desktop navigation and workspaces are window-owned; mobile navigation is scene-owned; live SSH/SFTP transports remain with the workspace/session that opened them. Refer to [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) for the detailed ownership map.

## AgentKit is an external, host-neutral boundary

`AgentKit` is a separately developed remote Swift Package dependency at `https://github.com/AkinoKaede/AgentKit.git`. The project declares `upToNextMajorVersion` from `0.15.2`, and `Package.resolved` currently pins version `0.15.2` at revision `4540847d4762f9040be7a8bab4cadd82e494c36d`. Xcode builds that resolved remote package, **not** a sibling `../AgentKit` working tree; an uncommitted sibling change cannot affect Termind.

AgentKit owns the host-neutral agent runtime: its loop, approval gate, provider adapters, MCP client, built-in tools, and their core types. Do not redefine AgentKit-owned runtime types in Termind, and do not edit AgentKit to add the Termind name, SSH, SFTP, app UI, or other host-specific behavior. A cross-repository change must be released and tested in AgentKit first, then consumed by bumping the project dependency and resolving `Package.resolved` in the same Termind change.

Termind owns host-aware behavior on its side of the boundary. `TermindRemoteInfrastructure` defines `TermindAgentToolEnvironment` with injected host resolution, connection pools, authentication, metrics, background commands, and optional scratch workspace. `TermindAgentTools` creates the SSH/SFTP, host-listing, metrics, and host-facing scratch tools; `AssistantToolRegistry` registers AgentKit’s built-ins first and supplies the Termind catalog as additive tools. This preserves a single runtime-owned built-in namespace while allowing Termind to supply the capabilities that actually touch Termind hosts.

## How to make a dependency-safe change

1. **Classify the responsibility.** Put stable values and rules in Domain; an abstract use case or port in Application; a concrete general service in Infrastructure; a remote transport/security implementation in Remote Infrastructure; schemas and SwiftData stores in Persistence; reusable view policy in Presentation; native assembly or lifecycle in the appropriate app.
2. **Make dependencies point inward through a port.** If an Application or feature model needs persistence, keychain, SSH, or network work, extend or inject an existing protocol/service rather than import and construct its concrete implementation.
3. **Keep persistence changes atomic.** Add models, schemas, migration behavior, and container-facing repositories under `TermindPersistence`; preserve historical schemas and do not create an independent app-level container.
4. **Keep host behavior out of AgentKit.** Add SSH/SFTP or Termind-specific agent functionality through `TermindAgentTools` and injected Remote Infrastructure services. Release AgentKit separately only for genuinely host-neutral runtime behavior.
5. **Validate the boundary, not only the feature.** Run the architecture tests after a dependency or ownership change, alongside the affected feature tests. Their source scans deliberately fail when a forbidden import or concrete construction crosses a layer.

The most common failure modes are a UI feature importing Persistence “just to fetch,” Application importing a concrete transport “just to connect,” a shared framework importing an app target for a native helper, and putting host-specific behavior in AgentKit. Each creates a reverse dependency or duplicates an owner; use injection at the existing boundary instead.

## Focused verification

`TFMTests/ArchitectureBoundaryTests.swift` is the focused regression suite for these constraints. In addition to layer imports and SwiftData ownership, it checks that AgentKit runtime type names are not redefined locally, limits `ListViewKit` to an explicit native-list allowlist, keeps forwarding/mobile authentication feature-owned, and ensures the forwarding benchmark is independent of app and test targets. The checks fail closed if an expected production root is missing or contains no Swift files, so relocating source cannot silently disable the safeguards.

For normal project validation, use the resolved dependency graph rather than allowing a fresh resolution:

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
```

Use the corresponding `TFI` build/test command when a change affects the mobile target. See [Build, Test, and Release](../operations/build-test-and-release.md) for the full command set.
