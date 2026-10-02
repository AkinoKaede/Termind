---
type: architecture guide
title: macOS UI and Workspace Ownership
description: How macOS window navigation, sidebar modes, workspace sessions and Vault editing routes divide responsibility between AppModel and WindowModel.
tags: [macos, ui, navigation, workspaces, swiftui, appkit, vault]
verified:
  - by: openwiki/0.5.2
    at: 2026-10-01T23:39:56.631Z
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
  - id: openwiki-source-02eecf143fd9df60be910051
    resource: repo://TFM/Features/Hosts/HostsPageView.swift
  - id: openwiki-source-cfe2a6b22338023c37a5b503
    resource: repo://TFM/Features/Settings/SettingsPageView.swift
  - id: openwiki-source-0854be84b166268626a3cb08
    resource: repo://TFM/Features/Sidebar/WindowSidebarView.swift
  - id: openwiki-source-507cd94a8ae82f840ac8591f
    resource: repo://TFM/Features/Vault/VaultView.swift
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
  - id: openwiki-source-9f99d64c8fdba496051cd3ce
    resource: repo://TFM/Platform/MainWindowSizeStore.swift
  - id: openwiki-source-5e2670d68f19777e2dd312ea
    resource: repo://TFM/UI/Components/WindowToolbar.swift
  - id: openwiki-source-29722107a3a9d938ca19ebb4
    resource: repo://TFM/UI/Components/WorkspaceLayoutDragSource.swift
  - id: openwiki-source-f941c4bd7cfa47476dcdb53f
    resource: repo://TFM/UI/Components/WorkspaceLayoutDropTarget.swift
  - id: openwiki-source-7e279101ce56c0b482381df4
    resource: repo://TFM/UI/Components/WorkspaceNavigatorDragAnimation.swift
  - id: openwiki-source-f6a967b4f14bf50d1af51b8b
    resource: repo://TFM/UI/Managed/ManagedCardPage.swift
  - id: openwiki-source-23acce6fe9173a886d433b44
    resource: repo://TFMTests/AssistantConversationMenuTests.swift
  - id: openwiki-source-38f1f2c3597d520d66dcdd62
    resource: repo://TFMTests/CardMarqueeSelectionTests.swift
  - id: openwiki-source-78797a18dd3153d23a2c42e2
    resource: repo://TFMTests/ChatComposerStateTests.swift
  - id: openwiki-source-0f45576cff16b6adfcaeefc0
    resource: repo://TFMTests/MainWindowSizingTests.swift
  - id: openwiki-source-a22920a2a9767ac44e072c9f
    resource: repo://TFMTests/MultiWindowTests.swift
  - id: openwiki-source-98505b843db3ce6b8e4ca024
    resource: repo://TFMTests/PersistentWorkspaceDeckLayoutTests.swift
  - id: openwiki-source-dceb8d7e7c5bb09359e70052
    resource: repo://TFMTests/ResponsivePageLayoutTests.swift
  - id: openwiki-source-44cb7a6172854edbfc9b5ccb
    resource: repo://TFMTests/SettingsNavigationTests.swift
  - id: openwiki-source-578f30372fe67f8688f44b76
    resource: repo://TFMTests/WindowStateTests.swift
  - id: openwiki-source-91826a88f242f001f33fff89
    resource: repo://TFMTests/WindowToolbarFindTests.swift
  - id: openwiki-source-a3093a0c1d98ecc1cdbc0279
    resource: repo://TFMTests/WorkspaceNavigatorDropTests.swift
  - id: openwiki-source-05f0aeba12df8388b97b3c76
    resource: repo://TFMTests/WorkspaceNavigatorRenameTests.swift
  - id: openwiki-source-a48980e81bab99fcd643df54
    resource: repo://TFMTests/WorkspaceWindowMoveTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-10-01T23:39:56.631Z" }
---

# macOS UI and Workspace Ownership

TFM uses SwiftUI for composition and AppKit-backed surfaces where native identity, focus, text handling or incremental rendering matters. Its central design is **one Navigator column and one persistent detail deck per window**, not a separate horizontal tab system for every feature.

This guide describes the current implementation. See [TFI Mobile UI Architecture](/openwiki/architecture/mobile-ui.md) for the different mobile shell and [UI Design Principles](/openwiki/concepts/ui-design-principles.md) for the sharing boundary.

## Code structure: composition and ownership

