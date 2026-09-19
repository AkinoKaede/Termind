# Termind Refactoring Backlog

English-only completed-work index. All entries below are closed per owner confirmation, including formerly stale
implementation/verification statuses. This consolidation does not claim new test runs or retroactive full-suite passes;
detailed evidence and execution logs remain in Git history. Current invariants live in [ARCHITECTURE.md](ARCHITECTURE.md).

For new work: confirm references with `rg`, record evidence/action/net production estimate, implement one independent
change, run risk-appropriate checks, then append status/verification. Retain completed entries; count tests separately
and label structural changes without a reduction claim. Preserve frozen schemas, native lifetimes and platform adapters.

## Completed items

### 2026-08-30 to 2026-09-04 — original IDs

1. **Legacy transcript:** removed unreachable SwiftUI trees; retained live timestamp/risk components.
2. **List hosting:** shared `HostingListRow`/`HostingListContent`; retained list-specific lifecycles.
3. **SSH initializers:** consolidated private initialization, preserving temporary Hosts.
4. **Terminal appearance:** SSH/Serial share `TerminalViewState.applyAppearance`.
5. **SFTP overloads:** removed four redundant `TransferLibraryModel` forwarders.
6. **Jump Host builder:** reused `sshJumpConfigurations`, retaining validation/errors.
7. **Connection interaction:** shared trust/progress/prompt/reconnect policy; transport teardown remains local.
8. **Text collectors:** shared streamed text/tool rejection for commands, titles and compaction.
9. **Provider authorization:** shared auth/ephemeral sessions; preserved Vertex/empty-secret rules.
10. **SwiftData transactions:** shared narrow commit helper; retained two-stage history writes.
11. **libssh2 continuations:** shared Exec/SFTP serial-worker bridges.
12. **Transcript helpers:** removed dead streaming/edit-binding/activity helpers.
13. **Composer access:** callers use `conversation.composer`; attachment hooks retained.
14. **Toolbar search:** removed unreachable menu/delegate/find plumbing; query/keyboard behavior retained.
15. **Agent SSH prompts:** one typed authentication request supplies Journey/passphrase projections.
16. **Atomic SFTP writes:** shared temp/cleanup/rename/progress, keeping source loops distinct.
17. **Transfer conflicts:** shared Keep Both/directory/file policy, retaining distinct jobs.
18. **Client leases:** shared acquisition/conditional disconnect, retaining reservation state.
19. **Legacy tool metadata:** one compatibility table with generic MCP fallback.
20. **Presentation actions:** removed unused automatic-message/action-kind duplication.
21. **Tool inputs:** shared object/array unpacking, keeping field presenters local.
22. **Idle sweepers:** shared `AgentIdleSweeper`; callers own registries/emptiness.
23. **Sidebar headers:** shared count/collapse header.
24. **Host deletion:** groups use repository/outbox saga, not direct snapshot deletion.
25. **Unused declarations:** removed reference-confirmed preflight/settings/metrics/reconnect/SSH wrappers/constants.
26. **Settings pages:** reused `SettingsFormPage`, deleted duplicate page.
27. **Cursor lists:** shared fixed-height chooser adapter; specialized rows excluded.
28. **Agent authentication:** shared typed Exec/SFTP authenticated-open retry loop.
29. **Transcript confirmation:** shared native-row risk color/destructive confirmation.
30. **Glass shapes:** shared private shape modifier, unchanged public behavior.
31. **Vault envelopes:** shared record indexing; versions/merge rules remain caller-owned.
32. **Remote preflight:** shared directory order/descendant skip/target lookup; jobs remain distinct.
33. **Vertex selection:** shared endpoint/credential selection, subsequently adapted to API formats.
34. **Dead fields:** removed unused onboarding/Agent/color/trial/runtime fields; retained JSON provenance.
35. **Run presentation:** derive state from reported runs/outstanding queues.
36. **Copy-only tests:** removed 20 tests/literals; retained behavioral/persistence/language/protocol coverage.
37. **Provider HTTP:** shared transport/status validation; requests/parsing remain local.
38. **Finder drop wrapper:** removed unconstructed wrapper, retained general target/test injection.
39. **Context Chip recovery:** shared payload boundaries/fallback filenames for live/restored attachments.
40. **Save/rollback:** reused save/commit helpers without changing transaction boundaries.
41. **Overlay chrome:** shared transient surface; content/transitions remain local.
42. **SSH form chrome:** shared styling, not form behavior.
43. **Snippet content:** shared card/drag-ghost content, separate interaction/chrome.
44. **SFTP reads:** shared remote read-handle lifetime; loops/destinations remain distinct.
45. **Chooser selection:** shared all-checked/toggle-all for equal eligibility sets only.
46. **AgentKit extraction:** moved portable runtime behind host/interaction/prompt/presentation seams.
47. **Workspace commands:** removed AppKit-shadowed commands; split shortcuts avoid system keys.
48. **Provider addressing:** one URL plus `ModelAPIFormat`; migrated safely with AgentKit 0.4.0/0.5.0.

