---
type: engineering quickstart
title: Repository Quickstart
description: Route Termind changes to architecture owners, connection and data workflows, focused regressions, and safe build and release checks. Source and tests remain authoritative.
tags: [engineering, architecture, routing, testing, macos, ios]
sources:
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-1635d0be12e44ef9134ffabc
    resource: repo://Frameworks/TermindApplication/Connections/ConnectionJourney.swift
  - id: openwiki-source-e08ad235d9d92a20cf09290b
    resource: repo://Frameworks/TermindDomain/Vault/SyncRecordFormats.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-131881b779429a1d1d605e52
    resource: repo://Frameworks/TermindPresentation/ConnectionJourneyRouteView.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-b41ffbd407a598b50512e10b
    resource: repo://FrameworkTests/HostIconTests.swift
  - id: openwiki-source-db40aa993661b07f1a9aff6d
    resource: repo://FrameworkTests/SSHInteractionPolicyTests.swift
  - id: openwiki-source-eaed8c88a9a3f24e3feb1f9c
    resource: repo://FrameworkTests/WebAuthnVaultMetadataTests.swift
  - id: openwiki-source-d125bef219ce9eee56abf917
    resource: repo://Scripts/check-localization.py
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-c1f5a86747a33d4e8472672c
    resource: repo://TFI/App/MobileWorkspaceSessionModel.swift
  - id: openwiki-source-f7aa24af0100c1767226879a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceSearchModifier.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-350d4a794cfef67e406ddf9b
    resource: repo://TFI/Infrastructure/MobileWorkspaceStore.swift
  - id: openwiki-source-707053bb7defcfbf9343584b
    resource: repo://TFI/UI/Components/MobileConnectionJourneyView.swift
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
  - id: openwiki-source-28243bbeecc381626d39eeb6
    resource: repo://TFITests/MobileTerminalRestorationTests.swift
  - id: openwiki-source-b360f8803ec98b554faad9bb
    resource: repo://TFITests/MobileWorkspaceSessionTests.swift
  - id: openwiki-source-cc27a76170a8c672a70e388a
    resource: repo://TFITests/Screenshots/MobileConnectionJourneyRenderingTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-873894299539cce9a737a860
    resource: repo://TFM/App/RootView.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-dad03c68d6b805a4170ffc02
    resource: repo://TFM/Platform/WorkspaceCloseConfirmation.swift
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
  - id: openwiki-source-d798805795e92534f3b13250
    resource: repo://TFMTests/WorkspaceCloseConfirmationTests.swift
generated: { by: "pi", at: "2026-10-17T05:01:23.054Z" }
verified:
  - by: openwiki/0.7.2
    at: 2026-10-17T05:24:30.305Z
---

# Repository Quickstart

Termind is one Xcode project with native `TFM` (macOS) and `TFI` (iPhone/iPad) apps over shared frameworks, plus separate test, widget, and macOS MCP bridge products. Native UI and lifecycle remain app-owned. Start with [Engineering Invariants](architecture/engineering-invariants.md), choose the changed boundary below, then follow its guide to source and behavioral tests.

## Find the owner

### Architecture and presentation

| Task | Owning guide | Focused starting checks |
| --- | --- | --- |
| Place shared code, change imports or dependency construction | [Module and Dependency Map](architecture/module-map.md) → [System Boundaries](architecture/system-boundaries.md) | `ArchitectureBoundaryTests` |
| Startup, shared services, backgrounding, termination | [Platform Runtime and Lifetimes](architecture/platform-runtime.md) | `AppTerminationTests`, `WorkspaceCloseConfirmationTests`, `MobileAppTests`, `MobileForwardingLifecycleTests` |
| Desktop navigation, window commands, workspace ownership | [Desktop UI and Window Ownership](architecture/desktop-ui.md) | Window/navigation and layout regressions |
| Mobile tabs, scene routes, editors, workspace continuity | [Mobile UI and Scene Ownership](architecture/mobile-ui.md) | `MobileWorkspaceSessionTests`, `MobileAdaptiveLayoutTests`, `MobileNavigationParityTests` |
| Shared fields, tokens, accessibility, native presentation contracts | [UI Design and Presentation Contracts](concepts/ui-design-principles.md) | Affected platform rendering and `ArchitectureBoundaryTests` |
| Workspace/pane sorting, merging, drag-out windows, Assistant reordering | [Desktop Workspace Drag and Drop](workflows/desktop-drag-and-drop.md) | `WorkspaceNavigatorDropTests`, `WorkspaceLayoutDropTests`, `WorkspaceWindowMoveTests`, `AssistantConversationListDropTests` |
| File drops, Assistant attachments, terminal uploads, remote-file dragging, key import | [File Drops and Terminal Uploads](workflows/file-drag-and-drop.md) | `FileURLDropTargetTests`, `MobileDropTests`, then the guide's upload/import suites |

