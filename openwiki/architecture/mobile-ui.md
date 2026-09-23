---
type: architecture guide
title: TFI Mobile UI Architecture
description: "How the iPhone/iPad app composes registered feature stacks, scene-local navigation, shared runtimes, adaptive content regions, native terminal/transcript surfaces and mobile interaction policies."
tags: [ios, ipados, tfi, ui, navigation, adaptive-layout, swiftui, uikit]
sources:
  - id: openwiki-source-d1d534769c300d5fb8dbe9d7
    resource: repo://Frameworks/TermindApplication/FeatureModels/HostCustomIdentityDraft.swift
  - id: openwiki-source-eec1a2bc6dfc2c60b2bee55c
    resource: repo://Frameworks/TermindPresentation/HostConnectionFields.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-60d390fe6fbfea55a2a8230a
    resource: repo://TFI/App/MobileFeatureRegistry.swift
  - id: openwiki-source-c8d832474c03f5ebad7b0578
    resource: repo://TFI/App/MobileRootView.swift
  - id: openwiki-source-e43a0da5ab77c2fc3554244d
    resource: repo://TFI/App/MobileSceneModel.swift
  - id: openwiki-source-d44869be46c03fbd0ce9c64c
    resource: repo://TFI/Application/Agent/MobileAssistantModel.swift
  - id: openwiki-source-851edcded7143bb79a41f6c6
    resource: repo://TFI/Application/Workspaces/MobileConnectionHistory.swift
  - id: openwiki-source-99e98ad50ba8a7c6df018977
    resource: repo://TFI/Design/MobileDesignTokens.swift
  - id: openwiki-source-0368ecce931d0fb26fe8f35f
    resource: repo://TFI/DesignSystem/MobileContentRegions.swift
  - id: openwiki-source-cbeb1570645eae169d495cbb
    resource: repo://TFI/DesignSystem/MobileLayoutEnvironment.swift
  - id: openwiki-source-bb7c576ff899dcdee98e37f9
    resource: repo://TFI/DesignSystem/MobileToolbarEnvironment.swift
  - id: openwiki-source-3dfad0e95bb7d66f292c20c9
    resource: repo://TFI/Features/AI/MobileAssistantConversation.swift
  - id: openwiki-source-d43ef236ba4bbb23d8dab797
    resource: repo://TFI/Features/Assistant/MobileAssistantView.swift
  - id: openwiki-source-fc448263e4e5ce330b8cbda1
    resource: repo://TFI/Features/HostEditor/MobileHostEditor.swift
  - id: openwiki-source-ad662f2a7016a994d8522bf2
    resource: repo://TFI/Features/KnownHosts/MobileKnownHostsView.swift
  - id: openwiki-source-3f37062f55fb57a9f2e97f35
    resource: repo://TFI/Features/Vault/MobileVaultView.swift
  - id: openwiki-source-a337b6f93e72977e59faaf14
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceListView.swift
  - id: openwiki-source-4c2de67bfdb2238d765a642a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceView.swift
  - id: openwiki-source-d34ac3e852773901d0566033
    resource: repo://TFI/Platform/MobileHomeScreenQuickActions.swift
  - id: openwiki-source-ca0b3e6e839587396cdeaf54
    resource: repo://TFI/Platform/MobileTerminalSurface.swift
  - id: openwiki-source-3af0aeffcab26dc81096aefc
    resource: repo://TFI/UI/Components/MobileEditorSheet.swift
  - id: openwiki-source-c99ab42abad536ed4396933c
    resource: repo://TFI/UI/Managed/MobileCards.swift
  - id: openwiki-source-fffc181d864b6caea779a6f5
    resource: repo://TFITests/MobileAdaptiveLayoutTests.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-c32ed562101f11a0c3c89663
    resource: repo://TFITests/MobileCardTests.swift
  - id: openwiki-source-16ec96bd78162e7e62effd0e
    resource: repo://TFITests/MobileConnectionPickerTests.swift
  - id: openwiki-source-5636c5d112b9e5b2266c3058
    resource: repo://TFITests/MobileVaultFeatureTests.swift
  - id: openwiki-source-11c91698354a4f95be3c4654
    resource: repo://TFITests/MobileWorkspaceMenuTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-23T10:36:38.039Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T14:32:50.942Z
---

