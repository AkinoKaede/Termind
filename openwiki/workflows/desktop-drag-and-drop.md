---
type: interaction workflow
title: Desktop Drag and Drop
description: Desktop managed-card drag lifecycle, full-size previews, insertion placeholders, and the boundary between presentation and reorder persistence. Also covers native workspace and pane dragging, cancellation, and deferred window ownership transfer.
tags: [macos, tfm, drag-and-drop, managed-cards, workspaces, panes, appkit, lifecycle, testing]
sources:
  - id: openwiki-source-685b7f8e7dbcf91b4e2a50e2
    resource: repo://Frameworks/TermindApplication/Agent/AssistantConversationOperations.swift
  - id: openwiki-source-160f180df5d3cb1457febfee
    resource: repo://Frameworks/TermindApplication/Agent/AssistantLibraryModel.swift
  - id: openwiki-source-c375092b23c70ace642fdbd7
    resource: repo://Frameworks/TermindApplication/Terminal/RemoteSessionCloseCoordinator.swift
  - id: openwiki-source-247755d873c5d94b0a364217
    resource: repo://FrameworkTests/AssistantConversationOperationsTests.swift
  - id: openwiki-source-ffc9054d578eba7be684b885
    resource: repo://FrameworkTests/SessionPersistenceTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-d35453512ef488d0cacdc06e
    resource: repo://TFM/Features/Assistant/AssistantView.swift
  - id: openwiki-source-7e796927b780e67cc73f6a5b
    resource: repo://TFM/Features/Terminal/SSHSessionModel.swift
  - id: openwiki-source-564c1a0cc523e70840b9fc66
    resource: repo://TFM/Features/Workspaces/PaneLayoutDropController.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-6551e1821f08f37b10dfe7fa
    resource: repo://TFM/Features/Workspaces/Workspace.swift
  - id: openwiki-source-931aff66b28d38cd69ce2324
    resource: repo://TFM/Features/Workspaces/WorkspaceContentView.swift
  - id: openwiki-source-7e364c6182a8339831ecab24
    resource: repo://TFM/Features/Workspaces/WorkspaceNavigatorView.swift
  - id: openwiki-source-22e92f96394f292a731fc6fb
    resource: repo://TFM/Platform/MainWindowCoordinator.swift
  - id: openwiki-source-dad03c68d6b805a4170ffc02
    resource: repo://TFM/Platform/WorkspaceCloseConfirmation.swift
  - id: openwiki-source-6bb48fd98bdef02c39562aed
    resource: repo://TFM/UI/Components/WorkspaceDragCancellationTracker.swift
  - id: openwiki-source-29722107a3a9d938ca19ebb4
    resource: repo://TFM/UI/Components/WorkspaceLayoutDragSource.swift
  - id: openwiki-source-f941c4bd7cfa47476dcdb53f
    resource: repo://TFM/UI/Components/WorkspaceLayoutDropTarget.swift
  - id: openwiki-source-7e279101ce56c0b482381df4
    resource: repo://TFM/UI/Components/WorkspaceNavigatorDragAnimation.swift
  - id: openwiki-source-8b520d36db484724deec3cf9
    resource: repo://TFMTests/AssistantConversationListDropTests.swift
  - id: openwiki-source-a08489338be00125d646c77e
    resource: repo://TFMTests/VisibleWindowTestTrait.swift
  - id: openwiki-source-d798805795e92534f3b13250
    resource: repo://TFMTests/WorkspaceCloseConfirmationTests.swift
  - id: openwiki-source-0ce84eda65c7f30273adfaa1
    resource: repo://TFMTests/WorkspaceDragCancellationTests.swift
  - id: openwiki-source-9a16ecbd92b03f0bdf831159
    resource: repo://TFMTests/WorkspaceLayoutDragSourceTests.swift
  - id: openwiki-source-1c583949c6f00d5acc015c90
    resource: repo://TFMTests/WorkspaceLayoutDropTests.swift
  - id: openwiki-source-9f742877a2683260dbcf1f45
    resource: repo://TFMTests/WorkspaceNavigatorDragAnimationTests.swift
  - id: openwiki-source-a3093a0c1d98ecc1cdbc0279
    resource: repo://TFMTests/WorkspaceNavigatorDropTests.swift
  - id: openwiki-source-a48980e81bab99fcd643df54
    resource: repo://TFMTests/WorkspaceWindowMoveTests.swift