### 2026-09-09 to 2026-09-14

- **09-09 StoreKit trials:** replaced local HMAC/Keychain/CloudKit trial with transaction watermark (−121 production lines).
- **09-09 Show Recents:** removed unread setting/UI/labels; retained Sidebar accessibility localization.
- **09-11 Test cleanup:** removed five redundant tests/literal snapshots (−77 test lines), retaining behavior.
- **09-11 Screenshot window:** production WindowGroup replaces demo-only window; demo restoration stays off.
- **09-11 SFTP permissions:** shared Domain draft/Presentation grid.
- **09-11 Persistence/sync:** moved CloudKit/settings/journals/terminal/history to frameworks; desktop adapters retained.
- **09-11 Metrics/Journey:** shared Application state/Presentation content; native keyboard/logs retained.
- **09-11 Skills/settings:** shared library/importer/role form, retaining native editors.
- **09-12 Assistant:** shared runtime/tools/attachments/speech/conversation/list behavior.
- **09-12 Aliases:** removed 86 files, 224 app and 20 Persistence aliases; retained six responsibility-named adapters.
- **09-12 Mobile layers:** separated TFI layers/shared connection construction; later adaptive navigation supersedes idiom policy.
- **09-12 Command generation:** shared draft/coordinator/timeout/cancellation/protocol constants.
- **09-12 SFTP boundary:** Domain `RemoteFile`, Application `RemoteFileSystem`/mobile session model; structural, not a reduction.
- **09-12 Connection recovery:** mobile adopts shared trust/progress/temporary-key preparation.
- **09-12 Terminal Find:** shared controller; platform binding closures retained.
- **09-12 Linux detection:** one Domain classifier distinguishes unavailable/conclusive results.
- **09-12 Journey content:** shared header/status; native logs/failures/backgrounds/keyboard retained (−98 production lines).
- **09-12 Terminal themes:** Presentation owns Ghostty conversion; desktop preference storage retained.
- **09-12 Terminal uploads:** shared readiness/notices; execution remains platform-specific.
- **09-12 Known Hosts:** shared hashed/endpoint titles; native cards retained.
- **09-12 Native lists:** removed eight Mac adapters/eleven mounts (−611 lines); retained justified UIKit uses.
- **09-12 Transcript:** shared tools/results/disclosures/timestamps/Markdown; native renderers/viewport lifetimes retained.
- **09-12 Dead code:** removed Periphery-confirmed imports/files/declarations (−150 production lines); dynamic entries retained.
- **09-12 Test boundaries:** removed concrete renderer/list-type assertions; retained behavior/identity/reuse/interaction coverage.
- **09-13 Localizations:** removed 81 compiler-confirmed unused entries, stale metadata and three obsolete expectations.
- **09-13 Slash commands:** shared `ChatSlashCommandRegistry` with explicit platform actions.
- **09-13 Feature registry:** one app-injected mobile tab/sidebar/destination registry.
- **09-13 Value policies:** shared tree/route/deletion/display/Snippet/model/SFTP-drag/service policy, not native lifetimes.
- **09-13 Annual offers:** StoreKit metadata replaces new standalone trials; legacy entitlement removed next.
- **09-13 Tests:** removed source/Keychain/status/permission/history duplication; shared contracts moved to FrameworkTests (−1,303 lines).
- **09-14 Legacy trial:** removed remaining standalone-trial product/domain/clock/UI/tests/copy; lifetime and annual trials retained.

