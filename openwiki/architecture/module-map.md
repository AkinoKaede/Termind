---
type: architecture map
title: Module and Directory Architecture Map
description: A concise map of Termind's modules, second-level functional directories, build dependencies, and responsibility boundaries, with links to the detailed directory guides.
tags: [architecture, modules, directories, dependencies, ownership]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T10:36:38.039Z
sources:
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-7f5c1cb6f348742514987bf8
    resource: repo://Benchmarks/PortForwarding/main.swift
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-e09fb7bc8e7ca0579f6d446e
    resource: repo://Frameworks/TermindApplication/FeatureModels/DeviceDirectoryModel.swift
  - id: openwiki-source-6f388236eaa573c3c2ba7706
    resource: repo://Frameworks/TermindApplication/Repositories/DeviceDirectoryRepository.swift
  - id: openwiki-source-d593fb9c62c3736497a39486
    resource: repo://Frameworks/TermindApplication/Transfers/RemoteFileSystem.swift
  - id: openwiki-source-7367aa06bc3b7ce470e78113
    resource: repo://Frameworks/TermindDomain/DeviceRecord.swift
  - id: openwiki-source-eaa9d39ab551840299164d96
    resource: repo://Frameworks/TermindInfrastructure/Cloud/VaultSyncCoordinator.swift
  - id: openwiki-source-0b6ab59ec6a684de8101ff8e
    resource: repo://Frameworks/TermindPersistence/SwiftDataDeviceDirectoryRepository.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-c4b6e224fdbea6dcd393344d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-a62bfbbc7de13a894444718b
    resource: repo://TermindMCPBridge/main.swift
  - id: openwiki-source-dc9295278cc250ed20567540
    resource: repo://TFI/App/MobileAppDependencies.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-d1ffd558b3360478aa85b5af
    resource: repo://TFIWidgets/WorkspaceLiveActivity.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-0f8d0f9d08d6674698dd054c
    resource: repo://WorkspaceActivitySupport/WorkspaceActivityAttributes.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-23T10:36:38.039Z" }
---

# Module and Directory Architecture Map

Termind has **two native apps and six shared frameworks**, not one framework per product feature. A feature such as SFTP crosses domain values, application policy, transport implementation, presentation, and native session ownership. Directory names describe responsibilities inside those layers; they are not necessarily independent build targets.

## Reading this map

The companion guides cover each module root and its functional children, including second-level directories such as `TFM/Features/SFTP`, `TFI/Application/Connections`, and `LandingPage/src/pages`. For frameworks, the module root is `Frameworks/Termind…`, not the enclosing `Frameworks` folder. Deeper functional divisions are included where useful. Flat modules are explicitly identified rather than assigned imaginary subdirectories. Repeated locale, device, and asset-catalog leaves are grouped.

| Guide | Scope |
| --- | --- |
| [Shared Framework Directory Responsibilities](shared-module-directories.md) | All six frameworks, every functional child directory, flat-root responsibilities, and shared resources. |
| [Native App Directory Responsibilities](native-app-directories.md) | Both apps, every feature directory, application/infrastructure subdirectories, native adapters, UI components, and resources. |
| [Supporting Products, Packages, and Tooling](supporting-system-directories.md) | AgentKit reference checkout, bridge, widgets, tests, benchmarks, website, assets, scripts, project metadata, and wiki automation. |

These are orientation guides, not replacements for [System Boundaries](system-boundaries.md) or [Engineering Invariants](engineering-invariants.md). Source locations and evidence are tracked in OpenWiki Claims; the tables intentionally describe directories rather than enumerate source files.

## Module owners

