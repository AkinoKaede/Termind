# Termind Refactoring Backlog

English-only durable history and redundancy backlog. For future work: confirm references with `rg`,
record evidence/action/estimated net production reduction, implement one independent change, run
risk-appropriate checks, and append status/verification. Retain completed items and native lifecycle
boundaries. Structural changes must explicitly disclaim reduction. Test additions are counted separately.
Historical results below describe their recorded runs, not current verification; pending work stays pending.
“Pinned” means `-onlyUsePackageVersionsFromResolvedFile`. Formatting/localization/diff checks mean strict recursive
Swift formatting, `Scripts/check-zh-localization.sh` and `git diff --check`; Xcode validates the app module graph.

## Completed items, 2026-08-30 to 2026-09-04

Items 1–32 and 34 date to August 30; later dates are explicit. “Build” means the recorded app build,
not a full test pass. Each item retains its original ID.

1. **Legacy SwiftUI transcript:** removed unreachable transcript/message/command/compaction/plan trees;
   retained live timestamps/risk components. Build and targeted Transcript tests passed.
2. **List hosting:** shared `HostingListRow`/`HostingListContent`; retained Transcript/conversation lifecycles.
   Build passed before the final parser-verified Connection Log migration.
3. **SSH initializers:** one private initializer, preserving temporary Hosts. Build passed.
4. **Terminal appearance:** SSH/Serial reuse `TerminalViewState.applyAppearance`. Build passed.
5. **SFTP store overloads:** removed four `TransferLibraryModel` forwarders for `RemoteSessionHostStore`. Build passed.
6. **Jump Host builder:** reused `sshJumpConfigurations`, preserving validation/errors. Build passed.
7. **Connection interaction:** shared trust/progress/prompt/reconnect policy in `RemoteSessionConnectionController`,
   keeping transport teardown local. Debug build and connection/SFTP tests passed.
8. **Tool-free text collectors:** shared streamed text/tool rejection for commands/titles/compaction. Focused tests passed.
9. **Provider authorization:** shared auth/ephemeral sessions; retained Vertex/empty-secret rules. Provider/ChatProbe passed.
10. **SwiftData transactions:** narrow `ModelContext.commit`, retaining two-stage history commits. Connection/SFTP History passed.
11. **libssh2 continuations:** shared identical SSH Exec/SFTP serial-worker bridges. Build passed.
12. **Legacy Transcript helpers:** removed dead streaming/edit-binding/activity helpers with item 1. Transcript checks passed.
13. **Composer migration:** callers use `conversation.composer`; removed four accessors, retaining attachment hooks.
    Build and Chat Composer tests passed.
14. **Toolbar search:** deleted unreachable menu/delegate/find-kind plumbing; query/keyboard behavior retained. Build passed.
15. **Agent SSH prompts:** `AgentSSHAuthenticationRequest` supplies both Journey/passphrase projections. Build passed.
16. **Atomic SFTP writes:** shared temp paths/cleanup/unlink/rename/progress, keeping source loops separate. Build/SFTP passed.
17. **Transfer conflicts:** shared Keep Both/directory/file policy, retaining distinct jobs. Debug build/SFTP passed.
18. **Client leases:** shared saved/borrowed acquisition and conditional disconnect; reservation state retained. Build/SFTP passed.
19. **Legacy tool metadata:** one compatibility table, retaining generic MCP fallback. Presentation tests passed.
20. **Test-only presentation actions:** removed unused automatic messages/verb duplication around `actionKind`. Presentation passed.
21. **Tool input unpacking:** narrow `AgentToolDetailFormatting` object/array helpers, local field presenters. Build passed.
22. **Idle sweepers:** one `AgentIdleSweeper`, caller-owned registries/emptiness. Focused tests passed.
23. **Sidebar headers:** reused `SidebarSectionHeader` for count/collapse instead of Assistant/Snippet copies. Build passed.
24. **Host deletion:** groups use repository/outbox saga; deleted direct snapshot deletion. Debug/repository/Snippet/forwarding passed.
25. **Unused declarations:** reference-confirmed Agent preflight/settings/metrics/reconnect/SSH-status wrappers/constants removed. Build passed.
26. **Settings page:** two callers use identical `SettingsFormPage`; deleted `SettingsCollectionPage`. Build/Settings passed.
27. **Cursor lists:** shared fixed-height Snippet Target/Host Chooser/Export Host adapter; specialized rows excluded. Build/list tests passed.
28. **Agent authentication:** shared typed Exec/SFTP authenticated-open retry loop. Build and all 21 Host Authentication tests passed.
29. **Transcript risk/confirmation:** shared native-row risk color/destructive confirmation. Build passed.
30. **Glass shapes:** one private shape-parameterized modifier, unchanged APIs/fallbacks. Build passed.
31. **Vault envelopes:** shared insert/update/upload indexing; callers retain versions/merge rules. Build/Vault Sync passed.
32. **Remote preflight:** shared directory ordering/descendant skip/target-kind lookup; prepared jobs remain distinct. Build/SFTP passed.
33. **Vertex selection (09-04):** `ModelProvider.usesVertexEndpoint`/`effectiveCredentialRef`, later adapted to API formats.
    Build/Provider checks passed.
34. **Dead fields:** removed unused onboarding/Agent/color/trial/runtime Linux metadata, retaining generated JSON provenance. Build passed.
35. **Run presentation (09-01):** derive state from reported run/outstanding queues. State/localization/diff checks passed.
36. **Copy-only tests (09-02):** removed 20 tests/literals; kept behavioral/persistence/language/protocol coverage.
    Target compiled; focused tests passed.
37. **Provider HTTP (09-02):** shared transport/HTTP/non-2xx validation; requests/parsing local. Build and 12 tests passed.
38. **Finder drop wrapper (09-02):** deleted unconstructed `NativeFileURLDropTarget`, retaining general target/test initializer.
    Build and five drop tests passed.
