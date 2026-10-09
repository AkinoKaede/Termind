---
type: architecture ownership guide
title: Supporting Systems Ownership Guide
description: Ownership and integration boundaries for external Swift packages, the MCP bridge, Live Activities, tests, forwarding benchmarks, the Astro site, assets, and maintenance scripts.
tags: [architecture, directories, agentkit, mcp, widgets, testing, website, tooling]
sources:
  - id: openwiki-source-6d4b4e707b8d60b6ccfa3425
    resource: repo://.github/workflows/openwiki-update.yml
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-7f5c1cb6f348742514987bf8
    resource: repo://Benchmarks/PortForwarding/main.swift
  - id: openwiki-source-4c22145572a82f1dd48f37e0
    resource: repo://fastlane/lib/screenshot_frames.rb
  - id: openwiki-source-cf46ee9dde9e2af41c84b62f
    resource: repo://fastlane/lib/screenshots.rb
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-23be2440342b8fbbefe69214
    resource: repo://Frameworks/TermindRemoteInfrastructure/Tailscale/LibTailscaleNodeSession.swift
  - id: openwiki-source-581eed02dfaf161420cc4d9d
    resource: repo://FrameworkTests/Fixtures/README.md
  - id: openwiki-source-d32eeff4d814c0dbd05e14b8
    resource: repo://Scripts/benchmark-port-forwarding.py
  - id: openwiki-source-c6328be86432b33a68051c73
    resource: repo://Scripts/check-cjk-localization.py
  - id: openwiki-source-790223eb6fb4a24b2cf2d359
    resource: repo://Scripts/check-mcp-bridge.py
  - id: openwiki-source-294dd6a8637abdafe40e9570
    resource: repo://Scripts/generate-v28-fixture.swift
  - id: openwiki-source-a90133154199a9c011127920
    resource: repo://Scripts/Tests/test_bump_version.py
  - id: openwiki-source-a1213a08e73ca7ac095748f3
    resource: repo://Scripts/Tests/test_port_forwarding_benchmark.py
  - id: openwiki-source-4a3da903a25eadf04e18c0fe
    resource: repo://Scripts/Tests/test_screenshots.rb
  - id: openwiki-source-2241f95e71114ed235d89f10
    resource: repo://Scripts/update-pi-model-catalog.sh
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-cd81b8b97e761c0120fdfccb
    resource: repo://Termind.xcodeproj/xcshareddata/xcschemes/TFI.xcscheme
  - id: openwiki-source-60081fe11e88625a130dd44c
    resource: repo://Termind.xcodeproj/xcshareddata/xcschemes/TFM.xcscheme
  - id: openwiki-source-a62bfbbc7de13a894444718b
    resource: repo://TermindMCPBridge/main.swift
  - id: openwiki-source-637644793f7e37cc057eb973
    resource: repo://TFI/Platform/MobileLiveActivityController.swift
  - id: openwiki-source-8d34d9ba6456e86e57933569
    resource: repo://TFITests/MobileLiveActivityRestorationTests.swift
  - id: openwiki-source-779ce1e482a2591d146f565f
    resource: repo://TFITests/Screenshots/MobileScreenshotTests.swift
  - id: openwiki-source-d1ffd558b3360478aa85b5af
    resource: repo://TFIWidgets/WorkspaceLiveActivity.swift
  - id: openwiki-source-76b1cdca4a02038756187f92
    resource: repo://TFM/Application/MCPServer/MCPServerTools.swift
  - id: openwiki-source-3cccceaeda63a663e84b5bfa
    resource: repo://TFM/Infrastructure/MCP/MCPServerSession.swift
  - id: openwiki-source-9d465cf017037915bf209e49
    resource: repo://TFM/Infrastructure/Networking/LoopbackHTTPServer.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-db017475c6e5a30e0527fd60
    resource: repo://TFMTests/Screenshots/MacScreenshotTests.swift
  - id: openwiki-source-0f8d0f9d08d6674698dd054c
    resource: repo://WorkspaceActivitySupport/WorkspaceActivityAttributes.swift
