# Termind Refactoring Backlog

This document is the long-lived record of removable redundancy and mergeable duplicate implementations in the Swift codebase. Append new findings at the end; retain completed items and update their status.

Documentation rule: **this file must contain English only.**

Implementation constraints:

- Refactoring must produce a net reduction in code. Do not trade superficial reuse for a thicker abstraction layer.
- Delete dead code without production entry points first, merge exact duplication second, and address merely similar structures last.
- Implement one independent item at a time and choose the smallest verification scope appropriate to its risk. Do not repeatedly run the full test suite during exploration.
- Do not merge deliberate SwiftUI/AppKit boundaries merely because their implementations look similar.

## Initial Scan — 2026-08-29

### 1. Delete the obsolete SwiftUI rendering tree left by the Native Transcript migration — Highest priority

**Status:** Completed on 2026-08-30; build and targeted Transcript tests passed.

**Evidence:**

- `ConversationTranscriptSurface.body` in `Termind/Features/AI/ConversationTranscriptView.swift` constructs `TranscriptListView` directly.
- `AgentWorkGroupView` in the same file has no production construction site. Its references to `AgentToolBatchView`, `AgentToolRowView`, and `AgentToolDetailView` form a closed dead-code subgraph.
- `AgentCompactionActivityRowView`, `AgentCompactionRowView`, and `AgentPlanRowView` also have no callers. Their active replacements live in `TranscriptNativeRows.swift`.
- `UserMessageView` and `AssistantMessageView` in `MessageViews.swift` only have declarations. `BubbleContextChipView`, `BubbleImageView`, `MessageActionRow`, `WorkingIndicator`, and `ScanningTextMask` are referenced only by those obsolete views or the dead subgraph above.
- `CommandCardView` is constructed only by the unreachable `AssistantMessageView`. `RiskBadge` remains in use by Snippets, Sidebar, and Markdown code blocks and must be preserved.
- `ChatMessageTimestampFormatter` remains in use by `TranscriptNativeRows.swift` and tests and must be preserved.

**Recommended action:**

1. Delete the closed subgraph from `AgentWorkGroupView` through the old compaction rows in `ConversationTranscriptView.swift`; retain `AgentTaskCapsuleView`, which is still used by the composer.
2. Delete the obsolete `AgentPlanRowView`; retain the current interaction panels beginning with `AgentApprovalCard`.
3. Keep only the timestamp formatter in `MessageViews.swift`. Preserve `CommandRisk.tint` and `RiskBadge` in `CommandCardView.swift`, but delete `CommandCardView`.
4. Run `rg` once before deletion to ensure no entry point was added, then run one build and targeted Transcript tests.

**Estimated net reduction:** Approximately 1,350–1,450 lines with no new abstraction.

### 2. Merge repeated `ListView` / `NSHostingView` bridge templates — High priority

**Status:** Implementation completed on 2026-08-30. Thirteen ordinary hosting rows share `HostingListRow`, and every ordinary SwiftUI-backed ListView coordinator now uses `HostingListContent`, including fixed-height, cursor-scrolling, click-monitoring, sidebar-container, and dynamically measured rows. `TranscriptListView` and the special Assistant conversation row remain dedicated implementations because they do not use the ordinary hosting-row lifecycle. The app build passed before the final Connection Log migration; that last migration passed parser validation, while its final build attempt was rejected by the approval service before execution.

**Evidence:**

- Exact-fragment scanning found 14 nearly byte-identical `*HostingRow: ListRowView` implementations across `TagField.swift`, `AssistantView.swift`, `WindowSidebarView.swift`, `SnippetsPageView.swift`, `SettingsPageView.swift`, `ModelListEditor.swift`, `HostChooserView.swift`, `QuickOpenView.swift`, `StatusBarView.swift`, `SFTPBrowserView.swift`, `KeychainPageView.swift`, `SlashCommandMenuView.swift`, `ConversationViews.swift`, and `ConnectionJourneyView.swift`.
- Each implementation creates `NSHostingView<AnyView>`, installs four edge constraints, clears the view in `prepareForReuse`, and exposes `configure(rootView:)`.
- At least 12 `*NativeList: NSViewRepresentable` implementations repeat renderer erasure, locale and color-scheme propagation, ID-sequence comparison, per-row update/apply behavior, and coordinator state. `ModelEditorNativeList<Item>` demonstrated that the core can be generic.

