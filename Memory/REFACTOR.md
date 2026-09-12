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

## Deep Scan III — 2026-08-30

This pass rescanned all 252 production Swift files after Items 1–25 were completed. It compared exact and identifier-normalized code fragments, checked low-reference declarations against both `Termind` and `TermindTests`, and then read each candidate in context. The findings below are new work; none requires reviving an abstraction rejected by an earlier item.

### 26. Delete the byte-identical `SettingsCollectionPage` wrapper — Highest priority

**Status:** Completed on 2026-08-30; build and focused Settings tests passed.

**Evidence:**

- `SettingsFormPage` and `SettingsCollectionPage` in `Termind/Features/Settings/SettingsPageView.swift` have identical stored properties and identical bodies: header, divider, grouped form, content-width constraint, and outer expansion.
- The only distinction is the type name. Provider and MCP routes construct `SettingsCollectionPage`; every other route constructs `SettingsFormPage`. There is no behavior or styling attached to the distinction.

**Recommended action:** Replace the two `SettingsCollectionPage` construction sites with `SettingsFormPage`, then delete `SettingsCollectionPage`. Do not introduce a renamed third wrapper.

**Estimated net reduction:** Approximately 15–17 lines with no new code.

### 27. Merge the three fixed-height cursor-scrolling hosting lists — High priority; follow-up to Item 2

**Status:** Completed on 2026-08-30; build and focused ListView/Chooser tests passed.

**Evidence:**

- `SnippetTargetNativeList`, `HostChooserNativeList`, and `ExportHostNativeList` are still nearly byte-identical after the general ListView migration.
- All three use a 52-point `HostingListRow`, `ListBouncyAnimator`, `HostingListContent`, animated updates, and `items.first(where: \.isCursor)` followed by the same non-animated nearest-row scroll.
- Their item types all satisfy the same real contract: `Identifiable & Hashable & SendableMetatype` plus a Boolean cursor property. Only the item and renderer types differ.

**Recommended action:** Add one narrowly named fixed-height cursor hosting adapter in `UI/Components`, backed by a tiny item protocol exposing `isCursor`. Replace only these three adapters. Keep dynamically sized lists, drag/drop lists, Assistant conversation rows, and Transcript rows out of it.

**Estimated net reduction:** Approximately 80–110 lines after the shared adapter is counted.

### 28. Share the Agent Exec/SFTP authentication retry loop — High priority

**Status:** Completed on 2026-08-30; build and all 21 Agent Host Authentication tests passed.

**Evidence:**

- `AgentSSHAuthenticationRegistry.openExec` and the loop inside `sftp` in `Termind/Application/Agent/AgentConnections.swift` repeat the same attempt-generation selection and four error branches.
- Both retry authentication, obtain a new configuration attempt, retry untrusted/changed host keys, and disconnect the matching pooled connection before retrying remote authentication or host-key failures.
- The meaningful differences are only the pool kind and the operation used to open the connection.

**Recommended action:** Extract a private generic `openAuthenticated` loop that receives the connection kind and one async open closure. Keep Exec and SFTP return types explicit at their public entry points. Do not move pool implementation or authentication-session state into the helper.

**Estimated net reduction:** Approximately 35–50 lines.

### 29. Remove the second Native Transcript risk-color and destructive-confirmation implementation — High priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:**

- `TranscriptNativeRows.swift` defines both `CommandNativeRow.riskColor` and file-private `nativeRiskColor`; their switches are identical.
- The same file defines both `CommandNativeRow.confirmDestructiveCommand` and `presentDestructiveCommandConfirmation`; the complete `NSAlert` construction and sheet/modal fallback are byte-identical.
- Each pair exists only because two native row implementations call different names. No type-specific state is used by either helper.

**Recommended action:** Keep one file-private risk-color function and one file-private confirmation function and route both row types through them. Prefer the file-private location because neither operation belongs to one row class.

**Estimated net reduction:** Approximately 25–35 lines.

### 30. Replace three copied Glass shape modifiers with one shape-parameterized modifier — Medium-high priority

**Status:** Completed on 2026-08-30; build passed.

**Evidence:**

- `TermindGlassSurface`, `TermindGlassCapsule`, and `TermindGlassCircle` in `Termind/Design/DesignTokens.swift` repeat the macOS 26 availability branch, regular Glass configuration, material fallback, optional tint fill, border, and hit-testing behavior.
- Their only semantic difference is the shape: rounded rectangle, capsule, or circle. The public `termindGlassSurface`, `termindGlassCapsule`, and `termindGlassCircle` methods can remain unchanged.

**Recommended action:** Use one private generic modifier parameterized by an insettable shape and have the three public view extensions construct it with the appropriate shape. Preserve the existing API and macOS 15 fallback exactly; do not type-erase the whole view tree.

**Estimated net reduction:** Approximately 35–45 lines.

### 31. Consolidate local Vault envelope insertion/update — Medium priority

**Status:** Completed on 2026-08-30; build and all focused Vault Sync tests passed.

**Evidence:**

- `VaultSyncPersistence.recordLocalChanges` repeats the same `if let row { apply } else { create, insert, cache }` block for payload changes and tombstones.
- `recordCurrentSnapshot` repeats that block again for current payloads, while `acceptRemote` contains the same insertion/update shape with `needsUpload: false`.
- Envelope construction and the rules deciding which records changed are meaningful and different; only persistence of an already-constructed envelope is duplicated.

**Recommended action:** Add a private helper that stores one `VaultEnvelope`, accepts `needsUpload`, and updates the in-memory `entries` index. Leave version creation, tombstone detection, `changed` tracking, and remote merge policy in their current callers.

**Estimated net reduction:** Approximately 20–30 lines.

### 32. Share remaining SFTP remote-conflict preflight — Medium-high priority; distinct from Item 17

**Status:** Completed on 2026-08-30; build and focused SFTP Feature/Session tests passed.

**Evidence:**

- `SFTPSessionModel.prepareUpload` and `prepareRemoteCopy` still independently sort remote directories by path length, skip descendants of an already-conflicting directory, query remote attributes, count conflicts, and then query every remaining destination path.
- Item 17 unified conflict-policy resolution after a batch exists. This duplication occurs earlier, while the two batch types are being prepared, so it was not removed by that work.
- `PreparedJob` and `PreparedRemoteCopyJob` should remain separate; the reusable result is only the set of conflicting directories and the attributes found for destination paths.

**Recommended action:** Extract a private async preflight that accepts remote directories and destination paths and returns ordered directories, conflicting directory paths, and conflicting target kinds. Each caller should map that result back onto its own job type. Do not create a universal transfer job with optional local/source fields.

**Estimated net reduction:** Approximately 25–40 lines.

### 33. Centralize the effective Vertex mode and credential reference on `ModelProvider` — Medium priority

**Status:** Completed on 2026-08-30; build and focused Provider tests passed.

**Evidence:**

- The expression `usesVertex && kind == .google` is repeated across `ModelProvider`, `ModelCatalogClient`, `ModelListEditor`, `ModelProviderEditorSheet`, `CommandGeneratorService`, `ConversationTitleService`, and `AppModel`.
- Six model-construction paths independently select `vertex.credentialRef` versus `credentialRef` with the same ternary expression.
- `ModelProvider` already owns related derived behavior such as `hasCredential`, `resolvedRequestURL`, and `resolvedModelsURL`; callers should not re-derive which authentication mode is active.

**Recommended action:** Add concise derived properties such as `usesVertexEndpoint` and `effectiveCredentialRef` to `ModelProvider`, then replace external branch copies. Keep `hasCredential` stricter than a nonempty reference because Vertex also requires project configuration.

**Estimated net reduction:** Approximately 15–25 lines while removing a repeated provider rule.

### 34. Delete newly confirmed uncalled declarations and unused decoded metadata — High priority; small batch

**Status:** Completed on 2026-08-30; build passed.

Reference scanning across production and test Swift found no caller for:

- `OnboardingController.isPresenting`.
- `AgentBuiltInTools.hostPreflight` in `AgentBuiltInSFTPTools.swift`.
- `TermindColor.disabledForeground`, `nativeSuccess`, `nativeWarning`, and `nativeDanger`.
- `TrialEligibilityStore.expireForTesting`; the Debug controller exposes only `resetForTesting`.
- Runtime reads of `LinuxDistributionIconEntry.slug`, `sourceURL`, and `license`, and of `LinuxDistributionIconCatalog.source`, `package`, `version`, and `integrity`. The icon lookup uses only `title`, `asset`, `ids`, and `hex`.

