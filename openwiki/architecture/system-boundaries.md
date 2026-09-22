---
type: architecture boundaries
title: System Boundaries and Dependency Ownership
description: Static framework layers, platform composition roots, persistence ownership, and the external AgentKit boundary that keep Termind changes dependency-safe.
tags: [architecture, modularity, dependencies, persistence, agentkit, swift]
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-1c845e5af67c400566be83bd
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AssistantToolRegistry.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
generated: { by: "omp", at: "2026-09-22T05:22:55.650Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-22T05:22:55.650Z
---

# System Boundaries and Dependency Ownership

Termind is built as two native applications around shared static frameworks. The boundary is intentional: reusable layers model policy and ports, infrastructure implements those ports, and `TFM` (macOS) and `TFI` (iOS/iPadOS) compose the result with native lifecycle and UI. A safe change starts by placing the responsibility with its owner rather than importing a convenient concrete dependency into a lower layer.

```mermaid
flowchart TD
    Domain["TermindDomain values and rules"] --> Application["TermindApplication ports and use cases"]
    Domain --> Infrastructure["TermindInfrastructure local and cloud implementations"]
    Application --> Infrastructure
    Domain --> Remote["TermindRemoteInfrastructure SSH SFTP Telnet"]
    Application --> Remote
    Infrastructure --> Remote
    Persistence["TermindPersistence SwiftData schemas and stores"] --> Infrastructure
    Domain --> Presentation["TermindPresentation reusable SwiftUI policy"]
    Application --> Presentation
    Domain --> TFM["TFM macOS app composition and UI"]
    Application --> TFM
    Infrastructure --> TFM
    Remote --> TFM
    Persistence --> TFM
    Presentation --> TFM
    Domain --> TFI["TFI iOS app composition and UI"]
    Application --> TFI
    Infrastructure --> TFI
    Remote --> TFI
    Persistence --> TFI
    Presentation --> TFI
    AgentKit["AgentKit pinned remote package"] --> Application
    AgentKit --> Remote
```

This diagram shows the permitted ownership direction at a high level; apps assemble shared layers and are never dependencies of them.

For a directory-oriented view, start with the [Module and Directory Architecture Map](module-map.md). Its companion guides describe the shared frameworks, native apps, and supporting systems through their second-level functional directories; the build graph there uses explicit consumer-to-dependency arrows.

## Layer responsibilities

| Owner | Put here | Keep out |
| --- | --- | --- |
| `TermindDomain` | Portable values, domain rules, records, and protocol-neutral concepts. | UI, persistence APIs, security/network frameworks, CloudKit, StoreKit, SSH C libraries, and terminal implementations. |
| `TermindApplication` | Use cases, feature models, repository and service ports, connection/import policy, and cross-feature policy. | SwiftUI/AppKit/UIKit, SwiftData/GRDB, concrete Keychain/network/SSH implementations, and concrete infrastructure construction. |
| `TermindInfrastructure` | General implementations such as in-memory repositories, CloudKit-backed sync, metrics parsers, logging, StoreKit, and settings/Vault services. | Native app targets and platform UI. It may depend on Application, Domain, and Persistence. |
| `TermindRemoteInfrastructure` | SSH, SFTP, Telnet, Keychain-backed remote credentials, host-key/authentication mechanics, transfers, forwarding, and the Termind-specific agent tools. | App targets and their UI; a feature should use its injected services rather than construct remote transports itself. |
| `TermindPersistence` | Every SwiftData `@Model`, versioned schema, migration plan, SwiftData repository/store, and `ModelContainer` factory. | Application-infrastructure implementation dependencies, remote infrastructure, and app targets. |
| `TermindPresentation` | Reusable SwiftUI presentation policy and content: formatting, forms, summaries, transcript/tool-card rendering, and terminal presentation helpers. | AppKit/UIKit, SwiftData/GRDB/Persistence, remote transport infrastructure, and app targets. |
| `TFM` / `TFI` | Native UI, platform adapters, dependency assembly, lifecycle, window/scene ownership, and platform-specific resources. | Shared implementation that should be portable; no shared framework may import an app target. |

`Frameworks/Resources/` is compiled into both application bundles. It is the place for shared resources such as localization catalogs, while app-owned icons, metadata, signing, native adapters, and platform behavior remain in `TFM` or `TFI`.

### Dependency rules that are enforced

`ArchitectureBoundaryTests` scans production source imports rather than relying on conventions alone. It prevents Domain from importing platform/UI, storage, security, networking, commerce, SSH, or terminal frameworks. It prevents Application and app feature code from importing UI/storage/transport implementation frameworks or constructing known concrete persistence, SSH/SFTP, and URL-session symbols. Presentation is separately prohibited from depending on platform UI, persistence, or remote infrastructure.

The checks also prohibit all shared frameworks from importing `Termind` or `TermindIOS`. Application may not import Infrastructure, Persistence, or SwiftData, and Persistence may not import Infrastructure or Remote Infrastructure. Thus depend on a port exposed by the owning higher-level module; do not repair an awkward dependency by a re-export, forwarding alias, generic “Core” module, or an app-to-framework reference.

## Persistence is a single-owner boundary

`TermindPersistence` exports the complete current schema (`TermindSchemaV31`) and builds a `ModelContainer` using its migration plan. Its factory rejects an in-memory request that also supplies a file URL and configures the store with CloudKit disabled; platform composition roots choose *where* the store lives and retain the container, but do not define the model set or construct a substitute container.

This separation matters for migrations: all SwiftData models, frozen historical schemas, migration plans, and container construction stay together in Persistence. The boundary test rejects `@Model` declarations everywhere else and requires Persistence to contain Swift files. A new persisted SwiftData entity therefore requires a Persistence schema/migration decision—not a model embedded in a feature, app, or general infrastructure module.

Both app roots call `TermindPersistence.makeContainer`. Desktop turns an unavailable local database into a startup `fatalError`, avoiding silent replacement with an empty store. iOS builds a `MobileAppModel` during startup and displays an unavailable-data screen when composition fails. See [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) for the app/window/scene lifetime split and platform-specific failure handling.

## Composition, resource, and state ownership

The app targets are composition roots. `TermindApp` creates the desktop `ModelContainer`, keychain store, sync persistence/coordinators, repositories, connection coordinator, logging, and app-wide `AppModel`; it injects the shared model and container into its window scenes. `TermindIOSApp` chooses live or testing dependencies, creates one startup `MobileAppModel`, and injects that model's container into its `WindowGroup`. This is where a concrete implementation becomes a port supplied to feature code.

Do not use this as permission to move live state into the app-wide layer. Durable stores and cross-window coordinators are app-wide; desktop navigation and workspaces are window-owned; mobile navigation is scene-owned; live SSH/SFTP transports remain with the workspace/session that opened them. Refer to [Platform Runtime, App Composition, and Lifetimes](platform-runtime.md) for the detailed ownership map.

## AgentKit is an external, host-neutral boundary

`AgentKit` is a separately developed remote Swift Package dependency at `https://github.com/AkinoKaede/AgentKit.git`. The project declares a minimum version and `Package.resolved` pins the build to an exact release revision. Xcode builds that resolved remote package, **not** a sibling `../AgentKit` working tree; an uncommitted sibling change cannot affect Termind.

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
