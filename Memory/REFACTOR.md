# Termind Refactoring Backlog

This English-only document is the durable record of completed redundancy removal and deliberately retained boundaries; append new findings, require a net code reduction unless the item is explicitly structural, verify references with `rg`, and preserve SwiftUI/AppKit and platform-specific lifecycle boundaries.

## Completed Items

1. **Delete the obsolete SwiftUI transcript tree (2026-08-30):** Removed the unreachable legacy transcript, message, command-card, compaction, and plan presentation subgraph while retaining live timestamp and risk components; the build and targeted Transcript tests passed.
2. **Merge repeated ListView hosting bridges (2026-08-30):** Introduced `HostingListRow` and `HostingListContent` for ordinary SwiftUI-backed rows while retaining dedicated Transcript and Assistant conversation lifecycles; the app build passed before the final parser-verified Connection Log migration.
3. **Consolidate `SSHSessionModel` initializers (2026-08-30):** Routed the two terminal entry points through one private initializer without changing temporary-host semantics; the build passed.
4. **Merge SSH and Serial terminal appearance configuration (2026-08-30):** Centralized shared appearance application in `TerminalViewState.applyAppearance`; the build passed.
5. **Delete redundant SFTP store overloads (2026-08-30):** Removed four `TransferLibraryModel` forwarding overloads in favor of the existing `RemoteSessionHostStore` entry points; the build passed.
6. **Reuse the Jump Host configuration builder (2026-08-30):** Made final SSH configuration reuse `sshJumpConfigurations` instead of duplicating route validation and error wrapping; the build passed.
7. **Share remote-session connection interaction (2026-08-30):** Moved host-key prompts, acceptance, route progress, prompt cleanup, and reconnect presentation into `RemoteSessionConnectionController` while preserving transport-specific teardown; the Debug build and targeted connection/SFTP tests passed.
8. **Merge short tool-free model text collectors (2026-08-30):** Centralized streamed text collection and tool-call rejection for command, title, and compaction services; their targeted tests passed.
9. **Merge provider authorization and session configuration (2026-08-30):** Added shared request authorization and ephemeral-session construction while retaining catalog-specific Vertex and empty-secret rules; targeted Provider and ChatProbe tests passed.
10. **Consolidate SwiftData save/rollback templates (2026-08-30):** Added a narrow `ModelContext.commit` helper while retaining semantic two-stage history commits; targeted Connection and SFTP History tests passed.
11. **Merge libssh2 queue/continuation bridges (2026-08-30):** Shared the byte-identical serial worker bridge between SSH Exec and SFTP workers; the build passed.
12. **Delete remaining legacy Transcript helpers (2026-08-30):** Removed dead streaming, edit-binding, and SwiftUI activity helpers as part of Item 1; targeted Transcript verification passed.
13. **Finish `ConversationComposerState` migration (2026-08-30):** Migrated callers to `conversation.composer` and deleted four compatibility accessors while preserving attachment mutation hooks; the build and Chat Composer tests passed.
14. **Delete the unreachable toolbar search-menu pipeline (2026-08-30):** Removed unused menu-item plumbing, `NSMenuDelegate` behavior, and the unread find-context kind while preserving query and keyboard behavior; the build passed.
15. **Share Agent SSH prompt conversion (2026-08-30):** Moved Journey prompt and passphrase derivation onto `AgentSSHAuthenticationRequest` for both presentation paths; the build passed.
16. **Extract atomic SFTP remote writes (2026-08-30):** Centralized temporary-path creation, handle cleanup, failure unlinking, atomic rename, and progress sampling while keeping data-source loops separate; the build and SFTP tests passed.
17. **Merge remote transfer conflict resolution (2026-08-30):** Shared Keep Both selection, remote-directory handling, and file conflict policy without merging distinct job types; the Debug build and targeted SFTP tests passed.
18. **Consolidate SFTP client leases (2026-08-30):** Centralized saved-versus-borrowed client acquisition and conditional disconnect while retaining coordinator reservation state; the build and SFTP tests passed.
19. **Centralize legacy tool-presentation metadata (2026-08-30):** Replaced scattered historical name mappings with one compatibility table while preserving generic MCP fallback semantics; targeted presentation tests passed.
20. **Delete the test-only presentation action path (2026-08-30):** Removed unused automatic action-message construction and compressed English verb forms around production `actionKind` semantics; targeted presentation tests passed.
21. **Merge tool-detail input unpacking (2026-08-30):** Added narrow object/array helpers in `AgentToolDetailFormatting` while keeping field-specific presenters local; the build passed.
22. **Merge Agent idle sweepers (2026-08-30):** Replaced two timer loops with `AgentIdleSweeper` while callers retain their own registry and emptiness policy; targeted tests passed.
23. **Reuse `SidebarSectionHeader` (2026-08-30):** Extended the shared header for count and collapse state and removed duplicate Assistant/Snippet layouts; the build passed.
24. **Unify Host deletion entry points (2026-08-30):** Routed group deletion through the repository/outbox saga and removed direct snapshot-persistence deletion; the Debug build and targeted repository, Snippet, and Port Forwarding tests passed.
25. **Remove uncalled wrappers and constants (2026-08-30):** Deleted confirmed-unused Agent preflight, settings, metrics, reconnect, and SSH-status declarations after reference scans; the build passed.
26. **Delete `SettingsCollectionPage` (2026-08-30):** Replaced its two construction sites with the byte-identical `SettingsFormPage`; the build and focused Settings tests passed.
27. **Merge fixed-height cursor lists (2026-08-30):** Shared the adapter used by Snippet Target, Host Chooser, and Export Host lists while excluding dynamic and specialized rows; the build and focused list/chooser tests passed.
28. **Share Agent Exec/SFTP authentication retries (2026-08-30):** Extracted a generic authenticated-open loop while preserving explicit connection kinds and result types; the build and all 21 Agent Host Authentication tests passed.
29. **Deduplicate native Transcript risk and confirmation helpers (2026-08-30):** Routed both row implementations through one risk-color function and one destructive-command confirmation function; the build passed.
30. **Merge Glass shape modifiers (2026-08-30):** Replaced three copied implementations with one shape-parameterized private modifier while preserving public APIs and fallbacks; the build passed.
31. **Consolidate Vault envelope persistence (2026-08-30):** Added one helper for insertion/update and upload-state indexing while leaving versioning and merge policy in callers; the build and Vault Sync tests passed.
32. **Share SFTP remote-conflict preflight (2026-08-30):** Centralized remote-directory ordering, descendant skipping, and target-kind lookup while retaining separate prepared job types; the build and focused SFTP tests passed.
33. **Centralize effective Vertex mode and credential selection (2026-09-04):** Added `usesVertexEndpoint` and `effectiveCredentialRef` to `ModelProvider`, later adapting the former to API-format-based providers; build and Provider verification passed.
34. **Delete newly confirmed dead declarations and decoded metadata (2026-08-30):** Removed unused onboarding, Agent, color, trial-test, and runtime Linux-catalog fields while retaining provenance in generated JSON; the build passed.
35. **Derive Conversation run presentation (2026-09-01):** Replaced manually synchronized run/streaming state with derivation from one reported state and outstanding queues; state-focused tests, localization, and diff checks passed.
36. **Delete tests that freeze user-facing copy (2026-09-02):** Removed 20 copy-only tests and isolated literal assertions while retaining behavioral, persistence, localization-selection, and protocol coverage; the affected target compiled and focused tests passed.
37. **Share checked provider HTTP execution (2026-09-02):** Centralized transport-error translation, HTTP validation, and non-2xx handling for model catalogs and probes while keeping request construction and parsing local; the build and all 12 focused tests passed.
38. **Delete the Finder-only native drop wrapper (2026-09-02):** Removed the unconstructed `NativeFileURLDropTarget` while retaining the generalized target and test-facing AppKit initializer; the build and all five File Drop tests passed.
39. **Centralize Context Chip recovery rules (2026-09-02):** Shared payload-boundary detection and fallback filename derivation between live attachments and restored references; the build and focused recovery tests passed.
40. **Finish save-or-rollback reuse (2026-09-02):** Added `ModelContext.savePendingChanges` and reused `commit` for staged Agent, Outbox, AI snapshot, and conversation mutations without changing semantic save boundaries; all 46 focused tests passed.
41. **Share transient overlay chrome (2026-09-02):** Replaced three identical surface modifier chains with `termindTransientOverlaySurface` while keeping content and transitions local; the Debug build passed.
42. **Share SSH form chrome (2026-09-02):** Replaced two identical conditional padding/glass/border branches with `connectionFormChrome` while preserving separate form behavior; formatting and the Debug build passed.
43. **Share Snippet card content (2026-09-02):** Extracted `SnippetCardContent` for the normal card and drag ghost while keeping their interaction and outer chrome distinct; formatting and the Debug build passed.
44. **Share SFTP read-handle lifecycle (2026-09-02):** Routed inline reads and both download paths through `withRemoteReadHandle` while preserving their distinct loops and destination policies; the build and all 47 focused SFTP tests passed.
45. **Share select/deselect-all helpers (2026-09-02):** Added `ManagedChooserState.allChecked(in:)` and `toggleAll(in:)` for the three identical-enabled-set callers while leaving restricted selection unchanged; the build, localization, and diff checks passed.
46. **Extract AgentKit (2026-09-02):** Moved the platform-neutral Agent runtime into the separately versioned package after introducing host-tool, interaction, prompt, and presentation seams; package build/tests/formatting and the app build/full suite passed.
47. **Collapse Workspace navigation commands (2026-09-02):** Removed commands shadowed by AppKit, kept the standard workspace shortcuts, and moved split shortcuts off system-owned keys with terminal routing coverage; the build, formatting, and localization checks passed.
48. **Address providers by one URL and API type (2026-09-04):** Replaced vendor-kind/default-path branching with explicit inference/base URLs and `ModelAPIFormat`, migrated persisted schemas safely, and shipped AgentKit 0.4.0/0.5.0; package checks, all 994 app tests, localization, and site build passed.