### Connections and remote services

| Task | Owning guide | Focused starting checks |
| --- | --- | --- |
| Host entitlement verification, locked-host admission, operation access | [Commerce, Localization and Product Surfaces](concepts/commerce-localization-and-product-surfaces.md) and [Remote Services and Forwarding Boundaries](concepts/remote-services-and-forwarding.md) | `HostAccessTests`, `HostOperationAdmissionTests`, `MetricsHostAccessTests` |
<!-- openwiki: broken internal link [workflows/local-network-discovery-and-wake.md] file "workflows/local-network-discovery-and-wake.md" does not exist. Fix the href or restore the target, then delete this comment. -->
| LAN discovery, permission handling, MAC lookup, manual/automatic wake | [Local Network Discovery and Wake-on-LAN](workflows/local-network-discovery-and-wake.md) | `LocalNetworkTests`, `LocalNetworkActionTests`, `LocalNetworkLifecycleTests` |
| SSH/Telnet, routes, credentials, trust, activation and cleanup | [Terminal Connection and Session Lifecycle](workflows/ssh-session-lifecycle.md) | Connection, authentication, host-key and PTY activation suites; `ConnectionJourneyTests` |
| Mosh and Eternal Terminal routing, startup and transport recovery | [Mosh + Eternal Terminal](integrations/mosh-and-eternal-terminal.md) | `ResumableTerminalEngineTests`, `TerminalTransportTests` |
| Remote multiplexer persistence, managed ownership and teardown | [Session Persistence](concepts/session-persistence.md) | `SessionPersistenceTests`, `MobileTerminalRestorationTests` |
| SSH admission/backpressure and multiplexed I/O | [SSH Multiplexing and Scheduling](concepts/ssh-multiplexing-and-scheduling.md) | Multiplexer and worker-lifecycle tests |
| Security Key registration, signing, Vault metadata, silent-connection restrictions | [SSH Security-Key Authentication](concepts/ssh-security-key-authentication.md) | `WebAuthnVaultMetadataTests`, `WebAuthnSSHTests`, `SSHInteractionPolicyTests` |
| Terminal Find, mobile search dismissal, SFTP filtering, retained surfaces | [Ghostty Terminal Integration](concepts/ghostty-terminal-integration.md) and [Mobile UI](architecture/mobile-ui.md) | `TerminalFindControllerTests`, `MobileTerminalSearchIntegrationTests` in `TFITests/MobileTerminalSearchTests.swift` |
| Ghostty menus, touch selection, fonts/themes, surface identity or dependency APIs | [Ghostty Terminal Integration](concepts/ghostty-terminal-integration.md) and [Build, Test and Release](operations/build-test-and-release.md) | `MobileTerminalUploadMenuTests`, `TerminalContextMenuTests`; review resolved upstream source for package internals |
| Active directory, draft input, command lifecycle and context consumers | [Shell Integration and Terminal Context](concepts/shell-integration.md) | Context and command-monitor tests |
| Terminal/metrics/Agent service ownership, host-scoped forwarding | [Remote Services and Forwarding Boundaries](concepts/remote-services-and-forwarding.md) → [Port Forwarding Pool and Dispatch](workflows/port-forwarding-pool-and-dispatch.md) | Service/pump/pool tests; native metrics authentication uses `MetricsJourneyRenderingTests` and `MobileMetricsJourneyTests` |
| Tailscale groups, login/logout, peer identity, routing and cleanup | [Tailscale Integration](integrations/tailscale.md) | Group-editor, identity, integration, cleanup, metrics and sync-safety tests |
| SFTP browsing, transfers, conflict handling, external edits | [SFTP Transfers and External Editing](workflows/sftp-transfer-and-external-edit.md) | Transfer, channel-lifetime, conflict and edit suites |

### Data, Assistant and operations