**Recommended action:** Delete the declarations after one final `rg` check. Remove the unused Linux metadata fields only from the runtime Codable structs; keep the metadata in the generated JSON and update script as supply-chain/license provenance. Swift's decoder ignores those extra JSON keys.

**Estimated net reduction:** Approximately 35–45 lines with no replacement abstraction.

## Deep Scan III — Items Deliberately Not Added

- The duplicated V7/V8 SwiftData Host models in `HostPersistence.swift` are migration schemas, not ordinary runtime duplication. Merging them would invalidate stored-model contracts.
- The dedicated Assistant conversation hosting row remains intentionally separate from `HostingListRow`: it clears itself when detached from the hierarchy and carries drag/drop identity state.
- SSH and SFTP session models still share visible authentication shapes, but their credential persistence, transient-host handling, transport startup, and failure recovery differ. No further whole-session abstraction is recommended beyond the small connection-controller boundary already completed in Item 7.
- The in-memory Command, Connection, and SFTP history repositories are structurally similar, but a generic repository would introduce type-erased predicates or policy closures for little net reduction. Their shared SwiftData transaction mechanics were already consolidated in Item 10.

## Deep Scan III Implementation Verification — 2026-08-30

- Items 26–34 add 235 and delete 508 production Swift lines: **net −273 lines**. Documentation changes are excluded from this count.
- One Debug macOS build completed successfully after all nine items were implemented.
- The focused batch ran 114 tests across Vault Sync, SFTP Feature/Session, Agent Connection Pool, ListView migration, Managed Chooser, AI Provider persistence, Settings navigation, and the color system. 113 passed. The sole failure is an unrelated pre-existing static-scan false positive: `ColorSystemTests.featureUIHasNoLiteralDisplayColorsOrDecorativeBlue` interprets the domain value `colorTag: .blue` in unchanged `HostLibraryModel+Demo.swift` as a display color.
- A separate final run of all 21 `AgentHostAuthenticationTests` passed, covering shared prompts, rejected credentials, stale generations, host-key retries, Exec/SFTP separation, and scratch SFTP reuse through the consolidated retry loop.
- `git diff --check` passed, and final reference scans found no remaining use of the deleted declarations or duplicate wrapper/helper names.

## Focused State Ownership Pass — 2026-09-01

### 35. Derive Conversation run presentation from one reported state — High priority

**Status:** Completed on 2026-09-01; build and all state-focused tests passed.

**Evidence:**

- `ConversationModel` stores the runtime's `AgentRunState` in `runtimeState`, copies a ranked projection into
  `runState`, and copies that projection again into `isStreaming` as a Boolean.
- Eighteen `refreshRunState()` calls manually synchronize those three properties after runtime events and pending
  approval, review, question, SSH authentication, and host-key queue changes.
- `Memory/ARCHITECTURE.md` already defines the intended invariant: run state is derived from what is outstanding
  rather than asserted by the last call to move. The public state and streaming flag therefore do not need their own
  storage.

**Recommended action:** Rename the private source to `reportedRunState`, make public `runState` rank that source
against the outstanding queues, and derive `isStreaming` from `runState`. Derive an active work group's presentation
state at read time while retaining only final states in its durable summary. Delete `refreshRunState()` and all manual
synchronization calls. Do not move approval or input queues into a new state container.

**Estimated net reduction:** Approximately 8–15 lines while deleting two independently mutable representations of
the same effective state.

**Verification:** Production Swift changed by +29/−64 lines, and production plus the new Observation regression test
remains net −8 Swift lines. All five `AgentApprovalQueueTests` passed, including derived-state invalidation. The eight
directly relevant Chat Composer stop, terminal-state, and streaming tests also passed during the focused run. The
complete Chat Composer suite still has two unrelated failures in its attachment-limit fixture and an existing Chinese
duration-string expectation. The localization check and `git diff --check` passed.

## Focused Test Value Pass — 2026-09-02

### 36. Delete tests that only freeze user-facing copy — High priority

**Status:** Completed on 2026-09-02; the affected test target compiled and focused behavioral tests passed.

**Evidence:**

- The first seven tests in `AgentToolPresentationTests` spend more than 300 lines enumerating exact English and
  Simplified Chinese sentences, verb forms, punctuation, and icon names. They do not exercise tool execution,
  authorization, persistence, structured detail safety, or output bounds.
- `SerialFeatureTests`, `SFTPFeatureTests`, `ManagedChooserTests`, `WindowToolbarFindTests`, `ChatProbeTests`, and
  `ScreenshotDemoTests` each contain isolated assertions whose only contract is literal UI copy or fixture prose.
- Exact copy assertions make ordinary wording and translation improvements require test edits while providing no
  regression signal for product behavior.

**Recommended action:** Delete whole tests whose sole subject is literal copy and remove isolated literal-copy
assertions from otherwise valuable behavioral tests. Retain localization selection behavior, persisted/wire values,
protocol payload formatting, state transitions, structured tool-detail redaction, and rendering bounds. Run the
affected focused suites, the localization script, a Debug build, and `git diff --check`.

**Estimated net reduction:** Approximately 450–550 test lines with no production changes.

**Verification:** Removed 20 complete tests plus isolated copy assertions from six retained behavioral tests. Test
Swift changed by +1/−531 lines (the added line shortens the name of a retained legacy-decoding test), for a net
reduction of 530 lines and no production changes. The focused batch compiled and ran 217 tests across the 14 affected
suites: 213 passed, and the four issues were the already-recorded Chat Composer attachment-limit fixture and Chinese
duration expectation. The one touched Chat Composer test then passed alone. The localization check and
`git diff --check` passed. The full suite compiled and ran 1,026 tests: 1,019 passed and seven existing or unrelated
failures remained in Chat Composer (three), Broadcast Input, Color System, SFTP upload refresh, and Window State. The
SFTP upload-refresh test passed in the focused batch, confirming its full-suite crash is not caused by deleting the
adjacent kind-description test. The repository-wide strict format lint remains blocked by pre-existing violations
across production and test files; the test target compilation is the syntax check for this deletion pass.

## Production Logic Pass — 2026-09-02

This pass excludes `TermindTests` from candidate discovery and focuses on runtime state, persistence, networking, and
feature orchestration under `Termind`. Migration schemas and the intentionally separate SSH/SFTP session lifecycles
remain out of scope.

### 37. Share checked HTTP execution for model catalog and connection probes — High priority

**Status:** Completed on 2026-09-02; build and focused Provider/Probe tests passed.

**Evidence:**

- `ModelCatalogClient.get` and `ChatProbe.run` both call the same injected `URLSession`, translate `URLError` into
  `ModelCatalogError.transport`, reject non-HTTP responses with the same localized error, and turn non-2xx responses
  into the same status/body error.
- `ProviderNetworking` already owns the shared provider authorization and ephemeral-session rules, so keeping response
  validation beside them removes a second transport policy without crossing an architecture boundary.
- `ChatProbe` still needs to measure elapsed time and parse its provider-specific reply; `ModelCatalogClient` still
  owns pagination and catalog decoding. Only the identical request execution and validation belong in the helper.

**Recommended action:** Add one checked-data operation to `ProviderNetworking` and route both callers through it.
Keep request construction, timing, pagination, and payload parsing in their current owners.

**Estimated net reduction:** Approximately 7 production lines.

**Verification:** `ProviderNetworking.data(for:using:)` now owns URLSession transport errors, HTTP response validation,
and non-2xx status/body errors for both callers. Production Swift changed by +22/−29 lines, for a net reduction of
7 lines. Strict format lint passed for all three touched production files. The Debug test build succeeded and all 12
tests in `AIProviderPersistenceTests` and `ChatProbeTests` passed. `git diff --check` passed.

### 38. Delete the uncalled Finder-only native drop wrapper — High priority

**Status:** Completed on 2026-09-02; build and focused File Drop tests passed.

**Evidence:**

- `NativeFileURLDropTarget` has no construction site in production or tests. All four production destinations use the
  more capable `NativeDropTarget` with explicit accepted kinds.