# TFI Mobile UI Architecture

TFI is not a scaled-down copy of the desktop split-pane window. It uses system-adaptive top-level tabs/sidebar, a navigation stack for each registered feature, scene-local routing, and shared application-owned sessions. Adaptation changes presentation without automatically replacing the conversation, terminal or connection being presented.

Read [TFM Desktop UI Architecture](/openwiki/architecture/desktop-ui.md) for the desktop contrast and [UI Design Principles](/openwiki/concepts/ui-design-principles.md) for shared presentation boundaries.

## Code structure and ownership

```mermaid
flowchart TD
    App[MobileAppModel] --> Shared[Libraries / transfers / forwarding / metrics]
    App --> Workspaces[MobileWorkspace instances]
    App --> AssistantRuntime[MobileAssistantModel]
    Root[MobileRootView] --> Scene[MobileSceneModel per scene]
    Root --> Registry[MobileFeatureRegistry]
    Registry --> Tabs[Sidebar-adaptable TabView]
    Tabs --> Vault[NavigationStack: Vault]
    Tabs --> Metrics[NavigationStack: Metrics]
    Tabs --> WorkspaceList[NavigationStack: Workspaces]
    Tabs --> Assistant[NavigationStack: Assistant]
    Tabs --> Settings[NavigationStack: Settings]
    Scene --> Routes[Selection / editor / workspace route]
    Scene --> AssistantScene[MobileAssistantSceneModel]
    AssistantScene -. shared runs and store .-> AssistantRuntime
    WorkspaceList --> Detail[MobileWorkspaceView]
    Detail -. renders .-> Workspaces
    Assistant --> Conversation[MobileAssistantConversation]
```

Application services are shared while each scene retains its own feature navigation and Assistant selection.

`MobileFeatureRegistry` is the single registration table for feature identity, order, localized title, symbol and view builder. Its standard order is Vault, Metrics, Workspaces, Assistant, Settings, and duplicate destination registration is rejected. `MobileRootView` iterates registrations rather than maintaining independent tab/sidebar/destination switches.

Each registered destination gets its own `NavigationStack`; the enclosing `TabView` uses `.sidebarAdaptable`. The system can change where navigation appears without the app rebuilding a different root tree for “phone” and “tablet.” `MobileLayout` supplies a compact/regular hint, defaulting to compact when size class is absent; it is not the whole adaptive layout algorithm.

### State lifetime matrix

| Owner | State or work | Expected lifetime |
| --- | --- | --- |
| `MobileAppModel` | Shared libraries, live/saved workspaces, transfers, synchronization and aggregate scene activity. | Application/service lifetime. |
| `MobileSceneModel` | Selected destination, workspace route, pending activation, editor/rename presentation, scene-local recent selection. | One scene. |
| `MobileAssistantModel` | Shared conversation store and execution services. | Survives scene navigation. |
| `MobileAssistantSceneModel` | Selected conversation and New Chat draft through its own library model. | Independent per scene over the shared store. |
| `MobileWorkspace` / `MobileTerminalSurface` | Connection/session state and owned native terminal view. | Workspace lifetime, not just the currently pushed detail. |
| Feature view state | Temporary picker, preview, drop loading and focus-request state. | Current presentation. |

Two iPad scenes can navigate independently without creating two copies of an already-running conversation. Likewise, selecting a workspace looks up the shared instance; `MobileAppModel.openWorkspace` publishes a restored workspace before connection work so scenes do not race to create separate initial instances.

## Navigation is an intent sequence

Opening a Host from another feature is deliberately staged:

```mermaid
sequenceDiagram
    participant User
    participant Scene as MobileSceneModel
    participant App as MobileAppModel
    participant List as MobileWorkspaceListView
    User->>Scene: activate Host or open explicit connection
    Scene->>App: resolve or create workspace
    Scene->>Scene: store pending ID and select Workspaces
    List->>List: destination task yields once
    List->>Scene: activatePendingWorkspace
    Scene->>Scene: set workspaceID and update recent selection
    List->>List: push MobileWorkspaceView
```

Cross-tab activation defers the push until the Workspaces destination has had a chance to mount.

When already on Workspaces, the scene can present the route directly. When changing tabs, pending activation waits for the Workspaces destination to participate before pushing its detail. Selecting another top-level destination clears pending workspace activation rather than leaving a delayed push armed.

