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

- **Change:** consolidated five libssh2 session/queue/pump owners and duplicated teardown/keepalive/EAGAIN rules. Added
  Channel-only (Agent exec/forwarding), connection-preferred with sibling-Channel fallback (Agent/user SFTP, copy/MCP streams),
  lease limits and a single-Channel Metrics/user SSH Adapter outside scheduling. Feature auth/recovery/lifetimes stay separate.
  Removed exec worker, dedicated-copy leases, whole-session background handoff and blocking key export. Planned deduplication
  became additive capability: +987/−931 tracked production lines plus 628 in three new core files, net +684; no reduction claim.
- **Verification:** TFM/generic iOS Simulator builds; 99 scheduling/auth/forwarding, 53 SFTP/PTY/key, 13 pool/Adapter and
  20 AgentRuntime tests; Chinese localization and changed-file strict format passed. Full macOS: 1,446 TFM/363 Framework tests,
  with unrelated reproducible `LaunchFileLogServiceTests.loggerDropsUnapprovedSensitiveValues` failure. Concurrent AgentRuntime
  cancellation failure passed on immediate 20-test rerun. Recursive format retained `LoggingFilesSettings.swift:110`.

### 2026-09-19 — fair SFTP admission and selectable topology (complete)

- **Change:** replaced first-eligible Workspace admission and Agent bypass of 15/5 limits with one process data scheduler for
  Workspace/terminal/edit/Agent, rotating Hosts then stable Workspace/Agent-run/batch sources. Admission precedes Smart
  (64 MB decimal)/Channels Only/Connections Preferred selection; feature lifetimes and connection-to-Channel fallback remain.
  Compatible synced preferences default new/missing settings to Smart and 30/10; saved values stay unchanged. Logical operations
  cost the same for Channels/connections; cross-Host copy counts once globally/per endpoint, `sftp_copy` uses one composite permit,
  and Agent control work is exempt. Private remote drag payloads no longer materialize Finder promises/redundant downloads;
  remote copy has one `.copy` row/regular file, no local staging. Additive; no reduction claim.
- **Verification:** macOS/generic iOS Simulator builds; focused scheduler/topology, settings persistence/sync, Agent auth/MCP,
  Agent/Workspace copy and native drag-selection suites; Chinese localization and diff checks passed. Final full-suite/format
  status remains in the task handoff, not asserted here.

### 2026-09-19 — shared Agent SSH/SFTP primary transport (complete)

- **Change:** replaced separate exec/primary-SFTP handshakes with Host-keyed primary entries/in-flight opens on
  `SSHMultiplexedSession`, sharing one authentication/connection in either call order. A non-blocking SFTP Channel client serves
  PTY/Agent owners. Admission, Smart thresholds, scheduler-selected auxiliary connections and silent Channel fallback remain.
  Host retirement, route changes and fatal primary failures close the shared lifetime atomically; no operation replay.
- **Verification:** focused pool/auth/copy tests and macOS build passed. Final cross-platform/localization/format status remains
  in the task handoff, not asserted here.

### 2026-09-20 — one SFTP Channel implementation (complete)

- **Change:** replaced `SFTPWorker`/`SSHSharedSFTPClient` operation engines and Agent/terminal Channel/EAGAIN owners with
  `SFTPChannel` and `SSHMultiplexedSFTPChannelOwner` for standalone/Agent/terminal use. `SFTPClient` stays the connection facade/
  `SSHMultiplexedSession` owner; pool APIs become `session`, `connection`, `sftpClient`. Preserved directory/resume, atomic rename,
  partial-file checks, edit permissions/version capture, streamed download validation and same-transport copy.
  Production including two new files: +1,523/−2,695 lines, net −1,172.
- **Verification:** macOS/iOS builds, 87 focused pool/auth/edit/resume/rename/copy, 14 opt-in loopback wire and 363 Framework tests
  passed. The 1,465-test TFM run had two unrelated concurrent `AgentRuntimeTests`/`MCPUploadTests` timing failures; both passed
  together on immediate focused rerun. Changed-file strict format/Chinese localization passed; recursive format retained
  `LoggingFilesSettings.swift:110`.

### 2026-09-20 — explicit SSH connection and Channel vocabulary (complete)