**Recommended action:**

- Keep one `HostingListRow` and a lightweight shared coordinator core under `UI/Components`. The shared layer should own hosting, environment propagation, and diff/apply behavior; closures should configure row height, insets, measurement, drag and drop, and cursor scrolling.
- Migrate fixed-height lists without drag and drop first, then handle Assistant, Sidebar, SFTP, and dynamically measured Connection Log rows.
- Preserve the Swift 6.3.3 `@_optimize(none) deinit` compiler-workaround behavior in the generic shared core.
- If the common component starts requiring many switches, keep the hosting row and coordinator core separate instead of introducing a giant configuration object.

**Estimated net reduction:** Approximately 700–1,000 lines.

### 3. Consolidate the two terminal initializers in `SSHSessionModel` — High priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:** The two designated initializers in `SSHSessionModel.swift` repeated nearly everything from `PendingInitialCommand`, relay/backend creation, `TerminalViewState`, and `PersistentTerminalViewOwner` through observation installation. Only the sources of host ID, title, transient host, and username hint differed.

**Recommended action:** Use one private designated initializer accepting the shared fields and optional `transientHost` / `usernameHint`. Existing entry points should only map arguments. Do not fabricate a `Host` merely to reuse the initializer because that would change temporary-target semantics.

**Estimated net reduction:** Approximately 35–45 lines.

### 4. Merge SSH and Serial terminal appearance configuration — High priority

**Status:** Completed on 2026-08-30 by consolidating on `TerminalViewState.applyAppearance`; build passed.

**Evidence:** `SSHSessionModel.applyAppearance` and `SerialSessionModel.applyAppearance` were identical apart from formatting: resolve the light/dark theme, set the Ghostty theme, then apply font size and X/Y padding.

**Recommended action:** Consolidate into `TerminalAppearancePreferences.apply(to:)` or `TerminalViewState.applyAppearance(_:)`. Each session model should retain only a one-line call. Keep the code within the existing Terminal design/feature boundary rather than creating a generic `Core` layer.

**Estimated net reduction:** Approximately 20–25 lines.

### 5. Delete meaningless `SFTPSessionModel` forwarding overloads for `TransferLibraryModel` — High priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:** `TransferLibraryModel` already conforms to `RemoteSessionHostStore`, yet `SFTPSessionModel` added forwarding overloads for `connect`, `trustAndConnect`, `continueWithTemporaryHostKey`, and `continueAuthentication` that performed only existential conversion. Existing call sites can bind directly to the protocol versions.

**Recommended action:** Delete the four concrete-type overloads and retain only the `using store: any RemoteSessionHostStore` versions. Call-site signatures need no change.

**Estimated net reduction:** Approximately 18–25 lines.

### 6. Reuse the existing Jump Host configuration builder — High priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:** `HostLibraryModel.sshConnectionConfiguration` inlined route validation, `dropLast().enumerated().map`, submission branching, and `TermindSSHError.routeHost` wrapping. The adjacent `sshJumpConfigurations` implemented the same logic.

**Recommended action:** Make the former call `sshJumpConfigurations(for:submissions:temporaryHostKeys:)` directly and leave it responsible only for the final host's username, credentials, expected keys, and proxy.

**Estimated net reduction:** Approximately 30–40 lines.

### 7. Move more shared SSH/SFTP connection interaction into `RemoteSessionConnectionController` — Medium priority

