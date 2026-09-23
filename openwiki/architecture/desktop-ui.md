---
type: architecture guide
title: TFM Desktop UI Architecture
description: "How the macOS app composes its native window shell, persistent workspace deck, split panes, management pages and Assistant surfaces, with explicit UI-state and runtime ownership."
tags: [macos, tfm, ui, navigation, workspaces, swiftui, appkit, design]
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T10:36:38.039Z
sources:
  - id: openwiki-source-e09fb7bc8e7ca0579f6d446e
    resource: repo://Frameworks/TermindApplication/FeatureModels/DeviceDirectoryModel.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-873894299539cce9a737a860
    resource: repo://TFM/App/RootView.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-6a1a95f7d01cc8e15a397f6b
    resource: repo://TFM/App/TermindCommands.swift
  - id: openwiki-source-f490cb5bfbb8ce236a7f1bf4
    resource: repo://TFM/Design/DesignTokens.swift
  - id: openwiki-source-95f72232fb896aa95dd5f6c7
    resource: repo://TFM/Features/AI/TranscriptListView.swift
  - id: openwiki-source-d35453512ef488d0cacdc06e
    resource: repo://TFM/Features/Assistant/AssistantView.swift
  - id: openwiki-source-0854be84b166268626a3cb08
    resource: repo://TFM/Features/Sidebar/WindowSidebarView.swift
  - id: openwiki-source-9cfd8531aa60dcfb31f04e04
    resource: repo://TFM/Features/Vault/VaultWorkspaceView.swift
  - id: openwiki-source-ee09ece1fddff7d72a2b5cf4
    resource: repo://TFM/Features/Workspaces/Pane.swift
  - id: openwiki-source-ba160208435f3410138a3539
    resource: repo://TFM/Features/Workspaces/PersistentWorkspaceDeckLayout.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-931aff66b28d38cd69ce2324
    resource: repo://TFM/Features/Workspaces/WorkspaceContentView.swift
  - id: openwiki-source-7e364c6182a8339831ecab24
    resource: repo://TFM/Features/Workspaces/WorkspaceNavigatorView.swift
  - id: openwiki-source-22e92f96394f292a731fc6fb
    resource: repo://TFM/Platform/MainWindowCoordinator.swift
  - id: openwiki-source-5e2670d68f19777e2dd312ea
    resource: repo://TFM/UI/Components/WindowToolbar.swift
  - id: openwiki-source-f6a967b4f14bf50d1af51b8b
    resource: repo://TFM/UI/Managed/ManagedCardPage.swift
  - id: openwiki-source-23acce6fe9173a886d433b44
    resource: repo://TFMTests/AssistantConversationMenuTests.swift
  - id: openwiki-source-98505b843db3ce6b8e4ca024
    resource: repo://TFMTests/PersistentWorkspaceDeckLayoutTests.swift
  - id: openwiki-source-dceb8d7e7c5bb09359e70052
    resource: repo://TFMTests/ResponsivePageLayoutTests.swift
  - id: openwiki-source-91826a88f242f001f33fff89
    resource: repo://TFMTests/WindowToolbarFindTests.swift
  - id: openwiki-source-a3093a0c1d98ecc1cdbc0279
    resource: repo://TFMTests/WorkspaceNavigatorDropTests.swift
  - id: openwiki-source-05f0aeba12df8388b97b3c76
    resource: repo://TFMTests/WorkspaceNavigatorRenameTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-23T10:36:38.039Z" }
---

# TFM Desktop UI Architecture

TFM uses SwiftUI for composition and AppKit-backed surfaces where native identity, focus, text handling or incremental rendering matters. Its central design is **one Navigator column and one persistent detail deck per window**, not a separate horizontal tab system for every feature.

This guide describes the current implementation. See [TFI Mobile UI Architecture](/openwiki/architecture/mobile-ui.md) for the different mobile shell and [UI Design Principles](/openwiki/concepts/ui-design-principles.md) for the sharing boundary.

## Code structure: composition and ownership

Solid arrows below mean composition/ownership or routing, not necessarily inheritance. The model branch is shown separately because a view appearing in the diagram does not own every runtime it displays.