- The wrapper only adapts `NativeDropTarget`'s underlying `FileURLDropNSView` back to file URLs and duplicates its
  make/update/target-binding bridge.
- The `FileURLDropNSView` convenience initializer remains useful to focused AppKit tests and is independent of the
  dead SwiftUI wrapper.

**Recommended action:** Delete only `NativeFileURLDropTarget`. Retain `NativeDropTarget`, `FileURLDropNSView`, and the
test-facing convenience initializer.

**Estimated net reduction:** 27 production lines.

**Verification:** Deleted only `NativeFileURLDropTarget`; the generalized production target and the test-facing
`FileURLDropNSView` convenience initializer remain. A final reference scan found no remaining wrapper use. All five
`FileURLDropTargetTests` passed as part of the focused Debug test build.

### 39. Centralize fallback Context Chip boundary and filename rules — Medium priority

**Status:** Completed on 2026-09-02; build and focused attachment recovery tests passed.

**Evidence:**

- `ContextChip.visiblePrompt` and `visibleReferences` independently scan every chip kind for the first model-facing
  attachment block boundary.
- `ContextChip.contextAttachment` and `ContextChip.Kind.fallbackAttachment` independently derive the same fallback
  filename: files become `<stem> extracted.txt`; other extensionless labels gain `.txt`.
- These are persistence-recovery rules, not presentation choices. Drift would make a restored chip disagree with the
  attachment created before persistence.

**Recommended action:** Add one private boundary helper and one `ContextChip.Kind` fallback-filename helper, then use
them from both live attachment creation and restored-reference recovery. Do not introduce a general markup parser.

**Estimated net reduction:** 3 production lines while removing two independently maintained rules.

**Verification:** `ContextChip.payloadBoundary` now serves both visible-text and reference recovery, and
`ContextChip.Kind.fallbackFilename` serves both live and restored fallback attachments. Production Swift changed by
+20/−23 lines. The directly relevant manual-attachment and legacy-file-reference tests passed. The complete 66-test
Chat Composer suite retained its two known unrelated failures: the attachment-limit fixture and Chinese duration copy.

### 40. Finish save-or-rollback reuse in SwiftData infrastructure — Medium priority

**Status:** Completed on 2026-09-02; build and focused persistence tests passed.

**Evidence:**

- `AgentPersistence` contains three byte-identical `do { save } catch { rollback; throw }` blocks after mutations;
  `SwiftDataOutboxStore` contains the same block as a private helper.
- `AIPersistence.save` and `AgentPersistence.createConversation` wrap larger mutation batches in the same lifecycle.
- `ModelContext+Commit` already establishes rollback-on-failure as the shared database transaction policy, but it only
  exposes the closure-taking form, leaving already-staged mutations to repeat the save tail.

**Recommended action:** Add a narrowly named save-pending-changes helper beside `ModelContext.commit`, reuse it for
the exact save tails, and let `commit` retain responsibility for rolling back operation failures. Do not rewrite the
two-stage history commits or Vault Sync transactions, whose save boundaries are semantic.

**Estimated net reduction:** 24 production lines.

**Verification:** Added `ModelContext.savePendingChanges`, reused it for the three staged Agent saves and the Outbox
save helper, and routed the AI snapshot and conversation-creation mutation batches through `ModelContext.commit`.
Production Swift changed by +10/−34 lines. The focused Debug build passed all 46 selected tests across Agent
Persistence, Repository Outbox, AI Provider Persistence, and File Drop. The database
scan no longer finds the four byte-identical save/rollback tails. Vault Sync and two-stage history commits were not
changed.

## Production Logic Pass Verification — 2026-09-02

- Items 38–40 add 30 and delete 84 production Swift lines: **net −54 lines**.
- The focused Debug test build passed all 46 selected tests. A separate complete Chat Composer run confirmed both
  directly affected attachment tests pass; its two previously recorded unrelated failures remain unchanged.
- The touched production files compiled under Swift 6 with warnings as errors. `Scripts/check-zh-localization.sh` and
  `git diff --check` passed.

## Production UI Duplication Pass — 2026-09-02

### 41. Share the transient overlay surface treatment — Medium-high priority

**Status:** Completed on 2026-09-02; Debug build passed.

**Evidence:**

- `DropTargetOverlay`, `TerminalUploadOverlay`, and `CommandGeneratorOverlay` repeat the same large-radius glass
  surface, separator border, shadow, and hit-testing suppression.
- The three overlays differ in content and transitions, but the copied modifier chain is byte-identical and already
  depends only on shared design tokens.

**Recommended action:** Add one narrowly named shared `View` helper for the transient overlay surface and replace the
three copied modifier chains. Keep each overlay's content, accessibility, animation, and transition behavior local.

**Estimated net reduction:** Approximately 10–15 production lines.

**Verification:** Added `termindTransientOverlaySurface` and replaced all three copied modifier chains without moving
their content, transitions, or accessibility behavior. Production Swift changed by +15/−21 lines, for a net
reduction of 6 lines. The macOS Debug build and `git diff --check` passed. Strict formatting of the four touched files
remains blocked by pre-existing indentation violations outside this change.

### 42. Share conditional chrome for SSH authentication forms — Medium-high priority

**Status:** Completed on 2026-09-02; Debug build passed.

**Evidence:** `SSHAuthenticationForm` and `SSHHostKeyConfirmationForm` in `ConnectionJourneyView.swift` contain
byte-identical `Group` branches that optionally add 18-point padding, a 14-point glass surface, and a separator
border. Their form content and keyboard actions remain meaningfully different.

**Recommended action:** Add one file-local conditional `View` helper for this established form chrome and replace
both copied branches. Do not combine the forms or their submission logic.

**Estimated net reduction:** Approximately 12–14 production lines.

**Verification:** Added the file-local `connectionFormChrome` helper and replaced both copied conditional branches.
The forms keep separate content and keyboard actions. Production Swift changed by +31/−39 lines, including chain
reindentation, for a net reduction of 8 lines. The new and modified regions pass strict-format checks, the macOS
Debug build passed with warnings as errors, and `git diff --check` passed.

### 43. Share Snippet card content with its drag ghost — Medium-high priority

**Status:** Completed on 2026-09-02; Debug build passed.

**Evidence:** `SnippetCard` and `SnippetGhostCard` duplicate the title, target-count summary, risk badge, body preview,
and all related layout and styling. The outer interactive card and dashed drag ghost are intentionally different; the
only content-level behavior difference is that the normal card enables text selection for the body preview.

**Recommended action:** Extract one file-local `SnippetCardContent` with an explicit text-selection option. Keep
selection, activation, context menus, help, and ghost chrome in their current outer views.

**Estimated net reduction:** Approximately 25–30 production lines.

**Verification:** Added `SnippetCardContent` with an explicit `allowsTextSelection` option and kept both outer card
implementations separate. Production Swift changed by +39/−53 lines, for a net reduction of 14 lines; the estimate
overstated how much of the duplicated body could be removed while preserving body-only text selection. The modified
region passes strict formatting, the macOS Debug build passed with warnings as errors, and `git diff --check` passed.

### 44. Share the SFTP remote-file read-handle lifecycle — High priority

**Status:** Completed on 2026-09-02; build and focused SFTP tests passed.

**Evidence:** `SFTPWorker.readFile` and both `downloadFile` implementations independently open the same remote path
with `LIBSSH2_FXF_READ` and `LIBSSH2_SFTP_OPENFILE`, produce the same open error, and close the handle in `defer`.
Directory listing uses a different open mode and is not part of this duplication.

**Recommended action:** Add a private `withRemoteReadHandle` beside `withAtomicRemoteWrite` and keep each consumer's
buffering, size limit, progress, local atomic replacement, and socket relay logic inside its own closure.

**Estimated net reduction:** Approximately 8–12 production lines while centralizing resource cleanup.

**Verification:** Added `withRemoteReadHandle` and routed inline reads, local downloads, and socket downloads through
it while leaving each read loop and destination policy local. Production Swift changed by +91/−95 lines, including
closure indentation, for a net reduction of 4 lines; the estimate did not account for the extra closure indentation
needed to preserve all three distinct loops. The macOS Debug build passed with warnings as errors, and all 47 tests in
`SFTPFeatureTests` and `SFTPSessionTests` passed. `git diff --check` passed.