**Status:** Completed at the safe abstraction boundary on 2026-08-30. Status aliases and Agent SSH prompts were unified; host-key prompt state, persistent/temporary acceptance, route progress forwarding, prompt cleanup, disconnect cleanup, and reconnect-journey presentation now live in `RemoteSessionConnectionController`. Transport-specific socket teardown, shell reset, SFTP refresh cancellation, and restart remain in their session models rather than being hidden behind callback-heavy orchestration. Debug build and targeted connection/SFTP tests passed.

**Evidence:**

- `SSHSessionModel` and `SFTPSessionModel` contained identical `trustAndConnect` implementations. `continueWithTemporaryHostKey`, `progressHandler`, `routeHostID`, `scheduleReconnect`, and `presentReconnectJourney` also share the same skeleton.
- Both own `RemoteSessionConnectionController`, but it currently contains only `ConnectionJourney` and `SessionReconnectController`; shared orchestration remains duplicated in the two large models.

**Recommended action:**

1. First merge transport-independent host-key acceptance, prompt cleanup, route-progress forwarding, and route-host-ID extraction.
2. Then let the controller provide the schedule-reconnect and present-journey skeleton, with closures for transport-specific cleanup and restart.
3. Do not move SSH shell state or SFTP refresh/transfer state into the controller. Stop after the first step if the abstraction requires many `inout` values or callbacks.

**Estimated net reduction:** Approximately 40–60 lines for the first step and 80–120 lines for full consolidation.

### 8. Merge text collectors for short tool-free model tasks — Medium priority

**Status:** Completed on 2026-08-30; targeted Command, Title, and Compaction tests passed.

**Evidence:** `CommandGeneratorService.generate`, `ConversationTitleService.summarize`, and `AgentCompactionService.summarize` all initialized text and stop reason, iterated `model.complete(request)`, handled delta/snapshot events, rejected tool calls, ignored reasoning/provider/search/usage events, and validated the stop reason. The first two differed only in error type and byte limit.

**Recommended action:** Provide a small buffered-text collector at the `AgentModelCompleting` boundary. It should return text and stop reason, support an optional byte limit, and throw a shared protocol error on tool calls. Each service should interpret stop reasons and map its own domain error instead of recreating complexity through policy closures.

**Estimated net reduction:** Approximately 55–80 lines.

### 9. Merge LLM request authorization and default `URLSession` configuration — Medium priority

**Status:** Completed on 2026-08-30; targeted ChatProbe and Provider tests passed.

**Evidence:**

- `ChatProbe.authorize` and `AgentProviderClient.authorize` both set OpenAI bearer authorization, Anthropic API key/version, and Google API key or Vertex access token with nearly identical code.
- `ModelCatalogClient` repeated the same header setup while retaining the meaningful differences that an empty secret adds no header and Vertex does not support the catalog.
- All three clients created ephemeral sessions with `waitsForConnectivity` disabled and differed only in timeout.

**Recommended action:** Create one `ProviderRequestAuthorizer`. Catalog should continue rejecting Vertex before authorization and retain its empty-secret policy. Use a small session factory parameterized by timeout; `AgentProviderClient` should still own its shared session lifetime.

**Estimated net reduction:** Approximately 30–50 lines while reducing provider-branch drift.

### 10. Consolidate SwiftData repository save/rollback transaction templates — Medium priority

**Status:** Completed on 2026-08-30. The two-stage commit required by overflow queries was retained; targeted Connection and SFTP History tests passed.

**Evidence:** `SwiftDataCommandHistoryRepository`, `SwiftDataConnectionHistoryRepository`, `SwiftDataSFTPHistoryRepository`, and `SwiftDataToolAuditRepository` repeatedly implemented `do { mutate; save } catch { rollback; throw }`. The first three also repeated the template for by-ID deletion and by-host clearing. Tool Audit had a file-private `mutate` helper that other repositories could not reuse.

**Recommended action:** Provide a narrowly scoped `ModelContext.commit(_:)` helper in Database infrastructure to centralize mutation, save, and rollback. Do not force SwiftData `#Predicate` through a generic abstraction because that would make macro expansion and type inference more complex. Connection/SFTP overflow trimming must remain a second commit because offset fetches require the inserted or updated row to be visible first.