39. **Context Chip recovery (09-02):** shared payload boundaries/fallback filenames for live/restored attachments. Build/recovery passed.
40. **Save/rollback reuse (09-02):** `savePendingChanges`/`commit` cover Agent/Outbox/AI/conversation without shifting commits.
    All 46 focused tests passed.
41. **Overlay chrome (09-02):** three modifier chains use `termindTransientOverlaySurface`; content/transitions local. Debug passed.
42. **SSH form chrome (09-02):** shared `connectionFormChrome`, distinct form behavior. Formatting/Debug passed.
43. **Snippet content (09-02):** `SnippetCardContent` shared with drag ghost, separate interaction/chrome. Formatting/Debug passed.
44. **SFTP reads (09-02):** inline/two download paths use `withRemoteReadHandle`, keeping loops/destinations. Build/47 tests passed.
45. **Chooser selection (09-02):** shared `ManagedChooserState.allChecked(in:)`/`toggleAll(in:)` for three equal eligibility sets;
    restricted selection retained. Build/localization/diff passed.
46. **AgentKit extraction (09-02):** moved portable runtime behind host/interaction/prompt/presentation seams.
    Package build/tests/formatting and app build/full suite passed.
47. **Workspace commands (09-02):** removed AppKit-shadowed commands, retained standard shortcuts and moved split bindings
    off system keys with terminal routing coverage. Build/formatting/localization passed.
48. **Provider addressing (09-04):** one URL plus `ModelAPIFormat` replaces vendor/default-path branching; safe migration,
    AgentKit 0.4.0/0.5.0. Package checks, 994 app tests, localization/site build passed.

## Later completed work, 2026-09-09 to 2026-09-14

| Date | Change and retained boundary | Recorded verification / reduction |
| --- | --- | --- |
| 09-09 | StoreKit replaces local HMAC/Keychain/CloudKit trial with transaction clock watermark. | −121 production lines; commerce passed except unrelated catalog expectation. |
| 09-09 | Delete unread Show Recents setting/UI/labels; retain Sidebar accessibility localization. | Builds, formatting, localization and relevant tests passed. |
| 09-11 | Remove five redundant tests and literal/enum/catalog snapshots; retain behavior. | −77 test lines; relevant checks passed, unchanged intermittent focus test passed rerun. |
| 09-11 | Delete `ScreenshotDemoWindow`; use production WindowGroup with demo restoration off. | Full pinned tests, native capture, formatting/localization passed. |
| 09-11 | Share SFTP permission Domain draft/Presentation grid. | Regression evidence was recorded in `MOBILE_ROLLOUT.md`. |
| 09-11 | Move CloudKit/settings transactions/journals/terminal/history to frameworks; retain desktop adapters. | Shared/mobile passed; full macOS retained known Agent timing failures. |
| 09-11 | Application owns Metrics/Journey state, Presentation panels/forms; native keyboard/logs stay local. | Shared/mobile and 127 focused macOS tests passed. |
| 09-11 | Share skill library/importer/role form in Application/Infrastructure/Presentation; native editors retained. | Isolated build and 81 mobile/shared tests passed. |
| 09-12 | Share Assistant runtime/tools/attachments/speech/conversation/list behavior. | Builds/navigation/Assistant/localization/formatting passed; unrelated mobile Metrics race passed rerun. |
| 09-12 | Remove app forwarding aliases; retain six responsibility-named adapters. | −86 files, 224 app aliases, 20 Persistence aliases; both builds/architecture/full TFI passed. |
| 09-12 | Align TFI layers, move connection construction to Infrastructure, centralize then-current idiom policy. | Both builds/architecture/full TFI passed; later width work supersedes idiom policy. |
| 09-12 | Share `TerminalCommandDraftController`/`CommandGenerationCoordinator`, timeout/cancellation/protocol constants. | Focused desktop/mobile passed. |
| 09-12 | Domain `RemoteFile`, Application `RemoteFileSystem`/`MobileSFTPSessionModel`. | Structural net increase; builds/architecture/SFTP passed. |
| 09-12 | Mobile adopts shared trust/progress controller and Workspace/Metrics temporary-key preparation. | Connection/Journey/Metrics/recovery passed. |
| 09-12 | Share `TerminalFindController`; platform binding closures retained. | Direct/platform tests passed. |
| 09-12 | Domain detects Linux distribution once, distinguishing unavailable/conclusive. | Domain/Host/mobile Workspace passed. |
| 09-12 | Share Journey header/status; native logs/failures/backgrounds/keyboard retained. | −98 production lines; builds/Journey passed. |
| 09-12 | Presentation owns Ghostty appearance conversion; desktop preference storage retained. | Both builds/themes passed; dependencies unchanged. |
| 09-12 | Share terminal-upload readiness/notices, distinct platform execution. | Direct policy tests/both builds passed. |
| 09-12 | Share hashed/endpoint Known Host titles, distinct cards. | Direct presentation/both builds passed. |
| 09-12 | Restrict ListViewKit: remove eight macOS adapters/eleven mounts, retain narrow UIKit transcript/history uses. | −611 macOS lines; builds/focused/format/localization/boundaries passed. |
| 09-12 | Share transcript tools/results/disclosure/timestamps/Markdown, retaining native renderers/viewport ownership. | Both builds/architecture record verify boundary. |
| 09-12 | Remove Periphery-confirmed 34 imports/three empty files/declarations; retain dynamic/protocol entry points. | −150 production lines; builds/focused/format/localization/diff passed. |
| 09-12 | Remove concrete native/list implementation-type assertions. | Behavioral rendering/identity/reuse/interaction/environment coverage retained. |
| 09-13 | Remove 81 compiler-confirmed unused localizations/three obsolete expectations/verified stale metadata. | Both builds and localization/language checks passed. |
| 09-13 | Use `ChatSlashCommandRegistry` with explicit platform ownership. | Both builds and registry/desktop/mobile tests passed. |
| 09-13 | Inject app-owned `MobileFeatureRegistry`; replace tab/sidebar/destination copies. | iOS build and 28 navigation tests passed. |
| 09-13 | Share tree/route/deletion/display/Snippet/model/SFTP-drag/service policy; retain native lifetimes. | Both builds/shared/mobile passed. |
| 09-13 | Annual introductory offers replace new standalone trials; legacy entitlement temporarily retained. | Offer/eligibility/duration/price/period/expiration derive from StoreKit; legacy removal follows below. |
| 09-13 | Remove 27 mobile/seven app source snapshots, host-state Keychain/status integration, duplicate permission/history tests; compatibility/defaults/limits move to FrameworkTests. | −1,303 lines; 1,079 macOS, 13 shared, 218 iOS tests plus formatting/localization/diff passed. Existing waveform bitmap failure remains outside cleanup. |
| 09-14 | Fresh scan removes standalone-trial ID/domain/clock/entitlements/product/UI/tests/copy; `lifetimeProductID` and annual trials remain. | Estimate −90 production lines; format/localization/site, 1,091 macOS, rerun Metrics and 187 shared iOS passed. iOS built; ten unrelated toolbar tests failed full/isolated runs. |