## Completion Audit — 2026-09-02

- A production-wide declaration scan found no type or private member with only its declaration as a reference. The
  remaining functions with a single textual occurrence are framework and protocol callbacks for AppKit, SwiftUI
  `Layout`, CloudKit sync, and callable transforms.
- Normalized 7-, 10-, and 12-line duplicate-block scans found no further independent production change that both
  preserves current boundaries and reduces code. Items 41–44 add 176 and delete 208 production Swift lines: **net
  −32 lines**.
- The remaining ordinary hosting-list bridge fragments already share `HostingListContent`; their small
  `NSViewRepresentable` shells are type-specific framework conformance, as recorded by Item 2. The Assistant hosting
  row retains its distinct detach and drag lifecycle.
- The remaining SSH/SFTP authentication and reconnect similarities intentionally preserve separate transport startup,
  credential persistence, and failure recovery, as recorded by Item 7 and Deep Scan III. The serial/SSH terminal-find
  surfaces also differ because SSH exposes independent navigation while Serial only exposes present-and-navigate.
- SwiftData V7/V8 models remain immutable migration contracts. Small repeated Settings error labels, search-field
  chrome, and sheet footers would require as much or more abstraction code than they remove.
- `ManagedChooserState` already owns the common selection and toggle-all policy. Host Chooser and Candidate Picker pass
  different enabled sets, so another wrapper would duplicate policy inputs rather than remove policy.

At this point additional consolidation would be driven by visual similarity rather than dead code or exact duplicated
behavior, and would conflict with this backlog's net-reduction and boundary-preservation rules.

Final verification compiled the app and test targets with warnings as errors. All 63 focused tests passed across
SFTP Feature/Session, Architecture Boundary, and Snippet Feature suites. The Simplified Chinese localization check and
`git diff --check` also passed.

## Re-verification Pass — 2026-09-02

An independent re-scan (fresh exact-fragment scan, dead-code scan, spot checks of completed items, and inspection of
every file touched since the Completion Audit) corroborated it: no dead code, no revived duplicates, and the
search-field-chrome/error-label claims held up on inspection. One item below the prior scan's granularity survived
independent review.

### 45. Share the "select/deselect all visible" helper pair for `ManagedChooserState` — Low priority

**Status:** Completed on 2026-09-02; build, `git diff --check`, and the Simplified Chinese localization check passed.

**Evidence:** `SnippetsPageView.allResultsChecked`/`toggleAllResults()`, `HostChooserView.allResultsChecked`/
`toggleAllResults()`, and `KeychainPageView.allEligibleChecked`/`toggleAllEligible()` each independently repeated
`!items.isEmpty && items.allSatisfy { chooser.selected.contains($0.id) }` and
`let ids = items.map(\.id); chooser.toggleAll(visible: ids, enabled: Set(ids))` — the common case where every visible
id is also enabled. The Completion Audit's note that "Host Chooser and Candidate Picker pass different enabled sets"
addressed a different, genuinely non-reusable case (`ModelListEditor`, which restricts `enabled` to a subset) and did
not cover this identical-enabled-set trio.

**Recommended action:** Add `ManagedChooserState.allChecked(in:)` and `.toggleAll(in:)` convenience members beside the
existing general-purpose `toggleAll(visible:enabled:)`, and reuse them from all three call sites. Leave
`ModelListEditor`'s restricted-`enabled` call untouched.

**Estimated net reduction:** Approximately 6–10 production lines.

**Verification:** Added the two convenience members and reused them from Snippets, Host Chooser, and Keychain.
Production Swift changed by +15/−17 lines, for a net reduction of 2 lines; the estimate did not account for the
shared helper's own line cost. The macOS Debug build passed with warnings as errors, and `git diff --check` and the
Simplified Chinese localization check passed.

### 46. Extract the agent runtime as the AgentKit package — Structural

**Status:** Completed on 2026-09-02; `swift build`/`swift test`/`swift-format lint --strict` pass in the package, the
macOS Debug build and full test suite pass in the app, and both Simplified Chinese localization checks pass.

**Evidence:** 49 files across `Domain/Agent`, `Application/Agent`, `Infrastructure/LLM`, `Domain/AI`, and
`Infrastructure/MCP` imported nothing but `Foundation` (plus `Security` for the Google service-account signer) and
already had four designed seams — `AgentModelStreaming`, `AgentLoopHook`, `AgentContextTransforming`,
`AgentToolCatalog`. What tied them to this app was four couplings, not a dependency: SSH tools listed in the same
static catalog as the generic ones, `requestSSHAuthentication`/`requestSSHHostKeyConfirmation` inside
`AgentUserInteractionHandling`, Termind literals in `AgentSystemPrompt`/`AgentPlanContractInjection`/
`AgentScratchWorkspace.defaultBase()`/`AgentPlanModeHook`, and four closed presentation enums carrying `sshConnecting`
and friends.

**Recommended action:** Cut those four couplings in place first, then move the files to a sibling package.

**Verification:** Done in that order. `AgentToolGroup` selects built-in tools by capability and
`AgentToolCatalog.registry(builtIn:additional:)` takes the app's own registrations after them; `AgentToolServices`
carries `AgentSSHInteraction` to the SSH/SFTP tools, which also makes credential prompts structurally absent from
`AgentEventChannel`; `TermindAgentPolicy` owns the prompts and the `ssh_exec` plan-mode rule as
`AgentPlanModeHook.hostDecision`; the four presentation vocabularies became open `RawRepresentable` structs with
their raw values unchanged, extended by `TermindAgentPresentation`. `ChatPermissionMode` was renamed
`AgentPermissionMode`, `AgentRunRequest.sessionContext` became `String?`, `AgentBuiltInTools` became
`AgentToolSupport`, and `ScratchPullTool`/`ScratchPushTool` moved to `AgentScratchTransferTools` because they are the
two scratch tools that touch a host.

This is not a net-line-reduction item and was not measured as one: the app shed roughly 9,500 lines to the package
and gained the seams above. What it buys is a boundary the compiler enforces, checked by
`ArchitectureBoundaryTests.typesOwnedByTheAgentPackageAreNotRedefinedHere`.

Two things surfaced that were not part of the plan. Adding the local package triggered a full SPM re-resolution that
silently bumped `libghostty-spm` 1.4.0 → 1.5.1 and broke the OSC working-directory and window-title suites; the pin
was restored and `-onlyUsePackageVersionsFromResolvedFile` is now documented in `AGENTS.md`. And `swift build` copies
resources verbatim rather than compiling string catalogs the way Xcode does, so the package keeps its catalog in
`Localizations/` and commits the compiled `.lproj` output built by `Scripts/build-localizations.sh` — without it
every lookup outside Xcode returns its key.

No other new exact-duplicate or dead-code candidate meeting this backlog's net-reduction and boundary-preservation
bar was found in this pass.

### 47. Collapse the duplicated Workspace navigation commands and move the splits off system-owned keys — Structural

**Status:** Completed on 2026-09-02; the macOS Debug build, `swift-format lint --strict`, and the Simplified
Chinese localization check passed.

**Evidence:** `TermindCommands.body` declared four Window-menu buttons for two actions. `Next Workspace` (⌃⇥) and
`Show Next Workspace` (⇧⌘]) both invoked `window?.selectNext()`; `Previous Workspace` (⌃⇧⇥) and
`Show Previous Workspace` (⇧⌘[) both invoked `window?.selectPrevious()`. The bodies were identical, not merely
similar, so this was exact duplication rather than a deliberate SwiftUI boundary.

Two of the four could not work in any case. The app never sets `NSWindow.allowsAutomaticWindowTabbing = false` —
the scene in `TermindApp.body` is a plain `WindowGroup` — so AppKit installs its own `Show Next Tab` ⌃⇥ and
`Show Previous Tab` ⌃⇧⇥ into the same menu, shadowing the app's copies. Separately, `Split Right` held ⌥⌘D, which
macOS reserves for Turn Dock Hiding On/Off as symbolic hotkey 52; the system consumed it before the menu saw it,
so the command was unreachable from the keyboard.

**Recommended action:** Delete the ⌃⇥ pair and rename the surviving ⇧⌘] pair to `Next Workspace` /
`Previous Workspace`, the titles Safari, Terminal and Finder already share. Move `Split Right` / `Split Down` to
⌥⌘→ / ⌥⌘↓, which keeps ⌥ as the mark of the pair that only rearranges the window while ⌘D stays with Duplicate,
the one that opens a connection.