generated: { by: "openwiki/0.7.0", at: "2026-10-25T22:25:01.745Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-25T22:25:01.745Z
---

# Desktop Drag and Drop

## Managed-card dragging: presentation is not persistence

Desktop manager pages share `ManagedCardPageRenderer`, which owns drag-session state, pointer-to-slot resolution and temporary omission of moving cards. Business pages supply actual card views, selection hooks and optional reorder capabilities. **The floating preview, the insertion gap and the saved order are three different things.** Changing preview rendering must not change model move semantics. Mobile reorder ownership is documented in [Mobile UI Architecture](../architecture/mobile-ui.md); this renderer is the desktop interaction path.

### Lift, hover, commit and cleanup

```mermaid
sequenceDiagram
    participant Card as Actual card
    participant Renderer as ManagedCardPageRenderer
    participant Session as Drag presentation state
    participant Resolver as ManagedCardDropResolver
    participant Model as Page move callback
    Card->>Renderer: onDrag when reordering is enabled
    Renderer->>Session: Capture ordered IDs and lift sizes
    Renderer-->>Card: Explicit full-size actual-card preview
    Renderer->>Session: After 100 ms omit moving IDs if session still matches
    Renderer->>Resolver: Hover with eligible sections and remaining items
    Resolver-->>Session: Section and insertion index
    alt Valid drop
        Renderer->>Model: Move IDs into section before next remaining ID
        Renderer->>Session: Clear session, omissions and placeholder
    else Invalid drop
        Renderer->>Session: Clear drag state without a move
    else Release outside destinations
        Card->>Renderer: Next normal page tap
        Renderer->>Session: Clear drag state
    end
```
The managed-card lifecycle keeps hover geometry local and invokes the business move only on a resolved drop.

- **Batch identity:** dragging a selected item uses selected visible items in page order; dragging an unselected item uses that item alone. With `.sameSection`, the batch is restricted to the source section. `ManagedCardDragSession` captures nonempty measured sizes at lift; unmeasured members use the source-card fallback (or minimum card width and height if its frame is unavailable).
- **Temporary layout:** the initial slot counts preceding nonmoving cards. After the guarded 100 ms delay, moving IDs are omitted from displayed sections. The adaptive `CardGrid` can reflow, but each moving item's placeholder retains its captured height. `ManagedCardReorderPlaceholder` is clear, noninteractive and accessibility-hidden: it paints neither card content, surface nor border. It is not a faded copy of the floating card.
- **Target resolution:** top content is excluded; sections must accept drops, satisfy the page policy and have measured frames. Moving IDs are removed before indexing. The resolver picks the nearest section vertically, uses card row bounds and horizontal midpoints for insertion, and places a drop on a collapsed section at its end. Leaving the receiver clears the insertion location, not the whole session.
- **Commit and cancellation:** the text provider carries the source item's ID string, but the move uses the renderer's local session IDs, not decoded external text. The delegate's type gate alone is not a valid reorder: location resolution also requires a live session. A valid drop converts the index into the next remaining stable ID (`nil` at the end), calls `move`, then clears presentation state. An invalid drop clears without moving. This SwiftUI path has no AppKit drag-ended observer; a release outside all valid destinations is restored on the next normal page tap, not via the workspace tear-off mechanism below.

Evidence: [session and resolver](../../TFM/UI/Managed/ManagedCardPage.swift#L179-L240), [renderer and drop lifecycle](../../TFM/UI/Managed/ManagedCardPage.swift#L293-L574), [adaptive grid](../../TFM/UI/Managed/CardGrid.swift#L528-L550).

### Full-size preview and standalone surface

`draggableCard` reuses the **actual business card** in the explicit `.onDrag` preview rather than a compact title surrogate or an insertion placeholder. `ManagedCardDragPreview` fixes width and height to the session size (falling back to the measured frame), disables hit testing, hides the preview from accessibility, and marks its subtree with `managedCardIsDragPreview`. The renderer explicitly forwards its captured `EnvironmentValues` into the preview, preserving the environment needed by business cards outside the normal page hierarchy. The source comment identifies macOS 27 default glass snapshots with an oversized prohibited-operation badge as the reason not to rely on the default snapshot.

`CardTile` consumes the preview flag. Normal cards retain interactive glass; preview cards instead draw a rounded `TermindColor.windowSurface` with the selected accent tint when applicable. Native glass needs a live backdrop, so the drag image needs this self-contained fallback. Clipping and the existing selection border remain in place. Preview cards cannot become Return-key focus targets and receive a nil card-geometry store, preventing their detached geometry from contributing to the page's marquee hit map.

The page's blank-area marquee is a native overlay that rejects card and control/header hits before interaction begins, rather than an ancestor SwiftUI `DragGesture` competing with `.onDrag`. Preserve that division when changing selection behavior. See [UI Design Principles](../concepts/ui-design-principles.md) for the wider presentation contract.

Evidence: [explicit preview and environment](../../TFM/UI/Managed/ManagedCardPage.swift#L390-L417), [preview wrapper and clear slot](../../TFM/UI/Managed/ManagedCardDragPreview.swift), [CardTile preview surface and isolation](../../TFM/UI/Managed/CardGrid.swift#L558-L646), [marquee arbitration](../../TFM/UI/Managed/CardGrid.swift#L189-L221).

### Which pages actually reorder?

All six callers use the inherited renderer and `CardGrid`; sharing the surface does **not** automatically enable dragging.

| Caller | Actual card and reorder boundary |
| --- | --- |
| [Hosts](../../TFM/Features/Hosts/HostsPageView.swift#L119-L220) | `HostCard`; unfiltered pages use `.anySection`, calling `app.hostLibrary.move(hostIDs:into:before:)` for group or ungrouped placement. Results cannot accept drops. |
| [Keychain](../../TFM/Features/Keychain/KeychainPageView.swift#L88-L173) | `KeyCard` or `IdentityCard`; empty-query pages use `.sameSection`, dispatching independently to `app.credentials.move(keyIDs:before:)` or `move(identityIDs:before:)`. A mixed selection does not convert keys into identities. |
| [Known Hosts](../../TFM/Features/KnownHosts/KnownHostsPageView.swift#L25-L66) | `KnownHostCard`; default capabilities contain no reordering and its section rejects drops. Shared CardTile changes do not create a drag source. |
| [Snippets](../../TFM/Features/Snippets/SnippetsPageView.swift#L73-L178) | `SnippetCard`; unfiltered pages use `.anySection`, calling `app.snippets.move(snippetIDs:into:before:)` for package placement. Results reject drops. |
| [Metrics](../../TFM/Features/Metrics/MetricsManagedCardPage.swift#L16-L54) | `ServerMetricsCard`; empty-query pages use `.sameSection` and `app.serverMetrics.move`. Its wider, potentially tall cards make captured per-item heights important. |
| [Forwarding](../../TFM/Features/Ports/PortForwardingView.swift#L25-L53) | Page-specific card content uses `CardTile`; capabilities enable selection/marquee but no reordering, and the section rejects drops. |

The renderer's callback returns `Void`: successful drop handling means dispatch, **not confirmation of durable storage**. Host and snippet moves update placement/sort indices and call `persistCore`; Keychain's independent manual-order operations also persist there. Metrics instead persists its reordered configuration before applying it. Keep those feature-model policies separate from preview fixes; do not infer a universal rollback policy from the shared renderer. In particular, the host model can reject a move containing a Tailscale-managed host or an invalid destination group even after the UI resolves a slot.

Evidence: [host move](../../Frameworks/TermindApplication/FeatureModels/HostLibraryModel.swift#L2263-L2288), [snippet move](../../Frameworks/TermindApplication/FeatureModels/HostLibraryModel.swift#L2000-L2027), [Keychain order persistence](../../Frameworks/TermindApplication/FeatureModels/HostLibraryModel.swift#L1792-L1813), [Metrics persistence-before-apply](../../Frameworks/TermindApplication/Metrics/ServerMetricsModel.swift#L226-L235).

### Focused managed-card regressions

- [ManagedCardDragPresentationTests](../../TFMTests/ManagedCardDragPresentationTests.swift) checks immutable lift heights across reflow, zero/offscreen-frame fallbacks, and fully transparent batch placeholders. Its light/dark image tests check a 360 × 240 actual `CardTile` preview retains both header and footer, an opaque center and transparent rounded corner. These are offscreen rendering tests, not end-to-end native drag or persistence tests.
- [KeychainOrderTests](../../TFMTests/KeychainOrderTests.swift) separately covers fixed/exchangeable drop policies, grid slots and collapsed-section ends, batch deduplication/order, and key/identity ordering after persistence reload.
- [CardMarqueeSelectionTests](../../TFMTests/CardMarqueeSelectionTests.swift) covers neighboring selection geometry. Keep selection regressions distinct from drag-image rendering failures.

A focused macOS test selection is:

```sh
xcodebuild -quiet -project Termind.xcodeproj -scheme TFM \
  -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:TFMTests/ManagedCardDragPresentationTests \
  -only-testing:TFMTests/KeychainOrderTests \
  -only-testing:TFMTests/CardMarqueeSelectionTests test
```

## Native workspace and pane dragging

TFM drag behavior spans SwiftUI row interaction, AppKit's native tracking loop, temporary layout previews and live session ownership. Changing one of these layers can break another without changing the final model operation. In particular, **Workspace rows retain the native SwiftUI List drag source**; the separate Pane source is not a replacement for it.

Start with [Desktop UI Architecture](../architecture/desktop-ui.md) for the window shell and persistent deck. This page explains internal layout and conversation-list dragging. File uploads and remote-file transfers have separate payloads and owners; see [SFTP Transfer and External Edit](sftp-transfer-and-external-edit.md).

For Assistant file attachments, SSH terminal uploads, SFTP file drops, Key import, and the shared Overlay UI, use [File Drag and Drop Across TFM and TFI](file-drag-and-drop.md).

## Interaction matrix

| Source and destination | Result | Boundary |
| --- | --- | --- |
| Workspace row → Navigator List | Reorder the existing workspace. | Pointer positions clamp to Workspace insertion boundaries; the List does not merge workspaces. |
| Workspace row → occupied pane edge | Insert the source workspace's complete split tree beside that pane. | Different workspaces in the same window; source and destination must support combining. |
| Workspace row → empty pane | Replace the slot with the source split tree. | The source workspace is removed after its layout joins the target. |
| Pane title → another pane edge or empty slot | Rearrange that live pane. | The drop controller permits moves within the same workspace. |
| Pane title → Navigator List | Lift the pane into a separate workspace at the insertion position. | A pane already alone in its workspace is a no-op here. |
| Workspace row or eligible Pane title → unaccepted release outside source window | Request a new window and transfer live ownership when it registers. | Workspace completion requires macOS 26+; the Pane source has no equivalent OS-version gate. |
| Assistant conversation → Pinned or Chats list | Reorder and optionally change pin status. | Separate conversation payload and persistence path; no tear-off request. |

Layout receivers resolve the **owning window's** drag state. They are not a general mechanism for importing a pane into an already-open different window. An unaccepted release over another Termind window still qualifies as outside the source and can create a new window. Within one window, moving a pane into a different workspace uses two deliberate gestures: detach it into the Navigator, then merge that workspace into the destination pane area.

Evidence: [Navigator source and receiver](../../TFM/Features/Workspaces/WorkspaceNavigatorView.swift#L144-L301), [pane drop policy](../../TFM/Features/Workspaces/PaneLayoutDropController.swift#L12-L76), [model operations](../../TFM/Features/Workspaces/WindowModel.swift#L1046-L1172).

## State owners and the native tracking loop

`WindowModel.dragging` projects a window-local `WorkspaceDragState.payload`: `.workspace(UUID)`, `.pane(UUID)` or `.assistantConversation(UUID)`. All three sources write a UUID string, so the string alone does not define its meaning. Layout receivers require both a layout payload from their live owner and a matching pasteboard UUID; Assistant payloads cannot become layout drops.

| Layer | Owner and responsibility |
| --- | --- |
| Workspace gesture and row preview | SwiftUI `List` and its row `.draggable` / `.onDrag`; `WorkspaceNavigatorDragSession` observes the List session. |
| Pane title gesture and completion | `WorkspaceLayoutDragSourceNSView`, attached through the title's background bridge. |
| Native layout destination and feedback | `WorkspaceLayoutDropNSView`: registration, hit participation, payload validation, preview drawing and native callbacks. |
| Placement policy | Navigator insertion geometry or `PaneLayoutDropController` for pane edges/empty slots. |
| Live layout mutation | `WindowModel` and the owning `Workspace`. |
| New-window request and ownership handoff | App-owned `MainWindowCoordinator`, consumed when the native destination registers. |

AppKit can enter its nested tracking loop immediately after drag state changes, before SwiftUI renders again. Receivers therefore mount and register **before** the gesture and use closures that read the current model in `draggingEntered`, `draggingUpdated` and `performDragOperation`. Caching the dragged ID or eligibility in `updateNSView` can leave the entire drag with stale state.

`WorkspaceLayoutDropNSView` registers for `.string` even when its workspace is parked. At each callback, its controller checks current destination visibility and pane identity. Its transparent overlay passes ordinary clicks, scrolling and pointer movement through; a stale drag pasteboard must not intercept normal interaction. An unrelated UUID, text or file drag fails payload validation even if old model drag state remains.

Evidence: [drag state](../../TFM/Features/Workspaces/WindowModel.swift#L132-L146), [payload cases](../../TFM/Features/Workspaces/WindowModel.swift#L1580-L1597), [native receiver](../../TFM/UI/Components/WorkspaceLayoutDropTarget.swift#L10-L113), [UUID validation](../../TFM/UI/Components/WorkspaceLayoutDropTarget.swift#L137-L153).

## Workspace source: preserve the native List contract

On macOS 26+, the row's `.draggable(workspace.id.uuidString)` stays outside the measurement modifier so the List sees its drag trait. It supplies the existing `ItemDragPreview`. A row being renamed has no drag modifier. Earlier macOS uses the original `.onDrag` writer and preview.

The macOS 26+ observer belongs on the **List**, not on a row: the List owns the native drag session. Only its `.active` phase reads `NSPasteboard(name: .drag)`, checks that the UUID belongs to this window's workspaces, begins cancellation tracking and sets `.workspace(id)`. List can request pasteboard writers after an ordinary click; querying a writer must not select a merge preview or mark a drag active. The older `.onDrag` path sets drag state in its writer and has no Workspace tear-off completion observer.

Keep single-click selection, double-click rename, close controls, the row preview and the List's gesture recognition intact. The new-window extension is session configuration plus completion policy, not a new Workspace gesture recognizer.

Evidence: [row modifiers](../../TFM/Features/Workspaces/WorkspaceNavigatorView.swift#L157-L175), [List observer](../../TFM/Features/Workspaces/WorkspaceNavigatorView.swift#L357-L415), [click/writer/native-session tests](../../TFMTests/WorkspaceNavigatorDropTests.swift#L11-L208).

## Destination geometry and temporary previews

### Navigator insertion

The layout receiver overlays the List's native rows. A target behind the List or only on a SwiftUI ancestor can lose the native responder path as a drag crosses from terminal content into the sidebar.

Rows and the Workspace header measure in SwiftUI global coordinates because named coordinate spaces do not propagate reliably across native List hosting boundaries. The overlay translates the pointer into that space and translates the resulting insertion rectangle back. Preserve this conversion when changing sidebar insets, titlebar layout or scrolling.

`WorkspaceSidebarDropGeometry` keeps two indices:

- `visibleBoundaryIndex` locates the insertion line among the displayed rows, including the source row.
- `insertionIndex` counts after excluding the dragged workspace, matching the collection after removal.

The overlay covers the List. Pointer positions above or below the Workspace rows clamp to the first or last insertion boundary; `workspaceDropBounds` establishes available section geometry, not a pointer-containment restriction. Hovering a collapsed Workspace section expands it. Switching the sidebar away from Navigator makes the live `draggedLayoutID` nil immediately, without waiting for a render.

On drop the Navigator dispatches `move` for a workspace or `detachPane` for a pane, then clears drag state. `detachPane` requires more than one source pane, so lifting a lone pane here does not create an extra workspace or perform a disguised reorder.

### Pane edges and split preview

When the selected combinable workspace is dragged, `displayedWorkspace` temporarily reveals an adjacent merge-capable workspace: next first, then previous. This is derived presentation, not a committed selection change or a scan for any distant candidate.

A dragged pane remains mounted with its stable identity while `omittedPaneID` collapses its branch's temporary geometry. Removing that native source view during the drag can end the session before the pointer reaches the Navigator. The model split tree remains unchanged until a drop commits.

`PaneLayoutDropController` checks the current displayed workspace and the exact target pane instance on every callback. It excludes the omitted source pane, allows a different combinable workspace to merge, and accepts individual panes only from the same workspace. Occupied panes choose the nearest proportional edge; an empty slot previews and replaces its whole area.

Mutation precedes clearing the preview state. Restoring an omitted source first could briefly mount the same terminal surface under both old and new parents. A participating but invalid inner target can finish the drag without a layout mutation and clear transient state; hidden or unrelated destinations reject participation altogether.

Evidence: [Navigator geometry](../../TFM/Features/Workspaces/WorkspaceNavigatorView.swift#L215-L301), [boundary indices](../../TFM/Features/Workspaces/WorkspaceNavigatorView.swift#L418-L443), [adjacent preview](../../TFM/Features/Workspaces/WindowModel.swift#L489-L513), [mounted pane preview](../../TFM/Features/Workspaces/WorkspaceContentView.swift#L99-L116), [pane controller](../../TFM/Features/Workspaces/PaneLayoutDropController.swift#L12-L123).

## Pane source and competing input

Only an eligible pane's **title** installs `WorkspaceLayoutDragSource`; terminal content remains available for text selection. The background view itself returns nil from hit testing, while its pan recognizer attaches to the window content view and restricts the initial event to the title's visible bounds. It rejects double-clicks, hidden/clipped sources, buttons and text editors, and refuses parked panes through `displayedWorkspace`. It does not delay ordinary mouse events and permits simultaneous recognizers.

The recognizer retains the actual `mouseDragged` event because AppKit may schedule its action after `NSApp.currentEvent` has changed. Before beginning the native session, the source captures the live model and payload, sets drag state and installs Escape tracking. The session allows `.move` inside the application and no operation outside it: its UUID is internal routing data, not text to paste into another app.

Pane content drops use a separate **outermost** `NativeDropTarget` above the terminal/table native content, outside the `WorkspaceLayoutDropTarget` overlay. It is enabled only for an active supported pane while `window.dragging == nil`: SSH accepts files, SFTP items and terminal paths; SFTP accepts files and SFTP items; Telnet and Serial accept terminal paths only; an empty pane has no such receiver. File/SFTP payloads dispatch to the pane's upload/copy requests, whereas terminal paths are pasted into a terminal. None of these content drops merges or transfers a workspace; do not replace the distinction with a generic `.string` drop target on the root.

Evidence: [title handle](../../TFM/Features/Workspaces/WorkspaceContentView.swift#L724-L761), [gesture lifetime](../../TFM/UI/Components/WorkspaceLayoutDragSource.swift#L79-L214), [retained event](../../TFM/UI/Components/WorkspaceLayoutDragSource.swift#L290-L305), [overlay ordering and payload types](../../TFM/Features/Workspaces/WorkspaceContentView.swift#L424-L483), [content dispatch](../../TFM/Features/Workspaces/WorkspaceContentView.swift#L546-L610).

## Outside release, cancellation and responsiveness

An outside release requests a new window only after these checks:

1. The native operation was unaccepted. Pane completion checks an empty `NSDragOperation`; Workspace observes `.cancel` or `.forbidden` from SwiftUI.
2. The primary mouse button is released and Escape was not recorded.
3. The source still owns the relevant live payload; Pane completion explicitly compares it with its captured payload.
4. The screen-space pointer is outside the **source window frame**. Workspace requires the coordinator to know that frame.

Do not reject a release merely because it is inside *some other* application window. A successful drop already wins via its returned operation, while an unhandled release over another Termind window is still a valid tear-off. Do not infer cancellation solely from an empty operation: Escape and an outside release can report the same result.

Workspace cancellation is latched by `WorkspaceDragCancellationTracker`. It observes local Escape events and samples Escape key state in both common and event-tracking run-loop modes, because the native drag loop can consume the event before a local monitor sees it. Repeated `.active` callbacks do not reset the latch. Ending the session or removing the observer view releases tracking. Pane completion combines its Escape monitor/current event with current button state and clears only the payload belonging to that session.

Responsiveness depends on **when** AppKit animation is configured:

- Pane creation disables `animatesToStartingPositionsOnCancelOrFail` when the native session begins.
- Workspace uses `WorkspaceNavigatorDragAnimation` to wrap the existing `NSOutlineViewDataSource`. The proxy forwards all existing behavior, invokes the original `willBegin` callback first, then disables the failed-drop return animation for this window's Workspace payload. Doing this only at completion misses the point where AppKit may start the return animation.
- The background marker identifies the nearest unambiguous outline viewport covering its center. It observes data-source replacement, rewraps after SwiftUI's assignment, and restores the forwarded source on unbind only if its own proxy is still installed. It never overwrites a newer replacement while tearing down.
- When a request carries a release point, destination registration sets `NSWindow.animationBehavior = .none` to avoid an additional window-opening animation.

Escape still cancels the operation; suppressing the return animation also suppresses its visual snapback. The tests verify session configuration and behavioral outcomes, not a fixed mouse-up-to-window latency.

Evidence: [release policy](../../TFM/UI/Components/WorkspaceLayoutDragSource.swift#L51-L75), [Pane completion](../../TFM/UI/Components/WorkspaceLayoutDragSource.swift#L216-L269), [Workspace completion](../../TFM/Features/Workspaces/WorkspaceNavigatorView.swift#L357-L415), [Escape tracker](../../TFM/UI/Components/WorkspaceDragCancellationTracker.swift#L11-L61), [animation adapter](../../TFM/UI/Components/WorkspaceNavigatorDragAnimation.swift#L47-L149).

## New-window transfer preserves the live owner until registration

```mermaid
sequenceDiagram
    participant Drag as Native drag completion
    participant Coordinator as MainWindowCoordinator
    participant Scene as Main WindowGroup
    participant Source as Source WindowModel
    participant Bridge as MainWindowRegistration
    participant Native as Destination NSWindow
    participant Target as Target WindowModel
    Drag->>Coordinator: moveWorkspace or movePane with release point
    Coordinator->>Scene: createScene with request UUID
    Note over Source: Live layout remains in source
    Scene->>Target: Construct fresh model
    Scene->>Coordinator: configure model with requested layout
    Scene->>Bridge: Attach native window to RootView bridge
    Bridge->>Native: Attach forwarding close delegate
    Bridge->>Native: Observe and clear edited decoration
    Bridge->>Native: Establish full-size content coordinates
    Bridge->>Coordinator: register native window and request UUID
    Coordinator->>Source: takeWorkspaceForMove or takePaneForMove
    Source-->>Coordinator: Existing workspace or pane wrapped in workspace
    Coordinator->>Target: open and install lifecycle router
    Coordinator->>Coordinator: Size and fit destination frame
    Coordinator->>Target: Bump sidebar layout generation for move
```

The handoff waits for native destination registration before extracting live ownership and installing the destination lifecycle router.

Scene creation and native registration are distinct phases; the diagram's transfer happens at registration, after native close-delegate attachment and content-coordinate setup, not at the drop or initial SwiftUI layout.

Request-to-registration transfer keeps the live session in its source until the destination has a native window.

`TermindCommands` installs the `openWindow(id: "main", value: id)` scene factory for the UUID-valued main `WindowGroup`. On the normal workspace scene path (after the diagnosis-consent gate), `TermindApp.makeWindow` creates a fresh `WindowModel` and applies the request's sidebar presentation and preferred width before constructing `RootView`. Its `MainWindowRegistration` bridge calls `register` only after AppKit attaches the native window; the registration view establishes full-size content coordinates before sizing. This keeps scene creation separate from live ownership transfer.

On native attachment, `MainWindowRegistrationView` installs its retained `WorkspaceWindowCloseDelegate` and observes `NSWindow.isDocumentEdited` with initial and new-value delivery, clearing it whenever it becomes true. Workspaces are not documents. Each registration attempt reattaches the proxy if needed before calling the coordinator. The proxy forwards other delegate callbacks and honors the existing delegate's close veto first. Live connections no longer require confirmation: it saves terminal theme changes and prompts for discard only if unsaved theme changes remain, even in an empty window. Detaching restores the forwarded delegate only if the proxy is still installed. This native dismissal guard does not change window-local drag ownership, stable Workspace/Pane identity, or move lifecycle semantics.

Evidence: [native attachment and edited decoration](../../TFM/Platform/MainWindowCoordinator.swift#L589-L628), [forwarding close delegate](../../TFM/Platform/WorkspaceCloseConfirmation.swift#L33-L77), [close veto, forwarding and recovery tests](../../TFMTests/WorkspaceCloseConfirmationTests.swift#L96-L188).

Live layout ownership changes only when the requested destination window registers.

The request stores a weak source, the move identity, a layout snapshot (ordinary content size, sidebar width and presentation, fullscreen state and source-screen center), and an optional release point. Repeated requests for the same source and move reuse the pending request ID; different pane requests may register in reverse order. A closed source, missing scene factory, nonexistent workspace, nonexistent or noncombinable pane cannot initiate a move. If the source or pane disappears before registration, the pending request cannot recreate it. `register` rejects a closed destination and duplicate native/model pair, then removes the pending request when a new destination consumes its ID, **even if extraction finds no live layout**. A late scene may therefore register empty; registering the same destination again cannot transfer a second copy.

Registration consumes the request once. A whole Workspace moves as the same object, including its complete split layout. A pane from a split workspace is extracted into a newly named workspace around the **same Pane object**; the remaining source tree repairs focus, group naming and broadcast eligibility through `Workspace.closePane`. A lone pane moves its original workspace, retaining its name and template identity.

The extraction paths deliberately bypass `WindowModel.close` and `closePane` teardown. `takeWorkspaceForMove` uses `removeWorkspaceForMove` and clears the transferred workspace's `lifecycleRouter`; destination `open` assigns the target window as router. For a split-pane extraction, `Workspace.closePane` only rewrites the source layout: the source workspace keeps its router, and the new wrapper receives the destination router on `open`. The wrapper uses `automaticallyNamedWorkspace`, so its workspace name is allocated from the saved host name or SSH/Telnet session title when available, subject to workspace naming preferences and occupied source-window names. It does not inherit the split group's name or template identity; the moved pane's own custom title survives.

Neither extraction entrypoint enqueues or cancels persistent-session cleanup. Moving transfers live layout ownership, not cleanup ownership; there is no persistent-close authorization generation to invalidate.

Explicit pane/workspace close is different from moving or dismissing a window. With a host store and app-owned `persistentSessionCloser`, `WindowModel` captures managed-session close requests, enqueues them and removes/disconnects the local layout without waiting for remote termination. `SSHSessionModel.takePersistentSessionCloseRequest` validates the snapshot's host and endpoint and can hand its SSH channel to a one-shot cleanup owner, clearing the session's channel reference. Without a cleanup owner, local close retains the recovery reference.

`RemoteSessionCloseCoordinator.enqueue` defaults to `.explicitClose`, deduplicates identities **while pending**, and runs best-effort background cleanup without retry or a termination-failure prompt. Its default 30-second deadline cancels the operation; completion or cancellation releases any transferred connection exactly once. Rejected passive-intent requests and duplicate requests also release their supplied connection. Cancellation is cooperative, not rollback or an authorization gate for local closure. `closeForWindow` records and disconnects only still-owned workspaces while preserving remote sessions and recovery references; it does not cancel app-owned cleanup. See [SSH Session Lifecycle](ssh-session-lifecycle.md) and [Session Persistence](../concepts/session-persistence.md) for persistent-session teardown semantics.

Evidence: [live extraction and close paths](../../TFM/Features/Workspaces/WindowModel.swift#L1490-L1558), [move-only removal](../../TFM/Features/Workspaces/WindowModel.swift#L1361-L1369), [background cleanup ownership](../../Frameworks/TermindApplication/Terminal/RemoteSessionCloseCoordinator.swift#L19-L110), [close request capture](../../TFM/Features/Terminal/SSHSessionModel.swift#L1127-L1145), [app-owned coordinator](../../TFM/App/AppModel.swift#L298-L301).

These are move operations, not close/reopen: they do not disconnect transports, end connection-history events or populate app-owned recently-closed history. Destination `open` installs its lifecycle router and shared services; history configuration skips a pane that already has an active event. The source refreshes its focused-session context and sidebar state. If its last workspace moved away, it returns to Welcome. On an actual window close, by contrast, `closeForWindow` disconnects the panes still owned there, not those already transferred.

Closing the source window removes its pending requests. A pane closed before registration cannot be resurrected by a late destination; an already-created scene may remain empty. A restored scene with no pending request retains its restored geometry and does not replay the move.

New windows use the source's last valid ordinary AppKit **content** size, not its fullscreen frame; if no source size was recorded, the shared default applies. During scene construction `configure` applies sidebar presentation and preferred width; registration reapplies them (and invalidates initial sidebar layout if they differ), sizes the native window, then bumps `sidebar.initialLayoutGeneration` for a move to rebuild the split view at the transferred width. For a release point, `applySize` selects the screen containing that point, centers the frame horizontally on it and places its top at the point's Y coordinate, then `fittingFrame` clamps its size and origin inside that screen's visible frame. The minimum content dimensions are enforced before fitting, so a release near a screen edge may shift the resulting window rather than leave it exactly centered on the cursor. Destination registration disables native opening animation for requests with a release point; the tests' `nativeWindow` fixture already has `.none` set and checks placement and layout rather than verifying that assignment separately. If the source was fullscreen, the destination also defers fullscreen activation until it becomes key. A restored scene without a pending request is left at its system-restored frame.

Evidence: [request and layout snapshot](../../TFM/Platform/MainWindowCoordinator.swift#L257-L299), [request consumption and registration](../../TFM/Platform/MainWindowCoordinator.swift#L329-L390), [placement, fullscreen and close](../../TFM/Platform/MainWindowCoordinator.swift#L392-L470), [frame fit and registration bridge](../../TFM/Platform/MainWindowCoordinator.swift#L565-L628), [scene factory](../../TFM/App/TermindCommands.swift#L31-L34), [scene construction and consent gate](../../TFM/App/TermindApp.swift#L224-L252), [RootView bridge](../../TFM/App/RootView.swift#L75-L85), [model extraction and close](../../TFM/Features/Workspaces/WindowModel.swift#L1402-L1482), [move regressions](../../TFMTests/WorkspaceWindowMoveTests.swift#L11-L254).

## Assistant conversation reordering

Assistant uses a SwiftUI `.onDrag` row over a ListViewKit-backed native list. It writes `.assistantConversation(id)` to the same window-local drag state and provides a conversation-title preview. Active conversations can move while running, waiting for approval or compacting; archived rows and rename editors cannot start a drag. Search results disable the list's reorder receiver and move callback.

`AssistantConversationDropResolver` maps native row frames to `(section, beforeID)`. Dropping on a section header inserts before its first conversation; the row midpoint selects before/after, and nil `beforeID` means the section end. Crossing Pinned/Chats changes pin status. The receiver reads `draggedID` at callback time for the same nested-loop reason as Workspace receivers. Its current native gate checks conversation drag state and a `.string` pasteboard type; it does not perform the layout receiver's UUID equality check.

The compact workspace Assistant remains mounted behind the other sidebar presentation. SwiftUI opacity and `allowsHitTesting(false)` alone do not remove native drag participation. `AssistantConversationListContainer.isInteractive = false` both unregisters dragged types and returns nil from native hit testing, clearing its insertion target. Both actions matter: otherwise an invisible list can take the drop and draw feedback behind the visible one. Recycled hosting rows also receive their window, locale and color scheme explicitly rather than relying on an attached SwiftUI environment during AppKit callbacks.

On a successful drop, the view expands the target section, dispatches `WindowModel.moveAssistantConversation` and clears transient drag state. Production commands route through `AppModel` to `AssistantConversationOperations.move`: normalized ordering is persisted before `AssistantLibraryModel.applyOrder` changes visible pin/sort values. Failure leaves the prior order intact and reports an operation error; moving preserves the running conversation and its approvals/transcript. Assistant has no Workspace/Pane new-window completion path.

Evidence: [active list routing](../../TFM/Features/Assistant/AssistantView.swift#L413-L496), [resolver](../../TFM/Features/Assistant/AssistantView.swift#L700-L754), [native participation](../../TFM/Features/Assistant/AssistantView.swift#L910-L1044), [source eligibility](../../TFM/Features/Assistant/AssistantView.swift#L1260-L1271), [drag guard](../../TFM/Features/Assistant/AssistantView.swift#L1354-L1356), [durable ordering](../../Frameworks/TermindApplication/Agent/AssistantConversationOperations.swift#L44-L60), [order normalization](../../Frameworks/TermindApplication/Agent/AssistantLibraryModel.swift#L170-L225).

## Regression map and change guidance

| Change or symptom | Focused coverage |
| --- | --- |
| Click turns into drag, row cannot start a native session, writer query changes preview | `WorkspaceNavigatorDropTests`: single-click, native mouse drag and writer-query cases. |
| Missing or misplaced Navigator insertion line | `WorkspaceNavigatorDropTests`: immediate callbacks, scrolling/titlebar insets and mode changes; `PersistentWorkspaceDeckLayoutTests`: insertion indices and parked geometry. |
| Split merge/rearrange, empty slots, hidden target or stale payload | `WorkspaceLayoutDropTests`, including Assistant UUID rejection. |
| Outside release, accepted drop, Escape, replaced payload or hidden Pane source | `WorkspaceLayoutDragSourceTests` and `WorkspaceDragCancellationTests`. |
| Return animation or data-source forwarding/replacement | `WorkspaceNavigatorDragAnimationTests`; native split-workspace tear-off also asserts the animation flag at session start. |
| Whole split Workspace fails to tear off | `WorkspaceNavigatorDropTests.draggingASplitWorkspaceOutsideItsSourceMovesTheWholeLayout()`: release over another window, one request, original Workspace and pane IDs. |
| Ownership loss, reconnect, changed history or late request | `WorkspaceWindowMoveTests`: destination delay, duplicate requests, lone-pane identity, closed sources, reversed arrival order and window placement. |
| Move versus remote cleanup ownership | `WorkspaceWindowMoveTests` verifies source close leaves transferred connections/history active until destination close. `SessionPersistenceTests` separately covers best-effort failure, passive intents, pending-identity deduplication, cancellation before background work and timeout without retry—not an end-to-end drag during termination. |
| Native close veto or lost delegate callbacks after registration | `WorkspaceCloseConfirmationTests`: populated windows close without a connection prompt, forwarded veto/callbacks, delegate restoration, theme-edit protection even in empty windows, and recovery-reference preservation on window close or close without a cleanup owner. These tests exercise the proxy directly; move tests register through the coordinator, not the registration view's edited-state observation. |
| Assistant hidden receiver or active-row eligibility | `AssistantConversationListDropTests`; `AssistantConversationOperationsTests` covers persistence failure and preserved activity; `WindowStateTests` covers stable manual order. |

Run the offscreen policy, geometry and lifecycle cases without visible-window opt-in first, keeping dependency resolution pinned. The suite selection below also includes three `WorkspaceNavigatorDropTests` mouse/session cases that will be skipped by default; an `NSWindow` fixture alone does not require the gate if it stays offscreen.

```sh
xcodebuild -quiet -project Termind.xcodeproj -scheme TFM \
  -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:TFMTests/WorkspaceNavigatorDropTests \
  -only-testing:TFMTests/WorkspaceLayoutDropTests \
  -only-testing:TFMTests/WorkspaceLayoutDragSourceTests \
  -only-testing:TFMTests/WorkspaceDragCancellationTests \
  -only-testing:TFMTests/WorkspaceNavigatorDragAnimationTests \
  -only-testing:TFMTests/WorkspaceWindowMoveTests \
  -only-testing:TFMTests/AssistantConversationListDropTests test
```

The `WorkspaceNavigatorDropTests` single-click, native mouse-session and split-workspace tear-off cases use `.requiresVisibleWindow` because they call `makeKeyAndOrderFront` (the tear-off case also orders another window and activates the app). The trait skips these cases unless the **test host** sees `TERMIND_WINDOW_TESTS=1`; the Xcode command-line prefix `TEST_RUNNER_TERMIND_WINDOW_TESTS=1` forwards that value. The Debug app also suppresses automatic test-window launch by default, but this does not replace the per-test gate. Opt in only when changing real mouse/List or focus behavior, with `-parallel-testing-enabled NO` and a narrow filter. In Xcode's Test action, set `TERMIND_WINDOW_TESTS=1` directly. Keep parentheses in a Swift Testing single-test filter and verify that the result bundle contains the intended test rather than trusting a zero exit status alone:

```sh
TEST_RUNNER_TERMIND_WINDOW_TESTS=1 xcodebuild -quiet \
  -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
  '-only-testing:TFMTests/WorkspaceNavigatorDropTests/draggingASplitWorkspaceOutsideItsSourceMovesTheWholeLayout()' test
```

When changing Workspace dragging, keep the row source and preview intact, inspect live callback timing before changing geometry, and verify cancellation independently of an outside release. When changing transfer ownership, use the coordinator request boundary and existing live objects. When changing Assistant presentation, test both visible and retained hidden native lists. Complete the repository's default test and formatting/localization gates after focused regressions; see [Testing Strategy](../testing/behavioral-boundaries-and-fixtures.md) and [Quickstart](../quickstart.md).