## Retained boundaries

Native transcript/conversation/dynamic/drag lists retain dedicated lifecycles. Share only portable SSH/SFTP/Serial/
platform policy; differing startup, credential saves, teardown, logs and interaction stay separate. Frozen SwiftData
schemas are migration contracts; small lookalike repositories/views need no abstraction without reduction.
`RuntimeVersions` stays platform-local to avoid invalid Ghostty dependencies. The 09-02 completion/recheck found
no further qualifying independent duplication/dead code; every later candidate needs fresh references.

## Planner reuse and test cleanup, 2026-09-16

### Desktop download planner — completed

- Evidence: `rg 'PreparedJob|PreparedBatch|pendingBatch|keepBothLocalURL' TFM TFI Frameworks TFMTests TFITests`
  found desktop's sole mixed batch path was download-only, with empty remote-directory collections; mobile already
  used `SFTPRemoteDownloadPlanner` and uploads `SFTPLocalUploadPlanner`.
- Adopt shared traversal/local conflicts/scoped destination/enqueueing; retain desktop pending/errors/copy policy/
  lifetimes. Destination ownership now creates directory-only trees. Estimate −180, actual −167 production lines
  (−59 including regression tests); architecture updated.
- All 75 SFTP/architecture tests passed, including three new tests/ten conflict/subtree/empty/cancellation cases;
  empty-directory regression fails with old production code. Full pinned macOS: 1,337/1,343. Four failures reproduce
  before change: `SettingsSyncTests.providedDatabaseCopyMigratesWithoutReset` (schema 15 vs 17),
  `ModelCapabilityResolverTests.reportedFieldsWinOverCodexAutoReviewOverride`,
  `ScrubberWebClientTests.fetchPreflightNeverEscalatesPrivateHTTP`,
  `ChatComposerStateTests.aFailureNoticeIsNotAnAnswerWorthNaming`.
  `MetricsJourneyTests.offlineRestoredMetricsReconcileOnMainActor` passed rerun;
  `SSHImportTests.indexedIdentityPlanningHandlesTheImportFileLimit` exceeded two seconds concurrently but passed
  isolated against both versions (final 0.100 s).
- Full pinned iPhone 17 Pro/iOS 26.5: 426/432, all 205 framework tests passed. Five Assistant/import failures remained
  on rerun (identifiers below); `MobileEditorToolbarTests.iconButtonsKeepTheirNamesAndSaveLifecycle` passed rerun.
  Formatting/localization/symbol/diff checks
  passed; no dependency/catalog/shared production changes.

### Desktop copy planner and duplicate assertions — implemented, partial verification

- Evidence: `rg 'PreparedRemoteCopy|pendingRemoteCopyBatch|SFTPRemoteCopyPlanner.enqueue|resolveRemoteDirectories'`
  across app/framework/test Swift found desktop-only preparation/conflict/enqueue copies. Adopt the existing mobile
  planner and directory-mutation reporting, preserving pending/errors/completion refresh/interactive deletion.
  Estimate −220, actual −193 production lines; coverage retains validated recursive deletion/cancellation and adds
  three-policy file/directory/subtree conflicts, empty refresh and pending cancellation. Upload helpers remained R2.
- Reference scans of role-label, unknown-command, approval-copy, handshake-description and upload-notice tests
  removed pure literals/duplicates, keeping parameterized classification, endpoint/destructive policy, locales,
  diagnostics and gating/payload behavior. Estimate −50, actual −59 test lines; +75 copy regression lines gives
  −177 total Swift. Architecture/language/catalog/protocol/round-trip/behavioral string assertions remain.
- Focused pinned TFM: 200/200; full: 1,436/1,437, unchanged
  `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable` bitmap assertion. Earlier records
  report it, but this pass ran no baseline/isolated rerun. TFI never built/tested: unavailable destination UUID;
  owner requested commit before retry after discovering a booted phone. Not a passing iOS result.
- Formatting/localization/removed-symbol/diff checks passed; Xcode resolved modules standalone SourceKit could not.
  Existing SwiftLint size/complexity findings stayed outside scope, without suppressions. Dependencies/catalogs unchanged.
  Evidence: `/tmp/termind-refactor-copy-{focused,macos}-20260916.xcresult`.

### Low-value UI/source assertions — implemented, full verification recorded as in progress

`rg '#filePath|sourceRoot|String\(contentsOf|source\.contains' FrameworkTests TFMTests TFITests` found 35 architecture
and eight UI/source snapshots. Removed implementation/copy/layout/enum/palette/fixed-canvas/disconnected sorting
checks and orphan helpers: 52 declarations/1,230 lines versus estimate 1,000–1,200. Source checks fell 43→9 narrow
ownership/dependency guards; native-list allowlist permits importer removal but rejects unapproved additions.
Grouped Host tests now use fixture placement. Behavioral/language/protocol/opt-in screenshots remain; production,
packages/catalogs unchanged and existing architecture edits preserved. Initial pinned macOS 18/18, iOS 5/5;
format/localization/remaining-source/diff checks passed. Standalone SourceKit partly inconclusive; generic SwiftLint
size/tuple/pixel-name/force-try findings untouched. Full runs were proceeding sequentially; no final pass recorded
here. Evidence: `/tmp/termind-test-cleanup-initial-{macos,ios}.xcresult`.