| Module or directory | Primary responsibility | Important distinction |
| --- | --- | --- |
| `Frameworks/TermindDomain` | Portable records, value types, parsing, and domain rules. | A Host or transfer record is not a live connection. |
| `Frameworks/TermindApplication` | Ports, use cases, observable feature models, connection policy, and Assistant coordination. | Defines/injects capabilities rather than constructing concrete storage or transports. |
| `Frameworks/TermindPersistence` | SwiftData models, historical schemas, migrations, stores, container factory, and GRDB-backed memory. | Owns stored representation, not a window or scene. |
| `Frameworks/TermindInfrastructure` | General concrete services: CloudKit, commerce, speech, logging, importers, and metrics parsing. | Separate from remote transport mechanics. |
| `Frameworks/TermindRemoteInfrastructure` | SSH/SFTP/Telnet, remote credentials, transfers, forwarding, sampling, and host-aware Agent tools. | Owns protocol machinery, not native interaction surfaces. |
| `Frameworks/TermindPresentation` | Reusable SwiftUI content, forms, formatting, transcript policy, and terminal appearance. | Does not own AppKit/UIKit surfaces or persistence. |
| `TFM` / `TFI` | Native composition, interaction, navigation, adapters, and runtime lifetimes. | macOS windows and mobile scenes are deliberately different owners. |
| `Frameworks/Resources` | Shared bundle assets, localization, model catalogs, and privacy metadata. | A resource group, not a seventh framework. |
| `AgentKit` | Reference checkout of the separately versioned, host-neutral agent package. | Xcode consumes the resolved remote package, not this checkout. |
| Supporting products | MCP stdio bridge, Live Activity extension, and standalone forwarding benchmark. | Different executable/extension boundaries, not app feature folders. |

## Shared-framework build dependencies

**Solid arrows mean “the source target directly depends on the destination target.”** This diagram shows the six shared Xcode targets only; external package products and app embedding are separate below. It is a build graph, not request order or data flow.

```mermaid
flowchart TB
    Presentation["TermindPresentation"] --> Application["TermindApplication"]
    Presentation --> Domain["TermindDomain"]
    Remote["TermindRemoteInfrastructure"] --> Infrastructure["TermindInfrastructure"]
    Remote --> Application
    Remote --> Domain
    Infrastructure --> Persistence["TermindPersistence"]
    Infrastructure --> Application
    Infrastructure --> Domain
    Persistence --> Application
    Persistence --> Domain
    Application --> Domain
```

Both `TFM` and `TFI` directly depend on all six frameworks; `TermindDomain` has no shared-target dependency. These are explicit `PBXTargetDependency` edges, not inferred from directory proximity or imports. The diagram also explains why Persistence is not interchangeable with general Infrastructure: Infrastructure can use Persistence, while Persistence must not depend on Infrastructure or Remote Infrastructure. Shared frameworks never depend on an app target. `FrameworkTests` depends on all six shared frameworks, while `TFMTests` and `TFITests` depend on their respective app plus selected shared frameworks; the benchmark does not depend on either app or a test target.

## Product and package boundaries

Arrows here are **labeled relationships**, not a complete link graph. The shared-framework group expands into the graph above. The remote AgentKit package supplies `AgentKit` to Domain, Application, Persistence, both apps, and tests; `AgentKitScrubber` is linked by Remote Infrastructure and desktop composition. The single package edge below groups those consumers rather than implying one exclusive entry point. `TermindPresentation` instead directly links the Ghostty and MarkdownView package products, and `TermindRemoteInfrastructure` links `CSSH2` and `OpenSSL`. Check target `packageProductDependencies` for the exact package linkage before relocating code.

```mermaid
flowchart LR
    Desktop["TFM / macOS"] -->|depends on| Shared["Six shared frameworks"]
    Mobile["TFI / iPhone and iPad"] -->|depends on| Shared
    Desktop -->|embeds executable| Bridge["termind-mcp"]
    Mobile -->|embeds extension| Widget["TermindWidgets"]
    Widget -->|depends on| Presentation["TermindPresentation"]
    Activity["WorkspaceActivitySupport"] -.->|source compiled into both| Mobile
    Activity -.->|source compiled into both| Widget
    Package["Resolved AgentKit package products"] -.->|linked by owning consumers| Shared
    Checkout["AgentKit reference checkout"] -.->|not an Xcode path dependency| Package
    Benchmark["Port-forwarding benchmark"] -->|depends on| Remote["Remote Infrastructure + Application + Domain"]
```

The MCP bridge translates stdio requests into authenticated HTTP calls to the desktop server; it is not the server itself. `TFM` builds and embeds this separate tool. `TFI` builds and embeds the `TermindWidgets` extension, which directly depends on Presentation; `WorkspaceActivitySupport` is source-compiled in both the app and extension (and in `TFITests`), not a seventh framework. The widget renders a bounded workspace summary; it does not establish SSH sessions. The benchmark is a standalone executable linked to Remote Infrastructure, Application, and Domain, not app startup logic or a test-host dependency.

