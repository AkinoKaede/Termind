---
type: integration guide
title: Ghostty Terminal Integration
description: Trace how Termind hosts Ghostty surfaces and extends native terminal menus on macOS and iOS, including selection, localization, upload availability, and package boundaries.
tags: [ghostty, terminal, menus, macos, ios, integration]
verified:
  - by: openwiki/0.6.0
    at: 2026-10-02T08:42:40.505Z
sources:
  - id: openwiki-source-b37c974aaea12bd08606d67d
    resource: repo://Frameworks/TermindDomain/Commerce/ProAccessTypes.swift
  - id: openwiki-source-8185a608f0b79f1af097efbd
    resource: repo://Frameworks/TermindPresentation/Terminal/TerminalAppearance.swift
  - id: openwiki-source-76bfec2a5f9d38c73ab870c3
    resource: repo://Frameworks/TermindPresentation/Terminal/TerminalKeywordHighlighting.swift
  - id: openwiki-source-9e7915b5fd54b91e430607e2
    resource: repo://libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView.swift
  - id: openwiki-source-bad342fc101e73486720b943
    resource: repo://libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView%2BClipboard.swift
  - id: openwiki-source-8ae52602ed3d3f309e86339b
    resource: repo://libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView%2BTouchMenu.swift
  - id: openwiki-source-3bbc1dc23d4e59b05f8d5f52
    resource: repo://libghostty-spm/Sources/GhosttyTerminal/Platform/UIKit/UITerminalView%2BTouchMenuActions.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-ca0b3e6e839587396cdeaf54
    resource: repo://TFI/Platform/MobileTerminalSurface.swift
  - id: openwiki-source-4be25dd014939527fac996f5
    resource: repo://TFITests/MobileTerminalUploadMenuTests.swift
  - id: openwiki-source-194f038fde2b1218c1c960b2
    resource: repo://TFM/Features/Terminal/DesktopTerminalSurface.swift
  - id: openwiki-source-fe5539ed6f675410b82b41c4
    resource: repo://TFM/Features/Terminal/PersistentTerminalSurfaceView.swift
  - id: openwiki-source-c5cf0bfb7f2ff215114f00d5
    resource: repo://TFM/Features/Terminal/TerminalPlaceholderView.swift
  - id: openwiki-source-835d474e3dc193359dcfbb0b
    resource: repo://TFMTests/TerminalContextMenuTests.swift
generated: { by: "codex", at: "2026-10-02T08:42:40.505Z" }
---

# Ghostty Terminal Integration

Termind uses the pinned remote `libghostty-spm` package for terminal parsing, rendering and native input. SSH, Telnet and desktop serial transports remain Termind-owned. Each terminal supplies Ghostty's `InMemoryTerminalSession` with received bytes, outgoing writes and resize callbacks; a `TerminalViewState` and native view live with the session or workspace rather than with a transient SwiftUI mount. This preserves the grid, selection and scrollback across navigation and desktop pane moves. See [Ghostty Fork Maintenance](/openwiki/operations/ghostty-fork-maintenance.md) for the package revision and binary release boundary.

## Native menu ownership

Ghostty defines the platform menu entry points and baseline terminal actions. Termind extends the native view subclass because it owns app commands, localization and SSH upload policy. The two platforms expose different seams:

| Surface | Package entry point | Termind extension |
| --- | --- | --- |
| iOS direct touch, no selected text | `touchMenuItems(for: TerminalTouchMenuContext)` | `MobileTerminalView` localizes the inherited actions and appends a grouped Upload File menu. |
| iOS direct touch, selected text | `touchSelectionMenuItems(for: TerminalTouchSelectionMenuContext)` | The separate override applies the same localization and upload menu; its context also carries a snapshot of selected text for future host actions. |
| macOS secondary click | `selectionMenuPoint(at:)` and `selectionContextMenu()` | `TermindTerminalView` permits a menu without selection and composes Copy, Paste, Select All and conditional Upload File. |

### iPhone and iPad touch menus

`MobileTerminalSurface` opts its retained `MobileTerminalView` into Ghostty's inline text selection. In the fork, a long press opens the touch menu, a double tap selects a word, a triple tap selects a row, and selection gestures stay inside the terminal view. On iOS 16 and later, Ghostty presents a `UIEditMenuInteraction`; it chooses **one of two hooks** according to whether `touchSelection.text` exists. With no selection, the baseline actions are Paste when pasteboard content exists, Select and Select All. With a selection, they are Copy, optional Paste and Select All. UIKit owns compact layout and, on iOS 17+, any AutoFill menu. The iOS 15 fallback uses `UIMenuController` and the responder chain, so the newer hook-built Upload File submenu is an iOS 16+ path.