**Estimated net reduction:** Approximately 45–65 lines.

### 11. Merge libssh2 worker DispatchQueue/continuation bridges — Low priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:** `SSHExecWorker` and the SFTP worker each had byte-identical `perform<T: Sendable>` and `performNoThrow` implementations that wrapped `queue.async` with checked continuations.

**Recommended action:** Define the smallest serial-worker bridge or `DispatchQueue` helper within `Infrastructure/SSH`. Do not expand it into a project-wide concurrency utility library.

**Estimated net reduction:** Approximately 10–16 lines.

## Items Not Recommended for Consolidation in This Pass

- The correct treatment of `TranscriptNativeRows.swift` and the obsolete SwiftUI Transcript tree is deletion of the unreachable tree, not wrapping the AppKit renderer back in SwiftUI.
- SSH terminal and SFTP transport success/cleanup behavior differs materially. Consolidate only the host-key, authentication, and reconnect skeleton; do not create a giant session base class.
- `TransferLibraryModel` forwarding appears redundant but is the narrow facade required by the architecture. No alternative currently both reduces code and preserves the permission boundary.

## Deep Scan II — 2026-08-29

This pass additionally inspected migration compatibility layers, single-use forwarding APIs, state machines, SFTP paths, and tool-presentation metadata. The working tree contained concurrent changes during the scan. Reconfirm line numbers and call relationships before implementing any item that touches concurrently modified files.

### 12. Delete remaining Native Transcript presentation helpers — High priority; supplement to Item 1

**Status:** Completed on 2026-08-30 as part of Item 1.

**Evidence:**

- `TranscriptEntry.isActivelyStreaming` had only a declaration and no call site; native rows determine their own activity state from entry content.
- `TranscriptPresentationState.messageEditBinding(for:)` was called only by the obsolete `UserMessageView`. It became dead code when Item 1 removed the old SwiftUI message tree.
- After removal of that tree, the SwiftUI versions of `WorkingIndicator` and `ScanningTextMask` also had no entry point; `TranscriptNativeRows.swift` already had an independent AppKit activity label.

**Recommended action:** Include these helpers in Item 1's deletion list rather than preserving them only as test interfaces. Tests should cover the real native-row entry point.

**Estimated additional net reduction:** Approximately 20–35 lines.

### 13. Finish the `ConversationComposerState` migration and delete four compatibility accessors — Medium-high priority

**Status:** Completed on 2026-08-30; build and targeted ChatComposer tests passed.

**Evidence:** `ConversationModel` explicitly marked `attachments`, `pendingAttachments`, `attachmentImportError`, and `draft` as compatibility accessors during a view migration. `ComposerView` had already created `@Bindable var composer = conversation.composer` and bound its editor directly, while other branches in the file, `AppModel`, `AssistantLibraryModel`, `TerminalPlaceholderView`, and tests still mixed the forwarding properties with direct composer state.

**Recommended action:**

1. Make all composer UI read and write `conversation.composer`; application code consuming the draft should also read the focused state directly.
2. Continue mutating attachments through existing `ConversationModel` methods so context-estimate refresh is preserved. Views must not replace the attachment array directly.
3. Update tests, then delete the four computed properties and the compatibility-accessor comment.

**Estimated net reduction:** Approximately 15–25 lines while removing two APIs for the same state.

### 14. Delete the unreachable Window Toolbar search-menu pipeline — High priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:**

- `WindowToolbarFindContext.menuItems` and `NativeSearchField.menuItems` were nil at every construction site. A Hosts comment also stated that tag filtering had moved to the page-canvas menu.
- Therefore the entire `NativeSearchField.Coordinator` `NSMenuDelegate`, persistent `NSMenu`, `updateMenu`, `menuNeedsUpdate`, and `searchMenuTemplate` path was unreachable.
- Every switch branch assigned `WindowToolbarFindContext.kind`, but no code read it. The real kind had already been consumed by `WindowModel.findKind` before constructing the context.