- **Change:** disambiguated `SSHMultiplexedSession`/pool `session`/transport terminology: transport means routed bytes;
  `SSHAuthenticatedConnection` owns that stream and libssh2 connection state (`LIBSSH2_SESSION`); `SSHConnection` exposes
  multiplexing. PTY/exec/SFTP/forwarding Channels align with `LIBSSH2_CHANNEL`; the SFTP opening facade is separate from
  `SFTPChannelProtocol`. Pool/retry/auth/budget/topology APIs and filenames follow these boundaries.
  `SFTPConcurrencyStrategy.channelsOnly` keeps `"channels_only"`; no synced-settings migration.
- **Verification:** TFM/generic iOS Simulator builds, 66 focused connection/Channel/SFTP tests, changed-file strict format and
  Chinese localization passed.

### 2026-09-20 — one-shot SSH secret ownership and connection attempts (complete)

- **Change:** replaced copy-on-write `Data`/NUL uncleared-allocation risks and temporary plaintext attempt dictionaries with
  one owned `SSHSecret` allocation before each attempt. `SecretMemory` clears source Data/proxy frames/one-shot allocations;
  attempt copies share invalidating owners, retries retain only selection/reentry metadata. Centralized five owners' reentry
  routing, removed session-host plaintext reads, narrowed connection-time resolution, used existence-only Keychain queries and
  rejected malformed legacy private-Key envelopes. Multi-Key export keeps references until work, then authenticates once/Host
  with sequential exec Channels instead of eagerly resolving secrets/reusing one-shot configs. Safety work; no reduction claim.
- **Verification:** macOS/generic iOS Simulator builds, 53 focused auth/Agent/authorized-Key and 381 Framework tests passed.
  Default macOS: 1,792 passed, 64 opt-in skips, no failures. Changed-file strict format, diff and Chinese localization passed.

### 2026-09-21 — low-value test scan

- **Change:** deleted the byte-identical iOS `ProviderHTTPIntegrationTests.swift` (AgentKit/TermindApplication only, no platform
  adapter), retaining macOS smoke coverage. Removed `memoryFollowsMCPInAISettings` enum-order and
  `connectionsCategoryUsesTheConnectSymbol` switch-literal snapshots: one file/two tests, −40 test lines. No production changes;
  escaping/persistence/migration/secret/runtime-linkage/behavior coverage retained.
- **Verification:** focused macOS: two passed, opt-in rendering skipped; iOS: 23 passed. Changed-Swift strict format,
  duplicate-file scan, diff and Chinese localization passed.

### 2026-09-21 — shared Host Custom Identity editing (complete)

- **Change:** replaced `HostEditorView`/`MobileHostEditor` Custom SSH/Proxy Identity loading/editability/validation/save helpers
  with Application-owned, memory-only `HostCustomIdentityDraft`; no plaintext persistence/descriptions. Preserved native
  controls/routes/navigation, Identity-before-Host saves and metadata edits with unavailable proxy passwords. Expanded deletion
  coverage from one projected SSH Identity to both purposes/passwords, `ownerHostID` isolation/unrelated retention, Keychain
  failures, app/outbox entry points and selective SwiftData finalization; removed misleading `legacy` envelope-test prefix.
  Production +204/−220 lines, net −16; no schema/localization changes.
- **Verification:** macOS Identity/draft/outbox/envelope suites, 25 mobile Vault tests and TFM/generic iOS Simulator builds passed.
  Default macOS: 1,831 passed, 64 opt-in skips, two unrelated concurrent Agent timing failures; both complete Agent suites passed
  on immediate rerun (35/35). Recursive strict format, diff and Chinese localization passed.

### 2026-09-21 — shared desktop terminal surface (complete)

- **Change:** consolidated `SSHSessionModel`/`TelnetSessionModel`/`SerialSessionModel` Ghostty backend, `TerminalViewState`,
  resize/native-view construction and neutral focus/find/failure/appearance/error presentation under TFM-owned
  `PersistentTerminalViewOwner` and shared desktop chrome. Telnet/Serial share simple Journey/focus/font lifecycle; SSH retains
  auth/Shell Integration/SFTP uploads/overlays, Telnet IAC/NVT/NAWS and Serial charset/input/local echo stay local. Model/native
  terminal/connection lifetimes remain separate. Estimated −40–80 production lines; actual +285/−296 including new file, net −11.
- **Verification:** TFM build, Chinese localization and changed-file strict format passed; 44-test focused run: no failures,
  two opt-in window skips. Default macOS: 1,858 passed, 65 opt-in skips, three unrelated Agent failures. Two timing failures passed
  on immediate 41-test rerun; deterministic `list_hosts` summary expectation remained. Recursive format retained
  `PortForwardingView.swift:197`.