### SFTP status labels — verified with existing iOS failures

`rg 'status\(for: transfer\)|transfer\.state\.label' TFM TFI` found mobile direction mapping/two generic desktop
labels. Presentation now supplies shared running/completed direction labels, generic other states: −8 production
lines as estimated, unchanged translations/transports. Pinned macOS 1,183 app +213 shared passed; iOS 212/217 app
+213 shared, with the same five Assistant/import failures/text as `/tmp/termind-test-cleanup-full-ios.log`.
Formatting/localization/diff passed; English/zh-Hans/zh-Hant resource-backed label matrices reviewed, not live
transfers. Evidence: `/tmp/termind-sftp-status-{macos,ios}-20260916.xcresult`, `/tmp/termind-sftp-status-preview/`.

### Desktop forwarding adapter — implemented; verification blocker later resolved by the 09-17 repair

- `rg 'PortForwardingEditorState|PortForwardingEditorPolicy'` across sources/tests/Memory/project found a 43-line
  adapter serving three computed desktop getters/seven tests; mobile already used shared policy. Replace with
  `PortForwardingEditorPolicy`, preserving synchronous observed saved-rule/Host/controller reads, callbacks,
  intent OR activity, normalization, draft Host-ID lookup, edit locks and native runtime values. No new wrapper/API/
  schema/secret/approval/dependency/localization change. Estimate −27–28; actual −27 production (−43/+16),
  +109 test lines, +82 total. Seven desktop behaviors retained; shared matrix adds 14 cases including hidden dynamic
  targets, local/remote normalization, activity/intent and missing targets. Independent reviews/audit found no issue.
- Focused pinned TFM 33/33 (14 feature, seven editor, nine architecture, three shared functions/14 cases), re-extracted
  without rerunning: `/tmp/termind-forwarding-adapter-verify.xMtOCK/focused.xcresult`.
  Full macOS 1,399/1,399 (1,183+216), no skips; iOS 428/433 (212/217+216), five failures/no skips, exact rerun 0/5.
  Simulator: iPhone 17 Pro/iOS 26.5, `38789AE8-B5AA-46CA-A15C-77CE760FC550`.
- Repeated iOS identifiers: `MobileAssistantTests.attachmentOnlyFirstSendPromotesTheConversation`,
  `firstNewConversationSendPromotesDraftAndStartsRun` (expected user/assistant),
  `existingConversationSendStillUsesTheDraftExecutionPath` (expected user/user/assistant),
  `completeRegistryIncludesRemoteAndBuiltInToolsOnlyForCapableModels` (expected no `terminal_suggest`), and
  `MobileVaultFeatureTests.importRequiresAnExplicitUsernameWhenTheConfigurationOmitsIt` (`model.canImport`).
  No pre-refactor baseline was run; attribution was unverified, not established regression/pre-existing behavior.
  All planned stages completed after provider interruption; it was neither test failure nor user stop.
- Formatting/localization/diff/retired-symbol checks passed. No-index exit 1 was corrected as “files differ” in
  `untracked-whitespace-adjudication.json`, preserving raw evidence; supplementary scan passed. Patch, including
  untracked test, matched verifier/`partial.patch` byte-for-byte (SHA-256
  `f76b9950aa3bb49140865feec1153836f59ce903d25f3a32edcbf07ab320a691`); dependency hashes matched HEAD/evidence.
  Audit altered documentation only, with no rebuild/source edit/commit; five paths remained at `8b01a631fefdbe14e1324d87c91d0860124d85d3`.
- Manual status/toggle/lock/save/cancel/back checks were not run; no visual claim. Full results retain 166 macOS
  warnings (88 locale/74 constraint/four StoreKit listener), 29 iOS (27 locale/two view-update publishing), none in
  targeted rerun; focused logs retain row-height/Xcode warnings. Warnings were not baseline-attributed/investigated.
- Evidence: `/tmp/termind-forwarding-adapter-recovery.eggzSE/remaining-checks.9wl35uwk/` contains full/rerun results,
  commands/logs/reports/test trees/comparisons/simulator/patch evidence; sibling `audit-record/` has independent
  re-extractions/integrity/diff results. Implementation: `/tmp/termind-forwarding-adapter-implement.aTsWRl/checks.{sh,log}`.

## Five repeated iOS failures, 2026-09-17 — repaired and verified

Clean pinned `d582d711` reproduced all five (0/5) before this test-only repair, establishing this repair's baseline,
not retroactively a pre-refactor baseline. Three send tests now assert user-only history, failed-run/prompt association,
failure timeline and title exclusion: `b2f05217` intentionally stopped synthesizing replies without a Chat model.
Existing-chat testing awaits failed state rather than 20 yields. Registry testing follows `df3bd04c`: stable
`terminal_suggest` definition, snapshot-gated execution, equal descriptors across surfaces and no tools for incapable
models. Import testing follows `ac165a9a`'s indexed identities: real `SSHImportReader`/temporary config/empty default
username reject invalid commits; adding `User deploy` and rescanning imports a linked Host/Identity. Obsolete fake
removed, without test-only production mutation API.

All five identifiers remain, none skipped/deleted/expected-failing; only two test files/record changed. Three
independent actions passed all five (`fixed-repeat`, `focused-2`, `focused-3`); the first `-test-iterations 3` actually
ran Swift Testing once. Full pinned TFI 433/433, TFM 1,399/1,399, no failures/skips, resolve the preceding automated
blocker. Formatting/localization/whitespace passed; Xcode, not inconclusive SourceKit, validates modules. Full runs
retain 29 iOS/168 macOS uninvestigated/unattributed warnings, focused runs none. Evidence/scripts:
`/tmp/termind-ios-five-fixes.NfgsN4/` (`baseline`, focused actions, `full-ios`, `full-macos` results).