```mermaid
flowchart TD
    App[TermindApp] --> Shared[AppModel and application services]
    App --> Scene[Main WindowGroup]
    Scene --> Root[RootView]
    Root --> Window[WindowModel per window]
    Root --> Shell[NavigationSplitView]
    Shell --> Sidebar[WindowSidebarView]
    Sidebar --> Navigator[WorkspaceNavigatorView]
    Sidebar --> Tools[AssistantPanelView / Snippets / History]
    Shell --> Deck[PersistentWorkspaceDeckLayout]
    Deck --> WorkspaceView[WorkspaceContentView]
    WorkspaceView --> Split[SplitNodeView / SplitBranchView]
    Split --> Pane[PaneView]
    Shell --> Destinations[Vault / Assistant / Metrics / Settings]
    Window --> WorkspaceModels[WorkspaceDeckModel and Workspaces]
    Window --> UIState[Sidebar / presentations / selections / queries]
    Window --> Cache[TranscriptListCache]
    Shared -. services .-> Window
```

The main layers are:

| Layer | Responsibility | What should not move into it |
| --- | --- | --- |
| App composition | Persistence container, shared service graph, launch locale, main and external-authentication scenes, application commands. | One window's selected pane, query, or editor route. |
| `WindowModel` | Workspace collection, selected destination, sidebar mode, presentation routes, page selection/search state, transcript cache and connection-service wiring. | A process-global assumption that all windows share the same active session. |
| Workspace and pane models | Live session ownership, pane identity, split tree, focused pane and workspace-specific command context. | Temporary divider-drag coordinates or a view's hover state. |
| Feature views | Render projected state, present interaction, dispatch intent to owners. | Recreating connections merely because a destination appears. |
| Reusable renderers and native bridges | Collection interaction, layout, focus/native mounting, terminal/transcript presentation. | Resource-specific repository mutations hidden behind generic drawing code. |

`TermindApp` builds the persistence container and shared `AppModel` once. Its `WindowGroup(id: "main", for: UUID.self)` calls `makeWindow(requestID:)` for each scene: ordinary and restored windows receive a fresh `WindowModel`, while a debug screenshot launch without a request ID can receive a demo-configured model. `RootView` stores the supplied instance in `@State` and exposes it through the environment and focused scene values so commands target the correct window. The separate `Window` for external authentication shares app dependencies but is not a workspace scene; `.commandsRemoved()` keeps it out of normal scene-opening commands. The main scene uses the saved default window size and content minimum resizing; screenshot mode disables scene restoration.

`MainWindowRegistration` connects a real AppKit window to `app.mainWindows`. A **Move Workspace to New Window** action requests the UUID-valued main scene first; the source retains its live workspace until the destination registers. Only then does `MainWindowCoordinator` take it from the source and open it in the new model, preserving the running session rather than treating a move as a close/reopen. Closing a real window instead unregisters its model and `closeForWindow()` disconnects its workspaces and clears window-scoped caches. A restored scene has no pending move request and keeps its system-restored frame.

```mermaid
sequenceDiagram
    participant Navigator as Workspace Navigator
    participant Coordinator as MainWindowCoordinator
    participant Scene as Main WindowGroup
    participant Source as Source WindowModel
    participant Target as Target WindowModel
    Navigator->>Coordinator: moveWorkspace with workspace ID
    Coordinator->>Scene: createScene with request UUID
    Scene->>Target: create fresh window model
    Target->>Coordinator: register native window and request UUID
    Coordinator->>Source: takeWorkspaceForMove
    Coordinator->>Target: open live workspace
```

A workspace move waits for native destination registration before changing ownership. [Source: `TFM/Platform/MainWindowCoordinator.swift` and `TFM/Features/Workspaces/WindowModel.swift`.]

## The window shell owns chrome once

`RootView` owns the split view, the window toolbar, search host, native window registration, title reporting, Quick Open, onboarding and app-level presentation bridges. It supplies one leading creation area, a principal Metrics page picker when applicable, and one Find slot following the content in front.