### 2026-09-16 to 2026-09-17 — planners, tests and skills

- **Desktop download planner:** adopted shared traversal/conflicts/scoped destinations/enqueueing, including directory-only trees;
  desktop pending/error/lifetime ownership retained (−167 production lines).
- **Desktop copy planner:** adopted shared preparation/conflicts/enqueueing/mutation counts; preserved recursive deletion/cancellation/
  refresh. Removed duplicate literal assertions while adding conflict regressions (−193 production, −59 old test lines).
- **UI/source assertions:** removed 52 declarations/1,230 lines; source checks narrowed 43→9 ownership/dependency guards with fail-closed
  roots/native-list allowlist. Behavioral/language/protocol/screenshot coverage retained.
- **SFTP status labels:** shared direction-specific running/completed presentation, generic other states (−8 production lines).
- **Forwarding adapter:** desktop uses shared editor policy directly, preserving saved/runtime/intent locks (−27 production lines).
- **Five iOS tests:** aligned no-model send failures, stable `terminal_suggest` descriptors and indexed SSH import with production behavior;
  retained all identifiers/no skips. Recorded verification: three independent focused actions, TFI 433/433 and TFM 1,399/1,399.
- **Skill loader:** `skill_read_file` replaces executable `load_skill`; historical replay/presenter retained. Package management is additive.
- **Skill starters:** replaced seeded runbooks/Reset with immutable runtime helpers; existing starters remain ordinary user records;
  conflict repair/atomic install/sync retained. Published AgentKit 0.13.0; no overall reduction claim.

### 2026-09-17 to 2026-09-19 — reuse scan IDs

Scan covered 516 production Swift files and framework imports; no prohibited edge found at discovery. File size alone
never justifies extraction. Keep schemas, native lists/terminal teardown and local `RuntimeVersions` adapters separate.

- **R1 — CloudKit record coding:** shared secure fields, payload/hash/asset mechanics and namespaces; coordinators retain metadata,
  validation/quarantine/legacy Guardian handling, 700,000-byte threshold and independent cleanup/lifetimes (−40 production lines).
- **R2 — Upload/copy conflicts:** shared resolver; upload retains strict-descendant versus copy's self-or-descendant policy and gains
  cancellation/recursive-name/path validation. Jobs/UI/accounting/errors remain separate (−139 production lines).
- **R3 — Pro offers:** value-only projection of StoreKit values/eligibility/plan; native layouts/actions/localization injection and
  History formatting remain separate (−32 production lines). R1–R3 total: −211 production lines, excluding tests/docs.
- **R4 — Architecture guards:** structural guard work closed per owner confirmation; retain fail-closed roots, dependency/ownership
  checks and native-list allowlist, not UI/copy/layout snapshots. No production-reduction or fresh verification claim.
- **R5 — CloudKit lifecycle:** one typed `CloudSyncLifecycle` instance/category with injected transport; zones/accounts/journals/engines/
  merge/acknowledgements remain independent. Secret upload needs current-engine fetch; pause/retirement revokes authorization.
- **R6 — MCP ticket policy:** shared metadata/expiry/retention/limits, not directional state machines. Preserve four slots, ten-minute
  capabilities, 64 unfinished and 256 terminal records/direction, thirty-minute retention, cleanup-held slots and Range-after-success.

### 2026-09-18 to 2026-09-19 — windows, mobile and authentication

- **Width-based mobile layouts:** removed idiom environment/duplicate root; subsequent stable adaptive tabs replace shell reconstruction.
- **Window registration:** apply native full-size content style before registration; removed extra bridge (−25 production lines).
  Normal/fullscreen/restored sizing remains window-owned.
- **Metrics clocks/knowledge cards:** tests await sampling/maintenance readiness; compact details use natural height within scaled caps.
  Production Metrics unchanged; short/long expansion and native width behavior retained.