**Estimated net reduction:** Approximately 6 production lines and 2 string-catalog entries.

**Verification:** Six button lines and the two now-unused `Show Next Workspace` / `Show Previous Workspace`
catalog entries were removed; `Next Workspace` and `Previous Workspace` already carried finished `zh-Hans`
translations, so the change needed none. Production Swift measured +13/−13 for a net of zero rather than the
estimated −6: `AppShortcutKey` gained `.rightArrow` and `.downArrow` (11 lines across its three switches), and the
two comments that record why ⌃⇥ and ⌥⌘D must not come back cost as much as the buttons saved. The catalog shrank
by 20 lines.

The arrow cases match on key code rather than character, as `.tab` and `.escape` do. That is what lets
`AppShortcutRegistry.routesToApplication` recognise ⌥⌘→ inside
`PersistentTerminalSurfaceView.TermindTerminalView.performKeyEquivalent` and decline it, so Ghostty writes no
escape sequence to the shell; `BroadcastInputTests.registeredApplicationShortcutsFallThroughTheTerminal` now
covers both arrows.

### 48. Address a provider by one URL and one API type — Structural

**Status:** Completed on 2026-09-04; AgentKit `swift build`/`swift test`/`swift-format lint --strict` pass, the
macOS build and all 994 Termind tests pass, `Scripts/check-zh-localization.sh` passes, and `npm run build` passes
for the site.

**Evidence:**

- `ModelProviderKind` named three vendors for four wire protocols, so `.openAI` had to carry `usesResponsesAPI` to
  express the fourth, and every dispatch site wrote `case .openAI where provider.usesResponsesAPI` before the three
  ordinary cases.
- Each kind carried a `defaultBaseURL` and a `defaultAPIPath`, which a blank field fell back to. The provider
  editor printed those defaults as placeholders, so `https://api.openai.com/v1` was on screen for anyone who had
  added a provider and typed nothing — and a provider with a credential but no address resolved to a vendor
  endpoint nobody had named.
- The address was two fields, base and path, which made "does the base URL include `/v1`" a question the user had
  to answer correctly.

**Action taken:** AgentKit gained `ModelAPIFormat` (`chatCompletions`, `responses`, `messages`,
`generateContent`) and two named addresses: `inferenceURL`, the complete address a request goes to, and
`baseURL`, that address with its endpoint segment removed, which is what `ModelCatalogClient` hangs `/models`
off. Neither is composed or defaulted there. Termind owns the `Automatic` choice and the suffix detection behind
it (`ModelAPIType`, `ProviderEndpoint`), composes both addresses, and shows one URL field with the composed
address and body format underneath it.

Removing the endpoint segment has to be the caller's job because only the caller knows which part it appended,
and `/v1/chat/completions` and `/v1beta/models/{model}:generateContent` do not put their endpoints in comparable
places — cutting at the colon leaves the model id behind and lists from `…/models/gemini-x/models`. Shipped as
AgentKit 0.4.0 and then 0.5.0, the second being that split and the rename it forced: with two addresses on a
provider, `url` no longer says which one.

**Net effect:** AgentKit measured +224/−205 including tests, with `ModelProvider.swift` down 203 lines to 121.
Termind removed the Vertex editor section, the service-account import, the API-path field, the Responses toggle,
and 15 string-catalog entries against 5 added.

**Verification:** `ProviderEndpointTests` pins the composition rule, including that an explicit API type changes
the body without moving the address, that a query stays at the end of whatever is composed, and that every
pre-V12 row folds back to the address it used to resolve to.

Two things did not go as planned. `TermindSchemaV12` first reused `TermindSchemaV11.models` verbatim, which
SwiftData rejected with "Duplicate version checksums detected" — every `VersionedSchema` in the plan points at
live model types, so two versions built from the same types hash identically. Dropping V12 then produced "Cannot
use staged migration with an unknown model version", because an installed store records the checksum of the shape
it was saved with and V11 no longer described it. `TermindSchemaV11Models.PersistentModelProvider` freezes the old
shape, following `TermindSchemaV9Models`; that is what gives V11→V12 two sides. Any future attribute change to a
persisted model needs the same freeze.

A guard added to `AIConfigurationModel.lookup` — skip providers with no URL — was removed again. It made a
provider with hand-added models vanish from every picker, which is exactly what the `enabledModelProviders` note
argues against, and the hazard it was written for no longer exists: with no default endpoint in AgentKit, a blank
URL fails with a bad-URL error naming the problem instead of reaching a vendor.

### 33 addendum (2026-09-04)

`usesVertexEndpoint` now reads `usesVertex && apiFormat == .generateContent`; `kind` is gone. Vertex itself stays
in AgentKit, which is an independent package and does not carry the app's constraints — but nothing in Termind
drives it any more, so `AgentProviderAdapterTests.vertexDerivesItsOwnAddressAndDeclinesTheCatalog` is the only
thing still holding it honest. `effectiveCredentialRef` is unchanged and still earns its place.

## StoreKit trial consolidation — 2026-09-09

**Status:** Completed. The full test run has one unrelated, pre-existing catalog expectation failure.

**Evidence:** `rg` confirms that `TrialEligibilityStore.swift` contains 260 lines of trial-only HMAC,
Keychain, UserDefaults, and CloudKit coordination. `ProAccessController` already owns StoreKit purchases,
transaction updates, and restored Pro entitlements, but starts the trial through this separate system.

**Action:** Replace the local seven-day trial with a zero-price, non-consumable 14-day StoreKit product.
Delete the old eligibility store and proof types; reuse the purchase and restore flow. Keep only a small
transaction-scoped clock watermark to avoid ordinary clock rollback. Previous trial records are ignored,
so existing users may claim the new trial. Update the app, both website languages, and configuration guidance.

**Estimated reduction:** Remove approximately 260 lines of legacy persistence and cryptography; net production
reduction depends on transaction validation and purchase-state handling. Tests and documentation are additional.

**Result:** Production Swift adds 306 and removes 427 lines (net -121); tests, catalogs, and
website/documentation changes are excluded.

**Verification:** The pinned macOS build passes. The final full run executes 1,006 tests in 98 suites. All commerce, StoreKit, language,
architecture, and timer tests pass. The only failing test is the unchanged
`ModelCapabilityResolverTests.bundledPiCatalogEnrichesKnownModelWithoutRegex`: it expects catalog version
0.84.3 / 1,312 models, while the committed, unchanged catalog is 0.85.1 / 1,354 models. Both source files
were checked against HEAD. Swift formatting, Chinese localization, and the website build pass.
English and Chinese paywall/settings screenshots plus desktop/mobile website screenshots are saved under
`.build/iap-verification` (ignored build artifacts).

StoreKit integration exposed purchase results arriving before history caches. Entitlement resolution now
includes the verified transaction being delivered. Concurrent refreshes join the latest read so a timer
cannot leave an awaiting purchase preflight with stale eligibility. Local macOS hosted StoreKit testing
exposes approved transactions in history without reliably pushing `Transaction.updates`; the approval
regression exercises the production event handler with that real verified transaction. Actual push delivery
and cross-device restoration remain in the App Store Connect Sandbox checklist.

## Remove the unused Show Recents preference — 2026-09-09

**Status:** Completed.

**Evidence:** `rg` finds `showRecents` only in `SettingsKey` and the `SidebarSettings` toggle.
No feature reads the preference; the settings group contains no other controls.

**Action:** Remove the toggle, its settings group, the unused preference key, and unused localized labels.

**Estimated reduction:** 22 lines of Swift and string-catalog entries. Keep the shared `Sidebar`
localization because the navigation sidebar uses it as an accessibility label.

**Verification:** The pinned macOS build, full Swift formatting lint, and Chinese localization checks pass.
Both full test runs execute 1,020 tests in 100 suites. The default Chinese environment reports 11 issues
from assertions expecting English output; all `AppLanguageTests`, `ArchitectureBoundaryTests`, and
`SettingsNavigationTests` pass. Repeating with `-testLanguage en -testRegion US` clears those issues and
leaves one failure: `explicitLanguagesWriteFullAppleLanguageTags`, because the launch-time `AppleLanguages`
override takes precedence over the test's stored Chinese preference. That test passes in the default run.
No production references to the removed preference or settings view remain.