## Later Completed Work

- **StoreKit trial consolidation (2026-09-09):** Replaced the local HMAC/Keychain/CloudKit trial system with StoreKit purchasing and a transaction-scoped clock watermark, producing a net 121-line production reduction with commerce checks passing apart from one unrelated catalog expectation.
- **Remove the unused Show Recents preference (2026-09-09):** Deleted the unread preference, its toggle/group, and unused labels while retaining the shared Sidebar accessibility localization; builds, formatting, localization, and relevant tests passed.
- **Remove low-value test assertions (2026-09-11):** Deleted five redundant tests and literal/enum/catalog snapshots for a net 77-line test reduction while retaining behavioral coverage; all relevant checks passed aside from an intermittent unchanged focus test that passed on rerun.
- **Remove the duplicate screenshot window host (2026-09-11):** Deleted `ScreenshotDemoWindow` and reused the production `WindowGroup` with demo restoration disabled; the full pinned test run, native capture, formatting, and localization checks passed.
- **Share SFTP permission controls (2026-09-11):** Moved permission draft behavior to Domain and a shared SwiftUI grid to Presentation for both editors; regression verification is recorded in `MOBILE_ROLLOUT.md`.
- **Share mobile settings and terminal behavior (2026-09-11):** Moved CloudKit, settings transaction/journal, terminal settings, and command-history behavior into their owning frameworks with only desktop adapters retained; shared/mobile tests passed and full macOS verification retained known Agent timing failures.
- **Share Metrics and connection presentation (2026-09-11):** Moved monitoring/Journey state to Application and portable panels/forms to Presentation while retaining native keyboard and log handling; shared/mobile and 127 focused macOS tests passed.
- **Share AI settings business logic (2026-09-11):** Moved the skill library, importer, and role form into Application, Infrastructure, and Presentation respectively while retaining native editors and panels; the isolated build and 81 mobile/shared tests passed.
- **Share Assistant execution (2026-09-12):** Moved runtime, tool adapters, attachments, speech, conversation projection, and transcript list behavior into owning frameworks for both apps; builds, Assistant/navigation tests, localization, and formatting passed apart from an unrelated mobile Metrics race that passed on rerun.
- **Remove app-target forwarding aliases (2026-09-12):** Deleted 86 pure-forwarder files, 224 app aliases, and 20 Persistence compatibility aliases while preserving six responsibility-named adapters; both builds, architecture guards, and the complete TFI test action passed.
- **Align the mobile target with desktop layers (2026-09-12):** Reorganized TFI into the shared layer model, moved connection construction to Infrastructure, and centralized interface-idiom policy; both builds, architecture tests, and the complete TFI tests passed.
- **Share terminal draft and generation lifecycles (2026-09-12):** Extracted `TerminalCommandDraftController` and `CommandGenerationCoordinator` with shared timeouts, cancellation, and protocol constants; focused mobile and desktop tests passed.
- **Separate remote-directory policy from SFTP transport (2026-09-12):** Moved `RemoteFile` to Domain, introduced an Application `RemoteFileSystem` port, and extracted `MobileSFTPSessionModel`, accepting a structural net increase to enforce the dependency boundary; builds, architecture guards, and SFTP tests passed.
- **Finish mobile adoption of shared connection policy (2026-09-12):** Made `RemoteSessionConnectionController` own mobile Host Key decisions and route progress and shared temporary-key preparation between Workspace and Metrics; focused connection, Journey, Metrics, and recovery tests passed.
- **Share terminal Find state (2026-09-12):** Replaced three desktop/mobile query state machines with one Application `TerminalFindController` while retaining platform binding closures; direct and platform tests passed.
- **Derive remote distributions once (2026-09-12):** Centralized Linux distribution detection in Domain with explicit unavailable-versus-conclusive results; Domain, Host projection, and mobile Workspace tests passed.
- **Share platform-neutral Connection Journey sections (2026-09-12):** Moved header and status sections to Presentation while retaining native logs, failures, backgrounds, and keyboard handling, reducing production code by 98 lines; builds and Journey tests passed.
- **Own Ghostty appearance in Presentation (2026-09-12):** Replaced duplicated desktop/mobile theme conversion with one shared bridge while retaining desktop preference storage; both builds and terminal theme tests passed without dependency changes.
- **Share terminal-upload availability and notices (2026-09-12):** Centralized readiness policy and notice presentation while retaining distinct desktop and mobile execution; direct policy tests and both builds passed.
- **Share Known Host presentation titles (2026-09-12):** Moved hashed-address versus endpoint title selection to Presentation while leaving platform cards distinct; direct presentation tests and both builds passed.
- **Restrict ListViewKit to native-list workloads (2026-09-12):** Removed eight unnecessary macOS adapters and eleven mounts, later retaining narrow UIKit transcript/history uses, for a net 611-line macOS reduction; builds, focused tests, formatting, localization, and boundary checks passed.
- **Share Assistant transcript presentation (2026-09-12):** Moved platform-neutral tool/result, disclosure, timestamp, and Markdown policy into Presentation while retaining native renderers and viewport ownership; architecture records and both builds verify the boundary.
- **Remove Periphery-confirmed dead code (2026-09-12):** Deleted 34 imports, three empty files, and confirmed-unused declarations for a net 150-line production reduction while preserving dynamic and protocol entry points; builds, focused tests, formatting, localization, and diff checks passed.
- **Remove UI implementation-type assertions (2026-09-12):** Deleted tests and helpers that pinned concrete AppKit/UIKit/ListViewKit types while retaining behavioral rendering, identity, reuse, interaction, and environment coverage.
- **Remove obsolete app localizations (2026-09-13):** Deleted 81 compiler-confirmed unused catalog entries and three obsolete test expectations and cleared only verified stale metadata; both builds and all localization/language checks passed.
- **Register cross-platform Assistant slash commands (2026-09-13):** Replaced duplicate desktop/mobile command catalogs and execution switches with `ChatSlashCommandRegistry` and explicit platform registration; both builds and focused registry, desktop, and mobile tests passed.
- **Register mobile feature destinations (2026-09-13):** Replaced separate tab/sidebar metadata and destination switches with an injected `MobileFeatureRegistry` while keeping it app-owned; the iOS build and all 28 focused navigation tests passed.
- **Share remaining mobile and desktop policies (2026-09-13):** Centralized tree layout, route planning, Host deletion, display projections, Snippet/model rules, SFTP drag values, and service composition in their owning layers while retaining native UI and transport lifecycles; both builds and focused shared/mobile tests passed.
- **Move trials to annual-subscription introductory offers (2026-09-13):** Retired the zero-price trial product for new sales, retained it only as a legacy entitlement, and made offer presence, eligibility, duration, price, period, and expiration come entirely from StoreKit annual-subscription metadata.
- **Remove brittle and redundant unit tests (2026-09-13):** Removed 27 source-text UI snapshots from `MobileNavigationParityTests`, seven more app source snapshots, real Keychain and status-item integration tests coupled to host state, and duplicated shared permission/history coverage while retaining architecture, persistence, behavioral, and opt-in screenshot checks. Shared credential-storage compatibility, permission defaults, and History limits now live in `FrameworkTests`; the change removes a net 1,303 lines. All 1,079 macOS app tests, 13 focused shared tests, 218 iOS tests, strict formatting, localization, and diff checks passed; the pre-existing `SpeechWaveformViewTests` bitmap-equality failure remains outside this cleanup.
- **Remove standalone-trial compatibility (2026-09-14):** A fresh reference scan confirmed that the retired product identifier, legacy domain value, clock guard, and two legacy entitlement states formed one isolated compatibility path with an estimated 90-line production reduction. Deleted that path, its local StoreKit product, UI states, tests, and copy; renamed the permanent identifier to `lifetimeProductID`; and retained annual introductory trials as the sole trial mechanism. Strict formatting, localization, site build, all 1,091 macOS app tests, the rerun Metrics suite, and all 187 shared iOS tests passed. The iOS target built, while 10 unrelated toolbar-inspection tests remained failing in both the full run and an isolated rerun.