| Task | Owning guide | Focused starting checks |
| --- | --- | --- |
| SwiftData models, secrets, historical migrations and local recovery | [Persistence, Compatibility and Secrets](concepts/persistence-and-secrets.md) | Historical-store upgrade **and reopen** tests; `HostIconTests`, `SnippetColorTests`, `RetiredTerminalHighlightingTests` as relevant |
| Settings writes or explicit CloudKit replication | [Settings and Cloud Sync](workflows/settings-and-cloud-sync.md) → [CloudKit Release Readiness](operations/cloudkit-release-readiness.md) | `CloudSyncLifecycleTests`, `CloudSyncSafetyTests`, coordinator and record-evolution tests |
| Assistant turns, approvals, host tools, skills and memory | [Agent Runtime and Assistant](concepts/agent-runtime-and-assistant.md) | Preparation, cancellation, persistence, tool and memory regressions |
| MCP server, external transfers or stdio bridge | [MCP Server and Bridge](integrations/mcp-server-and-bridge.md) | Token, server-session, transfer and bridge tests |
| Commerce, localized app copy, widgets or website | [Commerce, Localization and Product Surfaces](concepts/commerce-localization-and-product-surfaces.md) | `RevenueCatCommerceTests`, `ProPaywallStateTests`, feature-access tests, `AppLanguageTests` and localization checks |
| Capture, framing, app icons, Host artwork | [Marketing Assets and App Icons](operations/marketing-assets-and-app-icons.md) | Quiet `plan:true` and focused Ruby checks before capture; `HostIconTests` for runtime artwork |
| Live offers, purchase/restore, store imagery and delivery | [Storefront and Commerce Release](operations/storefront-commerce-release.md) | RevenueCat, App Store Connect and Sandbox checks plus actual final localized artwork review |
| Build/dependency/release tooling or forwarding measurements | [Build, Test and Release](operations/build-test-and-release.md); [Port Forwarding Benchmarks](operations/port-forwarding-benchmarks.md) | Resolved-only native validation or the benchmark's own measurement procedure |
| Choose a deterministic fixture or understand what a test proves | [Behavioral Boundaries and Test Fixtures](testing/behavioral-boundaries-and-fixtures.md) | Narrow behavioral regression first, then affected target suite |

## Preserve the changed boundary

These are routing reminders, not substitute specifications.

- **Layers:** `TermindDomain` owns portable rules; `TermindApplication` owns ports/use cases; `TermindPersistence` exclusively owns SwiftData models, historical schemas and container construction. Infrastructure implements services; `TermindPresentation` owns reusable content/copy; apps assemble concrete dependencies and native UI. `ArchitectureBoundaryTests` uses root-specific import and construction rules, not a blanket ban on every UI symbol. Shared Application cannot import Infrastructure, Persistence or SwiftData. Fix the ownership boundary rather than bypassing its tests.
- **Runtime owners:** app services are shared, desktop workspaces belong to window-local `WindowModel`s, and mobile navigation/Assistant presentation belongs to `MobileSceneModel`. Mobile descriptors and live workspaces belong to persistent native UIKit scene sessions, not an interchangeable cross-window pool. Desktop `RootView` registers its window and publishes the focused window value while preserving mounted workspace views across destination changes.
- **Mobile restoration is selective, not empty-on-launch:** legacy `mobile.workspaces.v1` and `mobile.recentlyClosed.v2` defaults are retired without migration, but `mobile.restorableWorkspaces.v1` stores eligible scene-keyed descriptors. Cold launch restores Mosh/Eternal Terminal and eligible SSH persistence descriptors **without creating live connections**. Selecting a descriptor publishes one live workspace before connecting; repeated selection reuses it, and links in another scene activate its owner. One-shot commands and initial paths are live construction inputs, not restoration descriptors, so restoration must not replay them. Recently closed records remain process-local. See [Mobile UI](architecture/mobile-ui.md) and [Session Lifecycle](workflows/ssh-session-lifecycle.md).
- **Separate the recovery mechanisms:** SSH session persistence uses remote-session references and selection/attachment policy; Mosh/Eternal Terminal use resumable transport checkpoints and their recovery state, not ordinary SSH reconnect. A missing or incompatible checkpoint must not silently bootstrap a replacement shell. `MobileTerminalRestorationTests` covers this distinction, retained terminal identity and selective cold-launch restoration; shared engine/journey tests cover retry without startup replay.
- **Scene lifecycle:** disconnect/background alone preserves workspace ownership. Native-session reconciliation can transfer live objects without reconnecting; a late explicit discard still targets only the source session's recovered workspaces. Background services pause when all scenes background; expiration suspends workspaces, stops forwards, pauses transfers and expires Assistant work. An active scene resumes eligible services. Follow [Platform Runtime](architecture/platform-runtime.md).
- **Desktop close and quit:** live connections alone no longer trigger a window-close or application-wide quit confirmation. Native window vetoes and unsaved terminal-theme protection remain; quit saves theme edits, asks before discarding any still-unsaved theme, then rechecks pending SFTP edits with cancellation before shutdown. Termination fences new Assistant work and drains conversations/preparations before agent resource closure while stopping MCP/transfers. Its three-second fallback bounds the once-only AppKit reply, not asynchronous cleanup completion. Debug tests do not terminate on last-window close; otherwise menu-bar metrics settings and running metrics decide. See [Desktop UI](architecture/desktop-ui.md) and [Platform Runtime](architecture/platform-runtime.md).
- **Connection presentation:** shared `ConnectionJourney` owns route progress and authentication/host-key checkpoints; `ConnectionJourneyRouteView` draws the shared route while apps supply native controls. State tests and opt-in native rendering fixtures are not live SSH validation. Mobile terminal search stays on stable chrome, and terminal surfaces remain mounted beneath journey gates. SSH, Mosh, Eternal Terminal and Telnet use workspace-owned `TerminalFindController`; SFTP filters bind to `sftpChannel.query`.
- **Local and wire compatibility are independent:** the live local schema is **V58**. Use migration/reopen tests rather than hard-coding the latest schema into unrelated tests. `SyncRecordFormats` independently defines per-kind wire readers/writers: Host writes V8, HostGroup V7, SSHKey V3, Snippet V2, WorkspaceTemplate V2 and Metrics V2. Follow the persistence/sync guides before changing compatibility; a successful build does not prove migration or CloudKit readiness.
- **Released dependencies, not maintenance trees:** AgentKit owns the host-neutral runtime; Termind registers SSH/SFTP tools through `TermindAgentTools`. Test and release cross-repository package changes before updating the Xcode requirement and `Package.resolved` together. App builds consume remote pins, not sibling or optional maintenance working-tree edits. The current AgentKit requirement is `upToNextMinorVersion` from `1.20.0`; libssh2 starts at `2.0.3-termind-4` under the same rule despite older exact-version guidance. Ghostty comes directly from `Lakr233/libghostty-spm`, currently `upToNextMinorVersion` from `2.2.2026101502`, with no local Ghostty maintenance submodule. For resolved-build behavior, inspect the project and pin rather than relying on conflicting generic dependency guidance.

