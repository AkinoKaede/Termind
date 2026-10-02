---
type: operations guide
title: Ghostty Fork Maintenance
description: Maintain Termind's pinned libghostty-spm fork, native XCFramework, Swift menu hooks, local test workspace, and synchronized Xcode dependency records.
tags: [ghostty, dependency, submodule, xcframework, release, menus]
verified:
  - by: openwiki/0.6.0
    at: 2026-10-02T08:42:40.505Z
sources:
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-50812a769fc99155abb6d582
    resource: repo://libghostty-spm/.github/workflows/release.yml
  - id: openwiki-source-34833edd0cee17db9fea8637
    resource: repo://libghostty-spm/Package.local.swift
  - id: openwiki-source-e1fc8cf726195ecc8e9ab874
    resource: repo://libghostty-spm/Package.swift
  - id: openwiki-source-fb125d5a34ed2ed61b600bcb
    resource: repo://libghostty-spm/Patches/ghostty/README.md
  - id: openwiki-source-57c7298b2f5de364df677135
    resource: repo://libghostty-spm/Script/apply-patches.sh
  - id: openwiki-source-a323a8a3504f40a6da6e0088
    resource: repo://libghostty-spm/Script/build-ghostty.sh
  - id: openwiki-source-24ff6f74c9f115e9e04ac0c4
    resource: repo://libghostty-spm/Script/verify-release.sh
  - id: openwiki-source-9e7915b5fd54b91e430607e2
    resource: repo://libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift
  - id: openwiki-source-caa5d720c9123cdab2a47976
    resource: repo://Scripts/prepare-local-ghostty-workspace.sh
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  - id: openwiki-source-ca0b3e6e839587396cdeaf54
    resource: repo://TFI/Platform/MobileTerminalSurface.swift
  - id: openwiki-source-fe5539ed6f675410b82b41c4
    resource: repo://TFM/Features/Terminal/PersistentTerminalSurfaceView.swift
generated: { by: "codex", at: "2026-10-02T08:42:40.505Z" }
---

# Ghostty Fork Maintenance

Termind has **three different Ghostty inputs**. `libghostty-spm/` is a maintenance Git submodule tracking the public fork's `termind` branch. Xcode builds the remote `AkinoKaede/libghostty-spm` Swift package at the exact revision in `Termind.xcodeproj/project.pbxproj` and `Package.resolved`, rather than reading uncommitted files from that submodule. The package's `Package.swift` separately downloads a prebuilt `GhosttyKit.xcframework.zip` for its `libghostty` binary target. At the current checkout, the submodule gitlink, project requirement and resolved package all identify `f4cc2d064baef32e2ab92b455b03b1a46880338b`; the manifest points to the `upstream.0538f7535be0-4` XCFramework asset with checksum `7ae784a888ec4bd5f46d67f761d09bf11b871d2e846cf02ade76e2515aec0c30`.

| Change | Source owner | App consumption boundary |
| --- | --- | --- |
| Ghostty engine, C API or Zig patch | Fork's `Ghostty.ref`, `Patches/ghostty/`, native build and XCFramework release | Update the binary asset URL/checksum in the fork manifest, publish the fork revision, then advance all three Termind pins. |
| Swift terminal view or menu hook | Fork's `Sources/GhosttyTerminal/` | Test and push the Swift fork change, then advance all three Termind pins. A Swift-only hook change can reuse the current XCFramework if its C API is unchanged. |
| Termind menu labels, grouping, upload choices and availability | `TFM/Features/Terminal/` or `TFI/Platform/` and shared `AppStrings` | Change the app's native subclass and catalogs; a fork release is needed only if the package's extension seam itself changes. |

## Menu extension boundary