Solid arrows below mean composition/ownership or routing, not necessarily inheritance. The model branch is shown separately because a view appearing in the diagram does not own every runtime it displays.

```mermaid
flowchart TD
    App[TermindApp] --> Shared[AppModel and application services]
    App --> Scene[Main WindowGroup]
    Scene --> Consent{"Diagnosis consent needed"}
    Consent -->|Yes| Diagnosis[DiagnosisConsentView]
    Consent -->|No| Root[RootView]
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

Window composition and state ownership; the deck stays mounted beneath foreground destinations.

The main layers are:

| Layer | Responsibility | What should not move into it |
| --- | --- | --- |
| App composition | Persistence container, shared service graph, launch locale, main and external-authentication scenes, application commands. | One window's selected pane, query, or editor route. |
| `WindowModel` | Workspace collection, selected destination, sidebar mode, presentation routes, page selection/search state, transcript cache and connection-service wiring. | A process-global assumption that all windows share the same active session. |
| Workspace and pane models | Live session ownership, pane identity, split tree, focused pane and workspace-specific command context. | Temporary divider-drag coordinates or a view's hover state. |
| Feature views | Render projected state, present interaction, dispatch intent to owners. | Recreating connections merely because a destination appears. |
| Reusable renderers and native bridges | Collection interaction, layout, focus/native mounting, terminal/transcript presentation. | Resource-specific repository mutations hidden behind generic drawing code. |

`TermindApp` builds the persistence container and shared `AppModel` once. Its `WindowGroup(id: "main", for: UUID.self)` calls `makeWindow(requestID:)` when the diagnosis consent gate is cleared: ordinary and restored windows receive a fresh `WindowModel` (which starts at Vault/Welcome), while a debug screenshot launch without a request ID can receive a demo-configured model. While consent is required, the main scene shows `DiagnosisConsentView` instead of creating the workspace root. `RootView` stores the supplied instance in `@State` and exposes it through the environment and focused scene values so commands target the correct window. `AppModel.registerWindow` wires shared connections, histories, host and metrics services into that model and adopts the shared conversation store; its workspace list, queries, presentation routes and transcript cache remain window-local. The separate `Window` for external authentication shares app dependencies but is not a workspace scene; `.commandsRemoved()` keeps it out of normal scene-opening commands. The main scene uses the saved default window size and content minimum resizing; in debug builds XCTest normally suppresses automatic test windows unless `TERMIND_WINDOW_TESTS=1`, and tests or screenshot mode disable main-scene restoration. The device-local `MainWindowSizeStore` validates ordinary content sizes and sidebar widths before loading or saving them; without stored values it defaults to 1180×740, a 320-point sidebar and a visible sidebar. This fallback does not replace individual system-restored window frames.

`MainWindowRegistration` connects a real AppKit window to `app.mainWindows`. A **Move Workspace to New Window** action requests the UUID-valued main scene first; the source retains its live workspace until the destination registers. Only then does `MainWindowCoordinator` take it from the source and open it in the new model, preserving the running session rather than treating a move as a close/reopen. Closing a real window instead unregisters its model and `closeForWindow()` disconnects its workspaces and clears window-scoped caches. A restored scene has no pending move request and keeps its system-restored frame. The coordinator tracks normal-size and sidebar-width fallbacks from registered main windows, preferring the most recently used window; requested scenes inherit source layout, while restored windows are not forcibly resized. Full-screen requests carry the source's ordinary (pre-full-screen) size and wait until the new window is key before toggling; normal resizing avoids recording full-screen or transitional dimensions. Sidebar measurements only replace a requested preferred width once the native column actually reaches that width, and hiding the sidebar does not overwrite its last valid width. Main-window registration disallows native tabbing and configures full-size transparent titlebar content coordinates before measuring or applying a size. Requested frames respect minimum content dimensions and are fitted to the available screen; auxiliary windows do not participate in the saved fallback. See [Platform Runtime](/openwiki/architecture/platform-runtime.md) for app lifecycle and auxiliary windows.

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

Scene-request handoff: the source keeps the session until the target's native window registers.

A workspace move waits for native destination registration before changing ownership. Repeated requests to move the same workspace or pane from the same source reuse the pending scene request. If no scene factory exists, the request fails without removing the source workspace; closing the source before registration cancels its pending requests and disconnects its sessions, so a late destination cannot resurrect them. A pane moved to another window uses the same request mechanism: a split pane becomes a new workspace around the existing live pane, while a lone pane carries its original workspace and name. The detailed release, cancellation and animation rules are in [TFM Drag and Drop](/openwiki/workflows/desktop-drag-and-drop.md). [Source: `TFM/Platform/MainWindowCoordinator.swift` and `TFM/Features/Workspaces/WindowModel.swift`.]

## The window shell owns chrome once

`RootView` owns the balanced `NavigationSplitView`: `WindowSidebarView` is the single leading column and the detail holds a persistent workspace deck with Vault, Assistant, Metrics or Settings layered above it. The sidebar visibility binding reads and writes `window.showsSidebar`; column widths and the window minimum adjust for available width. The floating status bar appears only over a selected workspace. The root also owns the window toolbar, search host, native window registration, title reporting, Quick Open, onboarding and presentation bridges. It supplies one leading creation area, a principal Metrics page picker when applicable, and one Find slot following the content in front. `WindowActivityReader` reports the focused SSH remote title for the window and key-window activity without tying either to a transient pane view.

The sidebar is one column whose mode rail switches between Navigator, Assistant, Snippets and History. `WindowModel.activateSidebarMode` is an **intent operation**, not just a property assignment: choosing Navigator from the full Assistant restores its prior destination (or Vault if that workspace closed), while choosing Assistant inside a workspace opens the contextual sidebar rather than hiding the terminal. Direct mode assignment remains available for presentation/restoration without these navigation side effects. History is unavailable for focused Telnet/serial sessions; a rejected direct assignment leaves the mode unchanged, while reconciliation replaces an already-invalid History mode with Snippets.

The column's material belongs to the native split view on macOS 26 and later; `RootView` does not layer another glass sheet over it. Earlier systems receive `LegacySidebarMaterialBackground`, an AppKit visual-effect fallback that blends within the window and follows its active state. `DesignTokens.swift` centralizes fixed spacing, sidebar/card/toolbar geometry and minimum window dimensions as `Metrics`; semantic `TermindColor` roles adapt to appearance, while `Motion` and glass modifiers use system glass on macOS 26+ and native material on older systems. The split view constrains the sidebar to 260–520 points and protects a 360-point detail minimum; row selection is drawn explicitly, with key/inactive styling rather than relying on native `List(selection:)` colors. Explicit glass remains on controls: the mode rail is one capsule with a neutral moving selection highlight, readable symbols, selected accessibility traits and a separate key-window keyboard-focus outline. Reduce Motion disables its selection animation. See [UI Design Principles](/openwiki/concepts/ui-design-principles.md) for row foreground and active/inactive selection roles.

The tool modes are projections of the **current window and focused pane**, not new destinations. Snippets searches the shared host-library snippets in its own footer, inserts into a live focused SSH/Telnet terminal on a single click, and double-click execution of a risky command asks for a second confirmation. History chooses SSH command history, SFTP browse history, or connection history from the focused pane; it uses the native `ListViewKit`-backed `SidebarNativeList` for stable card geometry and blank-area context menus. Snippet package folding is a persisted sidebar-only preference, separate from expansion on the main Snippets page. The snippet and history footer fields are not the titlebar Find field.

Keep the following coordinates distinct:

- **Destination**: Vault, a workspace, full Assistant, Metrics or Settings.
- **Sidebar mode**: what occupies the one shared left column.
- **Focused pane**: the session targeted by workspace commands.
- **Presentation route**: an editor, chooser, sheet, or other transient interaction.

They influence one another, but they are not interchangeable selections. A workspace drag adds a fifth, temporary distinction: `selectedWorkspace` remains the command/selection owner, but `displayedWorkspace` can show the next (or previous) merge-capable neighbour when the selected combinable workspace is being dragged. This is a derived preview, not a selection or session transfer; clearing the drag restores the selected workspace, and a drag without an eligible neighbour leaves it displayed. `RootView` uses the derived workspace to decide which deck child is active, while Navigator highlights the displayed row. `WindowModel` remembers return destinations for reversible trips to Assistant and Settings. If the remembered Assistant workspace has closed, Navigator falls back to Vault. Settings navigation uses a window-local `SettingsRoute` hierarchy: toolbar Back walks to the parent, then restores the prior destination, falling back to Vault if its workspace was removed. `SettingsPageView` cleans up incomplete provider, MCP and skill drafts on route changes or disappearance rather than treating a hidden Settings page as a persistent editor. Page searches, selections and archive presentation are window-local, so two windows may inspect the same shared data differently. The workspace collection and recoverable close stack live in its `WorkspaceDeckModel`; the `WindowSidebarState`, `WindowPresentationState` and `WorkspaceDragState` isolate the column, transient routes and live drag payload from session ownership.

### Navigator interactions and workspace lifetime

`WorkspaceNavigatorView` is an AppKit-backed SwiftUI `List` of Welcome, Metrics, Vault pages, Workspaces and Settings. A workspace row selects its workspace without starting a drag; the close affordance closes that workspace (Option-click closes the others). Its context menu can save/update a template, rename/reset eligible names, separate split panes, duplicate or split combinable sessions, move a workspace to another window, or close one/others/all. Context actions that operate on the selected pane first select the row's workspace. Section expansion is stored with `@AppStorage` and selecting a Vault page or workspace expands the corresponding section; this is sidebar presentation state, not the workspace collection.

Inline rename seeds the editor with `workspace.title(in: app.hostLibrary, locale: locale)` **before** activating the rename field; commit sends the text to `WindowModel.rename`, cancel discards it. The model refuses non-renameable workspaces and trims whitespace: split names belong to the workspace, single-pane overrides to its pane; clearing restores an automatically allocated/derived name. This ordering matters because the native text field selects its initial text when focused. The visible-window `WorkspaceNavigatorRenameTests` exercise both the context-menu and double-click entrypoints and require the full existing title in the editable field.

Navigator layout interaction is window-scoped: `WindowModel.dragging` carries the live workspace or pane identity for the native `List` receiver, while workspace ordering and pane ownership change only on an accepted drop. The selected workspace remains the command owner during preview. The Navigator overlays the native rows with its receiver because an ancestor receiver would compete with pane targets. For drag-source behavior, geometry, cancellation and cross-window release cases, see [TFM Drag and Drop](/openwiki/workflows/desktop-drag-and-drop.md).

### Toolbar commands follow the detail, not the mode rail

The window titlebar contributes creation actions from `WindowModel.creationActions` for the **foreground destination**: a single action is a plus button, several form a New menu, and Settings/Metrics detail can replace that position with Back or contextual controls. A Vault row's context menu calls `creationActions(for:)` through `creationMenu(for:locale:)`, so it can offer that page's creation verbs even when another page is in front. Switching the sidebar from Navigator to Assistant does not change the titlebar's New or Find target.

`WindowModel.findKind` resolves the foreground Vault page, full Assistant, Metrics list/process detail, Settings **terminal themes** route, or the **focused** SSH/Telnet/Serial terminal or SFTP pane. Welcome has its own content search and no titlebar Find; other Settings routes and unsearchable panes offer none. `findContext()` binds the toolbar to the actual page/window query or session query, with SSH/Serial terminal navigation and cancel callbacks and SFTP query cancellation. A focused Telnet pane reports `.terminal` from `findKind` and `focusToolbarFind()` presents its terminal search, but `findContext()` currently has no Telnet binding: unlike SSH/Serial it cannot render a usable titlebar field through that path. Vault page queries and each Settings theme scheme's query survive route switches. `TermindCommands` routes Find to the focused window model, which stands down pane focus *before* presenting terminal search, increments the focus request and invokes the mounted toolbar field's focus handler. Welcome instead increments its content-field request; with no searchable target it does nothing.

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

Find command routing and keyboard handoff in the focused main window.

Find ownership flows through the active window; the sidebar mode does not choose the query.

On macOS 26+, a background `WindowToolbarSearchHost` supplies the system `.searchable` item when `findKind` exists, binds it to `findContext()` and reports presentation as keyboard ownership; when Find is unavailable it dismisses search and releases that claim. Because the host checks `findKind` rather than `findContext()`, Telnet still installs the system search affordance although its missing query binding reads as empty and ignores edits. Its Return and Escape handlers use the context's navigation/cancel callbacks when present. This host does not change the persistent split-view branch; the toolbar slot itself is fixed by OS availability, not by navigation. On earlier macOS versions, `WindowToolbarLegacySearch` supplies a retained `NSSearchField` (or a compact Metrics-detail popover). The field owner and coordinator preserve editing/focus across toolbar bridge updates, handle terminal Return/Shift-Return and Escape, and release keyboard ownership on a real user exit so the pane can reclaim focus. Reserve toolbar height even when no Find target is available: removing the entire item would resize the content when switching destinations.

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

Destination switching parks layout, not sessions or native workspace view identity.

Do not replace this with an `if selected { WorkspaceContentView(...) }` that recreates the terminal hierarchy. Equally, do not let parked workspaces handle invisible keyboard shortcuts: broadcast and terminal-find shortcut owners are explicitly disabled unless their workspace is active.

The floating status bar overlays the current workspace rather than docking below it. This avoids changing the pane's available height when entering a workspace. Command-generation feedback reserves clearance above that capsule instead of competing for the same bottom edge.

## Split panes: stable identities, explicit fractions

`WorkspaceContentView` renders the model's recursive `SplitNode`: a leaf produces a stable-ID `PaneView`, while a branch produces a `SplitBranchView`. Branch geometry comes from its stored fraction rather than the divider state of a native `HSplitView` or `VSplitView`. That makes drop previews and later proportional resizing use the same model.

During divider dragging, a local preview fraction drives geometry. The gesture uses global coordinates and commits the model change once, instead of publishing the entire workspace tree for every mouse event. The divider's visible hairline and its wider hit region are separate design decisions.

Pane interaction separates **preview** from **mutation**. The dragged branch is temporarily omitted from preview geometry while its source view stays mounted; the model tree changes only on an accepted drop. `RootView` deliberately has no ancestor drop target that would compete with pane and Navigator targets. See [TFM Drag and Drop](/openwiki/workflows/desktop-drag-and-drop.md) for receiver mechanics.

## Vault and management pages

Vault management is a list/detail workspace, not a collection of unrelated sheets. `VaultWorkspaceContent` keeps the list and editor children stable across its width breakpoint:

- With enough space, the list and a fixed-width detail editor appear together.
- In a narrow detail region, the editor covers the list; the list retains its last visible size and state.
- Editor presentation animates position and reserved space, not the form's own width.

`WindowModel` owns the selected Vault page and optional `vaultWorkRoute`: `openPage` clears the work route, `openVaultWork` selects a page and detail route, and `closeVaultWork` dismisses the detail. `VaultWorkDetailView` dispatches the route to a resource-specific editor; its identity is keyed to the route. The view-local `VaultWorkEditingSession` protects dirty inline editors during page or editor transitions: an editor registers its route, dirty predicate and async commit with a token; a matching dirty transition waits for Save, Discard or Cancel, while an unchanged or clean route proceeds immediately. Save only executes the deferred transition after a successful commit; a failed save cancels it. Stale editors cannot unregister a newer editor's registration. This guard is used by the resource pages when routing away from an editor, not as a blanket guard on every direct `WindowModel` assignment.

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

Managed-page rendering computes placement intent; the feature owns the resulting mutation.

The renderer resolves a pointer to a section and insertion slot; it does not need to know what a Host, key or snippet means. Selection and deletion state stay with their appropriate owners. Creation belongs in the window toolbar and contextual blank-area menus rather than reintroducing a special “New” tile into each data grid.

## Assistant: route state and native rendering are separate

The full Assistant destination and the workspace's compact Assistant are different presentation surfaces. Opening a conversation **from the contextual panel** does not replace the foreground terminal; the conversation navigator shown instead when no workspace is in front deliberately opens full Assistant. The compact surface composes its transcript and interaction/composer regions separately, passing focused-terminal context/actions deliberately. Conversation list reordering has its own native receiver and hidden-list participation rules; see the brief [Assistant drag flow](/openwiki/workflows/desktop-drag-and-drop.md#assistant-conversation-reordering).

The compact Sidebar and full Assistant share one window-local Chat/Archive route. `AssistantLibraryModel.selectedConversationID` identifies the open chat, while `WindowModel.isAssistantArchivePresented` overrides it for Archive; entering Archive or returning to the chat landing state clears the selected conversation so the two surfaces cannot diverge. **Contextual panel** list, Archive and Back actions (`openAssistantInSidebar`, `showAssistantArchiveInSidebar`, `closeAssistantInSidebar`) change that route without replacing the workspace. By contrast, the full Assistant navigator and its footer, the blank-area New Chat menu on either surface, and the compact panel's explicit expand button select the full Assistant destination. The compact panel's blank-area Archive menu stays in the workspace. `openAssistantFullScreen` also selects the Assistant sidebar mode. Closing the last workspace promotes a selected compact chat or Archive when Assistant mode is selected; an empty chat landing state instead returns to Vault. The contextual Sidebar draft and focused-session context remain Sidebar-owned, and transcript owners remain keyed by conversation plus surface, so navigation is shared without merging draft or native-rendering lifetimes.

Native transcript ownership adds another boundary:

- `TranscriptListCache` is window-local.
- Its key includes **conversation ID and surface** (`fullScreen` or `sidebar`), because one AppKit view cannot have two superviews.
- A persistent owner retains the native list, presentation state, measured row heights and Markdown-related caches while a short-lived SwiftUI mount comes and goes.
- The default LRU target is eight owners. Trimming evicts unmounted owners and protects the just-requested owner; if all candidates are mounted, it does not force their eviction merely to meet the target.

Do not merge this cache with the persistent workspace deck. Both preserve continuity, but workspaces remain mounted with parked geometry while transcripts can unmount their native list and remount a retained owner.

Escape handling is also scoped. In the compact Assistant, an approval or user-interaction form can own Escape; resolving it must not let the same key event fall through and close the conversation. The view captures the blocking-interaction state for that render before applying its back policy.

## Connection history projections and pane lifetime

Desktop connection history is shared app data with two deliberately different projections. Welcome shows recent Hosts derived only from events whose stable `sourceDeviceID` matches this installation, so synchronized activity from another Mac does not reorder the local launch surface. Its row timestamp is likewise the newest local event. Deleting a Welcome recent clears every connection-history event for that Host, across protocols and synchronized devices, without deleting the Host. The contextual History sidebar instead shows the newest 100 matching events from the complete synchronized timeline. Each row keeps the protocol in its leading symbol and resolves the source device's current display name through the app-wide `DeviceDirectoryModel`; the event does not capture a hostname. Device synchronization invalidates the directory cache, and a successful local rename also invalidates it, so subsequent lookups use updated names. Directory reads and writes expose `storageError` instead of throwing into the sidebar: a failed load produces no cached devices, a failed rename leaves the old local name unchanged, and a missing device name renders as “—” in the row (the current device can fall back to its local name). Removing a row deletes only that event, while **Clear History** clears the complete timeline.

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
| Scene ownership, sizing, workspace moves, window close or return routes | `TermindApp`, `MainWindowCoordinator`, `MainWindowSizingTests` (stored fallback validation, source-size inheritance, restored frames, sidebar width handshake and visible full-screen behavior), `MultiWindowTests`, `WorkspaceWindowMoveTests` (live pane identity and history, lone-pane name, late-registration rejection), `WindowStateTests`, `SettingsNavigationTests`. |
| Sidebar modes, Navigator rename or layout drops | `WindowSidebarTests`, `WorkspaceNavigatorRenameTests` (visible-window), `WorkspaceNavigatorDropTests` (some visible-window cases), `WorkspaceLayoutDropTests`. |
| Shared Assistant Archive state and surface-aware blank-area menus | `AssistantConversationMenuTests.archiveStateIsSharedWhileSidebarActionKeepsWorkspaceInFront` and `WindowStateTests` compact/full-screen navigation cases. |
| Hidden workspace layout or drag geometry | `PersistentWorkspaceDeckLayoutTests`; split/pane interaction and broadcast tests. |
| Narrow editor, dirty Vault route transitions or Metrics detail layout | `ResponsivePageLayoutTests` checks narrow and resized editor identity/geometry; `CardMarqueeSelectionTests.vaultEditingSessionOffersSaveDiscardAndCancelForDirtyRoutes` checks clean, dirty, token replacement and save/discard/cancel transitions. |
| Managed selection/reordering | `ManagedCardDropResolver`, selection and marquee tests; resource-specific move tests. |
| Transcript persistence, incremental updates or mounting | `TranscriptListViewTests`, rendering and performance suites. |
| Focused toolbar and terminal commands | `WindowToolbarFindTests` pins foreground/focused-pane routing, Welcome focus, per-page queries and the theme-scheme Settings Find route; `TerminalFindTests` and `UserInputModalityTests` cover terminal interaction. |
| Welcome Recents, device names, connection-history limits or pane close tracking | `ConnectionHistoryTests` checks local-only recents, stable device IDs and rename lookup; `VaultSyncTests` and workspace close/reopen tests cover synchronization and pane lifetime. |

Some rendering tests explicitly require a visible window; routine checks should not enable those globally. The narrow-editor rendering cases cover English, Simplified Chinese and Traditional Chinese. This guide was derived from implementation and tests; it does not report a new test run or visual approval. Use [Build, Test, and Release Operations](/openwiki/operations/build-test-and-release.md) for the appropriate verification commands.