## Skill packages and immutable helpers, 2026-09-17

- **Single-document loader — implemented.** `load_skill` duplicated definition/presenter/guidance/output exemptions.
  Replace executable `LoadSkillTool` with `skill_read_file` for bounded instructions/supporting resources; retain
  historical presenter/replay only. Estimate about −100 retired-loader lines; package management is additive, no
  overall reduction claim. AgentKit tests passed; app skill/migration/memory/mobile suites exercised.
- **Starter runbooks — implemented.** `AgentSkillLibrary` shipped three editable seeds, duplicated in library/sync
  persistence, with destructive Reset in both apps. Replace with two immutable runtime helpers; delete seeds/Reset/
  old fixtures, preserving installed starters as ordinary user records. Native conflict repair and atomic install/
  sync transaction remain. Estimate about −200 retired production lines, excluding installer/migration coverage.
  Signed/published AgentKit 0.13.0: 213 package tests passed. Memory labels remain 持久化记忆 / 持久化記憶.
  Final iOS 452/452, macOS app 1,183 passed, AppLanguage independently passed; refreshed shared 231/232 with existing
  waveform PNG failure. New skill/library/sync tests, bilingual native review, formatting/localization/diff passed.

## Reuse and architecture scan, 2026-09-17

Discovery baseline `8509ddd5`: inventory/normalized-block scan of 516 production Swift files/113,165 lines across
frameworks/apps/bridge; inspected candidate bodies/callers/tests, not every file behavior. Import audit of 273
framework files found no prohibited edge. Stale source graph/unavailable structural navigation were not reachability
proof. Website localized home already shares one page; AgentKit/third parties excluded. Scan changed docs only;
source paths, English prose, diff/localization checks passed, no builds/tests/visual verification. At discovery all
six were pending. Estimates are net production lines including helpers/callers, excluding tests; abandon extractions
that cost more. Operator then authorized R1→R2→R3; R4–R6 were outside that pass, with later R5/R6 updates below.

### R1. CloudKit record coding — implemented, affected checks passed

- Evidence: three Cloud coordinators' `makeRecord|envelope|payloadData|systemFields|record|assetURL` methods repeated
  record restoration, hashing, inline/assets, secure fields and cache paths; confirm with `rg` in
  `Frameworks/TermindInfrastructure/Cloud`. Estimated −70–110, low/medium wire risk.
- `CloudSyncRecordCoding` shares mechanics, raw/quarantine vs validated reads, lowercase SHA-256, lazy assets and
  namespaces. Coordinators retain envelope metadata/validation, legacy Guardian canonicalization, errors/public
  entry points/zone names/casing/cleanup/independent lifetimes; exact 700,000-byte threshold and frozen models remain.
  Actual −40 (1,741→1,701), eight new functions/12 cases covering threshold/storage transitions/hash/corruption/missing
  payload/asset errors/secure fields/namespace boundaries. No need for a generic metadata API or R5 due to size alone.
- Pinned macOS 61/61, iOS 13/13, new suites executed with unchanged source snapshots; Vault/Settings/legacy Guardian/
  Metrics/architecture passed. Format/diff passed; Xcode resolved imports SourceKit could not. Evidence under
  `/tmp/termind-refactor-three.7kUsqP/r1-focused-*`. Initial full baseline before edits: macOS 1,502/1,505, iOS 502/503;
  approval/runtime cancellation, Metrics worker and mobile knowledge expansion failed. No unrelated fixes/package bump.

### R2. Upload/copy conflicts — implemented with characterized upload hardening

- Evidence: `remoteConflictPreflight|resolveRemoteDirectories|resolveRemoteConflict|deleteRecursively` in
  `SFTPLocalUploadPlanner`, `SFTPRemoteTransferPlanner` and `SFTPRemoteCopyOperation` duplicated subtree/Keep Both/
  delete policy. This is the 09-16 upload follow-up, not unfinished desktop planner adoption. Estimate −100–140;
  medium risk because Replace deletes directories. Before sharing, new fake-backend tests reproduced cancelled
  directory-only upload creating a directory and Replace accepting an outside child; macOS copy/SFTP 65/65,
  mobile upload 5/7 (only new cases failed).
- `SFTPRemoteConflictResolver` uses `RemoteFileSystem`, preserving strict-descendant upload preflight versus
  self-or-descendant copy. Upload deliberately gains copy's cancellation/recursive-name/path validation; not
  byte-equivalent old behavior. Keep manifests/local scoped traversal/jobs/enqueue/pending UI/interactive deletion/
  directory accounting/errors separate. Copy-source error moved unchanged to its own file.
- Actual −139 (906→767, five files); seven shared functions/17 cases cover both modes/all policies/subtree mapping/
  overwrite/counts/delete order/invalid paths/cancellation. FrameworkTests now links Remote Infrastructure on both
  platforms; production graph/pins unchanged. Required mobile coverage retains scoped symlink exclusion and empty
  directory uploads. Final focused macOS 81/81, iOS 23/23 include repaired cases/shared suite with unchanged snapshots.
  Formatting/plist/localization/diff passed; architecture records resolver/counting rules. Evidence: same root,
  `r2-before-*`, `r2-focused-*`; unrelated full failures remain tracked.

### R3. Pro offer projection — implemented, affected checks passed

- Evidence: `purchaseButtonTitle|selectedPlanDetail|trialBadge|annualBillingUnit|func formatted` repeated in desktop/
  mobile paywalls. Estimate −20–40, low risk. Value-only `ProOfferPresentation` consumes StoreKit-derived values/
  eligibility/plan, never Infrastructure/controller. Apps retain cards/features/sheets/navigation/purchase/management.
- macOS injects `AppLocalization`, mobile Foundation/Apple bundle lookup; both keep effective locale, Gregorian
  full units/one component. Compute once per purchase section; History's abbreviated/two-unit formatter stays separate.
  Actual −32 (602→570); nine functions/20 cases cover plan/trial/missing data/period priority/separate locale lookup,
  plus six real-catalog English/zh-Hans/zh-Hant AppLanguage cases, with no catalog changes.