## Remove low-value test assertions — 2026-09-11

**Status:** Completed. The full run encountered an intermittent focus-test failure; the focused rerun passed.

**Evidence:** `rg` confirms three static-translation tests in `MetricsInteractionTests`, a static-label
inventory mixed into the forwarding interpolation test, pinned catalog version/count assertions, and
enum-list snapshots. `ChatSlashCommandTests` also tests the compiler-synthesized raw-value round trip
without exercising command parsing.

**Action:** Delete these redundant checks. Resolve expected labels through localization resources in
title and metrics presenter behavior tests. Retain interpolation, plural rules, catalog completeness,
language preferences, model resolution, persistence compatibility, safe defaults, and source-boundary checks.

**Estimated reduction:** Approximately 80 lines of test code, with no production or dependency changes.

**Result:** Five redundant tests removed. Nine test files add 22 and remove 99 lines (net -77).
No production files, localization resources, dependency pins, or source-scanning tests changed.

**Verification:** Strict Swift formatting for all changed test files, `git diff --check`, and Chinese
localization checks for both Localizable and InfoPlist catalogs pass. The full macOS test command used
`-onlyUsePackageVersionsFromResolvedFile` and executed 1,121 tests in 111 suites. It reported two issues
in `statusItemCanBeEnabledDisabledAndOpenItsPopoverWithoutWindowEnvironment`: neutral initial focus
was false and input modality remained keyboard. That entire test is byte-for-byte identical to HEAD.
A focused rerun of all five `MetricsInteractionTests` passed, including the focus test. A preceding
single-function filter matched zero tests and is not counted as verification.
All other suites passed in the full run, including language, architecture, model resolution, composer,
command parsing, metrics presentation/lifecycle, settings navigation, and window-title behavior.
The full run log is `/tmp/termind-test-cleanup.log`; the focused rerun log is
`/tmp/termind-test-cleanup-focus.log`. The first sandboxed attempt could not write SwiftPM caches;
the reported test runs used the approved Xcode command outside the filesystem sandbox.

## Remove the duplicate screenshot window host — 2026-09-11

**Status:** Completed.

**Evidence:** `rg` found two screenshot-mode `RootView` construction sites: the production
WindowGroup and `ScreenshotDemoWindow`. The manual host forced compact toolbar geometry;
duplicate roots also competed for the persistent native terminal and transcript views.

**Action:** Delete `ScreenshotDemoWindow` and use the production WindowGroup with demo
state and restoration disabled. Report native titlebar height and backing scale when ready.

**Estimated reduction:** About 50 lines of duplicate window construction and launch wiring.

**Verification:** Full pinned macOS test run passed, including the new architecture guard
for a single root host. Native capture confirms a 52-point toolbar and visible terminal
and chat content. Strict formatting and Chinese localization checks passed.

## 2026-09-11 — Shared SFTP permission controls

- Evidence: `rg 'accessRows|permissionToggle|SFTPPermissionDraft' TFM/Features/SFTP` confirmed the permission grid and its row metadata were desktop-owned while mobile needed the same bit editing behavior.
- Action: moved the value-only permission draft into Domain and extracted a SwiftUI permission grid into Presentation, used by both editors. Removed the desktop-only row table and toggle builder.
- Estimated reduction: approximately 45 desktop view lines, with a single shared permission-control implementation replacing a second mobile implementation.
- Status: implemented; regression verification is recorded in `MOBILE_ROLLOUT.md`.

## 2026-09-11 — Share mobile settings and terminal behavior

- Evidence: `rg` confirms CloudKit coordinators, Settings transaction/journal, terminal settings, and command-history models were still desktop-owned; mobile used an unsynchronized AI store.
- Action: move these implementations to their owning shared frameworks, retaining desktop compatibility aliases and native surface adapters.
- Estimated reduction: avoids duplicating approximately 2,000 lines of synchronization and repository behavior in TFI.
- Status: implemented. Shared/mobile regression tests pass; full macOS verification retains existing Agent timing failures. See MOBILE_ROLLOUT.md for the complete verification record.

## 2026-09-11 — Share Metrics and connection presentation

- Evidence: desktop ServerMetricsModel already owns sampling, detail observers, host-key prompts and authentication while MobileMetricsModel duplicated a basic sampling loop; Journey graph and decision forms were embedded in the AppKit view.
- Action: move the monitor and Journey state to Application, metrics panels/instruments and connection decisions/route to Presentation; retain AppKit keyboard handling via a narrow injected adapter. Mobile metrics now delegates to that same monitor.
- Estimated reduction: removes the separate mobile sampling loop and avoids another approximately 1,200 lines of graph, instruments, panels and authentication form code.
- Status: implemented; shared/mobile regression tests and 127 focused macOS tests pass. The final full macOS run retains six existing Agent approval/input timing issues; see MOBILE_ROLLOUT.md.

## 2026-09-11 — Share AI settings business logic

**Status:** Completed. The isolated AI settings validation build and all 81 mobile/shared tests pass; the desktop SkillLibraryModelTests and ArchitectureBoundaryTests pass. The full desktop run has approval-queue and user-input test failures in unchanged execution code, recorded in the task verification report.

**Evidence:** `SkillLibraryModel` and `SkillImporter` live under TFM despite using portable APIs; `MobileAISettingsView` duplicates role selection with incomplete default labels.

**Action:** Move the skill library to Application, file import to Infrastructure, and role form to Presentation; retain native platform editors and file panels.

**Estimated reduction:** Remove approximately 35 lines of duplicate role form logic and avoid a second 250-line skill library implementation.


## 2026-09-11 — Shared Assistant execution (completed 2026-09-12)

Evidence: MobileAssistantModel registered no tools, while TFM/App/AppModel built the complete runtime and ConversationModel owned its event and interaction queues. The runtime, tool adapters, attachment and speech services now live in their owning frameworks; both apps consume the shared conversation projection, and both transcripts use ListViewKit. The macOS and iOS builds pass, Assistant/navigation tests pass, localization and format checks pass, and the full iOS run's only failure was an unrelated Metrics journey timing race that passed when its four-test suite was rerun.

## 2026-09-12 — Remove app-target framework forwarding aliases

- Evidence: `rg '^typealias ' TFM -g '*.swift'` found 224 module-level aliases in 96 files; 86 files contained no behavior beyond imports and aliases. Persistence also exported a second `Shared*` alias vocabulary solely for that forwarding layer.
- Action: delete the pure forwarders, migrate the six desktop convenience extensions to responsibility-named adapter files, use canonical framework types directly, and add an architecture guard that rejects forwarding aliases and public `Shared` namespaces.
- Estimated reduction: 86 source files and 224 app-target alias declarations, plus 20 Persistence compatibility aliases.
- Status: implemented. TFM and TFI builds pass, ArchitectureBoundaryTests pass, and the complete TFI test action passes.

## 2026-09-12 — Align the mobile target with desktop layers

- Evidence: TFI placed application models beside its entry point and all presentation in one flat Features directory; transport factories were embedded in `MobileWorkspace` and device-idiom checks were repeated in four views.
- Action: organize TFI under the eight desktop layers, move the workspace connection port and production implementation to Application/Infrastructure, extract mobile design tokens and an injectable interface-idiom environment, and move navigation metadata into Shell.
- Estimated reduction: no intentional feature reduction; the change removes one duplicate reconnect state machine and centralizes four device-idiom branches.
- Status: implemented. Both app builds, ArchitectureBoundaryTests, and the complete TFI test action pass.

## 2026-09-12 — Share terminal draft and generation lifecycles

- Evidence: desktop and mobile separately defined the same shell allowlist, draft request/clear escape payloads, two-second draft timeout, thirty-second model timeout, cancellation token and transient success/failure state.
- Action: extract `TerminalCommandDraftController` and `CommandGenerationCoordinator` into Application and make both terminal implementations supply only context, validity and insertion closures.
- Estimated reduction: approximately 190 duplicated lifecycle lines and one duplicate protocol constant set.
- Status: implemented. Mobile Command Generator, desktop Broadcast Input, Terminal Find, and direct draft-controller tests pass.