Host activation and explicit connection actions are different:

- `activateHost` prefers this scene's most recently selected matching terminal workspace, then another existing matching workspace, before creating one.
- Explicit SSH/SFTP connection actions call the open path and can create independent workspaces.
- The workspace title switcher replaces the pushed detail by workspace identity. This resets detail-specific state such as SFTP search without treating the owned terminal/session as a newly created runtime.

Unavailable saved workspace IDs produce an explicit unavailable state; a stale route does not silently open some other Host. Root-level deep links, quick actions and focused scene commands dispatch through that scene's model.

The Workspaces destination deliberately presents saved descriptors and live runtimes as one collection. `MobileAppModel`
seeds a display-order ID list from persisted descriptors, appends a Workspace only the first time it appears, and removes
an ID only when that Workspace is closed. Restoring a saved descriptor attaches a shared `MobileWorkspace` runtime to the
existing row instead of moving it. Newly created and process-only external Workspaces append in appearance order. The same
ordered descriptor projection drives the list and the detail switcher, so choosing a dormant saved item connects it without
reordering either surface.

Every row uses the same title, login address, protocol label and lifecycle actions. A live runtime adds the eight-point
connection-state dot; a saved-but-dormant descriptor has no dot. Rename edits either the live descriptor or the saved
descriptor directly, while Close removes the saved item and also disconnects it when a runtime exists. The detail switcher
includes both kinds, marks the selected descriptor with a checkmark, and uses the protocol symbol for every other item.

### Deleting a Host is not popping a workspace

Vault's confirmed **Delete Host** calls `MobileAppModel.deleteHost`, not the detail's back action. The app asks Assistant's connection pool to disconnect that Host, closes its saved live **and** unopened workspace descriptors (disconnecting any matching live workspace), invalidates SFTP edits, cancels transfers, stops/removes forwarding rules, removes Metrics selection, then requests repository deletion, projects the Host out of the library and starts the durable outbox. A repository error is reported through `app.error` and returns `false`; this is not an atomic rollback of the earlier cleanup. The registered outbox deletion handlers repeat workspace/history/projection, transfer and forwarding cleanup as the durable job proceeds. Deleting a Host group with `keepHosts: false` uses this Host path for each member; remote Vault removal closes associated saved descriptors and clears histories and Metrics too. Scenes reconcile routes against the changed live workspace IDs rather than owning the deletion itself.

### Local Recents versus synchronized History

The Workspaces destination and Vault History expose different projections over the shared synchronized event stream. `MobileVaultView` provides the navigation link (and searchable link); `MobileConnectionHistoryView` owns the History list, search, row actions and clear confirmation. `MobileConnectionHistory` builds the rows rather than either view storing a separate timeline:

- Workspaces Recents appears only if the ordered saved/live Workspace collection is empty. It uses this installation's events, aggregates protocols and attempts into one row per Host, and keeps the newest five Hosts. A primary tap resolves the Host's *current* preferred terminal protocol (SSH before Telnet); context and swipe actions offer only currently enabled SSH, Telnet or SFTP capabilities. Clearing a recent Host clears that Host's history across devices.
- Home Screen quick actions use the same local per-Host projection, publish at most three openable host-only `server.rack` items, and resolve the current preferred terminal protocol at activation. Older payloads carrying a protocol still decode, but that stale protocol is ignored. Root refreshes shortcuts on scene phase, history, Host and identity changes.
- Vault History follows Known Hosts in the unfiltered links and shows up to 50 individual events from all devices. Search filters by Host, login address, protocol and source-device name before applying the limit; Vault's own search can link into History with the query. The leading symbol stays protocol-specific and the device name comes from `DeviceDirectoryModel`. An event for a now-disabled protocol stays visible but cannot be tapped; row deletion removes one event, while **Clear History** clears the entire timeline, not just 50 displayed rows.

The unified Workspaces rows and local Recents align their text from the same 36-point Host distribution icon slot and
12-point gap. Workspace rows always show protocol at the common right edge and only live runtimes overlay the status dot;
aggregated Recents omits both protocol and live state. Local Recents replaces the empty Workspace section rather than
appearing beside saved-but-dormant Workspaces. TFI exposes no Serial workspace or connection-history kind.

## Vault cards, search and editor ownership