**Recommended action:** Delete both `menuItems` layers, the entire NSMenu delegate pipeline, and the context `kind` field. Shorten stale comments. `NativeSearchField` should continue handling only the query, focus, Return/Shift-Return, and Escape.

**Estimated net reduction:** Approximately 35–50 lines.

### 15. Move Agent SSH request-to-Journey prompt conversion onto the request type — Medium-high priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:** `ExternalAuthWindow.prompt(for:)` and `AgentSSHAuthenticationCard.prompt` constructed the same `SSHAuthenticationPrompt`: temporary `Host`, selected identity/key, username, failure, passphrase mode, and local/server-challenge mode. Both also independently checked whether `request.mode` was passphrase mode.

**Recommended action:** Add read-only `requiresPassphrase` and `journeyPrompt` properties to `AgentSSHAuthenticationRequest`, or use one Application-layer conversion function. Both presentations should consume that value, and submission should reuse `requiresPassphrase` when deciding whether saving is permitted.

**Estimated net reduction:** Approximately 20–30 lines.

### 16. Extract the SFTP atomic remote-write lifecycle — High priority

**Status:** Completed on 2026-08-30; build and targeted SFTP Feature/Session tests passed.

**Evidence:** `SFTPWorker.writeFile`, local-file `uploadFile`, and socket `uploadFile` each repeated the following sequence:

- Generate a `.termind-part-<UUID>` temporary remote path.
- Open it with WRITE/CREAT/TRUNC and mode 0600.
- Close the handle in `defer` and unlink it on failure.
- Atomically replace the destination with `renameOnQueue` and mark success.

The two upload paths also duplicated `completed`, `measuredBytes`, and `measuredAt` bookkeeping and calculated throttled `SFTPProgress` every 250 ms.

**Recommended action:** Add a file-private `withAtomicRemoteWrite` that passes an opened handle to a write closure and centralizes cleanup and rename. Use a small value type for throttled progress sampling. Keep each data source's read loop separate.

**Estimated net reduction:** Approximately 55–85 lines.

### 17. Merge conflict resolution for ordinary transfers and remote copies — High priority

**Status:** Completed on 2026-08-30. Keep Both path selection, remote-directory resolution, and remote-file conflict policy for ordinary transfers and remote copies were unified. Debug build and targeted SFTP Feature/Session tests passed.

**Evidence:**

- `SFTPSessionModel.enqueuePending` and `enqueuePendingRemoteCopy` separately implemented remote-directory skip/replace/keepBoth behavior, ancestor-prefix skipping, path mappings, and directory creation.
- The `index = 2` + `RemotePath.keepBothCandidate` + remote-attributes loop for selecting an available Keep Both path occurred four times across the two functions.
- Both prepared-job types store destination path, byte count, `hasConflict`, and `conflictingTargetIsDirectory`; they differ because ordinary jobs also carry local and direction fields.

**Recommended action:**

1. Extract `availableRemotePath(for:client:)` and a shared remote-directory conflict resolver.
2. Extract a narrow function that applies a conflict policy to one remote target and returns skip, new path, or overwrite. Keep ordinary-download local conflict handling separate.
3. Do not replace the two clear job types with one universal job full of optional local/source fields.

**Estimated net reduction:** Approximately 35–50 lines for the first step and 65–100 lines for full consolidation.

### 18. Consolidate saved/borrowed client leases in `SFTPTransferCoordinator` — Medium priority

**Status:** Completed on 2026-08-30; build and targeted SFTP Feature tests passed.

**Evidence:** `remoteManifest`, `start`, and `startRemoteCopy` repeatedly switched over `SFTPTransferConnection`: saved connections used factory + connect + final disconnect, while borrowed connections used the client directly and must not disconnect it. Remote copy duplicated this for source and destination.

**Recommended action:** Add a file-private client-lease value containing the client and `ownsConnection`. Centralize acquisition and conditional disconnect. Borrowed-connection reservation remains coordinator state and should not move into the lease.