## 2026-09-12 — Separate remote-directory policy from the SFTP transport

**Status:** Completed on 2026-09-12; both app builds, architecture guards, and focused desktop/mobile SFTP tests pass.

**Evidence:** `RemoteFile` and the complete directory-operation interface are declared beside the libssh2-backed
`SFTPClient`, so feature state cannot express its dependency without importing Remote Infrastructure. TFM and TFI
also independently validate remote entry names, mask permission bits, construct rename/create paths, and order
directory snapshots with folders first. `MobileWorkspace` additionally owns the SFTP path, listing, and stale-request
token even though those values have no SSH-shell or Activity lifecycle responsibility.

**Action:** Move the remote-file value to Domain, introduce a narrow `RemoteFileSystem` Application port with the
shared name/path/permission rules, and make `SFTPClientProtocol` refine that port. Extract mobile directory state into
`MobileSFTPSessionModel`; keep connection/recovery and concrete client construction in Workspace Infrastructure.
Reuse the same port helpers from the desktop SFTP model without merging the distinct desktop selection, history,
recursive-transfer, and automatic-refresh behavior.

**Estimated reduction:** Approximately 35–55 duplicated production lines, plus about 90 lines removed from the
mobile Workspace coordinator. The extracted mobile model is counted as moved responsibility, not code reduction.

**Result:** `MobileWorkspace` dropped from 1,203 to 1,109 lines and no longer owns a directory path, directory
snapshot, or stale listing token. The complete structural pass (including the Domain value move, Presentation
extensions, Application port, and extracted mobile model) adds 101 net production lines. This does not meet the
initial line-reduction estimate; it is retained as an explicit dependency-boundary migration, like Item 46, because
it removes the libssh2 module from mobile directory state and gives both apps one enforceable directory-policy seam.
No compatibility facade or forwarding alias was added.

## 2026-09-12 — Finish mobile adoption of shared connection policy

**Status:** Completed on 2026-09-12; focused connection, Journey, Metrics, and mobile recovery tests pass.

**Evidence:** After `RemoteSessionConnectionController` moved to Application, `MobileWorkspace` still retained its
own pending Host Key observation/host id, persistent and temporary acceptance, Journey pause/resume, and ordered
progress-handler filtering. Mobile Metrics and Workspace also repeated the same loop that injects temporary Host Keys
into an `SSHConnectionPreparation` route.

**Action:** Make the shared controller the only owner of a mobile session's Host Key decision and route progress.
Add one `RemoteSessionHostStore` preparation overload for temporary route keys and reuse it from mobile Workspace and
Metrics. Keep authentication forms, concrete transport creation, terminal teardown, and SFTP teardown in their
existing owners.

**Estimated reduction:** Approximately 30–45 production lines while deleting a second Host Key state vocabulary.

**Result:** Mobile Workspace now uses the shared pending Host Key, trust scope, Journey pause/resume, and ordered
progress handler directly. The temporary-key preparation loop has one Application implementation used by mobile
Workspace and Metrics. Authentication and transport-specific teardown remain separate, as required by Item 7.

## 2026-09-12 — Share terminal Find state across desktop and mobile

**Status:** Completed on 2026-09-12; desktop SSH/Serial, mobile Find, and direct controller tests pass.

**Evidence:** TFM SSH, TFM Serial, and TFI SSH each own the same query/presentation pair and repeat the open,
re-search, query update, next/previous, end-search, and focus-return transitions. Only the closure that sends a
Ghostty binding differs. Domain already owns `TerminalFindBinding` and `TerminalFindDirection`, so leaving the state
machines in the app targets preserves three sources of behavioral drift.

**Action:** Add a small Application `TerminalFindController` driven by binding and focus closures. Make all three
sessions expose that controller directly and delete their forwarding methods and duplicated state.

**Estimated reduction:** Approximately 35–50 production lines with one tested transition model.

**Result:** The three session models now expose one controller and no longer own query/presentation properties or
forwarding methods. The controller preserves the deliberate retained-query behavior and returns focus only after an
active search is dismissed.

## 2026-09-12 — Derive remote distributions once in Domain

**Status:** Completed on 2026-09-12; Domain detection, Host projection, and mobile Workspace tests pass.

**Evidence:** `HostLibraryModel.recordRemoteSystemInfo` and the mobile Workspace Activity projection repeat the same
case-insensitive Linux check, required distribution id, normalized like-id construction, and non-Linux reset rule.

**Action:** Make `RemoteSystemInfo.detectedDistribution` the single Domain derivation and let persistence and Activity
projection consume it.

**Estimated reduction:** Approximately 10–14 production lines while keeping icon selection in Presentation.

**Result:** `RemoteDistributionDetection` explicitly represents unavailable metadata versus a conclusive optional
distribution, so incomplete Linux reports cannot accidentally clear a persisted value while non-Linux reports can.

## 2026-09-12 — Share the platform-neutral Connection Journey sections

**Status:** Completed on 2026-09-12; both app builds and Connection Journey rendering/behavior tests pass.

**Evidence:** Exact eight-line cross-target scanning finds repeated blocks throughout desktop and mobile Connection
Journey pages. The 52-point destination header, protocol/address label, ready/waiting status, and reconnect countdown
are platform-neutral SwiftUI. The logs, failure actions, background, and keyboard bridge are not: desktop uses
ListViewKit/AppKit and offers Ask AI/compact actions, while mobile uses an adaptive scroll layout.

**Action:** Move only header, ordinary status, and reconnect status to Presentation. Inject the platform-selected
foreground/accent/danger colors and the log-toggle action; retain logs, failures, form wrappers, backgrounds, and
AppKit event handling in each app target.

**Estimated reduction:** Approximately 110–150 production lines without merging platform-specific UI boundaries.

**Result:** The app-target Journey files remove 288 lines and add 22; the shared sections contain 168 lines, for a net
reduction of 98 production lines. Platform-native logs, failure actions, keyboard handling, and backgrounds remain
separate.

## 2026-09-12 — Own the Ghostty theme bridge in Presentation

**Status:** Completed on 2026-09-12; both app builds and terminal theme tests pass.

**Evidence:** `TFM/Design/TerminalTheme.swift` and `TFI/Platform/MobileTerminalAppearance.swift` contain the same
palette-to-Ghostty conversion, theme catalog, custom-configuration merge, background lookup, and terminal preference
application. The only desktop-only concern is its `@AppStorage` property wrapper; SSH transport is not involved.

**Action:** Move the Ghostty-facing appearance bridge to Presentation, compile that framework against the already
pinned GhosttyTerminal/GhosttyTheme products, and retain only desktop preference reading in TFM. Both apps apply the
same Domain `TerminalPreferences` value.

**Estimated reduction:** Approximately 100–130 production lines and one complete mobile compatibility file.

**Result:** The 112-line mobile duplicate was deleted, desktop theme code dropped 131 lines, and the 119-line shared
bridge replaced both. The Presentation target now declares its existing pinned Ghostty products directly; no package
version changed. TFITests declares the Ghostty products it imports directly, and FrameworkTests now explicitly links
the Presentation target it has always imported instead of relying on host-app build order.

## 2026-09-12 — Share terminal-upload availability and notice semantics

**Status:** Completed on 2026-09-12; direct policy tests and both app builds pass.

**Evidence:** Desktop Terminal upload and mobile Workspace upload independently define the same
Preparing/Queued/Rejected value, localized title/detail/icon mapping, and SSH readiness/current-directory failure
messages. Their execution differs and must remain separate.

**Action:** Put the upload notice and terminal readiness policy in Application and its icon/title/detail projection in
Presentation. Keep desktop SFTP-session staging and mobile batch-planner execution in their current owners.

**Estimated reduction:** Approximately 35–50 production lines without coupling the two upload executors.

**Result:** Both terminals consume `WorkspaceUploadNotice` and `TerminalUploadAvailability`; the duplicated enum and
title/detail mapping were removed. The desktop and mobile task/client ownership code remains intentionally distinct.

## 2026-09-12 — Share the Known Host presentation title

**Status:** Completed on 2026-09-12; direct Presentation tests and both app builds pass.

**Evidence:** Desktop and mobile Known Host cards independently choose the localized `Hashed Address` label versus
the endpoint address.

**Action:** Move this display-only projection to Presentation and keep card layout, icons, selection, and platform
interaction in each app.