`MobileVaultView` is the Vault landing page, not the owner of every Vault operation. It composes Keychain, Port Forwarding, Snippets, Known Hosts and History as links in its own feature stack. Searching replaces the normal Host/group presentation with matching Host cards and deep links to matching items or page titles; linked subpages receive the query when the match was an item. Metrics search is a cross-tab selection, not an empty Vault detail. Vault's Host sections use the library's group projection: nested groups have path titles, empty groups remain visible, collapse is stored in the library, and search still finds Hosts inside collapsed groups. New Host and New Group are in the add menu; per-group menus create Hosts/subgroups and edit or delete a group. Group deletion offers keeping Hosts (ungrouping them) or deleting the tree's Hosts through the app's Host deletion path.

`MobileCardPage` is a grouped-background scrolling page; `MobileCardGrid` measures its actual width and computes flexible columns with 12-point gaps, forcing a single column at accessibility text sizes. `MobileCard` and `MobileActionCard` share a 106-point minimum-height surface. On iOS 26 the surface uses a concentric shape and glass only when transparency/contrast settings permit; older or higher-contrast/reduced-transparency presentation uses a solid grouped surface. The action card makes the *whole card* the primary button, leaving secondary actions in a context menu. Cards keep at most two visible Host tags to avoid varying the standard height; this is a display limit, not removal of tags from the Host.

A Vault Host card opens/reuses a terminal workspace through `scene.activateHost`; its context menu offers enabled SSH/Telnet/SFTP explicit connections separately from Edit, Duplicate and Delete. The card's relative timestamp comes from app connection history. `MobileAppModel.duplicateHost` gives the copy a new ID/name and strips Host-custom identity references rather than sharing Host-specific secrets. The edit sheet binds `scene.editingHost` so a New Host command can select Vault and present the same editor; Vault keeps only temporary delete/group confirmation state. Known Hosts is a *separate* Vault-linked card page: its primary card tap edits a known SSH host key, context actions copy the fingerprint or request deletion, and its add/edit sheet saves through `app.knownHosts`, not through the Host connection editor.

```mermaid
flowchart TD
    Tap["Vault Host card"] --> Activate["Scene activates preferred terminal Host"]
    Menu["Host context menu"] --> Connect["Explicit protocol connection"]
    Menu --> Edit["Scene-bound Host editor sheet"]
    Menu --> Duplicate["App duplicates Host without custom identity references"]
    Menu --> Confirm["Confirm Host deletion"]
    Confirm --> Cleanup["App deletes Host and cleans shared work"]
    Link["Vault History link"] --> Events["History view over shared event rows"]
```

Vault gestures route to scene selection or application services; a Vault page does not own a running connection or the history repository.