- **Adaptive navigation:** one sidebar-adaptable TabView/five stable stacks replaces root reconstruction/reset/save gates; preserve drafts,
  search/scroll/window independence and live session instances (−210 production lines).
- **Close/quit confirmations:** rejected removal, restored both dialogs/strings. The final change clears only `isDocumentEdited` decoration;
  dismissal delegate, Workspace confirmation and SFTP unsaved-edit checks remain. Visual correction, not a reduction claim.
- **Free Workspace composition:** removed 15 gates/window commerce/sticky grant state; aligned app/site/StoreKit copy (−34 production lines,
  two strings). Sync/other Pro gates remain; App Store Connect metadata is still a separate release operation.
- **Desktop authentication:** shared submission/Identity reuse on `RemoteSessionHostStore`; preserve Identity-before-Host writes, explicit
  secrets, validation, temporary Hosts and native retry/prompt lifetimes (−47 production lines).
- **Mobile toolbar:** removed Assistant/Metrics fallback reads; one shared policy retains geometry/reserved regions/native identity/OS checks.
- **Batch Startup:** Connect/Return is the sole confirmation, creating one new Workspace for selected SSH/SFTP Hosts; removed secondary
  button/policy/help/three strings (−53 chooser lines). Host-context-menu BatchLayout remains.
- **Port Forwarding:** removed unused wrappers/overload, narrowed picker/editor policy and shared typed managed-card deletion/error chrome
  with Known Hosts (−35 production, −73 test lines). Kept generation/task/Journey dictionaries: merging adds state without reduction.
  Forwarding pumps/authentication, frozen schemas, feature transactions and native cards remain separate.

### 2026-09-19 — unified SSH/SFTP channel scheduling (complete)

- **Evidence:** `SSHExecSession`, `SFTPClient`, `SSHSessionActor`, `SSHRoutedSocket` and `SSHForwardingSession` each own a
  libssh2 session/queue/pump. Agent pooling separates exec/SFTP and `sftp_copy` adds two dedicated connections; user
  transfers fall back from an additional connection to serialized use of the browser client. These owners duplicate
  connection teardown/keepalive/EAGAIN rules and prevent same-transport Channel concurrency outside forwarding.
- **Action:** extract one authenticated transport/Channel owner and two topology policies: Channel-only and
  connection-preferred with Channel fallback. Agent SSH uses Channel-only; Agent SFTP (including `sftp_copy`) and user
  transfers use connection-preferred; Port Forwarding uses Channel-only. Single-Channel consumers reuse the transport
  core without entering the scheduler. Feature domains retain independent authentication/recovery/lifetimes.
- **Expected reduction:** remove the dedicated Agent-copy lease path and duplicated exec/SFTP/PTY/forwarding pump and
  teardown code. Record the measured production-line change and focused/full verification only after the migration is
  complete; no reduction or performance claim is made while this item is in progress.
- **Result:** added explicit Channel-only/connection-preferred policies, multiplexed Agent exec, pooled Agent SFTP
  (including copy and MCP streams), sibling-Channel fallback, lease-based limits and a single-Channel Adapter for Metrics/
  user SSH. Removed the old exec worker, dedicated-copy leases, whole-session background handoff and blocking key export.
  This capability is additive: tracked production changed +987/−931 lines and three new core files add 628 lines, net
  +684; no reduction claim.
- **Verification:** TFM and generic iOS Simulator builds passed; 99 scheduling/auth/forwarding focused tests, 53 SFTP/
  PTY/key tests, 13 pool/Adapter tests and the 20-test AgentRuntime suite passed. Chinese localization and changed-file
  strict format checks passed. The full macOS run reached 1,446 TFM and 363 Framework tests but retained the unrelated,
  reproducible `LaunchFileLogServiceTests.loggerDropsUnapprovedSensitiveValues` failure; one concurrent AgentRuntime
  cancellation failure passed immediately when its 20-test suite was rerun. Recursive format also retains the unrelated
  existing `LoggingFilesSettings.swift:110` finding.

### 2026-09-19 — fair SFTP admission and selectable topology (complete)