- Pinned macOS 41/41, iOS 11/11 with stable sources, including new suites/access/trial/architecture/language tests.
  Diff-reviewed native layout/actions; no interactive storefront/screenshots claimed. Evidence: same root `r3-focused-*`.
  Repository formatting/localization/diff/plist passed. R1–R3 total −211 production lines, excluding tests/docs and
  unrelated `.TermindPresentationQA.xcodeproj` deletion.

### R1–R3 full verification — gate remained non-green

Final pinned macOS 1,527/1,530, iOS 528/529, no skips, unchanged action snapshots; all three new shared suites passed
on both. Three failures repeat immutable baseline:
`AgentApprovalQueueTests.cancellingAParallelBatchStillAnswersEveryCall`,
`ServerMetricsLifecycleTests.oneWorkerSurvivesWindowsAndStopsOnPauseSleepAndRemoval`,
`MobileKnowledgeToolRenderingTests.knowledgeRowsStayCompactAtPhoneWidthAndExpandOnDemand`.
Initial `AgentRuntimeTests.stoppingARunCancelsTheToolsItIsWaitingOn` did not recur; no fix claimed.

Final macOS additionally failed `SpeechWaveformViewTests.waveformRespondsToLevelsAndReduceMotionMakesItStable`,
absent in initial baseline despite earlier records. Unchanged HEAD source/test passed both tests in three independent
minimal-package processes; current isolated Xcode macOS failed 1/2, iOS passed 2/2. Clean pinned `8509ddd5` export
with separate DerivedData passed framework-only scheme 2/2 but reproduced 1/2 failure under original TFM scheme.
Thus all four final failures have pre-change evidence; smaller harnesses alone were insufficient. Scheme sensitivity
is established, root cause unrepaired. No unrelated tests/implementation/AgentKit/pins/QA deletion changed for green.
Evidence: `/tmp/termind-refactor-three.7kUsqP/` (`final-*`, `waveform-{baseline,current}-*`,
`waveform-head-tfm.*`, passing `waveform-head-xcode.*`, source manifests).

### R4. Architecture guards — pending, explicitly structural

`ArchitectureBoundaryTests` scans AgentKit ownership only in TFM, omits Remote Infrastructure/Presentation/bridge
from SwiftData checks, incompletely forbids Application UI/native I/O and Presentation Infrastructure imports, and
misses annotated/qualified imports. Confirm with `rg 'applicationDoesNotImport|typesOwnedByTheAgentPackage|sharedFrameworksCannot|sharedPresentation|swiftDataModels|swiftFiles|text.split' TFMTests/ArchitectureBoundaryTests.swift`.
Centralize production roots/dependency rules/bounded import recognition; cover all owners, preserving fail-closed
missing/empty roots/native-list allowlist. No production violation/reduction claimed; budget +20–60 test lines.
Use fixtures, never production mutations, to reject annotated/qualified forbidden imports/out-of-owner declarations,
allow valid imports/importer removal. Run boundary/both pinned suites; never restore UI/copy/layout/path/wiring snapshots.

### R5. CloudKit lifecycle — discovery follow-up, implementing as of 2026-09-19

`rg 'operationID|prepareAndSynchronize|synchronizeNow|isReadyToSend|stopEngineForAccountChange|handleZoneDeletion'`
in the three Cloud coordinators confirms duplicated operation/account/engine/fetch/send/pause/reset/error policy.
Existing codecs/journals/merges alone do not characterize async lifecycle. After R1, compose one typed Infrastructure
lifecycle instance per category with value journal projection/closures and injectable account/engine transport.
Keep codecs/merge/quarantine/version acknowledgements/legacy records/Settings secrets in adapters; no universal untyped
framework or model reshaping. Zones/journals/accounts/subscriptions/switches/engines/lifetimes remain independent;
secret uploads require current-engine fetch and revoke on pause/account retirement. Estimate −200–350 additional
production lines including driver/adapters, high risk; package/models unchanged.

Required deterministic coverage: pause/retry/stale callbacks, account switching/consent, zone/environment resets,
failed fetch/readiness-before-send, secret authorization/revocation; migrate categories individually and retain
tombstone/quarantine/versioned-ack tests. Fresh 09-19 scan reconfirmed evidence; implementation underway, unified
verification follows all requested edits. Architecture ownership is recorded; no completion/result is claimed here.

### R6. MCP ticket policy — discovery follow-up, implementing as of 2026-09-19

`rg 'has.*Activity|count < 64|addingTimeInterval\(600\)|maximumBytes|func (endSession|revokeSession|sweep)|1_800|count - 256'`
in `TFM/Application/MCPServer/MCP{Upload,Download}Coordinator.swift` confirms repeated metadata/activity/expiry/capacity/
retention; download references `MCPUploadRequest.maximumBytes`. Share only desktop metadata/expiry/retention/limits, reusing
four-slot `MCPTransferBudget`: ten-minute tickets, 64 unfinished/direction, 256 completions/direction/thirty minutes.
Keep separate dictionaries/errors/live states/claims/generations/stream loops/revocation/cleanup/task ordering;
no listener in mobile/frameworks/AgentKit or generic ticket superclass. Upload expiry may spawn cleanup; download
can serve Range after success; `cancelAndWait` captures tasks differently. Estimate originally −30–70, revised on
09-19 to −10–40 including narrow protocol cost; medium/high lifecycle/security risk.

Retain `MCPUploadTests`, `MCPDownloadTests` and session-teardown tests; add clock-boundary/retention coverage and preserve Range-after-success,
acknowledged offsets, late disconnects, Host/session revocation, slots held through cleanup, protocol strings and
metadata-only audit. Fresh scan reconfirmed evidence; implementing. User requested finishing both remaining refactors
before unified verification, superseding per-edit checks for this pass.

