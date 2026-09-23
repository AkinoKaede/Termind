---
type: engineering quickstart
title: Termind Engineering Quickstart
description: Task-oriented routes to Termind's owning layer, startup and shutdown lifetimes, focused tests, and build gates.
tags: [engineering, architecture, routing, testing, macos, ios]
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-7341d7b266d976d7aac5d161
    resource: repo://TFITests/MobileEditorToolbarTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-73c75477db0674192248aa00
    resource: repo://TFMTests/AppTerminationTests.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-0dd012e3740bcc348fc36ccb
    resource: repo://TFMTests/StoreKitTrialTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-23T10:36:38.039Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T14:32:50.942Z
---

# Termind Engineering Quickstart

Termind is one Xcode project with native `TFM` (macOS) and `TFI` (iPhone/iPad) products over shared frameworks; platform UI and lifecycle remain app-owned. Source and tests are authoritative. Before changing an ownership boundary, read [Cross-Cutting Engineering Invariants](/openwiki/architecture/engineering-invariants.md) and the narrowest topic page below.

## Find the owner

| Change | Route and focused check |
| --- | --- |
| Module placement, imports, nested directories, or shared resources | [Module and Directory Architecture Map](/openwiki/architecture/module-map.md), [Shared Framework Directory Responsibilities](/openwiki/architecture/shared-module-directories.md), [Native App Directory Responsibilities](/openwiki/architecture/native-app-directories.md), and [Supporting Products, Packages, and Tooling](/openwiki/architecture/supporting-system-directories.md); run `ArchitectureBoundaryTests` for dependency changes. |
| Composition, startup failure, window/scene state, backgrounding, quit | [Platform Runtime, App Composition, and Lifetimes](/openwiki/architecture/platform-runtime.md); use `AppTerminationTests`, `MobileAppTests`, or `MobileForwardingLifecycleTests` for the changed lifetime. |
| Desktop Navigator, sidebar, workspaces, Vault, Assistant layout | [TFM Desktop UI Architecture](/openwiki/architecture/desktop-ui.md); target window/navigation or layout tests. |
| Mobile tabs, scene routes, cards, editors, terminal continuity | [TFI Mobile UI Architecture](/openwiki/architecture/mobile-ui.md); target `MobileAdaptiveLayoutTests`, `MobileNavigationParityTests`, or the relevant feature test. |
| Shared UI conventions, fields, tokens, accessibility | [UI Design Principles and Shared Presentation Boundaries](/openwiki/concepts/ui-design-principles.md); check platform renderings and `ArchitectureBoundaryTests`. |
| SSH/Telnet, credentials, routes, host-key trust, session cleanup | [SSH, Telnet, Trust, and Workspace Session Lifecycle](/openwiki/workflows/ssh-session-lifecycle.md); run connection, trust, authentication, and session tests. For channel admission and backpressure see [SSH Multiplexing and I/O Scheduling](/openwiki/concepts/ssh-multiplexing-and-scheduling.md). |
| Terminal, metrics, forwards, shell hooks or forwarding pools | [Remote Services and Forwarding](/openwiki/concepts/remote-services-and-forwarding.md), [Shell Integration](/openwiki/concepts/shell-integration.md), [Port Forwarding Dispatch](/openwiki/workflows/port-forwarding-pool-and-dispatch.md); choose the matching service or pump tests. |
| SFTP browsing, transfer scheduling, external edit | [SFTP Transfer, Scheduling, and External Edit Workflow](/openwiki/workflows/sftp-transfer-and-external-edit.md); select the transfer, conflict, or edit suite. |
| Assistant turns, approvals, host tools, skills, memory | [Assistant, Agent Runtime, Skills, and Memory](/openwiki/concepts/agent-runtime-and-assistant.md); target preparation, cancellation, persistence, tools, or memory tests. |
| SwiftData, secrets, migrations, CloudKit, settings | [Persistent Data, Migrations, and Secret Boundaries](/openwiki/concepts/persistence-and-secrets.md) and [Settings, Vault, Metrics, and Cloud Sync](/openwiki/workflows/settings-and-cloud-sync.md); select repository, migration, or sync lifecycle tests. |
| MCP server, external upload/download, bridge | [MCP Server, Transfer APIs, and Stdio Bridge](/openwiki/integrations/mcp-server-and-bridge.md); run token, server-session, transfer, or bridge tests. |
| StoreKit, localized copy, widgets, screenshots, website | [Commerce, Localization, and Product Surfaces](/openwiki/concepts/commerce-localization-and-product-surfaces.md) and [Build, Test, and Release](/openwiki/operations/build-test-and-release.md); use localization, app, screenshot, StoreKit, or website checks as appropriate. |
| Picking a deterministic test seam | [Testing Strategy and Behavioral Boundaries](/openwiki/testing/behavioral-boundaries-and-fixtures.md); run the narrow behavioral test before the affected target suite. |