- **Evidence:** the app transfer coordinator admitted the first eligible queued row, so one Workspace could fill every
  Host slot, while Agent SFTP leases bypassed the 15/5 limits entirely. User and Agent pools also fixed their topology
  at connection-preferred even when a small transfer would not repay another SSH handshake. Internal SFTP drag providers
  advertised both a private remote payload and a Finder file promise; reading both representations could start a redundant
  download beside the direct remote copy.
- **Action:** add one process scheduler shared by Workspace/terminal/edit and Agent data work, rotating Hosts and then stable
  Workspace/Agent-run/batch sources. Resolve Smart (64 MB decimal), Channels Only and Connections Preferred only after admission;
  retain feature-owned connection lifetimes and connection-to-Channel fallback. Extend the existing synced SFTP preference
  record compatibly and consume the private drag payload without materializing its local-file promise.
- **Result:** new/missing settings default to Smart and 30/10 while saved values remain unchanged. Logical file operations
  consume identical capacity whether backed by a Channel or connection; cross-Host copy counts once globally and once per
  endpoint. Agent control operations remain outside data capacity, `sftp_copy` uses one composite permit, and in-app remote
  copy exposes one `.copy` row per regular file without local staging. This is additive scheduling work, not a reduction claim.
- **Verification:** macOS and generic iOS Simulator builds passed. Focused suites passed for scheduler/session topology,
  settings persistence/sync, Agent authentication/MCP, Agent/Workspace copy and native drag payload selection. Chinese
  localization and diff checks passed; final full-suite/format status is recorded in the task handoff.

### 2026-09-19 — shared Agent SSH/SFTP primary transport (complete)

- **Evidence:** Agent exec and the primary Agent SFTP client still used separate authenticated transports even though the
  non-blocking connection owner could host both Channel types. A first exec followed by SFTP therefore performed two handshakes,
  while connection-preferred SFTP concurrency correctly needed its independent auxiliary transports.
- **Action:** rename the exec-only session abstraction to `SSHMultiplexedSession`, expose SFTP Channel creation on it, and key the
  Agent pool's primary entry/in-flight open by Host only. Keep SFTP admission, Smart thresholds, auxiliary connections and silent
  Channel fallback unchanged.
- **Result:** exec and primary SFTP now share one authentication and physical connection in either call order. A reusable full
  non-blocking SFTP Channel client serves PTY and Agent owners; only scheduler-selected auxiliary SFTP work opens more transports.
  Host retirement, route changes and fatal primary failures close the shared lifetime atomically, without replaying operations.
- **Verification:** focused pool/authentication/copy tests and macOS build passed during implementation; final cross-platform,
  localization and format status is recorded in the task handoff.

### 2026-09-20 — one SFTP Channel implementation (complete)

- **Evidence:** the standalone `SFTPWorker` and multiplexed `SSHSharedSFTPClient` separately implemented directory, atomic write,
  resume, edit, streaming and copy semantics, while the Agent and terminal workers duplicated SFTP Channel ownership and EAGAIN
  loops. The new type name also described reuse (`Shared`) rather than responsibility.
- **Action:** keep `SFTPClient` as the public connection facade and `SSHMultiplexedSession` owner, move all file operations to
  `SFTPChannel`, and share `SSHMultiplexedSFTPChannelOwner` across standalone, Agent and terminal transports. Rename
  Agent pool APIs from exec-only terms to `session`, `connection` and `sftpClient`.
- **Result:** removed the second SFTP operation engine and both feature-local Channel owners. One implementation now preserves
  atomic rename, partial-file verification, edit permissions/version capture, streamed download validation and same-transport copy
  for every entry point. Tracked production plus the two new files changed +1,523/−2,695 lines (net −1,172).
- **Verification:** macOS and iOS builds, 87 focused pool/auth/edit/resume/rename/copy tests, 14 opt-in loopback SSH/SFTP wire
  tests and all 363 Framework tests passed. The 1,465-test TFM run retained two unrelated concurrent timing failures in
  `AgentRuntimeTests`/`MCPUploadTests`; both passed together on immediate focused rerun. Changed-file strict formatting and Chinese
  localization checks passed; recursive formatting retains the pre-existing `LoggingFilesSettings.swift:110` finding.