## Deliberately Retained Boundaries

- Native Transcript/AppKit rendering, Assistant conversation rows, and specialized dynamic or drag/drop lists keep dedicated lifecycles instead of being forced through generic SwiftUI hosting abstractions.
- SSH, SFTP, Serial, desktop, and mobile implementations share only platform-neutral policy; transport startup, credential persistence, teardown, logs, interaction, and native presentation remain separate where behavior differs.
- SwiftData historical schemas remain frozen migration contracts, small structurally similar repositories and views remain separate when abstraction would not reduce code, and `RuntimeVersions` stays platform-local to avoid introducing an invalid Ghostty dependency.

The 2026-09-02 completion and re-verification scans found no further independent dead-code or exact-duplication change that met the backlog's reduction and boundary-preservation rules; later work should be appended only after a fresh reference scan.

## Fresh Refactoring Pass (2026-09-16)

- **Reuse the shared SFTP download planner — completed.** Evidence: `rg -n 'PreparedJob|PreparedBatch|pendingBatch|keepBothLocalURL' TFM TFI Frameworks TFMTests TFITests` found only one desktop `PreparedJob`/`PreparedBatch` construction path, in `SFTPSessionModel.prepareDownload`, with direction fixed to `.download` and both remote-directory collections empty. Uploads already used `SFTPLocalUploadPlanner`. `SFTPRemoteDownloadPlanner` already owned the equivalent download traversal, local conflict policies, scoped destination access, directory creation, and transfer enqueueing for mobile. Adopted that planner in the desktop session and removed the obsolete mixed-direction batch and local helpers, retaining desktop pending-state/error handling, remote-copy policy, and transfer lifetimes. Estimated production reduction: 180 lines; actual reduction: 167 lines, or 59 lines including the added regression tests. Directory-only downloads now create their empty directory trees because the shared batch retains its destination independently of file jobs. The architecture record documents that ownership.

Verification completed on 2026-09-16:

- All 75 SFTP and architecture tests passed, including three new parameterized/behavioral tests covering ten file/directory conflict, subtree, empty-directory, and cancellation cases. The empty-directory regression fails against the pre-refactor `SFTPSessionModel` and passes with the final implementation.
- The full pinned TFM test action built successfully and passed 1,337 of 1,343 tests. Four failures also reproduce with the pre-refactor production source: `SettingsSyncTests.providedDatabaseCopyMigratesWithoutReset` (expects schema 15, current schema is 17), `ModelCapabilityResolverTests.reportedFieldsWinOverCodexAutoReviewOverride`, `ScrubberWebClientTests.fetchPreflightNeverEscalatesPrivateHTTP`, and `ChatComposerStateTests.aFailureNoticeIsNotAnAnswerWorthNaming`. `MetricsJourneyTests.offlineRestoredMetricsReconcileOnMainActor` passed on rerun. `SSHImportTests.indexedIdentityPlanningHandlesTheImportFileLimit` exceeded its two-second wall-clock limit when run concurrently, but passed in isolation against both versions (0.100 seconds with the final source).
- The full pinned TFI test action on iPhone 17 Pro / iOS 26.5 built successfully and passed 426 of 432 tests, including all 205 framework tests. The unchanged mobile graph retained five failures on isolated rerun: `MobileVaultFeatureTests.importRequiresAnExplicitUsernameWhenTheConfigurationOmitsIt` and four `MobileAssistantTests` cases (`completeRegistryIncludesRemoteAndBuiltInToolsOnlyForCapableModels`, `firstNewConversationSendPromotesDraftAndStartsRun`, `attachmentOnlyFirstSendPromotesTheConversation`, and `existingConversationSendStillUsesTheDraftExecutionPath`). `MobileEditorToolbarTests.iconButtonsKeepTheirNamesAndSaveLifecycle` passed on rerun.
- Strict Swift formatting across all production/test targets, `Scripts/check-zh-localization.sh`, the removed-symbol reference scan, and `git diff --check` passed. Both full test actions retained `-onlyUsePackageVersionsFromResolvedFile`; no dependency, localization, or shared production source changed.

## Follow-up Reuse and Test Cleanup (2026-09-16)

- **Reuse the shared remote-copy planner — implemented; full verification remains partial.** Evidence: `rg -n 'PreparedRemoteCopy|pendingRemoteCopyBatch|SFTPRemoteCopyPlanner.enqueue|resolveRemoteDirectories' TFM TFI Frameworks TFMTests TFITests -g '*.swift'` confirms the desktop-only batch types and duplicated preparation, conflict resolution, and enqueue loops in `SFTPSessionModel`; mobile already uses `SFTPRemoteCopyPlanner`. Replaced the desktop path with that planner and returned directory-mutation information so empty-directory copies still refresh the browser. Retained app-owned pending state, error handling, transfer completion refresh, and the interactive deletion lifecycle. Estimated production reduction: 220 lines; actual reduction: 193 lines. Added behavioral coverage for file/directory and subtree conflicts across all three policies, empty-directory refresh, and pending-copy cancellation; retained the planner's cancellation and validated recursive deletion checks. Upload conflict helpers remain a separate candidate rather than widening this change.
- **Remove copy-only and duplicated test expectations — implemented; full verification remains partial.** Evidence: `rg -n 'roleLabelsMatchDesktopDefaults|cautionLabelAlsoFitsUnknownCommands|copyApprovalLabelsAndOverwriteWarningUseAppResources|approvalDetailsLocalizeBothEndpointsAndDestructiveWarning|handshakeFailureDescriptionsDistinguishBannerConditions|uploadNoticePresentationUsesOneCrossPlatformMapping' FrameworkTests TFMTests TFITests -g '*.swift'` identifies role-label snapshots, a duplicate unknown-command case, repeated cross-platform approval copy checks, and mixed behavior/copy tests. Removed pure copy assertions and duplicate cases, retained unknown-command classification in its parameterized suite, and consolidated approval endpoint values and destructive-warning policy coverage across policies/locales. Preserved diagnostic context, upload gating, and notice payload/state coverage. Also dropped isolated fixed title/icon assertions from otherwise behavioral tests. Estimated test reduction: 50 lines; actual cleanup reduction: 59 lines, excluding 75 net lines of remote-copy regression coverage. Total Swift reduction: 177 lines. Retained architecture guards, language-selection/catalog validation, protocol strings, user-data round trips, and behavioral assertions that contain strings.

Verification and remaining limitations (2026-09-16):

- The pinned TFM focused test action passed all 200 tests, including SFTP/session/copy, architecture boundaries, tool presentation, handshake diagnostics, SSH import, toolbar behavior, app language, upload availability, and command classification. Result: `/tmp/termind-refactor-copy-focused-20260916.xcresult`.
- The pinned full TFM test action built successfully and passed 1,436 of 1,437 tests. The sole failure is the unchanged `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable` bitmap equality assertion. An earlier backlog entry records this same test failure; no baseline or isolated rerun was performed in this pass. Result: `/tmp/termind-refactor-copy-macos-20260916.xcresult`.
- The full TFI action did not build or execute tests: the supplied simulator destination UUID was unavailable. This is not a passing iOS verification. A fresh device listing found an available booted iPhone 17 Pro, but the owner requested an immediate commit before rerunning either platform.
- Strict Swift formatting across all production/test targets, `Scripts/check-zh-localization.sh`, the removed desktop-helper reference scan, and `git diff --check` passed. Xcode successfully resolved modules that standalone SourceKit could not find. Existing generic SwiftLint file/type/function-size and complexity findings remain outside this independent refactor; no inline suppressions were added. Dependencies and localization catalogs are unchanged.
- Submitted at the owner's explicit request with these verification limitations retained rather than deleting unrelated behavioral tests to obtain a green result.

## Remove Low-Value UI and Source Assertions (2026-09-16)

