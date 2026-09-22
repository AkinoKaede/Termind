---
type: engineering quickstart
title: Termind Engineering Quickstart
description: A task-oriented guide to finding the right Termind owner, lifecycle boundary, workflow documentation, and focused validation before making a change.
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
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
generated: { by: "omp", at: "2026-09-22T03:23:14.035Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-22T03:23:14.035Z
---

# Termind Engineering Quickstart

Termind is one Xcode project with two native products: `TFM` for macOS and `TFI` for iPhone/iPad. They compose shared static frameworks, but platform UI and lifecycle remain app-owned. Start from the task you intend to change, identify the state and dependency owner, then use the focused tests that protect that boundary. Source and tests are authoritative. Read [Cross-Cutting Engineering Invariants](/openwiki/architecture/engineering-invariants.md) for the exhaustive safety contract, then use the routed specialist page for mechanisms, release operations, and historical benchmark constraints.

## Explore modules and directories

Start with the [Module and Directory Architecture Map](/openwiki/architecture/module-map.md) for module ownership and dependency diagrams. Its companion guides cover at least second-level functional directories, explicitly identify flat modules, and distinguish directory containment from runtime ownership:

- [Shared Framework Directory Responsibilities](/openwiki/architecture/shared-module-directories.md): the six frameworks and shared bundle resources.
- [Native App Directory Responsibilities](/openwiki/architecture/native-app-directories.md): TFM/TFI application, feature, infrastructure, platform, UI, and resource areas.
- [Supporting Products, Packages, and Tooling](/openwiki/architecture/supporting-system-directories.md): AgentKit, bridge, widgets, tests, benchmarks, website, assets, and automation.

## Before editing

1. **Read the cross-cutting invariants and the narrowest routing page below**, then follow their cited code and tests. Do not use this page as a substitute for the detailed workflow.
2. **Locate the owner before adding an import.** `TermindDomain` holds portable values and rules; `TermindApplication` holds ports, use cases, and cross-feature policy; Persistence owns all SwiftData models and container construction; infrastructure implements concrete services; `TFM` and `TFI` own native UI, composition, and lifecycle. Shared frameworks must not depend on either app target.
3. **Classify the lifetime.** App-wide services and durable stores are shared; desktop navigation and workspaces are window-local; mobile navigation is scene-local; an SSH/SFTP transport belongs to the workspace/session that opened it. Do not turn transient connections or credentials into restored state.
4. **Keep secrets and remote behavior at their existing boundaries.** Metadata can be persisted, while secrets are referenced through Keychain-backed storage. SSH/SFTP, host-key trust, and transport ownership belong on the Termind side of the host-neutral AgentKit boundary.
5. **Plan the regression check alongside the change.** Add or update the focused test that demonstrates the contract, then run the appropriate build/test command using the resolved package graph.

## Task-routing map

| If you are changing… | Start here | Also inspect | Focused validation |
| --- | --- | --- | --- |
| Finding what a module or nested directory owns, or understanding how modules collaborate | [Module and Directory Architecture Map](/openwiki/architecture/module-map.md) | Shared-framework, native-app, and supporting-system directory guides | Follow the owning feature's focused tests; use architecture checks for dependency changes |
| App startup, dependency assembly, window/scene behavior, backgrounding, or shutdown | [Platform Runtime, App Composition, and Lifetimes](/openwiki/architecture/platform-runtime.md) | `TFM/App/TermindApp.swift`, `TFI/App/TermindIOSApp.swift` | Relevant `TFMTests` or `TFITests` lifecycle/window suite |
| A module import, framework placement, SwiftData model, shared resource, or AgentKit-facing API | [System Boundaries and Dependency Ownership](/openwiki/architecture/system-boundaries.md) | `TFMTests/ArchitectureBoundaryTests.swift` and the owning composition root | `ArchitectureBoundaryTests` plus the affected feature tests |
| TFM window chrome, Navigator modes, split panes, persistent workspaces, Vault editors, or desktop Assistant rendering | [TFM Desktop UI Architecture](/openwiki/architecture/desktop-ui.md) | Component and ownership diagrams; [UI Design Principles](/openwiki/concepts/ui-design-principles.md) | Window/sidebar, workspace layout, responsive editor and transcript tests |
| TFI feature tabs, scene routes, mobile toolbars, adaptive regions, terminal continuity, or composer focus | [TFI Mobile UI Architecture](/openwiki/architecture/mobile-ui.md) | Scene-versus-runtime ownership and native surface identity across layout changes | `MobileAdaptiveLayoutTests` plus scene, workspace and Assistant behavior tests |
| Shared form fields, presentation values, visual tokens, collection interaction, accessibility, or cross-platform UI reuse | [UI Design Principles and Shared Presentation Boundaries](/openwiki/concepts/ui-design-principles.md) | Platform-specific owners; architecture restrictions on shared presentation and native adapters | `ArchitectureBoundaryTests`, input/presentation tests, and targeted multilingual rendering checks |
| SSH, Telnet, proxy/jump routing, trust prompts, credentials, or workspace reconnect | [SSH, Telnet, Trust, and Workspace Session Lifecycle](/openwiki/workflows/ssh-session-lifecycle.md) | Remote Infrastructure callers and the owning session feature | SSH preparation, host-key, authentication, journey, and session tests |
| Terminal services, metrics, port forwarding, channel limits, or shared remote transport policy | [Remote Services: Terminal, Metrics, and Port Forwarding](/openwiki/concepts/remote-services-and-forwarding.md) | [Port Forwarding Benchmarks](/openwiki/operations/port-forwarding-benchmarks.md) for measurement semantics | The relevant terminal, metrics, or forwarding suite |
| SSH connection reuse, session-channel admission, exec/SFTP queue turns, libssh2 retries, or backpressure | [SSH Multiplexing, Channel Admission, and I/O Scheduling](/openwiki/concepts/ssh-multiplexing-and-scheduling.md) | Separate file permits, channel leases, owner queues, and physical pools before changing a limit | `SSHMaxSessionsPolicyTests`, `SSHForwardingPumpTests`, and the affected Agent/SFTP tests |
| Shell bootstrap, Bash/Zsh/Fish hooks, OSC parsing, cwd/home, command history, or prompt/draft readiness | [Shell Integration: Bootstrap, OSC Events, and Terminal State](/openwiki/concepts/shell-integration.md) | Preserve desktop/mobile differences in event delivery and prompt readiness | `ShellIntegrationBootstrapTests`, `CommandHistoryTests`, and mobile command-generator tests |
| Forwarding pool warm-up, local/SOCKS distribution, remote listeners, silent recovery, or listener retirement | [Port Forwarding: Multi-Connection Pool and Flow Dispatch](/openwiki/workflows/port-forwarding-pool-and-dispatch.md) | Distinguish auxiliary repair from whole-context recovery; use the benchmark guide for measurements | Pump and reconnect suites; opt-in forwarding wire tests when the fixture is available |
| SFTP browsing, transfer scheduling/topology, conflict behavior, resume, external editing, or cleanup | [SFTP Transfer, Scheduling, and External Edit Workflow](/openwiki/workflows/sftp-transfer-and-external-edit.md) | The feature owner plus `SFTPTransferContext`/scheduler callers | Matching SFTP transfer, edit, conflict, or mobile SFTP tests |
| Assistant turns, approval, host tools, skills, scratch space, agent persistence, or Hermes memory | [Assistant, Agent Runtime, Skills, and Memory](/openwiki/concepts/agent-runtime-and-assistant.md) | AgentKit boundary in [System Boundaries](/openwiki/architecture/system-boundaries.md) | Agent, approval, scratch, skill, or memory suites in `TFMTests`/`FrameworkTests` |
| Hosts, Vault records, migrations, Keychain references, repositories, or data compatibility | [Persistent Data, Migrations, and Secret Boundaries](/openwiki/concepts/persistence-and-secrets.md) | Persistence compatibility tests and schema owners | Persistence, repository, secret, and migration tests |
| CloudKit selection, sync lifecycle, journals, account transitions, settings, or secret-upload authorization | [Settings, Vault, Metrics, and Cloud Sync Workflow](/openwiki/workflows/settings-and-cloud-sync.md) | [CloudKit Release Readiness](/openwiki/operations/cloudkit-release-readiness.md) for deployment/device checks | Sync lifecycle/coordinator and affected feature tests |
| macOS MCP server, external authentication, transfers, bearer tokens, or `termind-mcp` | [MCP Server, Transfer APIs, and Stdio Bridge](/openwiki/integrations/mcp-server-and-bridge.md) | `TermindMCPBridge/` and MCP server/transfer tests | MCP token, server-session, upload, download, and bridge tests |
| Entitlements, StoreKit, localization, widgets, screenshots, or marketing/landing-page work | [Commerce, Localization, and Product Surfaces](/openwiki/concepts/commerce-localization-and-product-surfaces.md) | [Storefront Commerce Release](/openwiki/operations/storefront-commerce-release.md), [Marketing Assets and App Icons](/openwiki/operations/marketing-assets-and-app-icons.md), and [Build, Test, and Release](/openwiki/operations/build-test-and-release.md) | Localization check, relevant app tests, screenshots, Sandbox checks, or `npm run build` |
| Choosing a regression seam or a representative test across framework and platform targets | [Testing Strategy and Behavioral Boundaries](/openwiki/testing/behavioral-boundaries-and-fixtures.md) | Existing tests nearest the feature | Narrow behavioral test first, then affected target suite |

## The ownership decisions that prevent most regressions

### Put behavior with the correct layer

A feature model should depend on an injected port or service, not construct a database, Keychain store, SSH client, or network implementation because it is nearby. `ArchitectureBoundaryTests` actively rejects lower-layer platform/storage/transport imports, duplicate AgentKit runtime types, and SwiftData models outside Persistence. Treat a boundary-test failure as an architectural error, not a test to work around.

AgentKit is a separately versioned remote package. It owns the generic agent loop, approval gate, provider adapters, MCP client, and host-neutral tools; Termind owns SSH/SFTP tools and registers them additively. A change that genuinely spans the package boundary must be released in `../AgentKit`, then update AgentKit's `minimumVersion` in `Termind.xcodeproj/project.pbxproj` and the resolved revision together. A sibling working-tree edit is not used by Xcode's resolved build.

### Preserve runtime and failure boundaries

The macOS app constructs its model container and app-wide services in `TermindApp`; failure to open the local database terminates startup instead of silently substituting a blank store. The iOS app creates one `MobileAppModel` at startup and shows an unavailable-data view when that composition fails. Test and screenshot modes explicitly select in-memory/test composition rather than modifying production persistence behavior.

Remote trust and authentication are part of the real connection attempt: route preparation supplies a snapshot, while Remote Infrastructure completes socket, handshake, host-key authorization, and authentication. The feature that started the connection retains its journey UI, retry lifetime, and workspace/session ownership. This is why a trust, route, or credential change should be traced through both its shared remote policy and the initiating feature rather than patched in a single screen.

## Validation baseline

Use the narrowest test that proves the changed contract, followed by the affected product suite when risk warrants it. Keep `-onlyUsePackageVersionsFromResolvedFile`; without it an ordinary build can resolve a dependency revision different from `Package.resolved`.

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile build
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile build
xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge
Scripts/check-zh-localization.sh
```

Use an installed iPhone or iPad simulator destination for `TFI` tests. Keep visible-window macOS tests opt-in with `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` and a narrow `-only-testing` selection; routine checks should stay headless. UI string changes require completed `zh-Hans` and `zh-Hant` translations in `Frameworks/Resources/Localizable.xcstrings`; landing-page work is separately validated with `cd LandingPage && npm ci && npm run build`.

## Change checklist

- Identify the domain and owner in the routing map; read the detailed page before implementing.
- Trace callers and callees across the integration boundary; include lifecycle, retry/cancellation, persistence, and cleanup paths—not only the happy path.
- Preserve the contracts in the routed OpenWiki page and update `ArchitectureBoundaryTests` when an intentional ownership rule changes; generated pages are refreshed through the OpenWiki lifecycle rather than hand-maintained as a parallel architecture log.
- Add a targeted regression test at the layer where the behavior is observable, and run the relevant focused check.
- Run resolved-package product validation, strict formatting, and the localization gate appropriate to the changed surface.
- Inspect the diff for secret material, accidental generated artifacts, unintended `Package.resolved` churn, and cross-layer imports.

For general commands, localization, and the AgentKit release procedure, continue with [Build, Test, and Release](/openwiki/operations/build-test-and-release.md). Use the dedicated operations pages for CloudKit deployment, App Store commerce, marketing/assets/icons, and historical forwarding benchmarks.