**Estimated net reduction:** Approximately 25–45 lines.

### 19. Consolidate historical tool-presentation mappings into one legacy metadata table — High priority

**Status:** Completed on 2026-08-30. The metadata table preserves the old fallback-matching semantics; targeted `AgentToolPresentation` tests passed.

**Evidence:** `AgentToolPresentation.swift` retained compatibility for old transcripts, but mappings from a tool name to presentation semantics were spread across:

- The argument/label switch in `recoveredBuiltInOperation`.
- The action switch in `actionKind(for:)`.
- The descriptor-name + fallback switch in `legacyActivity`.
- A temporary array of SFTP tool names.

The same built-in name consequently appeared in three or four places. Current descriptors already carry semantic activity and action; only historical records require these mappings.

**Recommended action:** Create one `LegacyToolPresentation` table keyed by tool name and storing argument key, fallback activity, and action kind. All fallback entry points should read the same record. Unknown MCP tools must continue through the generic fallback and must not enter the built-in table.

**Estimated net reduction:** Approximately 70–110 lines while reducing historical-mapping drift.

### 20. Delete the test-only `Presentation.Action` construction path and compress verb forms — Medium priority

**Status:** Completed on 2026-08-30. English verb forms were compressed, tests now use the production `actionKind` semantics, and the old Action construction path was deleted.

**Evidence:**

- `AgentToolDescriptor.Presentation.Action` and the initializer's `action:` parameter had no production callers and were constructed only by `AgentToolPresentationTests`.
- Every production `includesTarget` call was paired with `actionKind` while `action` was nil, so the initializer branch that generated target-bearing messages never ran.
- `actionName` encoded 22 actions × 3 tenses as approximately 66 tuple cases, and `localizedActionVerb` listed the same 22 actions again.

**Recommended action:**

1. Update historical-template tests to pass `messages` overrides directly, then delete `Action`, `action:`, `includesTarget`, and automatic message generation. Preserve persisted decoding of the `messages` field.
2. Return a three-form English verb record for each action kind and select the requested form afterward, reducing approximately 66 combinations to 22 records. Keep Chinese localization and English forms keyed by the same action enum.

**Estimated net reduction:** Approximately 55–85 lines.

### 21. Merge the input-unpacking template used by tool detail presenters — Medium priority

**Status:** Completed on 2026-08-30. Object/array unpacking and generic fallback now live in `AgentToolDetailFormatting`; build passed at implementation time.

**Evidence:** Built-in Agent presenters contained 23 copies of `guard let object/values = input.result... else { genericItems }`; 19 then created an empty `items` array. `AgentScratchTools.swift` alone copied the same function prefix 11 times.

**Recommended action:** Add two narrow helpers to `AgentToolDetailFormatting`: `objectItems(input, build:)` and `arrayItems(input, build:)`. They should own only type checking and generic fallback; each tool must retain its field-specific presentation instead of introducing a schema-driven universal renderer.

**Estimated net reduction:** Approximately 35–55 lines.

### 22. Merge the two Agent idle-sweeper timers — Medium priority

**Status:** Completed on 2026-08-30. Both registries share `AgentIdleSweeper`; related targeted tests passed.

**Evidence:** `AgentBackgroundCommands.startSweeping/stopSweepingIfEmpty` and the corresponding `AgentConnectionPool` methods used the same timer task: start when nonempty, sleep for `sweepInterval`, call `sweepIdle(now:)`, exit when none remain, and cancel when empty. The only meaningful difference was whether emptiness also considered pending connections.

**Recommended action:** Use a small Application/Agent-scoped `IdleSweeper` to manage Task lifetime while callers provide the asynchronous sweep closure and their own emptiness condition. Extract only the timer, not registry entries or expiry logic.

**Estimated net reduction:** Approximately 15–25 lines.