- **Implemented; full verification in progress.** Evidence: `rg -n '#filePath|sourceRoot|String\(contentsOf|source\.contains' FrameworkTests TFMTests TFITests -g '*.swift'` found 35 architecture tests plus eight source snapshots in Color System, Menu Symbol, SSH Import, Keychain Order, Commerce Configuration, and Mobile Navigation Parity. At the owner's request, removed implementation-spelling/layout snapshots, enum and palette echoes, fixed-canvas render checks, disconnected standard-library sorting tests, and orphaned helpers; trimmed literal copy from mixed behavioral tests. Removed 52 test declarations and a net 1,230 Swift lines against an estimated 1,000–1,200-line reduction. Source assertions dropped from 43 tests to nine narrow module/dependency and ownership guards. The ListViewKit import allowlist now permits removing an importer without requiring a snapshot update, while still rejecting new unapproved importers. Retained language/catalog validation, protocol/data contracts, behavioral lifecycle/rendering coverage, and opt-in screenshot capture. Grouped host-list coverage now checks row placement using fixture data rather than localized headings. No production, dependency, or localization catalog changed; existing architecture-document edits were preserved.

Verification in progress:

- Initial pinned Xcode checks passed all 18 selected macOS tests and five selected iOS tests, compiling both test targets. Results: `/tmp/termind-test-cleanup-initial-macos.xcresult` and `/tmp/termind-test-cleanup-initial-ios.xcresult`.
- Strict Swift formatting across production/test targets, `Scripts/check-zh-localization.sh`, the remaining-source-assertion scan, and `git diff --check` passed. Active standalone SourceKit checks could not resolve the Xcode test module graph and were partly inconclusive; Xcode compilation is the authoritative check. Pre-existing generic SwiftLint size, tuple, pixel-coordinate naming, and force-try findings were left outside this deletion; no inline suppressions were added.
- Full pinned macOS and iOS test actions are running sequentially. No unrelated behavioral test is being removed to hide a failing result.

## Share SFTP Transfer Status Labels (2026-09-16)

- **Implemented and verified with existing iOS failures.** Evidence: `rg -n 'status\(for: transfer\)|transfer\.state\.label' TFM TFI` found a mobile-only direction/state mapping and two generic desktop labels. Moved the agreed running/completed direction labels into Presentation, reused generic labels for other states, and connected both apps to the shared property. Production reduction: eight lines, matching the estimate. Existing translations and transport behavior are unchanged.
- The pinned full TFM action passed all 1,183 app tests and 213 shared tests, including language and architecture checks. Result: `/tmp/termind-sftp-status-macos-20260916.xcresult`.
- The pinned full TFI action compiled both targets and passed 212 of 217 app tests plus all 213 shared tests. Its five failures in `MobileAssistantTests` and `MobileVaultFeatureTests` match the pre-change `/tmp/termind-test-cleanup-full-ios.log` exactly; no unrelated tests were changed. Result: `/tmp/termind-sftp-status-ios-20260916.xcresult`.
- Strict Swift formatting, `Scripts/check-zh-localization.sh`, and `git diff --check` passed. Visually reviewed English, Simplified Chinese, and Traditional Chinese status matrices rendered from the built shared property and app localization resources in `/tmp/termind-sftp-status-preview/`; these are label previews, not live transfer screenshots.

## Retire the Desktop Forwarding Editor Adapter

- **Implemented; verification pending (reproduced iOS failures).** Evidence: `rg -n 'PortForwardingEditorState|PortForwardingEditorPolicy' TFM TFI Frameworks TFMTests TFITests FrameworkTests Memory Termind.xcodeproj -g '*.swift' -g '*.md' -g '*.pbxproj'` confirms that the 43-line desktop adapter has only three production consumers, all computed state getters in `TFM/Features/Ports/PortForwardingView.swift`, and seven desktop tests. It already delegates saved eligibility and normalization to Application's existing `PortForwardingEditorPolicy`; its remaining flags derive identically from enabled intent and runtime activity. Mobile already uses the policy directly. Action: adopt that policy in the three desktop getters and delete the adapter, retaining synchronous observable saved-rule/saved-host/controller reads and full runtime values for native presentation. Preserve all callbacks, enabled intent OR activity, draft normalization, saved-host lookup by the editor host's ID, and editing locks. Retarget all seven desktop test behaviors and add shared-policy eligibility/intent/activity coverage. Estimated production reduction: 27–28 Swift lines; test additions counted separately. No architecture invariant changes, boundary-guard edits, public API, dependency, persistence, runtime, approval, secret, or localization changes are required.
- Implementation outcome: removed the adapter without a replacement wrapper; production Swift decreased by 27 lines (43 deleted, 16 net added to the view). All seven desktop test behaviors remain, including the AppModel save-without-start integration and saved-host lookup through a changed draft host's ID. Expanded active-phase coverage across both intent values, local/remote normalization boundaries and missing targets, and invalid hidden dynamic targets. Added 14 shared-policy matrix/eligibility cases. Test Swift increased by 109 lines; total Swift increased by 82 lines, with regression additions reported separately from the production reduction. Architecture records/guards, feature integration suites, native copy, shared production code, and pinned dependencies are unchanged.

- Reviews: both independent code reviews and the prior final audit found no code issue or requested revision. This documentation audit independently inspected the actual diff and unchanged shared policy and found no behavior or boundary issue. Only this appended entry was updated; every earlier entry is preserved.

Verification audit (2026-09-16 UTC):

- The prior pinned focused TFM action passed **33/33 tests**, zero failures/skips: 14 forwarding feature, seven editor, nine architecture, and three shared-policy tests (the latter cover 14 parameterized cases). Independently re-extracted `/tmp/termind-forwarding-adapter-verify.xMtOCK/focused.xcresult` and checked `focused.log` and `focused.command.txt` in that directory; the action was not repeated.
- The full pinned TFM action passed **1,399/1,399 tests** (1,183 TFMTests + 216 FrameworkTests), zero failures/skips, exit 0. Result: `/tmp/termind-forwarding-adapter-recovery.eggzSE/remaining-checks.9wl35uwk/macos.xcresult`.
- The full pinned TFI action passed **428/433 tests** (212/217 TFITests + 216/216 FrameworkTests), five failures, zero skips, exit 65. Result: `/tmp/termind-forwarding-adapter-recovery.eggzSE/remaining-checks.9wl35uwk/ios.xcresult`. The exact five-test pinned rerun passed **0/5**, with the same five identifiers and identical failure text, exit 65: `/tmp/termind-forwarding-adapter-recovery.eggzSE/remaining-checks.9wl35uwk/ios-rerun.xcresult`. Both used the freshly discovered iPhone 17 Pro / iOS 26.5 simulator, UDID `38789AE8-B5AA-46CA-A15C-77CE760FC550`.
- Actual repeated failures (all in TFITests):
  - `MobileAssistantTests/attachmentOnlyFirstSendPromotesTheConversation()` and `MobileAssistantTests/firstNewConversationSendPromotesDraftAndStartsRun()`: `Expectation failed: draft.messages.map(\.role) == [.user, .assistant]`.
  - `MobileAssistantTests/completeRegistryIncludesRemoteAndBuiltInToolsOnlyForCapableModels()`: `Expectation failed: !names.contains("terminal_suggest")`.
  - `MobileAssistantTests/existingConversationSendStillUsesTheDraftExecutionPath()`: `Expectation failed: conversation.messages.map(\.role) == [.user, .user, .assistant]`.
  - `MobileVaultFeatureTests/importRequiresAnExplicitUsernameWhenTheConfigurationOmitsIt()`: `Expectation failed: model.canImport`.