The sidebar is one column whose mode rail switches between Navigator, Assistant, Snippets and History. `WindowModel.activateSidebarMode` is an **intent operation**, not just a property assignment: choosing Navigator from the full Assistant restores its prior destination, while choosing Assistant inside a workspace opens the contextual sidebar rather than hiding the terminal. Direct mode assignment remains available for presentation/restoration without these navigation side effects. History is unavailable for focused Telnet/serial sessions, and reconciliation moves away from an invalid mode.

The column's material belongs to the native split view on macOS 26 and later; `RootView` does not layer another glass sheet over it. Earlier systems receive `LegacySidebarMaterialBackground`, an AppKit visual-effect fallback. Explicit glass remains on controls: the mode rail is one capsule with a neutral moving selection highlight, readable symbols, selected accessibility traits and a separate key-window keyboard-focus outline. Reduce Motion disables its selection animation. See [UI Design Principles](/openwiki/concepts/ui-design-principles.md) for row foreground and active/inactive selection roles.

The tool modes are projections of the **current window and focused pane**, not new destinations. Snippets searches the shared host-library snippets in its own footer, inserts into a live focused SSH/Telnet terminal on a single click, and double-click execution of a risky command asks for a second confirmation. History chooses SSH command history, SFTP browse history, or connection history from the focused pane; it uses the native `ListViewKit`-backed `SidebarNativeList` for stable card geometry and blank-area context menus. Snippet package folding is a persisted sidebar-only preference, separate from expansion on the main Snippets page. The snippet and history footer fields are not the titlebar Find field.

Keep the following coordinates distinct:

- **Destination**: Vault, a workspace, full Assistant, Metrics or Settings.
- **Sidebar mode**: what occupies the one shared left column.
- **Focused pane**: the session targeted by workspace commands.
- **Presentation route**: an editor, chooser, sheet, or other transient interaction.

They influence one another, but they are not interchangeable selections. `WindowModel` remembers return destinations for reversible trips to Assistant and Settings. If the remembered Assistant workspace has closed, Navigator falls back to Vault. Page searches, selections and archive presentation are window-local, so two windows may inspect the same shared data differently. The workspace collection and recoverable close stack live in its `WorkspaceDeckModel`; the `WindowSidebarState`, `WindowPresentationState` and `WorkspaceDragState` isolate the column, transient routes and live drag payload from session ownership.

### Navigator interactions and workspace lifetime

`WorkspaceNavigatorView` is an AppKit-backed SwiftUI `List` of Welcome, Metrics, Vault pages, Workspaces and Settings. A workspace row selects its workspace without starting a drag; the close affordance closes that workspace (Option-click closes the others). Its context menu can save/update a template, rename/reset eligible names, separate split panes, duplicate or split combinable sessions, move a workspace to another window, or close one/others/all. Context actions that operate on the selected pane first select the row's workspace. Section expansion is stored with `@AppStorage` and selecting a Vault page or workspace expands the corresponding section; this is sidebar presentation state, not the workspace collection.

Inline rename seeds the editor with `workspace.title(in: app.hostLibrary, locale: locale)` **before** activating the rename field; commit sends the text to `WindowModel.rename`, cancel discards it. The model refuses non-renameable workspaces and trims whitespace: split names belong to the workspace, single-pane overrides to its pane; clearing restores an automatically allocated/derived name. This ordering matters because the native text field selects its initial text when focused. The visible-window `WorkspaceNavigatorRenameTests` exercise both the context-menu and double-click entrypoints and require the full existing title in the editable field.

The layout drop receiver overlays the `List`, rather than attaching a target behind its native rows. Workspace and pane drags carry IDs, but live `WindowModel.dragging` identifies the payload during native callbacks, even before another SwiftUI render. On macOS 26+, the workspace row uses `.draggable` and the **active** native drag session sets this state from the pasteboard; querying a writer after a click must not start a drag. Earlier systems set it with `.onDrag`. Row/header frames are measured in global coordinates, translated at the receiver, then insertion geometry excludes the dragged workspace from the mutation index. A valid drop reorders with `move` or lifts a pane from a split workspace with `detachPane`; a lone pane cannot detach. Drops outside the Workspace section or after switching away from Navigator are rejected, and successful drops clear drag state. Older systems may retain drag state after a release outside any target until the next click or drag, so receivers still validate the pasteboard. See `WorkspaceNavigatorDropTests` for native drag, scrolled insertion previews, immediate callbacks, mode-change rejection and pane detachment.