Scan disposition: R1 first, then R2/R3; R4 before expanding dependency/lifecycle ownership, separate R5/R6 design/
characterization. Retain frozen schemas, responsibility-named Vault facades, native lists/terminal teardown and local
runtime-version adapters. File size or a small pixel-test duplicate alone never justifies merging native renderers.

## Window and mobile changes, 2026-09-18

### Width-based mobile layouts — implemented, later navigation design superseded below

`rg 'mobileInterfaceIdiom|MobileInterfaceIdiom' TFI TFITests` found device-based shells/sheets/cards and a duplicate
test root. Removed environment/injection, tested real roots rebuilding native compact/regular shells; estimate −50
obsolete lines excluding transition behavior/tests. Coverage includes reconstruction/actual selection, Settings/draft
reset, Metrics mapping/Back, Assistant drafts, window independence, deferred saves/errors and live SSH/SFTP.
Phone focused 25 passed; final breadcrumb four Workspace tests passed on phone/tablet. English/zh-Hans/zh-Hant snapshots
and actual rotation reviewed. Device Hub did not perform Stage Manager corner resizing; frame/trait real-root tests
cover width/two-window behavior. Formatting/localization/diff passed, pins unchanged.

Full iPad: 537 passed/3 failed/0 skipped of 540; macOS: 1,527/1/13 of 1,541, all new tests passed. Clean `c015d5f3`
with original TFI scheme reproduced iPad tab-bar visibility/Host-card height/knowledge expansion; baseline cards pass
on phone. Mac retained unchanged waveform failure. Earlier interrupted cleanup run was superseded by complete iPad.
Evidence: `/tmp/termind-width-{final-ipad,rebuild-macos,iphone,path-final,path-final-ipad,baseline-ipad,baseline-cards}.xcresult`.
Not a green full-suite claim; unrelated assertions/code were not changed.

### Main-window registration/content style — completed

`rg` found RootView mounting `MainWindowRegistration` plus `FullHeightWindowContent` solely for two native properties;
independent attachment could size before the full-size coordinate system. Move style/transparency before registration
in the existing macOS bridge, removing representable/NSView (−30/+5). All 47 window/lifecycle/shortcut checks and
formatting/localization/diff passed. Native checks: 904×572 copies exactly, fullscreen Command-N opens Connect, exit/
close/reopen preserves size; isolated quit/relaunch preserves 1004×652 and last-used 904×572 across differing windows.
System restored one scene; distinct restored frames are test-covered. Same-bundle demo interference prompted clean
relaunch repeats.

Full pinned immutable `94ad70f1` avoided concurrent Dock-menu test compilation errors: 1,593 passed/5 failed/8 skipped.
Failures: `StoreKitTrialTests.annualProductSuppliesPriceBillingPeriodTrialDurationAndEntitlement` (JPY vs USD),
parallel approval cancellation, Metrics worker lifecycle,
`MetricsJourneyTests.offlineRestoredMetricsReconcileOnMainActor`,
`TerminalCommandDraftControllerTests.readsOneDraftAndRejectsConcurrentRequests`. Only Agent/worker had earlier baseline
evidence; no baseline claim/fix for the other three. Results:
`/tmp/termind-window-sizing-{focused-fixed,snapshot-full}.xcresult`.

### Metrics clock and short knowledge cards — repaired, full suite still non-green

Metrics tests advanced the manual clock before GPU work/next sleep registration; pre-fix failed 3/5 and a model probe
needed another 0.05 s. Await both maintenance/sampling sleeps and preserve caller locations in polling; production
Metrics unchanged. Compact SwiftUI details accepted tall proposals; trailing vertical `fixedSize` restores natural
height within scaled cap (short phone fixture 99.33 vs 180 points). Tests classify truncation, checking natural short
height and long expand/layout-retain/collapse, not tool names.

macOS lifecycle/knowledge 26 functions passed plus 20/20 lifecycle repeats; all three mobile knowledge tests passed
English/zh-Hans/zh-Hant, phone/accessibility; native desktop widths 380/720 retained. Format/localization/diff passed.
Full pinned macOS 1,600 passed/1 failed/8 skipped of 1,609, iOS 584/3/0 of 587; repaired tests passed. Remaining macOS
parallel-approval failure was recorded earlier. Mobile `MobileUploadBatchTests.sftpFolderUploadUsesTheCurrentDirectoryAndOneBatch`,
`MobileEditorToolbarTests.cancelOnlyDismissesUnmodifiedDrafts(isDirty:)`,
`MobileAdaptiveLayoutTests.settingsDepthAndUnsavedFormsResetOnlyAcrossWidthClasses` passed focused reruns, not proof
of baseline/fix. Full mobile bundles finished before optional slow `simctl diagnose` was interrupted; finalized
587-test result is intact. Pins/APIs/persistence unchanged. Evidence:
`/tmp/termind-metrics-knowledge-fix-{macos-focused,repeat20,ios-focused,macos-full,ios-full,ios-unrelated-rerun,ios-upload-rerun}.xcresult`.

### Preserve mobile navigation during resizing — implemented

`rg 'layoutTransition|compactMetrics|registrations\(on|scene\.layout' TFI TFITests` found two roots, route resets,
Metrics copies and reconstruction save gates. Replace with one native sidebar-adaptable TabView/five stable stacks;
remove migration/registration/save gating, keep single Metrics shortcut target and save/cancel/error/native terminal
ownership. Estimate −150–200, actual −210 production lines; Metrics/Vault search use `waveform.path.ecg`.

Focused iPad 21/21; phone 20/21 because a test forced unsupported regular class, changing search placement. Corrected
native-class/compact-width fixture passed three times on each, retaining iPad width transitions. Coverage preserves
pages/Settings/drafts/search/scroll/window independence/save/errors/session instances. English/zh-Hans/zh-Hant normal/
accessibility screenshots reviewed: five titles fit 320/375-point bottom bars; intermediate iPad top bar scrolls with
all items selectable. Hosting-window/child resize tests do not mistake native title scaling for truncation. Manual
rotation retained Models/icon; Device Hub did not perform corner resizing, covered through frame/trait tests.