- These failures are **baseline-unverified**, not established pre-existing failures or proven regressions. No pre-change baseline was run for this patch; earlier backlog notes are not substituted for baseline evidence. Their triage/baseline attribution and a passing required iOS verification remain blockers to completion. All planned automated stages reached terminal completion after the prior provider interruption; none is missing, and that interruption was not a test failure or a user-requested stop.
- Static checks passed: full strict recursive Swift formatting over `Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge`, `Scripts/check-zh-localization.sh`, and `git diff --check` (all exit 0). The first-party Swift retired-symbol scan found no `PortForwardingEditorState` (expected `rg` exit 1). The new test's whitespace checks had no diagnostics; the runner initially mislabeled no-index exit 1 (files differ), corrected in `untracked-whitespace-adjudication.json` without altering raw evidence, with a supplementary read-only scan passing at exit 0. Implementation-stage evidence remains in `/tmp/termind-forwarding-adapter-implement.aTsWRl/checks.sh` and `checks.log`.
- Integrity: before this documentation update, the complete patch, including the untracked test, matched both the focused verifier's initial patch and `/tmp/termind-forwarding-adapter-recovery.eggzSE/partial.patch` byte-for-byte (SHA-256 `f76b9950aa3bb49140865feec1153836f59ce903d25f3a32edcbf07ab320a691`). Reviewed production/test bytes remain unchanged. `project.pbxproj` and `Package.resolved` hashes match both the saved verification evidence and HEAD; no dependency drift. The same five paths remain uncommitted on `main` at `8b01a631fefdbe14e1324d87c91d0860124d85d3`; no further builds, source/test edits, or commits were made by this audit.
- Limitations/warnings: native manual status/toggle/edit-lock and save/cancel/back testing was **not executed**; layout and copy are unchanged, and no visual evidence is claimed. Full-suite xcresult summaries retain 166 macOS runtime warnings (88 environment-locale, 74 constraint, four StoreKit transaction-listener) and 29 iOS warnings (27 environment-locale, two publishing-during-view-update); the targeted rerun reports none. These warnings were not baseline-attributed or broadly investigated. Focused logs also retain native row-height and Xcode diagnostic warnings despite the passing result.
- Artifacts: `/tmp/termind-forwarding-adapter-recovery.eggzSE/remaining-checks.9wl35uwk/` contains `verification-report.md`, `verification-report.json`, `runner.log`, `runner.completed.json`, per-stage `*.command.txt`/`*.record.json`/logs, `*-summary.json`, `*-tests.json`, `failure-comparison.json`, simulator selection, and postverification patch/dependency evidence. Independent re-extractions, count/failure comparisons, before/after integrity, and the post-documentation `git diff --check` result are preserved in `/tmp/termind-forwarding-adapter-recovery.eggzSE/audit-record/`.

## Repair the Five Repeated iOS Test Failures (2026-09-17)

- **Completed and verified.** Before editing, the exact five tests failed on clean `d582d711` using the pinned dependencies and iPhone 17 Pro / iOS 26.5. This establishes the baseline for this repair without retroactively claiming a pre-refactor baseline for earlier entries. Result: `/tmp/termind-ios-five-fixes.NfgsN4/baseline.xcresult` (0/5 passed, exit 65).
- Three `MobileAssistantTests` send cases expected a synthetic assistant message from an in-memory app with no Chat model. `b2f05217` intentionally replaced that message with a failed run and a separate timeline failure notice. The tests now verify user-only history, failed-run metadata, prompt-to-run association, the visible failure row, and exclusion from title generation. The existing-conversation case awaits the actual failed state rather than yielding 20 times for an assistant message that must not exist.
- The registry case expected `terminal_suggest` to be absent on mobile. `df3bd04c` intentionally stabilized definitions across surfaces; the executor gates availability from the delivered user snapshot. The test now requires the tool, compares descriptors with and without terminal availability, and still requires an empty registry for models without tool-call capability.
- The import case directly mutated `items[0].host.username` after scanning. Since `ac165a9a`, scanning also builds indexed Identity previews, so the selected Identity retained its invalid empty username. The replacement uses a temporary config and the real `SSHImportReader` with an explicitly empty default username: invalid input cannot commit anything, then adding `User deploy` and rescanning rebuilds both previews and imports the correctly linked Host/Identity. The obsolete reader fake was removed; no production mutation API was added for a test-only path.
- All five original test identifiers are retained; none is skipped, deleted, or marked as an expected failure. Only the two mobile test files and this record change. Production behavior, architecture invariants/guards, localization catalogs, and pinned dependencies remain unchanged.
- Verification: all five tests passed in three separate Xcode test actions (`fixed-repeat.xcresult`, `focused-2.xcresult`, `focused-3.xcresult`), then the full pinned TFI action passed **433/433** and full TFM action passed **1,399/1,399**, both with zero failures/skips (`full-ios.xcresult`, `full-macos.xcresult`, exit 0). Although the first action supplied `-test-iterations 3`, its log contains only one Swift Testing run; two independent actions supply the actual repetition evidence. This resolves the outstanding automated iOS verification blocker in the preceding entry.
- Full strict recursive Swift formatting, `Scripts/check-zh-localization.sh`, and whitespace checks passed. Standalone SourceKit probes could not confirm the Xcode test-module graph; the successful Xcode compilation and simulator tests are the authoritative checks. Full results retain 29 iOS and 168 macOS runtime warnings, not investigated or baseline-attributed by this test-only repair; the three focused actions have none. Artifacts and the sequential verification script are under `/tmp/termind-ios-five-fixes.NfgsN4/`.


## 2026-09-17 — Replace the single-document skill loader

- Evidence: `load_skill` had its own definition, presenter, catalog guidance, and name-based output exemptions. A package file reader now supplies the same bounded SKILL.md behavior plus supporting resources.
- Action: remove the executable `LoadSkillTool` and register `skill_read_file`; retain only the historical presenter ID and replay compatibility.
- Estimated reduction: remove roughly 100 lines of the superseded loader; package management is an additive feature, not a net code-reduction claim.
- Status: implemented. AgentKit tests pass; application skill, migration, memory lifecycle, and mobile suites have been exercised.


## 2026-09-17 — Replace seeded runbooks with immutable skill helpers

- Evidence: `AgentSkillLibrary` shipped three editable runbooks; `SkillLibraryModel` and `SettingsSyncPersistence` both seeded them, and both apps exposed a destructive library-wide Reset.
- Action: replace the seeds with two runtime-only skills and remove generation seeding, Reset, and old runbook definitions/fixtures. Previously installed starters remain ordinary user-owned records without content rewriting or automatic deletion. Keep conflict repair in native editors and use the existing atomic skill/sync persistence boundary for package installation.
- Estimated reduction: roughly 200 production lines from retired runbooks, duplicated seeding and Reset UI, excluding the new installer capability and migration tests.
- Status: implemented. AgentKit 0.13.0 is signed and published; 213 package tests passed. Existing skills remain user-owned and the Chinese memory label is 持久化记忆 / 持久化記憶.
- Verification: the final iOS run passed all 452 tests. The macOS app run passed 1,183 tests; AppLanguageTests passed again independently. The refreshed shared-framework run passed 231 of 232 tests, with the existing `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable` PNG byte-equality failure remaining. New skill/library/sync tests passed, bilingual native screenshots were reviewed, and strict formatting, Chinese localization and whitespace checks passed.

## Reuse and Architecture Scan (2026-09-17)

**Status: discovery only; all six candidates below are pending.** Baseline: clean `main` at `8509ddd5`.
The inventory and normalized-block scan covered 516 tracked first-party production Swift files (113,165 lines)
under `Frameworks/`, `TFM/`, `TFI/`, and `TermindMCPBridge/`. Candidate bodies, consumers, and relevant tests
were then inspected directly; this is not a claim that every file received a behavioral audit. A source import
check across the 273 shared-framework Swift files found no disallowed first-party dependency edge relative to
`ARCHITECTURE.md`. The source graph was stale and Swift structural navigation was unavailable, so neither was
used as proof of reachability or dead code. The website's localized home routes already reuse one page.
AgentKit and other third-party sources were not included.

Estimates below are prospective **net production Swift reductions**, allowing for a narrow shared implementation
and caller changes but excluding regression tests. They are not measured patch outcomes. Implement and verify
one independent item at a time; abandon a reduction claim if the new abstraction costs more than it removes.
No production, test, dependency, localization, or architecture-invariant change is made by this scan.

### R1. Share CloudKit record transport coding — first implementation candidate

- **Evidence:** `VaultSyncCoordinator.swift:475-548`, `SettingsSyncCoordinator.swift:519-594`, and
  `MetricsSyncCoordinator.swift:424-498`, all under `Frameworks/TermindInfrastructure/Cloud/`, repeat CKRecord
  restoration, metadata assignment, SHA-256 payload hashing, inline-versus-CKAsset storage, secure system-field
  archiving, and cache-file construction. Confirm with
  `rg -n 'static func (makeRecord|envelope|payloadData|systemFields|record|assetURL)' Frameworks/TermindInfrastructure/Cloud`.
- **Action:** introduce an internal record-coding helper in the same Infrastructure layer. Share transport
  mechanics, not the three envelope codecs or their semantic validation. Keep existing public entry points,
  record/zone names, record-name casing, the 700,000-byte threshold, separate asset directories, error mapping,
  and Settings' legacy Guardian canonicalization. Do not change persistence entities or sync engine ownership.
- **Estimated reduction:** 70–110 lines. **Risk:** low-to-medium; wire compatibility matters even without a migration.
- **Required verification:** retain `VaultSyncTests.cloudRecordUsesAssetForLargePayloadAndRejectsCorruption`,
  Settings record round trips and legacy Guardian tests, and `MetricsSyncTests.recordsRoundTripAndRemoteChangesMergePerHost`.
  Add shared boundary cases for payload sizes at/above the threshold, corrupt or missing payloads, system-field
  restoration, and asset namespace separation; run both pinned app test actions. This estimate excludes R5.