### Toolbar commands follow the detail, not the mode rail

The window titlebar contributes creation actions from `WindowModel.creationActions` for the **foreground destination**: a single action is a plus button, several form a New menu, and Settings/Metrics detail can replace that position with Back or contextual controls. A Vault row's context menu calls `creationActions(for:)` through `creationMenu(for:locale:)`, so it can offer that page's creation verbs even when another page is in front. Switching the sidebar from Navigator to Assistant does not change the titlebar's New or Find target.

`WindowModel.findKind` resolves the foreground Vault page, full Assistant, Metrics list/process detail, or the **focused** SSH/Telnet/Serial terminal or SFTP pane. Welcome has its own content search and no titlebar Find; Settings and unsearchable panes offer none. `findContext()` binds the toolbar to the actual page/window query or session query, with SSH/Serial terminal navigation and cancel callbacks. A focused Telnet pane reports `.terminal` from `findKind` and `focusToolbarFind()` presents its terminal search, but `findContext()` currently has no Telnet binding: unlike SSH/Serial it cannot render a usable titlebar field through that path. Per-page queries survive page switches. `TermindCommands` routes Find to the focused window model, which stands down pane focus *before* presenting terminal search, increments the focus request and invokes the mounted toolbar field's focus handler. Welcome instead increments its content-field request; with no searchable target it does nothing.

```mermaid
sequenceDiagram
    participant Command as Find command
    participant Model as WindowModel
    participant Toolbar as Toolbar search
    participant Pane as Focused pane
    Command->>Model: focusToolbarFind
    alt Welcome content search
        Model->>Model: request Welcome field focus
    else Searchable foreground content
        Model->>Pane: suppress pane keyboard claim
        Model->>Pane: present terminal find if applicable
        Model->>Toolbar: request focus through installed handler
        Toolbar->>Model: bind query and report keyboard ownership
    end
```

Find ownership flows through the active window; the sidebar mode does not choose the query.

On macOS 26+, a background `WindowToolbarSearchHost` supplies the system `.searchable` item without changing the persistent split-view branch; the toolbar slot itself is fixed by OS availability, not by navigation. On earlier macOS versions, `WindowToolbarLegacySearch` supplies a retained `NSSearchField` (or a compact Metrics-detail popover). The field owner and coordinator preserve editing/focus across toolbar bridge updates, handle terminal Return/Shift-Return and Escape, and release keyboard ownership on a real user exit so the pane can reclaim focus. Reserve toolbar height even when no Find target is available: removing the entire item would resize the content when switching destinations.

## Persistent workspace deck: hidden is not destroyed

Every open workspace remains a child of `PersistentWorkspaceDeckLayout`. The selected workspace becomes visible and interactive; parked workspaces are transparent, disabled, excluded from hit testing and hidden from accessibility. Other top-level destinations are overlaid in front of that deck.

The layout maintains a size cache keyed by workspace identity:

1. The active workspace receives the current container size and updates its cached size when usable.
2. A hidden workspace keeps its last visible size.
3. A never-visible workspace captures the first finite, positive parking size.
4. Closed workspace IDs are pruned from the cache.

This is both a lifecycle rule and a layout-performance rule. Keeping views mounted protects terminal grids, scrollback and SFTP state; parking their geometry avoids recursively resizing every hidden split tree during a sidebar animation. Merely changing opacity would not prevent hidden views from receiving new layout proposals.

```mermaid
sequenceDiagram
    participant User
    participant Window as WindowModel
    participant Root as RootView
    participant Deck as PersistentWorkspaceDeckLayout
    User->>Window: select Assistant or another workspace
    Window->>Root: selected destination changes
    Root->>Deck: update active workspace flags
    Deck->>Deck: park hidden workspaces at cached sizes
    Root->>Root: show selected destination and gate interaction
    Note over Window,Deck: Session ownership is retained
    User->>Window: return to workspace
    Deck->>Deck: lay out active workspace at current size
```

Do not replace this with an `if selected { WorkspaceContentView(...) }` that recreates the terminal hierarchy. Equally, do not let parked workspaces handle invisible keyboard shortcuts: broadcast and terminal-find shortcut owners are explicitly disabled unless their workspace is active.