Full before fixture corrections: iPad 583/586, phone 584/586, macOS 1,598 passed/1 failed/8 skipped of 1,607. New label/
scroll failures were corrected; other failures were reproduced iPad tab visibility/Host-card height and recorded Mac
waveform. No unrelated assertions/production changed; not all-green. Format/localization/diff passed; pins/APIs/stores
unchanged. Evidence: `/tmp/termind-adaptive-tabs-{ipad,iphone,macos}-full.xcresult`,
`/tmp/termind-adaptive-tabs-final-{ipad,iphone}.xcresult`,
`/tmp/termind-adaptive-tabs-scroll-native-{iphone,ipad}.xcresult`.

### Window/quit confirmation removal — superseded

`rg 'dismissalConfirmationDialog|Quit with unuploaded changes|sftpEdits.recheck' TFM` found Workspace close and SFTP
quit warnings/five unique strings. Proposed removal preserved native dismissal/pane-first Command-W/ownership/bounded
cleanup, estimated −25–35 production lines/five entries. User instead requested both confirmations retained and only
the edited indicator hidden; both dialogs/all strings restored.

### Close-button edited indicator — implemented, verification pending

Restored SwiftUI WindowGroup sets `NSWindow.isDocumentEdited` for Workspace confirmation. Isolated Demo probe cleared
it while retaining Close Window/Cancel. Attached registration now observes/clears decoration only, preserving dismissal
delegate/condition/copy/SFTP quit checks. Visual correction, no code-reduction/API/persistence/package claim.

### Free Workspace composition — implemented, full verification stopped by user

`rg 'workspaceComposition|window.proAccess' TFM Frameworks` found 15 gates, window commerce dependency and launch grant.
Remove gates/sticky state, align app/site/StoreKit/docs. Estimate −35–45 production lines plus strings; actual −34/two
entries. All 28 composition cases/seven non-Pro states, six remaining Pro gates and entitlement checks passed, plus
format/localization/site build/diff. English/zh-Hans/zh-Hant desktop/mobile home/FAQ and legacy Chinese redirects reviewed.
User stopped full macOS/iOS tests; before stopping, Mac AgentBackgroundCommand/AgentApprovalQueue/SpeechWaveform failed,
without investigation/rerun. No green full-suite claim; App Store Connect metadata remains a release step.

## Desktop authentication submission, 2026-09-19 — implemented, full verification pending

`rg 'continueAuthentication|submittedPassword|let existing = store.identity|passwordUpdate'` in desktop SSH/SFTP models
confirmed duplicated fallback/submission/selected Identity updates/custom reuse/Host association. Share two methods
on existing Application `RemoteSessionHostStore`; sessions retain username validation/passphrase continuation/prompts/
errors/ephemeral SFTP secrets/transient SSH Hosts/reconnect ordering. Preserve separate Identity-before-Host writes and
secret usage; mobile/Metrics/forwarding keep different save rules. Estimate −40–80, actual −47 production lines; no
new model/base/dependency/schema/secret store or localization change. Architecture updated, boundary rules unchanged;
existing catalog edit stays outside scope.

Focused 83 functions/105 cases passed: shared policy/desktop entry points, credential usage/preparation/Identity,
Journey/SFTP/window lifetimes/architecture. Initial fixture `Host` ambiguity was fixed with explicit Domain import.
Formatting/localization/diff passed; full pinned macOS/iOS pending. Evidence:
`/tmp/termind-auth-refactor.uUFmoB/focused-macos-2.xcresult` with logs/summary/line counts/dependency/catalog fingerprints.

## Mobile toolbar policy, 2026-09-19 — implementing

`rg 'tabBarPlacement|mobileToolbarLayout' TFI` found feature-local Assistant/Metrics fallbacks despite shared stack
environment; production already has no idiom/model layout branches. Remove both reads and consume one shared toolbar
policy, retaining container geometry/active reserved regions/native identity/OS API checks. Estimate −2 production
lines/two duplicate conditions. Native title/menu transitions and fold/session lifetime verification remain pending.

## Batch Startup confirmation, 2026-09-19 — implemented, verification pending

`rg 'showsWorkspaceChoice|workspaceConfirmLabel|workspaceHelp|openChecked' TFM TFMTests` confirmed one chooser-only
secondary action and layout parameter. Keep Connect/Return as the single confirmation, explicitly opening one new
Workspace for one or more selected SSH/SFTP Hosts. Remove the redundant button/policy/help and three unused localized
entries; retain shared BatchLayout for Host context menus. Estimate −45–60 chooser lines; actual −53 including stable
accessibility identifiers for behavioral UI coverage. Focus/menu changes are tracked by the same regression run.

## Port Forwarding refactor, 2026-09-19 — completed

`rg` plus Periphery on TFM/TFI confirmed the removable surface. Removed the unused forwarding-library route wrapper
and configuration-only session overload, made the direction picker private, and replaced the stateful editor policy
with static normalization/start validation that retains rule-ID, Host-ID, saved validity and runtime checks. Shared
the otherwise identical Port Forwarding/Known Hosts deletion, pruning and error presentation through one typed
managed-card modifier; feature state and transactions remain local. Actual change: −35 production and −73 test lines.

Controller bookkeeping consolidation was rejected: one record would have to encode active generation, stopped-but-
serializing work and failed-but-presented Journey state, plus an identity token to safely retire completed tasks after
rapid stop/start. The concrete shape adds lifecycle state without reducing code, so the existing dictionaries remain.

Focused 53 tests passed: Framework forwarding/editor/Known Host presentation, desktop forwarding/editor/Journey/
selection, and mobile forwarding/Vault lifecycle. TFM and TFI pinned builds passed. The ordinary TFM test build is
currently blocked by unrelated concurrent `ColorSystemTests` and `BroadcastInputTests` API edits; the 29 desktop tests
passed when only those two files were excluded. Formatting, localization and diff checks passed. Retained boundaries:
forwarding/jump pumps, frozen schemas, forwarding authentication/Journey ownership and platform-native card renderers.