**AgentKit version boundary:** `.gitmodules` names an `AgentKit/` reference checkout, and repository guidance also describes a sibling `../AgentKit` development tree. Neither is wired into this Xcode project as a local package path: the project declares a remote `upToNextMajorVersion` requirement starting at `0.14.0`, and `Package.resolved` currently pins the remote to `0.14.0` at revision `ffc4aa41c8854142aa47c35231e57f56f961ba9f`. A local checkout edit alone will not change the Xcode build; release the package change, update the project requirement, and re-resolve the pin together. AgentKit owns the generic agent loop and tools; Termind registers host-specific SSH/SFTP tools in Remote Infrastructure.

## How responsibilities meet

| Task | Policy / data owner | Concrete mechanism | Native owner |
| --- | --- | --- | --- |
| Connect a terminal | Domain host/session values; Application route, trust, and retry policy. | Remote Infrastructure SSH or Telnet; desktop serial adapter for serial sessions. | Desktop session/pane or mobile workspace; native terminal surface. |
| Browse or transfer files | Domain remote-file values; Application remote-filesystem and edit model. | Remote Infrastructure SFTP channels, transfer scheduler, planners, and edit service. | Native browser, conflict UI, local file access, and Open With presentation. |
| Run an Assistant turn | Application conversation/execution coordination; AgentKit generic runtime. | Termind host tools in Remote Infrastructure; persistence and memory stores. | Native composer, approval/input presentation, transcript mounting, and navigation. |
| Edit and synchronize Vault data | Domain snapshots and mutations; Application library/use-case state. | Persistence local stores and journals; Infrastructure CloudKit coordinators; Keychain secret implementation. | Platform editors and app-level service assembly. |
| Resolve this or another installation's display name | Domain `DeviceRecord`; Application device-directory port and observable model. | Persistence-owned SwiftData device records and Vault journal payloads. | Platform composition supplies the stable installation ID and system display name. |
| Display remote metrics | Domain metrics; Application sampling/snapshot interfaces and model. | Remote SSH sampler plus Infrastructure output parsers. | Native dashboards and desktop menu-bar integration. |

This split is also a placement rule: shared behavior belongs with its existing owner; native lifetime or platform API usage stays in the app. Similar names such as `Agent`, `Transfers`, `Terminal`, or `Metrics` in different modules do not imply duplicated responsibilities.

## Composition and state boundaries

`TFM/App/TermindApp.swift` is the desktop `@main` entrypoint. It opens the Persistence container, wires stores, Keychain-backed secrets, sync and connection coordinators into an app-wide `AppModel`, and injects that model and container into each `WindowGroup` root. Each main window receives its own `WindowModel`; a separate authentication window uses the shared app environment. A failed desktop database open ends launch with `fatalError`. On mobile, `TFI/App/TermindIOSApp.swift` is the actual `@main`, **not** `MobileAppModel.swift`: it chooses live versus test dependencies, creates one `MobileAppModel` and supplies its container to the scene root, or shows an unavailable-content view if initialization throws. `MobileAppModel` assembles SwiftData, Keychain or in-memory secrets, remote services, sync coordinators, Assistant and workspaces. In the in-memory/test path it disables live sync and Live Activities. `MobileSceneModel` resolves selected workspace IDs against app-owned live instances rather than owning connections itself.

- **Process-wide:** shared stores, service coordinators, and application models.
- **Desktop window:** navigation, workspace collection, pane selection, searches, and transcript caches.
- **Mobile scene:** navigation, selected workspace/conversation, and transient presentations; live workspace instances remain app-owned.
- **Session/workspace:** transport and terminal/browser runtime state. Disappearing views are not a general disconnect signal.
- **Durable storage:** metadata, histories, configuration, and separately governed memory; not live transports or transient credentials.

For lifetime diagrams, continue with [Native App Directory Responsibilities](native-app-directories.md) and [Platform Runtime](platform-runtime.md). For change-oriented navigation and verification, return to the [Engineering Quickstart](../quickstart.md).

## Verifying a boundary change

`TFMTests/ArchitectureBoundaryTests.swift` checks import and ownership restrictions: Domain stays free of platform and transport libraries, Application cannot construct concrete implementations, Persistence cannot import Infrastructure or Remote Infrastructure, shared Presentation avoids app and storage dependencies, and native Features do not reach directly into storage or transports. It also checks that the forwarding benchmark is not pulled into apps or tests and that AgentKit-owned runtime types are not redefined in the app. These source-level guards complement rather than replace the Xcode target graph: when moving a capability, inspect both the destination target's dependency/package-product list and these tests. Use the pinned-resolution build/test commands in [Engineering Quickstart](../quickstart.md).