The floating status bar overlays the current workspace rather than docking below it. This avoids changing the pane's available height when entering a workspace. Command-generation feedback reserves clearance above that capsule instead of competing for the same bottom edge.

## Split panes: stable identities, explicit fractions

`WorkspaceContentView` renders the model's recursive `SplitNode`: a leaf produces a stable-ID `PaneView`, while a branch produces a `SplitBranchView`. Branch geometry comes from its stored fraction rather than the divider state of a native `HSplitView` or `VSplitView`. That makes drop previews and later proportional resizing use the same model.

During divider dragging, a local preview fraction drives geometry. The gesture uses global coordinates and commits the model change once, instead of publishing the entire workspace tree for every mouse event. The divider's visible hairline and its wider hit region are separate design decisions.

Pane dragging also separates **preview** from **mutation**. The dragged branch is temporarily omitted from the preview geometry while its source view stays mounted; removing the native drag source can terminate the drag before it reaches the Navigator. The model tree changes only when the drop lands. `RootView` deliberately has no ancestor drop target that would compete with pane and Navigator targets for the same internal text payload.

## Vault and management pages

Vault management is a list/detail workspace, not a collection of unrelated sheets. `VaultWorkspaceContent` keeps the list and editor children stable across its width breakpoint:

- With enough space, the list and a fixed-width detail editor appear together.
- In a narrow detail region, the editor covers the list; the list retains its last visible size and state.
- Editor presentation animates position and reserved space, not the form's own width.

Resource pages plug into `ManagedCardPage` using typed sections, stable item IDs, externally owned selection, capabilities and page-specific presentation modifiers. `ManagedCardPageRenderer` handles the reusable interaction machinery; the page supplies business cards, section headers, drag ghosts, empty/no-results states and blank-canvas menu entries.

```mermaid
flowchart LR
    Feature[Resource-specific managed page] --> Spec[Sections / selection / capabilities]
    Feature --> Views[Cards / headers / empty states]
    Spec --> Renderer[ManagedCardPageRenderer]
    Views --> Renderer
    Renderer --> Geometry[CardPage and drop geometry]
    Geometry --> Intent[Stable IDs and destination sibling]
    Intent --> Action[Page-owned move or business action]
```

The renderer resolves a pointer to a section and insertion slot; it does not need to know what a Host, key or snippet means. Selection and deletion state stay with their appropriate owners. Creation belongs in the window toolbar and contextual blank-area menus rather than reintroducing a special “New” tile into each data grid.

## Assistant: route state and native rendering are separate

The full Assistant destination and the workspace's compact Assistant are different presentation surfaces. Opening a conversation in the compact sidebar does not replace the foreground terminal. Its transcript region and interaction/composer region can be composed separately, and terminal context/actions are passed deliberately.

Archive presentation is one `WindowModel.isAssistantArchivePresented` flag shared by these two surfaces within the window, not a second flag on `WindowSidebarState` and not app-wide navigation state. Conversation selection remains surface-specific. `AssistantConversationMenuSurface` reads the current shared flag when constructing the native blank-area menu, so both **Show Archive** checkmarks agree. Its action still respects the invoking surface: the sidebar route clears the compact conversation and shows the archive without replacing the foreground workspace; the full-screen route clears compact selection and selects the Assistant destination. Opening or closing a compact conversation clears the shared archive flag, and the compact archive's **Open Full Screen** control explicitly promotes the archive to the main destination.

Native transcript ownership adds another boundary:

- `TranscriptListCache` is window-local.
- Its key includes **conversation ID and surface** (`fullScreen` or `sidebar`), because one AppKit view cannot have two superviews.
- A persistent owner retains the native list, presentation state, measured row heights and Markdown-related caches while a short-lived SwiftUI mount comes and goes.
- The default LRU target is eight owners. Trimming evicts unmounted owners and protects the just-requested owner; if all candidates are mounted, it does not force their eviction merely to meet the target.

Do not merge this cache with the persistent workspace deck. Both preserve continuity, but workspaces remain mounted with parked geometry while transcripts can unmount their native list and remount a retained owner.