`MobileHostEditor` holds an in-memory Host draft plus `HostCustomIdentityDraft` (password fields live only for the editor's lifetime). Shared `TermindPresentation` Host organization, protocol-profile and connection sections provide the form, while mobile-specific sheets let the user create a group, identity or environment variable and apply that result to the draft. Selecting the SSH or Telnet profile changes which authentication, proxy and session controls appear; save requires an address, an enabled terminal protocol, valid enabled ports, identity/proxy validation and valid SSH environment variables. `HostCustomIdentityDraft.save(into:using:)` persists applicable custom identities and then the Host via the library, throwing on failure. Do not treat a profile switch or sheet dismissal as a save.

`MobileEditorSheet` owns async Save/Cancel behavior for these forms: dirty Cancel asks before discard, Save disables editing and shows progress, a thrown error stays on the sheet in an alert, and success dismisses it. Dirty or saving sheets cannot be interactively dismissed; disappearance cancels the in-flight task. Group and Known Host editors use the same wrapper with their own validation/storage boundary; the Known Host editor distinguishes Add from Edit and does not expose a port field for hashed addresses whose original address/port cannot be recovered.

## Adaptation has three inputs, not one device check

| Input | Mechanism | What it controls |
| --- | --- | --- |
| System navigation placement | `MobileToolbarLayout`, read from tab placement and optionally vertical toolbar edge. | Icon versus title switcher and whether workspace detail keeps tabs visible. |
| Available content geometry | `MobileRegionReader` → `MobileContentRegions`. | Continuous safe area and optional pair of regions around a division. |
| Content/input needs | Measured card width, Dynamic Type, composer height, focus and marked text. | Grid density, scrolling and retained native input surfaces. |

### Content-region algorithm

`MobileContentRegions` starts with the local container bounds, filters active intersecting reserved regions, and computes the largest usable rectangle that avoids them. It retains overlapping candidate rectangles during subtraction; forcing candidates to be disjoint could discard the largest continuous solution. Equal-area candidates prefer earlier vertical then horizontal coordinates.

A **division** can additionally yield a pair of usable regions on either side. An **occlusion** reduces usable space but does not by itself request a two-pane layout. A division with one unusable side is not a valid split. This is region-based layout, not a hard-coded assumption that a particular device always has a hinge.

```mermaid
flowchart LR
    Bounds[Container bounds] --> Regions[MobileContentRegions]
    Reserved[Active divisions and occlusions] --> Regions
    Regions --> Continuous[Largest continuous rectangle]
    Regions --> Pair[Optional usable split pair]
    Continuous --> Terminal[Workspace terminal or SFTP content]
    Pair --> Assistant[Transcript and interaction regions]
    Continuous --> Assistant
    Assistant --> Layout[MobilePaneLayout with stable children]
```

Reserved geometry determines usable content and optional Assistant pane placement without replacing its native children.

Production reserved-region and vertical-toolbar queries require both the `TERMIND_HAS_IOS_27_1_SDK` compilation gate and runtime availability. On older builds/systems the reader falls back to no reserved regions, while previews/tests can inject regions through the environment. The presence of deterministic fold-like tests is not a claim of verification on every physical device.

`MobilePaneLayout` retains a valid size per child index and places the same children into their new frames. Covered content keeps a valid size rather than replacing or reparenting its native surface. The layout must be paired with opacity, hit-testing and accessibility gates: parked geometry alone does not make a covered view noninteractive.

### Examples

- A terminal workspace uses the largest **continuous** region instead of splitting one terminal across a division.
- Assistant uses the first split region for the transcript and bottom-aligns its interaction surface in the second. Without a split, it subtracts measured interaction height from the continuous transcript region.
- A top or vertical navigation arrangement uses an icon-based workspace/conversation switcher; the ordinary arrangement can use the navigation title menu.
- Cards adapt to their measured container width, not a global “iPad has two columns” rule. Accessibility Dynamic Type forces one column.

## Workspace UI: protocol-specific actions, retained terminal

`MobileWorkspaceView` composes the connection/content area, search, feedback overlays, toolbar and transient sheets. Its toolbar is capability-shaped:

| Workspace kind | Representative actions |
| --- | --- |
| SSH | Generate Command, Snippets, command History, terminal match navigation, same-directory action and workspace lifecycle. |
| Telnet | Snippets, terminal match navigation and lifecycle; it does not inherit the SSH generation/history surface. |
| SFTP | Back/forward directory, Transfers, SFTP History, upload/new folder/paste, sort/hidden files/refresh, same-directory action and lifecycle. |

These are not all enabled merely because the menu exists. Connection state, available history, refresh state and operation capability control individual actions.

`MobileTerminalSurface` owns the native terminal view even when SwiftUI navigates away. Its `MobileTerminalView` adds terminal Find key equivalents while preserving Ghostty's ordinary key commands. Escape is intercepted for Find dismissal only while Find is actually presented.

Presentation cleanup is narrower than session shutdown: workspace view disappearance disables external Open With presentation and window drop handling, clears drop targeting and cancels drop loading. It is not itself the instruction to disconnect the workspace. Drop handling is also gated by scene activity and destination changes, so an invisible detail does not accept a late upload as though it were foreground.

Command-generation and upload notices are overlays in the usable region; they do not take over hit testing. File previews, edit-copy export, transfer sheets and conflict alerts remain explicit temporary presentations over the workspace rather than new session owners.

## Assistant: stable transcript/input, independent run ownership

`MobileAssistantView` owns conversation navigation controls, library/archive routes and focus restoration requests. Replacing a conversation preserves composer focus only when it was already focused and the new state can accept focus. The asynchronous request rechecks the conversation ID after yielding, preventing an old request from focusing the wrong chat.

`MobileAssistantConversation` renders an incremental `MobileNativeList` plus a separately measured, scrollable interaction region. Stable entry IDs and per-row presentation revisions let disclosure changes target the relevant rows; viewport callbacks collapse offscreen work presentations. Transcript and interaction children remain stable through region changes, preserving native list identity and text-input composition.

The interaction region can contain more than the composer, so its height is measured rather than assumed from a fixed input-bar constant. It bottom-aligns and scrolls based on content size. Tapping the transcript can dismiss composer focus without changing the conversation or ending the run.

The application runtime owns execution, not `onDisappear` on the conversation view. The view's disappearance only removes its temporary preview directory. App background expiration is a separate boundary.

## Scene activity and background limits

`MobileRootView` reports its scene phase; `MobileAppModel` aggregates all scenes. Entering background handling occurs when **all tracked scenes** are backgrounded, not whenever one feature disappears or one scene resigns activity.

At that boundary the app pauses edit monitoring, memory/sync/Metrics/outbox work and recording, then starts its background allowance. Expiration suspends workspaces, stops forwarding, pauses transfers and expires Assistant background execution. An active scene ends the allowance and asks retained workspaces to resume, rechecks edited files, and restarts the appropriate services. This is best-effort mobile continuity, not unlimited background network execution.

Closing a workspace, navigating back from its detail, switching tabs, and exhausting background allowance are therefore four different actions with different owners. A UI refactor must preserve that distinction.

## Mobile design principles and verification

Implemented principles:

1. **Let the system adapt navigation.** Register each feature once and keep its stack stable.
2. **Adapt to usable space and capability.** Size class alone is insufficient for divisions, occlusions, vertical toolbars and large text.
3. **Preserve native input identity.** A layout transition should not discard marked text, keyboard focus or terminal scrollback.
4. **Use mobile affordances without losing desktop parity of intent.** Primary card taps, context menus, swipe actions, title menus and hardware-keyboard commands can expose the same operation differently.
5. **Keep app work out of transient view lifetimes.** Scene routes select shared work; they do not own every connection or Agent run.
6. **Hide covered interaction as well as pixels.** Hit testing and accessibility must follow the visible region.

`MobileAdaptiveLayoutTests` mounts `MobileRootView` in a UIKit window and checks the same native `UITabBarController` with five selectable destinations over simulated 1024/600/375/320-point widths, regular/compact traits, large/accessibility Dynamic Type, and English, Simplified and Traditional Chinese locales. In compact mode it asserts all five tab labels are visible; on regular iPad widths the system bar can scroll. Other tests retain Assistant conversation/draft and Metrics navigation through resizing, check title-menu/icon switchers and Settings edit sheets, and isolate two scene models. Injected division and occlusion changes verify Metrics keeps the same native list and scroll offset and Assistant keeps its conversation, transcript `ListScrollView`, focused composer and Chinese marked text; a save-in-flight test preserves a sheet and failure feedback through width changes. These are simulated layout and injected-geometry tests, not proof of every physical device or SDK availability branch.

`MobileAppTests` separately covers descriptor order after restoring, opening and renaming live/dormant workspaces, transient external entries, single-connect restoration across scenes, explicit retry after failed connection, and local/remote Host deletion removing both open and unopened descriptors while retaining unrelated Hosts. The adaptive suite also checks localized compact/regular Workspace rows and that choosing a dormant row restores only that runtime without moving the row.

`MobileCardTests` tests card column thresholds (one below 652 points, two from 652, three from 984, but always one for accessibility text), stable Host/action-card height with long or absent tags, the two-tag display limit, nested/empty/collapsed Host groups, Known Host add/edit titles, and Host connection timestamps. `MobileVaultFeatureTests` exercises capability-filtered Host context menus, independent duplication, keep/delete group-tree behavior and proxy validation; `MobileConnectionPickerTests` checks that History caps *matching event rows* at 50, searches device names and leaves disabled-protocol events visible but not openable. These policy tests complement, rather than replace, the UIKit-hosted adaptive tests for real navigation and sheet continuity.

For a change, inspect scene routing tests for navigation, region/layout tests for geometry, workspace/terminal tests for session continuity, and Assistant tests for run-versus-selection ownership. See [Platform Runtime Composition](/openwiki/architecture/platform-runtime.md) and [Build, Test, and Release Operations](/openwiki/operations/build-test-and-release.md) before changing the lifetime boundary.