`MobileTerminalView` calls the matching superclass hook, then maps Ghostty's stable action identifiers (`terminal.copy`, `.paste`, `.select`, `.selectAll`) to shared `AppStrings` resources. It leaves the package's action handlers intact and appends one localized Upload File `UIMenu` with Photos and Files actions. `MobileWorkspace.configureTerminalUpload` installs handlers only for SSH workspaces. The submenu is absent when no file-upload handler is bound, and both child actions are disabled when the live workspace cannot upload. Each handler checks availability again when invoked, so an earlier visible menu cannot submit an upload after the connection or destination becomes unavailable. `uploadTargetProblem` is the workspace's connection, transfer-configuration and working-directory gate; the shell must report a usable directory through OSC 7. This upload is available without a Pro entitlement.

The touch hooks do not build every possible UIKit menu. The fork's indirect-pointer `UIContextMenuInteraction` uses `selectionContextMenuElements()` for its selection menu, which currently returns Ghostty's Copy action; Termind's touch-hook overrides do not add its Upload File submenu to that pointer path. A menu change should explicitly choose which interaction it targets and test both selection states. The package keeps terminal action semantics; group titles, localization and upload authorization belong in the Termind subclass.

### macOS secondary-click menu

`TermindTerminalView.selectionMenuPoint(at:)` allows the default menu even on blank terminal space, while captured remote mouse mode suppresses the host menu. Its `selectionContextMenu()` uses Ghostty's Copy item only when Ghostty reports a selection, localizes that title, then adds Paste and Select All. Paste is disabled without pasteable text or file URLs and takes Ghostty's `paste_from_clipboard` binding. Upload File appears only while a pane has bound an upload action; its enabled state reads the current visibility and upload-target problem, and the action checks that gate again before invoking the file picker.

Desktop's **Paste on Right Click** preference changes the gesture: an ordinary secondary click pastes and does not open the menu, while Option-secondary-click still opens it. Remote mouse capture remains Ghostty-owned. The session's `PersistentTerminalViewOwner` binds upload actions with an ID; updates or teardown from an old pane cannot disable or remove the menu installed by a replacement pane. On disappearance the current pane unbinds its ID. The menu therefore follows the presenting pane even when SwiftUI reparents the same native terminal.

## Surface and appearance flow

Desktop `PersistentTerminalViewOwner` creates the in-memory backend, `TerminalViewState` and `TermindTerminalView` once, then mounts the same view in a changing `NSViewRepresentable` container. Mobile `MobileWorkspace` likewise creates a backend and state once and returns its retained `MobileTerminalSurface` view through `makePlatformView`. Both pass remote output into the backend and route keyboard/paste output to their transport. Do not reset surface options on an ordinary view update: replacing the controller or backend can tear down the live surface.

Shared Presentation maps Termind palettes and the Ghostty theme catalog into light/dark terminal configurations. It applies the chosen base, optional custom commands and then device-local font overrides; app command notifications force Ghostty's `notify-on-command-finish` to `never` so the Termind notification coordinator owns delivery. The shared keyword-highlighting modifier converts synchronized domain rules into Ghostty runtime rules and applies only rules accepted by the current engine. Domain defines fixed built-in rules plus bounded custom rules; Application persists changes before publishing them, Persistence stores the preferences in V46, and Settings sync distributes them. Both platform surfaces update highlighting in place.

## Focused checks

- `TFMTests/TerminalContextMenuTests.swift` covers blank-space Paste/Select All, conditional Copy, right-click-paste with Option bypass, live Upload File availability and stale pane-binding teardown.
- `TFITests/MobileTerminalUploadMenuTests.swift` checks the native Photos/Files group, absent handlers and enabled/disabled children. The fork's `GhosttyKitTest/Input/TerminalTouchSelectionTests.swift` covers its selection mechanics; inspect both hook implementations when changing menu construction.
- `TFMTests/TerminalKeywordHighlightingTests.swift`, `TFITests/MobileTerminalHighlightingTests.swift` and `FrameworkTests/TerminalHighlightPreferencesTests.swift` cover rule validation, rendering and preference persistence. Use the resolved-only Xcode build for either app; package changes also need the fork's own tests and release sequence.

For upload destination and drop behavior, continue with [File Drag and Drop](/openwiki/workflows/file-drag-and-drop.md). For theme browser and settings ownership, see [UI Design and Shared Presentation](/openwiki/concepts/ui-design-principles.md).