**Estimated reduction:** Approximately 6–8 production lines.

**Result:** Both cards now consume `KnownHostEntry.presentationTitle`; platform card composition is unchanged.

## 2026-09-12 — Remaining exact cross-platform duplicates reviewed

`RuntimeVersions` and `MobileRuntimeVersions` remain intentionally separate. Sharing their identical decoder would
force Application or Remote Infrastructure to depend on GhosttyKit, or require a common-source group outside the
framework ownership model, for fewer than 20 lines saved. Snippet target summaries also remain separate: desktop
counts stored targets, while mobile deliberately counts only targets still valid in the current Vault. The remaining
Connection Journey matches are the expected outer layout and log header around deliberately different native log
renderers. Other scan matches are incidental SwiftUI structure, not shared behavior.

## Cross-platform session and presentation pass verification — 2026-09-12

The production diff for this pass adds 660 new lines and removes a net 811 tracked lines, for **net -151 production
lines**. Tests and architecture documentation are excluded. `MobileWorkspace` is 1,072 lines, down from 1,203; its
directory state and Find state now have dedicated Application owners. Assistant execution and UI were explicitly out
of scope and unchanged.

The complete iOS action passes 257 tests in 43 suites. The complete macOS action executes 1,197 tests in 126 suites;
all refactored SFTP, connection, Journey, theme, Find, upload, Vault presentation, architecture, and shared framework
tests pass. Nine issues remain outside this change: five Data Protection Keychain cases fail with OSStatus -25308,
two Metrics popover focus assertions depend on the current native window environment, and two Agent cancellation /
approval timing cases are intermittent. The 25 Agent tests pass on immediate focused rerun; the Keychain and Metrics
issues also reproduce in focused isolation.

Both app builds pass with pinned package versions. Strict Swift formatting, Simplified Chinese localization,
`git diff --check`, forwarding-alias scans, and retired-name scans pass. No persistence schema, remote protocol,
dependency version, localization catalog, or Assistant behavior changed.

## 2026-09-12 — Restrict ListViewKit to native-list workloads

**Status:** Completed on 2026-09-12; macOS build and focused ListView tests pass.

**Evidence:** Production imported ListViewKit from 16 Swift files through 12 adapters and 19 mount sites. The package
was originally introduced for the unbounded, streaming Assistant transcript, then one migration applied the same
AppKit hosting, diff, reuse, and environment bridge to compact menus, bounded popovers, settings editors, and ordinary
chooser sheets. Those lightweight surfaces received no capability that SwiftUI `LazyVStack` could not provide.

**Action:** Keep ListViewKit only for the transcript, SFTP directory, Assistant conversation library, window tool
sidebars, and their shared hosting row. Return Tag suggestions, Slash Commands, Quick Open, the model picker and model
editors, Transfer Center, Connection Log, and the three Host chooser variants to local SwiftUI lazy stacks. Enforce
the six-file production import boundary in `ArchitectureBoundaryTests`.

**Estimated reduction:** Remove eight adapters and eleven mount sites while retaining the package for four proven
native-list workloads.

**Follow-up:** The platform restriction was removed for the TFI Terminal Snippets and History sheets. They share one
UIKit bridge for variable-height rows and History swipe deletion; ListViewKit remains excluded from shared frameworks.

**Result:** Production imports fell from 16 files to a six-file allowlist. Eight adapters and eleven mount sites were
removed; the TFM production diff adds 225 and removes 836 lines for a net reduction of 611 lines. The macOS build,
85 focused Architecture/ListView/Quick Open/SFTP tests, strict formatting, Simplified Chinese localization check, and
`git diff --check` pass. The complete TFM action ran 1,198 tests: all affected suites passed, while the same nine
environment/timing issues already recorded by the preceding verification remain in Data Protection Keychain, Metrics
popover focus, Agent cancellation, and approval timing.

**Second follow-up:** TFI Assistant conversation and Archive lists returned to native SwiftUI `List`. Their bounded
management rows benefit from system swipe actions and navigation behavior, while the unbounded streaming transcript
continues to use ListViewKit. Active rows swipe to Archive and archived rows swipe to Unarchive; permanent deletion
remains behind the context menu and confirmation dialog.


## 2026-09-12 — Share Assistant transcript presentation

**Status:** In progress.

**Evidence:** `rg` confirms mobile renders literal Worked/tool names and duplicates result projection, while desktop owns AgentToolPresentation (1,087 lines), disclosure/deadline state, timestamps and Markdown policy.

**Action:** Move platform-neutral presentation into TermindPresentation, inject tool presenters from the existing registry, and retain native platform rendering and viewport ownership. Replace mobile disclosure and detail branches with shared policy consumers. Estimated duplicate-policy reduction: 150–250 lines, with desktop presentation code moved rather than copied.

**Verification:** Pending shared, desktop, mobile and bilingual rendering checks.

## 2026-09-12 — Remove Periphery-confirmed dead code

**Status:** Completed on 2026-09-12; both app builds, focused tests, formatting, and localization checks pass.

**Evidence:** Periphery 3.8.0 reported 461 diagnostics while indexing the TFM scheme and 73 while indexing TFI.
After excluding test-only diagnostics and reconciling the two platform scans, source-reference checks confirm 34
unused production imports, several uncalled private/internal helpers and compatibility accessors, and stored fields
that are written but never read. SwiftUI/AppKit lifecycle entry points, Codable payload fields, C callback parameters,
protocol witnesses, and fields whose synthesized conformance reads are intentionally excluded from this pass.

**Action:** Repair the stale Periphery scheme configuration, remove only declarations confirmed by both index data
and `rg`, then rerun both app builds, focused tests for changed behavior, strict formatting, localization validation,
and Periphery to measure the reduced result set.

**Estimated reduction:** 70–110 production lines without adding an abstraction.

**Result:** Removed 34 unused production imports, three empty source files, and confirmed dead initializers,
accessors, view helpers, state storage, and background-command metadata. Production code changed by net -150 lines.
The TFM production diagnostic count fell from 114 to 69 (461 to 416 including test diagnostics), while the TFI
production count fell from 66 to 41. Remaining reports are retained protocol/C callback parameters, synthesized
conformance or Codable fields, dynamic UI entry points, and separate candidates that require their own behavioral
review. The macOS and iOS builds pass, as do 49 focused Agent background command, port forwarding, and speech tests,
strict Swift formatting, Simplified Chinese localization validation, and `git diff --check`.

## 2026-09-12 — Remove UI implementation-type assertions

**Status:** Completed.

**Evidence:** `TranscriptListViewBridgeTests` directly asserts dedicated concrete row classes, the mobile Terminal
list suite reflects private SwiftUI/ListViewKit view types, and the macOS Host chooser render test additionally
requires an `NSTableView`. Existing behavior tests already cover rendering, row identity and reuse, dynamic type,
virtualization, interaction, and state isolation without requiring those implementation choices.

**Action:** Remove the two tests whose only result is a concrete UI type, drop their test-only helper, and keep the
Host chooser environment/rendering coverage without asserting its underlying AppKit table class. Preserve UI type
access that is required to exercise or observe actual interaction behavior.

**Estimated reduction:** 30–40 test lines with no production or public API changes.

## 2026-09-13 — Remove obsolete app localizations

**Status:** Completed on 2026-09-13; both app builds, localization validation, and App language tests pass.

**Evidence:** Fresh macOS and iOS compiler extraction with localization emission enabled found 1,558 production
keys. Comparing that union with `Localizable.xcstrings` identified 81 catalog entries used by neither app. The old
catalog also marked 509 entries stale, although 471 of them are still emitted by current production sources.

**Action:** Delete the 81 unused entries and their obsolete Simplified Chinese translations, remove the three test
expectations that existed only to keep retired formatting templates alive, and clear stale metadata only for keys
confirmed by the new compiler extraction. Keep every InfoPlist localization because both current plists still use all
seven entries.

**Estimated reduction:** About 1,350 catalog and test lines without changing current user-facing text.

**Result:** The app catalog fell from 1,637 to 1,556 entries and now contains no stale entries. Both app builds pass
with pinned dependencies; `AppLanguageTests`, both Simplified Chinese catalog checks, direct string-catalog
compilation, strict formatting for the touched test, and `git diff --check` pass.