The pinned fork exposes separate iOS 16+ hooks on `UITerminalView`: `touchMenuItems(for:)` before selection and `touchSelectionMenuItems(for:)` while selected. Their baseline actions retain Ghostty's copy/paste/selection behavior and stable `terminal.*` identifiers. Termind overrides **both** in `MobileTerminalView` to localize inherited titles and append its grouped Photos/Files upload choices. Keep the fork host-neutral: Termind's upload closures, translated copy, capability check and grouping belong to the app. The fork's indirect-pointer context menu uses a different `selectionContextMenuElements()` seam, so a change intended for pointer secondary-clicks must be evaluated there separately. macOS extends `selectionContextMenu()` on its own `TermindTerminalView`; no iOS touch hook affects that AppKit path. See [Ghostty Terminal Integration](/openwiki/concepts/ghostty-terminal-integration.md) for the current actions, fallback behavior and focused tests.

For a menu API change in the fork, run `swift test` and the package's relevant `GhosttyKitTest/Input` suites against the proposed Swift sources, then test Termind's desktop and mobile menu suites after updating its pin. The fork's `Script/check-licenses.sh` is a required package check because its resource bundle ships inside host apps. If a change touches native Ghostty source or resources, run the fork's platform build/test matrix and verify the published binary consumer before the app pin advances.

## Native patch and binary path

The fork pins upstream Ghostty in `Ghostty.ref`. `Script/build-ghostty.sh` calls `Script/apply-patches.sh` before each target's Zig build. That script walks `Patches/ghostty/` in name order: `.patch` files use `git apply` with a three-way fallback, `.sh` patches must be repeatable, Markdown is ignored, and an unsupported or conflicting patch stops the build. The host-managed I/O patch is skipped if the pinned upstream header already provides its C API. Build-cache input stamps include the source revision, Zig version and patch contents, so a patch edit invalidates the cached native build. Patch changes need a new fork XCFramework release and a corresponding manifest URL/checksum; changing the submodule source alone cannot change the binary Xcode downloads.

The fork's `release.yml` cuts a **Swift package tag** only after the `upstream.<sha12>` binary release exists. It downloads that asset, generates the release `Package.swift` URL/checksum, verifies an XCFramework consumer, runs its package matrix and Swift tests with the local binary, then verifies that the final manifest digest matches the release asset. These package tags and upstream binary asset tags are distinct. Current Termind Xcode references a commit revision, not a package version range, so record the exact pushed commit you intend the app to build.

## Local development and app pin update

1. Initialize the maintenance checkout with `git submodule update --init libghostty-spm`; inspect its own guidance and source before changing its menu hooks or native patch stack. Test a Swift-only fork edit in that checkout with `swift test` and its relevant package tests.
2. For a local app build against a **locally built native XCFramework**, first build `libghostty-spm/BinaryTarget/GhosttyKit.xcframework` through the package build flow, then run `Scripts/prepare-local-ghostty-workspace.sh`. The helper stages `build/KeywordHighlighting/Termind.xcworkspace`, copies `Package.local.swift` as its local package manifest and links the fork's sources, tests and binary without changing the committed Xcode pin. This workspace is a development override, not release evidence.
3. For an engine/patch change, publish the XCFramework asset and update the fork's release manifest URL/checksum before advancing the app. For a Swift-only menu hook change, reuse the existing binary when its native API is unchanged. Push the fork change to `termind` and verify the revision is available remotely.
4. Move the Termind submodule gitlink to that pushed revision, set the same revision in `Termind.xcodeproj/project.pbxproj`, and re-resolve so `Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` matches. Commit those three records with the app change that consumes the new hook. Build with `-onlyUsePackageVersionsFromResolvedFile` to prove Xcode used the committed resolution.

`TFMTests/TerminalContextMenuTests.swift` checks AppKit menu composition, availability and stale pane teardown. `TFITests/MobileTerminalUploadMenuTests.swift` checks the UIKit upload group and its enabled state. The package's touch-selection tests check its terminal-local selection mechanics. If a menu change alters the actual interaction, inspect both selection states, iOS fallback and pointer behavior in addition to the unit tests. [Build, Test, and Release](/openwiki/operations/build-test-and-release.md) holds the general app test commands and opt-in rules.