generated: { by: "openwiki/0.7.0", at: "2026-10-09T00:05:26.272Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-09T00:05:26.272Z
---

# Supporting Systems Ownership Guide

Not every top-level directory is an app module. This guide distinguishes separately built products, a package reference checkout, source-sharing groups, test targets, and development assets. It complements [Shared Framework Directories](shared-module-directories.md) and [Native App Directories](native-app-directories.md).

## AgentKit — separately versioned package

`.gitmodules` declares `AgentKit` as a submodule, but **the app builds the remote versioned Swift package, not the submodule or the sibling `../AgentKit` working tree**. `project.pbxproj` declares `https://github.com/AkinoKaede/AgentKit.git` with `upToNextMajorVersion` starting at `0.19.1`; Xcode builds the committed `Package.resolved` pin. Use `-onlyUsePackageVersionsFromResolvedFile` so ordinary app builds do not silently advance the pin. [Repository guidance](../../AGENTS.md) assigns the host-neutral loop, approvals, providers, MCP **client**, and built-in tools to the separately released package; this is an ownership contract, not an inspection of its current remote source.

The Xcode product dependencies are the verifiable local integration boundary: `AgentKit` is linked by both apps and by `TermindDomain`, `TermindApplication`, and `TermindPersistence` (as well as test targets); `AgentKitScrubber` is linked by the desktop app, `TermindRemoteInfrastructure`, and desktop tests. Both product references point to the same remote package. Do not infer the package manifest's internal target/dependency layout from product names. Termind's own `TermindAgentTools` registers host, SSH, and SFTP tools alongside runtime built-ins and composes their presenters; host-specific code stays outside AgentKit. `ArchitectureBoundaryTests` prevents app-local redefinitions of selected AgentKit-owned runtime types by scanning Swift declarations in the desktop app tree; this is a source-level guard against shadowing imports, not a test of the package's own implementation. For changes spanning repositories, test and tag/push AgentKit in `../AgentKit` first, then update the app's Xcode minimum version and resolved revision in the same app-side commit. Package localization and tests are operated from the separate AgentKit repository; verify them against the released package revision when changing that boundary. See [Assistant Runtime](../concepts/agent-runtime-and-assistant.md) and [Build and Release](../operations/build-test-and-release.md).

Maintenance checkout presence is not an Xcode build input: `libssh2-spm` tracks `termind`, while Xcode consumes its remote exact `2.0.3-termind-4` release. Ghostty is different: there is no local Ghostty maintenance submodule or staging override. Xcode consumes `Lakr233/libghostty-spm` directly, with an up-to-next-major requirement and resolved version `2.2.2026100501`. Keep its requirement and resolution aligned; see [Ghostty Dependency Updates](../operations/ghostty-fork-maintenance.md).

### Maintenance checkouts versus build inputs

Maintenance checkouts and resolved build inputs are separate. An initialized checkout may track a different maintenance commit than the released package pin; its presence alone does not change an ordinary Xcode build. `.gitmodules`, the Xcode package requirements, and `Package.resolved` establish the integration boundary; they do not verify fork manifests, patches, binary contents, or internal tests. Initialize the relevant checkout before inspecting or changing those internals. Keep the direct Ghostty dependency boundary in [Ghostty Dependency Updates](../operations/ghostty-fork-maintenance.md), and app build/release procedures in [Build and Release](../operations/build-test-and-release.md).

`libtailscale-spm` follows the same separation: `.gitmodules` declares a checkout tracking `main`, while Xcode requires the remote package through `upToNextMinorVersion` from `1.0.2`, resolved to `1.0.2` at `098e6b69ea128f3a55bc560f005a3e851123dc99`. Its `TailscaleKit` product is linked by `TermindRemoteInfrastructure`; Termind's `LibTailscaleNodeSession` is the app-side adapter that owns the embedded node. The checkout is not a native feature owner or the default source of that product.

The former keyword-highlighting local Ghostty workspace and preparation script were removed. Do not use the retired local-fork release/staging instructions for the current upstream package.

## MCP bridge and desktop server

`TermindMCPBridge` is flat: its entry point implements the `termind-mcp` executable, with executable entitlements alongside it. It reads newline-delimited JSON-RPC from stdin, sends authenticated HTTP requests to the desktop MCP endpoint, carries negotiated session/protocol headers, writes responses to stdout, and requests session deletion at EOF.

**Solid arrows are runtime requests; the dashed arrow is an interactive authorization request.** The bridge is a protocol adapter, not an SSH implementation or a second AgentKit runtime.

```mermaid
flowchart TB
    Client["External MCP client"] -->|stdio JSON-RPC| Bridge["TermindMCPBridge"]
    Bridge -->|HTTP + bearer token| HTTP["TFM / Infrastructure / Networking"]
    HTTP --> Protocol["TFM / Infrastructure / MCP"]
    Protocol --> Tools["TFM / Application / MCPServer"]
    Tools --> Services["Shared host and remote services"]
    Services -.->|when interaction is required| Auth["TFM / Features / ExternalRequests"]
```

The diagram shows stdio-to-desktop requests and the separate interactive authorization boundary.

The server's lifetime/controller is assembled by the desktop app. The bridge takes `TERMIND_MCP_URL` (default `http://127.0.0.1:7391/mcp`) and `TERMIND_MCP_TOKEN`, overrideable by `--url` and `--token`; it refuses a missing token or invalid URL. It skips malformed stdin objects, returns JSON-RPC errors to callers with request IDs on HTTP/transport failures, and sends a best-effort DELETE for its session at EOF. For modern requests with `params._meta["io.modelcontextprotocol/protocolVersion"]`, it forwards version, method, and optional encoded name in headers without a session ID; for legacy initialization it stores the server's session ID and negotiated protocol version for subsequent requests and cleanup. `Scripts/check-mcp-bridge.py` exercises the built executable against a local test server for both header modes, error passthrough, and legacy DELETE; this is not a replacement for desktop server tests. Upload/download application policy, transfer tickets, bearer-token handling, and native authentication presentation stay on their respective sides of this boundary. Details: [MCP Server and Bridge](../integrations/mcp-server-and-bridge.md).

## Live Activity product and shared source

| Directory | Responsibility |
| --- | --- |
| `TFIWidgets` | Flat widget entry/presentation source and bundle metadata for the `TermindWidgets` extension. Renders Lock Screen and Dynamic Island workspace summaries and links. |
| `TFIWidgets/Assets.xcassets` | Widget-owned catalog; `TermindLiveActivityIcon.imageset` supplies its template icon. |
| `WorkspaceActivitySupport` | Flat shared source group compiled into both the mobile app and widget, **not a separate framework target**. Defines ActivityKit attributes, bounded summary payloads, and workspace deep-link encoding/decoding. |
| `TFI/Platform` | Native Live Activity controller/services that create, update, and retire activities from app-owned workspace state. |

```mermaid
flowchart TB
    Workspaces["Mobile app workspace state"] -->|summarize| Controller["Mobile Live Activity controller"]
    Contract["WorkspaceActivitySupport / shared source"] -.->|payload contract| Controller
    Contract -.->|payload contract| Widget["TermindWidgets"]
    Controller -->|ActivityKit content updates| Widget
    Widget -->|workspace deep link| Scene["Mobile scene routing"]
    Scene -->|select retained workspace| Workspaces
```

The diagram shows how shared ActivityKit content connects app-owned updates, widget rendering, and workspace navigation.

Here solid arrows are updates/navigation and dashed arrows are shared type contracts. The payload has bounded session summaries and excludes credentials and terminal output. The extension displays state; it does not keep an SSH connection alive. The app controller restores one active or stale activity and ends duplicates, serializes start/update/end, ends when no workspaces remain, and only starts a missing activity after an explicit open intent and permission to start; ordinary updates cannot resurrect one dismissed by the user.

`MobileLiveActivityRestorationTests` checks duplicate cleanup and retained focus, non-resurrection after dismissal, and close-last/open-new ordering with a suspended end operation. The shared `TFI` scheme selects both `TFITests` and `FrameworkTests`; run it with an available iOS simulator rather than treating the widget as an independent connection or state owner.

## Tests, fixtures, benchmarks, and scripts

| Directory | Responsibility |
| --- | --- |
| `FrameworkTests` | Flat shared-layer test suites for values/use cases, persistence/migration, sync, shared presentation, and other framework contracts. |
| `FrameworkTests/Fixtures` | Synthetic original-module V1/V14 SwiftData stores and a V28 store generated against the historical Persistence framework. Preserve these historical model identities instead of regenerating with current models; `Scripts/generate-v28-fixture.swift` records V28 provenance. |
| `TFMTests` | Flat desktop and integration suites: architecture boundaries, windows/navigation, terminal/remote flows, transfers, MCP, and rendering. Visible-window and screenshot cases have explicit opt-in gates. |
| `TFITests` | Flat mobile suites: app/scene ownership, workspace/session behavior, backgrounding, editor/Assistant behavior, adaptive layout, and screenshots. |
| `Benchmarks/PortForwarding` | Standalone forwarding benchmark executable over shared-framework SPI; not hosted by an app or test bundle. |
| `Scripts` | Flat executable utilities grouped by function below. |
| `Scripts/Tests` | Python resource/version and benchmark checks, plus Ruby regression tests for screenshot capture/frame orchestration. |
| `StoreKit` | Local StoreKit product/test configuration; not the production entitlement implementation. |

The standalone benchmark reads fixture metadata, enforces the host's 1–64 connection limit, and exits with diagnostics on invalid inputs or workload failures. Its runner exercises local, remote, and dynamic forwarding, jump hosts, duplex/mixed traffic, and idle CPU; it waits for the connection pool before recording JSON `FORWARDING_METRIC` lines and disconnects on both success and failure. `Scripts/benchmark-port-forwarding.py` builds its own Release scheme with resolved package versions, runs repetitions and connection limits, and fails if the executable emits no metrics; `ArchitectureBoundaryTests` protects it from becoming an app dependency or a test-host workload. The `TFM` scheme tests `TFMTests` and `FrameworkTests`; use an iOS simulator for `TFITests`. Architecture guards also check cross-layer imports, persistence ownership and feature boundaries, so an ownership refactor should update the focused source-level guard and functional tests together; these guards do not execute the forwarding benchmark. Visible-window macOS, StoreKit, and mobile key-window integration suites have separate opt-in gates rather than running in routine test invocations.

The script root has multiple independent workflows:

- **Release and resource maintenance:** version bumping, CJK-localization validation, shared presentation-copy checking, Linux-distribution icon refresh, and model-catalog refresh. `Scripts/update-pi-model-catalog.sh` requires an explicit Pi version, records npm commit/integrity, preserves model type/input/output, and deduplicates `(provider, id)` entries preferring chat over image over other types; missing output defaults by model type. `Scripts/check-cjk-localization.py` checks catalog normalization and JSON structure, positional format arguments and plural shape, then rejects missing or unfinished `zh-Hans`/`zh-Hant`/`ja` translations and spacing violations; by default it checks both app catalogs, not AgentKit's catalog.
- **Remote fixtures and benchmarks:** SSH authentication, OpenSSH forwarding, and Telnet fixtures; native/external forwarding runners and their shared benchmark helpers.
- **Screenshots and assets:** `fastlane/Fastfile` runs scan over app-owned `MacScreenshotTests` / `MobileScreenshotTests`, not XCUITest snapshot helpers. The Mac lane requires macOS 27 and defaults to Workspace in four locales; its focused native-window marker, scan status and dimensions gate promotion. The iOS lane defaults to iPhone 18 Pro and iPad M5 on 27.0; Duo inner/outer are separate opt-in 27.1 display batches. A unique ready/ack handshake and exact native pixels gate each device/locale scene set. Both lanes share a nonblocking lock, preserve pinned packages and back up replaced sources with SHA-256 manifests. `Scripts/run-mac-screenshots.sh` and `run-mobile-screenshots.sh` delegate to these lanes; `fastlane frames` stages read-only source copies and publishes only after every selected frame succeeds. The full commands, licensed template imports, mask mechanics and Figma delivery contract are in [Marketing Assets and App Icons](../operations/marketing-assets-and-app-icons.md).

Use [Behavioral Boundaries and Fixtures](../testing/behavioral-boundaries-and-fixtures.md) to choose tests and [Forwarding Benchmarks](../operations/port-forwarding-benchmarks.md) for measurement semantics. Routine documentation validation does not imply these app or wire suites have run.

## Public website and asset submodule

[Repository guidance](../../AGENTS.md) identifies `com.akinokaede.termind/` as an independent public website and assets repository with an Astro project at its root; `assets/` and `design/` own marketing and brand assets. Utilities and screenshot tooling remain in the parent repository. Native app builds do not require this submodule. Initialize it only for website or asset work:

```sh
git submodule update --init com.akinokaede.termind
```

Commit and push reviewed asset changes via SSH **before** updating the application's gitlink. Keep the public HTTPS clone URL declared in [`.gitmodules`](../../.gitmodules).

**Evidence boundary:** the submodule directory is empty in this checkout. Its website implementation and asset inventory are unavailable for inspection, not demonstrated to have been deleted. This guide therefore does not assert its current Astro directory structure, locale routes or redirects, pricing/comparison implementation, image import allowlist or transforms, final store-board inventory, or design-master layout. Initialize the submodule and inspect its own source before changing those internals. See [Commerce, Localization, and Product Surfaces](../concepts/commerce-localization-and-product-surfaces.md) for the related product boundary.

The parent repository documents `cd com.akinokaede.termind && npm ci && npm run dev` for installing locked dependencies and starting Astro, and `cd com.akinokaede.termind && npm run build` for type-checking and emitting the production site to `com.akinokaede.termind/dist/`. These are documented operating commands, not verification of the unavailable package scripts or image-generation behavior.

## Marketing and design assets

The paths below are **destinations and inputs configured by the parent repository's Ruby tooling**, relative to `com.akinokaede.termind`; they are not an inventory of files present in the empty checkout.

| Path | Locally evidenced responsibility |
| --- | --- |
| `assets/captures/<locale>/<device>` | Default full-resolution native capture destination and frame input. Device directories map to `iphone-6.3`, `ipad-15`, `mac-14`, `iphone-duo-inner`, and `iphone-duo-outer`. |
| `assets/device_frames/<locale>/<device>/<scene>.png` | Default derived PNG destination; the frame planner preserves locale/device/scene identity from the capture input. Locale directory names are lowercased. |
| `assets/device_templates` | Default local template input for frame generation; required template dimensions are checked before rendering. Template paths can be overridden. |
| `assets/`, `design/` | Marketing and brand ownership assigned by `AGENTS.md`; final store artwork and design-master contents must be verified in the initialized asset repository. |

Default capture output requires the submodule's `.git` marker and `assets/` directory, failing with an initialization instruction before building when they are absent. Default frame input or output uses the same prerequisite. An explicit capture `output` bypasses that default destination requirement; framing can operate outside the submodule when both `input` and `output` are supplied, with valid external templates where needed. This is an asset-tooling prerequisite, not a native app-build dependency.

**Arrows below mean locally evidenced asset production or consumption, not code dependencies.**

```mermaid
flowchart TB
    Native["App-owned native fixtures"] --> Capture["fastlane scan and system capture"]
    Capture --> Raw["Configured captures / locale / device"]
    Raw --> Frames["Staged copies and frame composition"]
    Templates["Validated local device templates"] --> Frames
    Frames --> Framed["Configured device_frames / locale / device"]
```

The diagram shows parent-owned capture production and frame consumption, without asserting an uninspected website or App Store composition pipeline.

`ScreenshotFrames` defaults to iPhone, iPad, and Mac and a parent-defined `WEBSITE_SCENES` subset; Duo displays are selectable separately. That selector is not proof of the website's current imports. Frame generation validates native source dimensions and template dimensions, masks staged copies, uses frameit for mobile frames and local composition for Mac, and checks that every requested render produced a valid image before publishing any selected frame. Sources remain read-only; this tool does not establish how final App Store artwork is composed.

`Scripts/Tests/test_screenshots.rb` covers missing-submodule failures before capture/frame work, explicit external paths, default scene selection, native-size rejection, source-byte preservation, and withholding publication when a requested frame is missing. These are focused orchestration regressions, not tests of the unavailable website. Asset commands and capture verification are described in [Marketing Assets and App Icons](../operations/marketing-assets-and-app-icons.md).

## Project metadata and documentation tooling

| Directory | Responsibility |
| --- | --- |
| `Termind.xcodeproj` | Target definitions, build settings, source/resource membership, linking, and product embedding. |
| `Termind.xcodeproj/xcshareddata/xcschemes` | Shared build/test/run schemes for the apps, bridge, and benchmark. |
| `Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm` | Resolved remote-package revisions. This is the app's dependency pin, independent of the AgentKit submodule and sibling repository. |
| `.github/workflows` | Scheduled/manual OpenWiki refresh and documentation-PR automation. |
| `.agents/skills/openwiki` | Repository-installed OpenWiki lifecycle instructions and integration metadata; `agents` contains host descriptors. |
| `.codex` | Coding-agent integration configuration, not application runtime configuration. |
| `openwiki/architecture`, `concepts`, `workflows` | Ownership/directory guides, mechanism explanations, and end-to-end behavior. |
| `openwiki/integrations`, `operations`, `testing` | External interfaces, release/development procedures, and verification guidance. |
| `openwiki/.claims` | Generated, page-aligned evidence sidecars; not hand-authored documentation or app state. |

Local dependency/build caches such as `node_modules`, `.build`, `build`, and website output are excluded from the source architecture map. Git internals and user-specific IDE state are also not product modules. Generated OpenWiki indexes, Claims, and lifecycle metadata are maintained through OpenWiki rather than edited as source files.

Return to the [Module Map](module-map.md) or the [Engineering Quickstart](../quickstart.md).

Screenshot suites live directly under `TFMTests/Screenshots/` and `TFITests/Screenshots/`; lanes select suites by Swift type.