### R2. Share the remaining upload/copy remote-conflict helpers

- **Evidence:** `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPLocalUploadPlanner.swift:178-310` repeats
  preflight, subtree skip/remapping, conflict resolution, Keep Both naming, and recursive deletion from
  `SFTPRemoteTransferPlanner.swift:311-439`. Copy helpers also serve `SFTPRemoteCopyOperation.swift:108,126`.
  Confirm with
  `rg -n 'remoteConflictPreflight|resolveRemoteDirectories|resolveRemoteConflict|deleteRecursively|SFTPRemoteCopyPlanner\.(resolveDirectories|resolveConflict)' Frameworks/TermindRemoteInfrastructure/Transfers`.
  This freshly verifies the upload-helper follow-up left open in the 2026-09-16 remote-copy entry; it is not
  another claim that desktop planner adoption remains unfinished.
- **Action:** extract a focused Remote Infrastructure helper using the existing `RemoteFileSystem` port where
  sufficient. Keep local upload traversal, remote manifests, their different job values/enqueue operations,
  browser pending-state ownership, and interactive deletion separate. Preserve both directory-mutation reporting
  and the copy operation's created-directory accounting.
- **Behavioral caveat:** copy helpers check cancellation and validate recursive child names/paths; upload helpers
  do not contain equivalent checks. Copy preflight uses self-or-descendant containment while upload preflight
  checks descendants. Characterize these differences before sharing; do not weaken the copy checks or describe
  any deliberate upload hardening as a byte-equivalent refactor. No failure or vulnerability was reproduced here.
- **Estimated reduction:** 100–140 lines. **Risk:** medium because Replace may delete remote directories.
- **Required verification:** extend `SFTPFeatureTests` upload preflight/subtree tests and retain copy conflict,
  empty-directory, pending-cancellation, and `SFTPCopyToolTests` coverage. Parameterize all three conflict policies,
  file/directory type collisions, nested path mappings, cancellation, and invalid child paths for both callers.
  Retain mobile upload tests, including scoped symlink exclusion and directory-only uploads, and run both pinned suites.

### R3. Share Pro offer presentation calculations without merging the paywalls

- **Evidence:** `TFM/Features/Commerce/ProPaywallView.swift:179-219,238-248` and
  `TFI/Features/Commerce/MobileProView.swift:212-247,290-300` independently compute purchase titles, annual/trial
  disclosures, trial badges, billing units, and localized duration formatting. Confirm with
  `rg -n 'purchaseButtonTitle|selectedPlanDetail|trialBadge|annualBillingUnit|func formatted' TFM/Features/Commerce TFI/Features/Commerce`.
- **Action:** add a small value-based projection in `TermindPresentation`, receiving the selected plan, live
  StoreKit-derived price/period/offer values, eligibility, and effective locale. Do not import
  `TermindInfrastructure` or pass `ProAccessController` into Presentation. Both app views keep their own cards,
  feature lists, sheet/navigation state, purchase tasks, and native subscription-management action.
- **Estimated reduction:** 20–40 lines after projection construction at both call sites. **Risk:** low.
- **Required verification:** cover annual versus lifetime, eligible versus unavailable trial, missing product data,
  singular versus composite periods, and locale selection without full-copy snapshots. Retain `ProAccessTests`
  and `StoreKitTrialTests`, run `AppLanguageTests` and both pinned suites, and review English/Chinese paywalls.
  macOS must retain its explicit app-language choice; mobile must keep Apple's per-app language behavior.

### R4. Complete the existing architectural guards — explicitly structural

- **Evidence:** `TFMTests/ArchitectureBoundaryTests.swift:29-42,81-148,157-167` checks the AgentKit-owned type list
  only under `TFM`; its SwiftData ownership scan omits Remote Infrastructure, Presentation, and the bridge.
  The shared Application import guard does not include the full UI/native-I/O prohibition, and Presentation's
  guard does not reject `TermindInfrastructure`. Import checks compare entire lines, so annotated or qualified
  imports are not recognized. Confirm with
  `rg -n 'applicationDoesNotImport|typesOwnedByTheAgentPackage|sharedFrameworksCannot|sharedPresentation|swiftDataModels|swiftFiles|text.split' TFMTests/ArchitectureBoundaryTests.swift`.
- **Action:** centralize the production-root/dependency rules and a bounded import recognizer. Apply existing
  ownership rules across all appropriate production roots; recognize ordinary, annotated, and symbol-qualified
  imports. Retain fail-closed behavior for missing/empty roots and the native-list allowlist.
- **Benefit and estimate:** no production reduction is claimed; allow approximately 20–60 net test lines if needed
  for complete coverage. This closes test coverage gaps, not an observed production dependency violation.
  Do not reintroduce source snapshots of UI copy, layouts, retired paths, or shared-component wiring.
- **Required verification:** fixture-based behavioral checks must reject forbidden annotated/qualified imports
  and out-of-owner declarations while allowing valid imports and removal of an allowed native-list importer.
  Run `ArchitectureBoundaryTests` and both pinned suites; do not mutate production files to exercise negative cases.

### R5. Reuse CloudKit engine lifecycle implementation — staged architecture follow-up

- **Evidence:** the same three Cloud coordinators independently own `operationID`, operation serialization,
  account preparation, engine creation, fetch-before-send readiness, delegate forwarding, and account/zone reset.
  Examples: Vault `127-246,291-357`, Settings `134-247,327-393`, Metrics `129-240,275-334`.
  Confirm with
  `rg -n 'operationID|prepareAndSynchronize|synchronizeNow|isReadyToSend|stopEngineForAccountChange|handleZoneDeletion' Frameworks/TermindInfrastructure/Cloud`.
  Existing sync tests primarily exercise codecs, journals, merge behavior, and preference switches rather than
  a deterministic asynchronous engine/account lifecycle.
- **Action:** after R1, investigate a composed, typed Infrastructure driver with per-category persistence/event
  adapters. Share implementation, **not instances**: all three zones, journals, account bindings, subscriptions,
  category switches, and independent coordinator lifetimes must remain. Settings retains secret migration and
  upload authorization at the current fetch/account boundary, plus its legacy-record handling. Avoid an untyped
  universal sync framework or changing the frozen SwiftData models to satisfy a generic protocol.
- **Estimated reduction:** 200–350 additional lines, excluding R1's record coding. **Risk:** high; design and
  characterization must precede migration. Update the architecture ownership record only when implemented.
- **Required verification:** first add deterministic coverage for pause/retry and stale callbacks, account
  switching/confirmation, zone and environment reset, failed fetch, readiness before sends, and Settings secret
  authorization/revocation. Migrate one category at a time, retaining quarantine, tombstones, and versioned-upload
  acknowledgement tests. Record codec round trips alone are not sufficient proof for this change.

### R6. Share MCP transfer ticket policy, not transfer execution

- **Evidence:** `TFM/Application/MCPServer/MCPUploadCoordinator.swift:42-135,224-246,374-409` and
  `MCPDownloadCoordinator.swift:36-128,364-403` duplicate session/host ticket bookkeeping, ten-minute expiry,
  64 unfinished tickets per direction, thirty-minute retention, 256 terminal records per direction, and activity
  eligibility. Download also references `MCPUploadRequest.maximumBytes` at line 243 despite the limit applying
  to both directions. Confirm with
  `rg -n 'has.*Activity|count < 64|addingTimeInterval\(600\)|maximumBytes|func (endSession|revokeSession|sweep)|1_800|count - 256' TFM/Application/MCPServer/MCP{Upload,Download}Coordinator.swift`.
- **Action:** extract only common metadata/retention/limit policy within the macOS MCP implementation, reusing
  the existing shared `MCPTransferBudget`. Keep protocol-specific claim checks, response/error payloads, attempt
  generations, read/write loops, cleanup, and cancellation tasks separate. Do not move the local listener into
  a mobile/shared framework or AgentKit, and do not introduce a broad generic ticket base class merely to rename fields.
- **Behavioral caveat:** expired uploads may need asynchronous partial-file cleanup; downloads can re-serve a
  Range after success and retain revocation independently. The two `cancelAndWait` methods capture tasks at
  different times, and upload cancellation can create cleanup work. These paths must not be mechanically merged.
- **Estimated reduction:** 30–70 lines if a narrow metadata/policy extraction pays for itself. **Risk:** medium-to-high;
  authorization, retention, and capacity release remain security/lifecycle boundaries.