Escape handling is also scoped. In the compact Assistant, an approval or user-interaction form can own Escape; resolving it must not let the same key event fall through and close the conversation. The view captures the blocking-interaction state for that render before applying its back policy.

## Connection history projections and pane lifetime

Desktop connection history is shared app data with two deliberately different projections. Welcome shows recent Hosts derived only from events whose stable `sourceDeviceID` matches this installation, so synchronized activity from another Mac does not reorder the local launch surface. Its row timestamp is likewise the newest local event. Deleting a Welcome recent clears every connection-history event for that Host, across protocols and synchronized devices, without deleting the Host. The contextual History sidebar instead shows the newest 100 matching events from the complete synchronized timeline. Each row keeps the protocol in its leading symbol and resolves the source device's current display name through the app-wide `DeviceDirectoryModel`; the event does not capture a hostname. Removing a row deletes only that event, while **Clear History** clears the complete timeline.

An event follows the pane's usage lifetime rather than every physical reconnect. `WindowModel` assigns history tracking only to saved-host SSH, Telnet and SFTP panes; local Serial panes and unsaved external targets never enter this timeline. Closing a pane or workspace records `endedAt` before disconnecting its transport. Moving a live pane between workspaces preserves the same event, and reopening a closed workspace creates a new event. A process crash can leave `endedAt` absent rather than inventing an inaccurate end time.

## Desktop design principles and change checklist

The implemented patterns suggest these rules for extending TFM:

1. **One owner for each kind of state.** Shared app data, window routes, workspace sessions, native view caches and temporary gestures have different lifetimes.
2. **Preserve continuity without keeping everything active.** Park layout, disable invisible interaction, and bound expensive native caches.
3. **Make geometry predictable.** Reuse stored split fractions and stable identities; do not let an animation resize editor content incidentally.
4. **Use native desktop affordances.** Window-focused commands, keyboard equivalents, pointer selection, context menus and precise drop targets belong in the desktop composition.
5. **Keep generic renderers capability-driven.** Share interaction machinery without moving resource-specific mutation or authorization into it.
6. **Make reversible navigation explicit.** A trip to Settings or Assistant should not silently discard the workspace the user was using.

Before changing a UI owner, trace both what happens when its view disappears and what happens when the user explicitly closes its runtime. Those are different events.

## Verification map

| Change | Focused seams |
| --- | --- |
| Scene ownership, workspace moves, window close or return routes | `TermindApp`, `MainWindowCoordinator`, `MultiWindowTests`, `WindowStateTests`, `SettingsNavigationTests`. |
| Sidebar modes, Navigator rename or layout drops | `WindowSidebarTests`, `WorkspaceNavigatorRenameTests` (visible-window), `WorkspaceNavigatorDropTests` (some visible-window cases), `WorkspaceLayoutDropTests`. |
| Shared Assistant Archive state and surface-aware blank-area menus | `AssistantConversationMenuTests.archiveStateIsSharedWhileSidebarActionKeepsWorkspaceInFront` and `WindowStateTests` compact/full-screen navigation cases. |
| Hidden workspace layout or drag geometry | `PersistentWorkspaceDeckLayoutTests`; split/pane interaction and broadcast tests. |
| Narrow editor or Metrics detail layout | `ResponsivePageLayoutTests`, including native table identity and retained scroll positions. |
| Managed selection/reordering | `ManagedCardDropResolver`, selection and marquee tests; resource-specific move tests. |
| Transcript persistence, incremental updates or mounting | `TranscriptListViewTests`, rendering and performance suites. |
| Focused toolbar and terminal commands | `WindowToolbarFindTests` pins foreground/focused-pane routing, Welcome focus and per-page queries; `TerminalFindTests` and `UserInputModalityTests` cover terminal interaction. |
| Welcome Recents, connection-history limits or pane close tracking | `ConnectionHistoryTests`, `VaultSyncTests`, and workspace close/reopen tests. |

Some rendering tests explicitly require a visible window; routine checks should not enable those globally. The narrow-editor rendering cases cover English, Simplified Chinese and Traditional Chinese. This guide was derived from implementation and tests; it does not report a new test run or visual approval. Use [Build, Test, and Release Operations](/openwiki/operations/build-test-and-release.md) for the appropriate verification commands.