## Validate narrowly, then validate the product

Use [AGENTS.md](../AGENTS.md) and [Build, Test and Release](operations/build-test-and-release.md) for full setup and release procedures. Project settings use Swift 6, complete strict concurrency, warnings as errors, approachable concurrency and default `MainActor` isolation; bridge/benchmark targets use `nonisolated` isolation. Read the selected target's effective settings rather than treating project defaults as product metadata.

Keep `-onlyUsePackageVersionsFromResolvedFile` so routine validation cannot silently move the dependency graph:

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile build
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile build
xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge
python3 Scripts/check-localization.py
```

Run mobile tests on an installed simulator. For a focus-changing search regression, replace the destination placeholder locally:

```sh
TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1 xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'platform=iOS Simulator,name=<installed simulator>' -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO -only-testing:TFITests/MobileTerminalSearchIntegrationTests test
```

### Keep native presentation opt-ins explicit

- macOS tests that present windows or activate the app require `.requiresVisibleWindow` and `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` (or `TERMIND_WINDOW_TESTS=1` in Xcode), preferably with `-only-testing:TFMTests/<Suite>`. Debug XCTest launches the real app but suppresses automatic main/external-auth windows by default and disables scene restoration; the visible-window opt-in or screenshot demo lifts window suppression. Keep gates off for routine checks; offscreen logic/layout tests remain enabled.
- Mobile key-window suites require `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1`, `-parallel-testing-enabled NO` and narrow `-only-testing:TFITests/<Suite>` filters. `MobileAdaptiveLayoutTests` gates native-window cases individually, leaving pure width logic enabled; `MobileMetricsJourneyTests` is serialized and suite-level key-window-gated. Desktop `MetricsJourneyRenderingTests` is visible-window-gated. These fixtures exercise native presentation and restore temporary windows, not quiet model-only coverage.
- Journey screenshot export remains separately opt-in under `TERMIND_JOURNEY_SCREENSHOTS`. Check individual suite annotations and the [fixture guide](testing/behavioral-boundaries-and-fixtures.md), not an assumption that every window-creating test shares one gate.

### Copy and external delivery boundaries

App-facing copy belongs in `Frameworks/TermindPresentation/Strings` and manually maintained catalogs. After catalog edits run `Scripts/normalize-string-catalogs.py --write`, `Scripts/check-appstrings.sh`, and `python3 Scripts/check-localization.py`. The validator checks `zh-Hans`, `zh-Hant`, `ja`, `ko`, `de` and `fr`, including formats, plurals, spacing and canonical formatting; use `AppLanguageTests` for language behavior. Run localization validation even without intentional copy changes.

The independent `com.akinokaede.termind/` website/assets submodule is optional for native builds. Initialize it only for website/asset work, inspect its own source and consumers, and follow the [asset guide](operations/marketing-assets-and-app-icons.md). Parent guidance calls for a production website build and visual English/Chinese checks; native catalog/commerce tests do not verify external copy, deployed routes or RevenueCat dashboard content. `StoreKit/Termind.storekit` is a manual development fixture, not proof of live products, trial eligibility or purchase/restore behavior: use the [storefront guide](operations/storefront-commerce-release.md) for separate live checks.

Before submission, inspect the diff for secrets, generated artifacts, cross-layer imports and accidental `Package.resolved` churn. The commands above are validation entrypoints, not results: **no builds, tests, captures or live integrations were executed during this documentation research.**