- **Required verification:** retain `MCPUploadTests`, `MCPDownloadTests`, and session teardown tests. Add shared
  clock-boundary/retention cases while retaining the distinct range-after-success, acknowledged upload-offset,
  late-disconnect, session/host revocation, and four-slot-until-cleanup behaviors. Preserve public protocol strings
  and metadata-only audit behavior.

### Scan disposition and verification scope

- Start with **R1**, then consider R2 or the smaller R3; address R4 before expanding dependency/lifecycle ownership.
  R5 and R6 need separate characterization/design work, not one large combined refactor.
- Retain frozen persistence shapes, responsibility-named Vault facades, native transcript/list renderers, platform
  terminal/session teardown, and platform-local runtime-version adapters. Large files alone are not evidence for
  a code-reducing extraction. The small pixel-inspection duplicate does not justify merging native renderers.
- Discovery used source reads, fresh `rg` references, normalized-block signals, and an import-direction audit.
  No Xcode tests, application builds, or visual checks were run by this documentation-only scan; prior results
  above are not reused as verification of these pending candidates.
- Documentation verification passed: the previous backlog is preserved byte-for-byte, the addition is English-only,
  referenced source paths were checked, and `git diff --check` plus `Scripts/check-zh-localization.sh` passed.
  Only this backlog file changed; all six candidates remain unimplemented and unverified at runtime.

## Ordered Implementation Follow-up (2026-09-17)

The operator approved R1, R2, and R3 in that order. R4–R6 remain outside this implementation pass.

### R1: CloudKit transport coding — implemented, affected checks passed

- Added internal `CloudSyncRecordCoding` and adopted it in Vault, Settings, and Metrics. Record restoration,
  secure system-field archiving, lowercase SHA-256, raw/quarantine versus validated payload reads, the exact
  inline threshold, lazy asset creation, and namespaced asset paths now have one implementation.
- Per-envelope metadata assignment deliberately remains at each coordinator, alongside semantic validation and
  Settings' legacy Guardian canonicalization. This avoids a large generic metadata API. Public entry points,
  error mapping, record/zone names, cleanup, persistence models, and independent sync lifetimes are unchanged.
- Measured production change: **40 fewer lines**, including the new helper (1,741 to 1,701 lines across the four
  production files), rather than the discovery estimate of 70–110. Added eight focused test functions with
  twelve parameter-expanded cases for boundaries, hash compatibility, storage transitions, corruption/raw
  quarantine access, missing payloads, asset I/O errors, system fields, and asset namespace isolation.
- Pinned Xcode focused actions passed: **macOS 61/61**, **iOS 13/13**; both actually executed the new suite, and
  source snapshots were unchanged throughout each action. Existing Vault/Settings/legacy Guardian, Metrics,
  and architectural tests in the selected actions passed. Evidence: `/tmp/termind-refactor-three.7kUsqP/r1-focused-*`
  contains commands, logs, `.xcresult` bundles, test trees, summaries, and source snapshots. Strict formatting
  and whitespace checks passed. Standalone SourceKit cannot resolve Xcode test/framework imports; actual
  Xcode compilation succeeded. Pre-existing coordinator-size advisories are not a reason to implement R5.
- Full-suite baseline was captured before any production edit: macOS **1,502/1,505** and iOS **502/503**.
  Failures were the parallel approval cancellation, runtime tool cancellation, metrics worker lifecycle, and
  mobile knowledge-row expansion tests. These are separate baseline issues, not verification passes; final
  full-suite comparison remains pending. No AgentKit dependency or unrelated production/test repair was made.

### R2: Remote conflict resolution — implemented, affected checks passed

- Before changing Remote Infrastructure, new mobile upload cases reproduced the two guard gaps with a fake
  backend: a cancelled directory-only enqueue still created a directory, and Replace accepted a child outside
  the conflicting directory. Existing copy/SFTP feature checks passed **65/65** on macOS; mobile upload checks
  passed **5/7**, failing only the two new cases. Both action source snapshots were unchanged. Evidence:
  `/tmp/termind-refactor-three.7kUsqP/r2-before-*` (commands, logs, result bundles, test trees, snapshots).
- Added `SFTPRemoteConflictResolver` against the existing `RemoteFileSystem` port, retaining both preflight
  counting modes: upload blocks strict descendants, while copy also blocks the conflicting root itself.
  Upload deliberately gains the existing copy cancellation and recursive-entry checks; this is characterized
  hardening, not identical old behavior. Manifests, scoped local traversal, enqueue lifetimes, created-directory
  accounting, and existing error/context reporting remain separate. The legacy copy-source error moved to its
  own file without changing its type or localized text.
- Measured production change: **139 fewer lines**, including both new files (906 to 767 lines across the five
  production files). Seven new shared test functions cover seventeen parameter-expanded cases for both preflight
  modes, all conflict policies, subtree boundaries/mapping, overwrite flags, directory accounting, deletion order,
  invalid child entries, and existing cancellation checkpoints. `FrameworkTests` now links Remote Infrastructure
  to exercise the helper on both platforms; the production dependency graph and package pins did not change.
- Post-change pinned actions passed **macOS 81/81** and **iOS 23/23**, including the two previously failing mobile
  upload cases and the new shared suite on both platforms. Sources were unchanged throughout each action.
  Evidence: `/tmp/termind-refactor-three.7kUsqP/r2-focused-*`. Strict formatting, project plist validation,
  localization, and whitespace checks passed. The architecture record now documents the shared resolver and
  retained counting rules. The unrelated full-suite baseline failures remain tracked for final comparison.

### R3: Pro offer presentation — implemented, affected checks passed

- Added the value-only `ProOfferPresentation` from StoreKit-derived price/period/offer data, eligibility, and
  the selected plan. No StoreKit controller, native purchase task, layout, or navigation state moved layers.
- The two localization policies remain separate: macOS supplies its explicit `AppLocalization` lookup; mobile
  uses the initializer's Foundation/Apple-selected bundle lookup. Both retain their effective locale for Gregorian
  duration formatting, full unit names, and one displayed component. Each purchase section computes the projection
  once. The existing History duration formatter remains separate (abbreviated/two units).
- Measured production change: **32 fewer lines**, including the new projection (602 to 570 across three files).
  Nine new shared test functions exercise twenty parameter-expanded cases for purchase/trial branches, missing
  product data, lifetime behavior, singular/composite periods, unit priority, and independent formatting/lookup
  policies. An additional six-case `AppLanguageTests` check uses the app's real English, zh-Hans, and zh-Hant
  catalogs for both plans. No catalog entries or translations changed.
- Pinned focused actions passed **macOS 41/41** and **iOS 11/11**, including the new suite on both platforms,
  explicit app-language cases, access/trial policies, architectural guards, and mobile language preference tests.
  Both actions retained unchanged source snapshots. Evidence: `/tmp/termind-refactor-three.7kUsqP/r3-focused-*`.
  Native layout/action wiring was reviewed in the diff; no interactive storefront or screenshot check is claimed.
- Repository-wide strict Swift formatting, Chinese localization, whitespace, and project plist checks passed.
  All three changes total **211 fewer production Swift lines**, excluding added tests/docs and the unrelated
  worktree deletion of `.TermindPresentationQA.xcodeproj`. Full-suite results and their limitations follow below.

### Final verification — full-suite gate remains blocked

- The final pinned full actions built successfully and reported **macOS 1,527/1,530** and **iOS 528/529**, with
  no skipped tests and unchanged source snapshots throughout both actions. All three new shared suites passed
  on both platforms. Full evidence: `/tmp/termind-refactor-three.7kUsqP/final-*`.
- Three failures repeat the immutable initial baseline: `AgentApprovalQueueTests.cancellingAParallelBatchStillAnswersEveryCall`,
  `ServerMetricsLifecycleTests.oneWorkerSurvivesWindowsAndStopsOnPauseSleepAndRemoval`, and
  `MobileKnowledgeToolRenderingTests.knowledgeRowsStayCompactAtPhoneWidthAndExpandOnDemand`.
  The initial `AgentRuntimeTests.stoppingARunCancelsTheToolsItIsWaitingOn` failure did not recur; no fix is claimed.
- The final macOS run also failed `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable`.
  This did not fail in this pass's initial baseline, although three earlier entries record the same assertion.
  Both its production source and test are byte-identical to `HEAD`. A minimal Swift package containing only
  those two unchanged HEAD files passed all two tests in three independent processes; that smaller harness
  is not equivalent to the complete Xcode target. Current Xcode isolation reproduced the macOS assertion
  (1/2 passed), while iOS passed 2/2. Evidence: `waveform-baseline-*`, `waveform-current-*`, and the source manifest
  under `/tmp/termind-refactor-three.7kUsqP/`.