## Lifetime and change boundaries

`TermindDomain` defines portable rules; `TermindApplication` owns ports and use cases; Persistence owns SwiftData models and container construction; infrastructure implements services; apps assemble concrete dependencies and native UI. `ArchitectureBoundaryTests` rejects shared-layer app imports, forbidden platform/storage/transport imports, concrete implementations in feature/application layers, duplicated AgentKit runtime types, and SwiftData models outside Persistence. Fix an ownership violation rather than bypassing the test.

`TermindApp` makes the macOS container and shared `AppModel` at launch; XCTest and debug screenshot demos use in-memory stores. If the local database cannot open, startup fails rather than replacing it with an empty store. Each `WindowGroup` instance gets its own `WindowModel` for selection and workspaces, while app services are shared. `TermindIOSApp` migrates language preferences and creates one live or testing `MobileAppModel`; successful scenes receive its container, and failure shows an unavailable-data view. Each `MobileRootView` makes a scene-local `MobileSceneModel`, but the mobile app model shares services and live workspaces across scenes. Restore workspace descriptors, not live transports or credentials. Desktop session/pane and mobile workspace owners end their own connection-history entries on close.

Mobile phase changes are aggregated across scenes: background work is paused when *all* registered scenes are backgrounded; the expiration handler suspends workspaces, stops forwards, pauses transfers, and expires Assistant work. An active scene resumes monitoring, memory, workspaces, eligible sync, and metrics. On macOS, closing the last window does **not** always quit: the menu-bar metrics preference and running metrics decide. Quit first rechecks unuploaded SFTP edits and can be cancelled; confirmed termination fences new Assistant runs, drains cancellation/persistence, stops transfers and MCP, then closes agent resources. The delegate waits for cleanup or a three-second fallback before replying to AppKit. Use [Platform Runtime](/openwiki/architecture/platform-runtime.md) for the full sequence and ownership rules.

AgentKit is a separately versioned, host-neutral remote package for the agent loop, approvals, providers, MCP client and built-in tools; Termind owns SSH/SFTP tools and registers them additively. For a cross-repository change, release `../AgentKit`, then update `minimumVersion` in `Termind.xcodeproj/project.pbxproj` **and** `Package.resolved`; the sibling working tree does not affect Xcode's pinned build. Keep metadata in persistence and secret values behind Keychain references. Follow [System Boundaries and Dependency Ownership](/openwiki/architecture/system-boundaries.md) for imports and [Build, Test, and Release](/openwiki/operations/build-test-and-release.md) for release steps.

## Focused validation

Run the nearest behavioral regression first, then the relevant product suite. Always keep `-onlyUsePackageVersionsFromResolvedFile` so ordinary builds do not silently move the resolved dependency graph:

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile build
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile build
xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge
Scripts/check-zh-localization.sh
```

For `TFI` tests use an installed iPhone/iPad simulator. Visible-window macOS suites require `.requiresVisibleWindow` and explicit `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` (or `TERMIND_WINDOW_TESTS=1` in the Xcode test action), preferably with `-only-testing:TFMTests/<Suite>`. Mobile key-window integration suites require `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1`, `-parallel-testing-enabled NO`, and a narrow `-only-testing:TFITests/<Suite>`. StoreKit suites require manual authorization and `TERMIND_STOREKIT_TESTS=1`. Keep these gates off for routine checks; offscreen tests remain enabled. New app text needs completed `zh-Hans` and `zh-Hant` translations in `Frameworks/Resources/Localizable.xcstrings`; run the localization script (requires `jq`) even without intended copy changes, and `AppLanguageTests` for language behavior. For web changes run `cd LandingPage && npm ci && npm run build` and check English and `/zh/` routes.

Before submitting, inspect the diff for secrets, generated artifacts, cross-layer imports and accidental `Package.resolved` churn; use the routed operations pages for CloudKit deployment, StoreKit release, marketing assets, and forwarding benchmark measurement semantics.