### 23. Reuse `SidebarSectionHeader` for count/collapse layout — Medium priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:** `AssistantSectionHeaderRow` and `SnippetSidebarSectionHeaderRow` exactly duplicated title, count, chevron, 34-point height, sidebar insets, accessibility, and toggle layout. `UI/Components/SidebarRow.swift` already contained a nearly identical `SidebarSectionHeader` without count support.

**Recommended action:** Let the shared header accept an optional count, configurable title `Text`, and Binding/closure toggle. Assistant's AppStorage Boolean and Snippets' serialized collapsed state should only provide state and no longer redraw the row.

**Estimated net reduction:** Approximately 35–50 lines.

### 24. Unify Host deletion entry points and remove direct persistence deletion — Medium-high priority

**Status:** Completed on 2026-08-30. Group deletion now uses the repository deletion saga and the old direct `delete(hostID:)` path was removed. Debug build and targeted Repository Outbox, Snippet, and Port Forwarding tests passed.

**Evidence:**

- `HostLibraryModel.delete(hostID:)` and `projectHostDeletion` duplicated cleanup of hosts, jump references, snippet targets, forwardings, and runtime status. The former additionally triggered a callback and `persistCore`.
- Single-Host UI already used `AppModel.requestHostDeletion` → repository/outbox → projection, while `HostLibraryModel.delete(groupID:keepHosts:false)` still called the old direct deletion path. Two tests also used the old entry point.
- This kept both the repository saga and the old snapshot-persistence lifecycle alive.

**Recommended action:** For group deletion, compute the affected hosts in AppModel/repository code, request durable deletion for each, and then remove the empty group. Update tests to verify `projectHostDeletion` or the repository saga. Finally delete `delete(hostID:)` and retain only one projection helper.

**Estimated net reduction:** Approximately 15–30 lines. The main benefit is deleting the second lifecycle rather than raw line count.

### 25. Remove confirmed uncalled thin wrappers and constants — High priority; small batch

**Status:** Completed on 2026-08-30; build passed.

Reference scanning confirmed that the following declarations had no callers:

- `AgentBuiltInTools.hostPathPreflight`.
- `SettingsKey.isRemoteWindowTitleInMenuBarEnabled`; real reads use `@AppStorage` plus a default.
- `Metrics.Chat.caretWidth` and `caretHeight`.
- `RemoteSessionConnectionController.retryNow` and `stopReconnecting`; both session models call the internal reconnect controller directly.
- `RemoteSessionHostStore.setSSHSessionStatus` and its `HostLibraryModel` / `TransferLibraryModel` forwarders; it only renamed `setConnectionStatus`.

**Recommended action:** Delete these declarations and standardize SSH status calls on the shared name. Run `rg` once immediately before implementation in case a concurrent change added a caller.

**Estimated net reduction:** Approximately 25–40 lines.

## Implementation Verification — 2026-08-30

- Current Swift changes, including untracked Swift support files, add 1,448 lines and delete 3,677 lines: **net −2,229 lines**. The deleted count remains substantially greater than the added count.
- A current Debug macOS build passed after Items 2, 7, 17, and 24 were implemented. The final Connection Log coordinator migration was then parser-verified; a subsequent build request did not execute because the approval service returned a transient 502 rejection.
- The targeted verification batch passed: `ConnectionJourneyTests`, `SFTPFeatureTests`, `SFTPSessionTests`, `QuickOpenTests`, `WindowSidebarTests`, `RepositoryOutboxTests`, `SnippetFeatureTests`, and `PortForwardingFeatureTests`. Earlier targeted batches for tool presentation, histories, idle sweeping, provider networking, compaction, and Transcript/Composer behavior also passed.
- Compiling the test target exposed two stale Swift 6 issues in `ExternalRequestTests`: missing required `startedAt` arguments and mutation of an actor-isolated captured Boolean from a Sendable observation callback. Fixed timestamps and a nonisolated reference flag now keep those serialized tests deterministic and compilable.
- Items 1–25 are implemented at their documented safe boundaries. Future entries should be appended for newly discovered duplication instead of broadening completed items into callback-heavy abstractions.