- A clean export of `8509ddd5` was then built with pinned dependencies and a separate DerivedData directory.
  A framework-only diagnostic scheme passed 2/2, but the **original TFM scheme reproduced the same waveform
  assertion (1/2 passed)** with unchanged baseline sources and without any of these refactors. Evidence:
  `/tmp/termind-refactor-three.7kUsqP/waveform-head-tfm.*`; the passing framework-only comparison is
  `waveform-head-xcode.*`. The failure is sensitive to the scheme/harness; its underlying cause was not repaired
  or fully diagnosed. All four final failing cases now have pre-change evidence; a smaller harness alone
  would have been insufficient to establish that.
- No unrelated failing implementation/test, AgentKit source, package pin, or user's QA-project deletion was
  changed to force a green result. The three requested implementations have passing affected checks, but this
  is not an all-green full-suite result and the outstanding test gate remains unresolved.
## Width-based mobile layouts (2026-09-18)

- **Evidence:** `rg 'mobileInterfaceIdiom|MobileInterfaceIdiom' TFI TFITests` found
  device-based navigation, sheets and cards, plus a duplicated workspace test shell.
- **Action:** remove the device environment and injection; use the real root in
  workspace tests. Native compact and regular shells may rebuild at width-class changes.
- **Estimated reduction:** about 50 lines from the obsolete environment and test shell,
  excluding the new width transition behavior and regression coverage.
- **Status:** implemented and verified within the simulator coverage below; the
  full-suite gate remains non-green because of confirmed baseline failures.
- **Verification:** real-root tests cover repeated native sidebar/tab reconstruction,
  actual sidebar selection, Settings depth reset, discarded unsaved forms, Metrics
  list mapping and Back, retained Assistant drafts, independent window gates,
  deferred successful/failed saves, and existing SSH/SFTP connections. English,
  Simplified Chinese and Traditional Chinese snapshots are attached to the results.
  iPhone focused checks passed 25 tests; the final breadcrumb adjustment passed
  all four workspace rendering tests again on both iPhone and iPad. Actual
  portrait/landscape navigation was inspected on both simulators. Device Hub did
  not drive the system window-corner resize gesture: width changes and two-window
  independence were verified with real roots using frame and trait changes,
  rather than a manual Stage Manager drag. Formatting, Chinese localization and
  whitespace checks pass. Dependencies remain pinned and unchanged.
- **Full runs:** iPad reported 537 passed, 3 failed, 0 skipped out of 540;
  macOS reported 1,527 passed, 1 failed, 13 skipped out of 1,541. All new tests
  passed. Results: `/tmp/termind-width-final-ipad.xcresult`,
  `/tmp/termind-width-rebuild-macos.xcresult`, `/tmp/termind-width-iphone.xcresult`,
  `/tmp/termind-width-path-final.xcresult`, and
  `/tmp/termind-width-path-final-ipad.xcresult`. An earlier mobile run interrupted
  during cleanup of an older test process was superseded by the complete iPad run.
- **Baseline failures:** a clean export of `c015d5f3` with the original TFI scheme
  reproduces the iPad tab-bar visibility, host-card height and knowledge-row
  expansion assertions. The same baseline card suite passes on iPhone. Evidence:
  `/tmp/termind-width-baseline-ipad.xcresult` and
  `/tmp/termind-width-baseline-cards.xcresult`. No unrelated code or assertion was
  changed to hide these failures. The macOS full run has the previously documented
  `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable`
  failure; its source and test remain unchanged.

## Consolidate Main Window Registration and Content Style (2026-09-18)

- Evidence: `rg` found `RootView` mounting both `MainWindowRegistration` and
  `FullHeightWindowContent`; the latter existed only to set two native window
  properties. Separate attachment callbacks could size a window before its
  full-size content coordinate system was established.
- Action: set the style and titlebar transparency in the existing registration
  bridge before registering, and remove the redundant representable and NSView.
  Both operations remain in the macOS platform layer.
- Reduction: remove 30 lines of bridge plumbing, adding 5 lines at registration.
- Status: completed. All 47 focused window, lifecycle, and terminal-shortcut tests
  passed. Strict Swift formatting, localization validation, and diff checks passed.
- Full pinned macOS verification used the immutable `94ad70f1` snapshot because
  concurrent Dock-menu work introduced a separate test compilation error into
  the shared checkout. Result: 1,593 passed, 8 skipped, 5 failed. Failures were
  `StoreKitTrialTests.annualProductSuppliesPriceBillingPeriodTrialDurationAndEntitlement`
  (JPY storefront values instead of the test's USD values),
  `AgentApprovalQueueTests.cancellingAParallelBatchStillAnswersEveryCall`,
  `ServerMetricsLifecycleTests.oneWorkerSurvivesWindowsAndStopsOnPauseSleepAndRemoval`,
  `MetricsJourneyTests.offlineRestoredMetricsReconcileOnMainActor`, and
  `TerminalCommandDraftControllerTests.readsOneDraftAndRejectsConcurrentRequests`.
  The Agent and server-worker failures have earlier baseline evidence above;
  no baseline claim is made for the other three. No unrelated implementation or
  assertion was changed. Evidence: `/tmp/termind-window-sizing-focused-fixed.xcresult`
  and `/tmp/termind-window-sizing-snapshot-full.xcresult`.
- Native app checks confirmed a 904-by-572 window creates another of exactly the
  same size, fullscreen Command-N opens Connect, and leaving fullscreen retains
  the original size. Close/reopen preserved 904 by 572; isolated quit/relaunch
  preserved 1004 by 652. Quitting with differently sized windows and reopening
  used the last-used 904-by-572 size. The current macOS setting reopened one scene;
  preserving distinct restored frames is covered by the native-window tests.
  A concurrently running same-bundle demo initially interfered with system frame
  restoration; the relaunch checks were repeated without another instance.

## Resolve Metrics Clock and Short Knowledge-Card Baseline Failures (2026-09-18)

- The Metrics lifecycle test advanced its manual clock after the first base point,
  before optional GPU collection and the sampler's next sleep had necessarily
  finished registering. The pre-fix repeated run failed 3 of 5 iterations. A
  controlled probe of the existing model reproduced the missed advance; another
  0.05 seconds of simulated time released the sampler. The test now waits for
  both maintenance and sampling sleeps, and its polling helper preserves the
  caller's source location. Production Metrics lifecycle code is unchanged.
- The SwiftUI compact detail's flexible maximum height accepted the test's large
  height proposal even for short content. A trailing vertical `fixedSize` now
  preserves natural height within the scaled preview cap. The short installation
  fixture measures 99.33 points instead of occupying 180 points on the iPhone
  simulator. Tests classify the fixtures by preview truncation rather than tool
  name: short details must match natural height, while long rows must expand,
  retain expansion across layout, and return to compact height when collapsed.
- Focused macOS lifecycle/knowledge checks passed all 26 test functions; the
  lifecycle case additionally passed 20 of 20 repetitions. All three mobile
  knowledge tests passed, covering English, Simplified Chinese, Traditional
  Chinese, phone width, and accessibility text size. Native macOS row checks
  retain their 380- and 720-point widths. Strict Swift formatting, Chinese
  localization validation, and whitespace checks passed.
- Full pinned results: macOS **1,600 passed, 1 failed, 8 skipped / 1,609**;
  iOS **584 passed, 3 failed, 0 skipped / 587**. The repaired lifecycle and all
  knowledge rendering tests passed in these full actions. The macOS failure was
  the previously recorded
  `AgentApprovalQueueTests.cancellingAParallelBatchStillAnswersEveryCall`.
  Mobile failures were
  `MobileUploadBatchTests.sftpFolderUploadUsesTheCurrentDirectoryAndOneBatch`,
  `MobileEditorToolbarTests.cancelOnlyDismissesUnmodifiedDrafts(isDirty:)`, and
  `MobileAdaptiveLayoutTests.settingsDepthAndUnsavedFormsResetOnlyAcrossWidthClasses`.
  All three mobile cases passed focused reruns. This is not an all-green full
  suite, and those reruns do not establish a baseline or fix for unrelated cases.
- Evidence: `/tmp/termind-metrics-knowledge-fix-{macos-focused,repeat20,ios-focused,macos-full,ios-full}.xcresult`
  and the matching logs; mobile reruns are `ios-unrelated-rerun` (editor/settings)
  and `ios-upload-rerun` under the same prefix. The full mobile action completed
  both test bundles before its slow optional `simctl diagnose` collection was
  interrupted; its finalized result retains all 587 tests and the three failures.
  Package pins, public interfaces, and persistence were unchanged.
