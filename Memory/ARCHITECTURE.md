# Termind architecture

Current ownership and safety contracts; implementation details belong in code/tests, completed-work evidence in
[REFACTOR.md](REFACTOR.md). Read before changing dependencies, lifetimes, persistence, execution or secrets.

## Modules and persistence

One Xcode project builds TFM (macOS), TFI (iOS/iPadOS), separate test targets and the macOS-only `termind-mcp` bridge.
AgentKit is a separately versioned remote package; its sibling working tree is not the app dependency. Follow
`AGENTS.md` for package releases and pinned builds.

| Owner | Responsibilities / dependencies |
| --- | --- |
| TermindDomain | Portable values/rules; Foundation, CryptoKit, AgentKit values; no UI/concrete I/O. |
| TermindApplication | Ports, feature models, connection/import policy, remote-file-system and sync/outbox use cases; Domain, AgentKit. |
| TermindInfrastructure | In-memory repositories, metrics parsing, StoreKit, Vault/Settings/Metrics CloudKit; Application, Domain, Persistence. |
| TermindRemoteInfrastructure | SSH/SFTP, Keychain, keys, sampling, forwarding, transfers, scoped imports; Infrastructure, Application, Domain. C libraries stay outside portable framework tests. |
| TermindPresentation | Reusable SwiftUI policy/content, Ghostty themes, `TerminalPreferences` bridge; Application and Domain only. |
| TermindPersistence | All SwiftData models, frozen V1–V22 schemas, migrations and container construction; no app dependency. |
| TFM / TFI | Native UI/adapters/lifetimes; shared modules never import apps. |

- Use direct owner imports/public APIs, not re-exports, forwarding aliases, `Shared` types or a generic Core module.
  Shared resources enter both app bundles; icons, metadata and signing remain platform-owned.
- Moves preserve entity identity, fields, defaults and historical semantics. Original-module V1/V14 fixtures guard
  migration. `makeContainer` fixes the complete schema/plan; one container per process serves all scenes. Never
  recreate a failed store silently. macOS retains its `Termind` location; mobile uses Application Support/in-memory
  tests. Both apps share the CloudKit container and bundle-derived Keychain access group.
- Architecture tests fail closed on absent/empty production roots. Source checks guard dependencies, native-list
  allowlists, AgentKit/SwiftData ownership only; UI/copy/wiring need behavioral or visual coverage.

## State, navigation and editing

### Saved values

- Single-line presentation normalizes newlines only on edits; paste adapters act before native controls flatten
  breaks and rename editors preserve marked text. Reads, multiline content, secrets and validation stay unchanged;
  no bulk cleanup/migration.
- Domain optional-name defaults serve hints and saves: Host address, Identity username, key algorithm, Host plus SSH
  argument, provider protocol or model ID. Missing sources yield empty hints. Nonempty names remain stored; clearing
  requests a fresh default. Legacy blanks materialize on the next local save in its existing transaction.
- Desktop autosave uses page-owned buffers; reopening shows saved values. Mobile provider drafts merge raw names
  before defaulting at Save: explicit clearing conflicts with a concurrent rename, unlike legacy blank-to-default.

### Windows and sessions

- App-wide snapshots/preferences and `VaultStore` transactions feed narrow feature intents; sessions receive only
  `RemoteSessionHostStore`. Each scene owns a `WindowModel`, shell/navigation/search/context panels. Process routing
  is UUID-scoped with weak native windows. Paywalls stay pinned to one window; speech belongs to one composer.
- New desktop windows start at Welcome; Dock reopen preserves destination and Metrics entry selects Metrics. Dock
  New Window uses the registered factory and activates hidden/windowless apps. Restoration never reconnects live
  Workspaces. New windows snapshot ordinary content size once, after full-size content styling; fullscreen/auxiliary
  windows cannot replace device-local last size. System-restored frames/positions win; tests use in-memory sizing.
- Quick Open claims focus only after mounting in its active window; close retires requests. It releases toolbar Find
  and suspends terminal autofocus. Batch Startup opens selected SSH/SFTP Hosts as panes in one new Workspace.
- Command-W closes the focused pane, removing empty Workspaces but retaining the window; otherwise dismisses natively.
  All window-close paths confirm if that window owns any Workspaces, even hidden/disconnected. Shift-Command-W requests
  window dismissal. Clearing document-edited decoration must not change confirmation/delegate behavior.
- Moving a Workspace between registered windows preserves surfaces/transports/splits/state, without close history;
  out-of-window drags create no window. Native close disconnects only owned sessions and cancels pending moves;
  independent transfers/services survive. Mounting never repeats authentication; explicit retry/reopen may.
- Desktop Vault/Assistant, Metrics, dynamic Workspaces and Settings routes are window-local. Settings data is app-wide;
  closing it restores the replaced destination. Width changes may adapt panels, never routes/editor identity/session
  composition/monitor ownership; covered panels retain last size, native table identity, sorting and scroll.
- `AssistantLibraryModel` owns standalone conversations, not panes. Workspaces own SSH/SFTP/serial panes and session
  conversations; sessions own transports/terminal/browser state. Ordering/pinning commits metadata before publication
  and preserves instances during runs/approvals/compaction. Archive/delete keep run guards; archived chats cannot move.
- Connection/authentication/forwarding state is memory-only, excluded from domain records, sync and UserDefaults.
  Serial is local/temporary, never persisted or an Agent host. Vault-synced Workspace templates contain named
  SSH/SFTP/empty split trees/fractions; only TFM materializes them, preserving empty panes for missing Hosts.

### Trust, imports and local preferences

- Known Hosts is independent of Host records: editing/deleting a Host never changes trust. Plain and OpenSSH `|1|`
  hashed endpoints share matching; hashed records retain wire hostname and ignore the separate port.
- SSH import previews are window-owned indexed public metadata. Host selection never selects credentials; imported
  identities require selected keys. The actor retains scoped descriptors/digests, not private-key text/passphrases;
  reread selected keys at unlock/commit and fail closed if changed. Picking/drop share validation; config parsing
  executes nothing. Create credentials before one Vault save, clean up failure, never overwrite records/clear mismatch.
- macOS appearance/language are local; System appearance clears `NSApplication.appearance`. Login launch reads
  `SMAppService`, not mirrored preferences; quiet launch hides the app without suppressing its window. Mobile uses
  Apple's per-app language settings without an injected locale override.
- Debug visibility/logging are device-local/default-off for saving. Inject SwiftLog `Logger`; no process-global
  bootstrap. Infrastructure owns one locked writer/file per launch: disable closes but preserves, re-enable resumes,
  deletion recreates only when enabled. No retention policy or in-app viewer. Debug stderr uses the same sanitization.
  Log stable English codes/non-sensitive metadata, never credentials, prompts, identities/paths, remote output, process
  names or raw errors. Metrics always logs received byte size; capped incomplete/oversized diagnostics redact addresses.

## Remote sessions, terminals and files

### Connection and authentication

- SSH/SFTP/mobile Workspaces/Metrics share preparation/recovery policy. Host-key approval occurs inside the actual
  socket/libssh2 handshake-to-auth attempt, never a discovery connection. Generations reject retired callbacks,
  credential results and timers.
- Desktop SSH/SFTP submission uses `RemoteSessionHostStore`: explicit password wins; custom input never borrows an
  unselected Identity password. Only explicit input changes selected credentials; custom input reuses the Host Identity.
  Identity/secret writes precede separate Host association. Keep temporary credentials, validation/passphrase ordering,
  transient Hosts and reconnect state session-owned.
- Keyboard-interactive uses the same opener for PTY/exec/SFTP/forwarding/key installation/jumps. C callbacks wait only
  on the transport queue for cancellable async responders showing literal server prompts/echo flags. Request IDs isolate
  rounds; answers are ephemeral, never autofilled/cached/logged/in Agent history. Empty answers are valid; zero prompts
  need no form. Waiting excludes network timeout; cancellation wakes the callback, cancels responder and interrupts open.
- User sessions own challenge queues; Agents use interaction queues. Desktop external auth separates app/MCP origins;
  stopping MCP preserves app requests. Mobile has no app auth sheet. Forwarding/Metrics own Journey challenges, never
  external-window fallback.
- Terminal drops/additional transfer connections forbid app password/passphrase/MFA/trust forms throughout the route,
  but permit system key authorization. Username-only/SSH `none` remain eligible: actual connection success, not saved
  credential presence, decides. Cancellation interrupts opening. A terminal drop always tries its independent SFTP
  preflight first; any non-cancellation connection failure, including interaction-required authentication, falls back to
  SFTP Channels on the already authenticated terminal transport without presenting a form.
- Username-only Identities try `none`, then advertised methods. Device-local `lastUsedAt` tracks successful saved-secret
  reads, not authentication. Batch route reads; missing/availability/edit reads do not count. First access per Identity/
  process writes directly without Vault journal/refresh; sync strips this field and preserves local values on apply.
- Welcome parses bounded SSH grammar without shell/OpenSSH config execution. Exact aliases supply metadata; overrides
  create session route snapshots, never replaced with saved endpoints. Routes cap at eight Hosts and reject cycles.
  Connect saves nothing. Explicit Save copies changed records/prerequisites in one Vault transaction, rolling back new
  passwords on failure; originals remain unchanged. Host-key decisions stay in the live handshake.

### Port Forwarding

- Independent Vault library/rules, outside Host drafts, with rollback-safe save/delete and saved names unaffected by Host
  rename. V20 freezes earlier entities and adds palette color. UI selection/editor transitions do not own connections or
  challenges. Start/retry is single-rule only; no bulk start. Only explicit actions create running intent.
- After a listener has run, transport loss silently recovers active rules on one shared Host connection: 1/2/5/10/30-second
  delays, reset after 60 stable seconds. Use in-memory authenticated configuration with refreshed durable trust; once-only
  trust/MFA answers never authorize reconnect. Forbid app forms but permit system key authorization across the route.
  Auth/trust/interaction failure ends recovery inline; explicit Retry alone opens Journey. Initial failures require Retry;
  listener failure is rule-local and old TCP streams never replay.
- Stop one rule without disturbing peers. Last stop cancels opens/prompts/retries and releases credential snapshots.
  Expiration/termination stop resources; Host/route edits and rule replacement stop affected runs. Generations reject stale
  opens/listeners; replacement awaits cleanup. Disconnect completes after source-cancellation descriptor closure. Local/
  SOCKS use SO_REUSEADDR for TIME_WAIT, never SO_REUSEPORT/live shared binds.
- One serial owner per libssh2 session across PTY, exec, SFTP, jump bridges and forwarding. Readiness, deduplicated FIFO and
  bounded fair passes replace bulk polling; Metrics and user SSH use `SSHSingleChannelAdapter` without a topology scheduler.
  Preserve immutable write buffers across EAGAIN, drain half-close, bound queues/DNS/connect deadlines and retain
  session-wide pending operations. Slice deadlines include callbacks/inner loops; protocol progress wakes peers.
- Public send/receive adapters accept complete encrypted packets and apply bounded backpressure outside library calls,
  avoiding pinned libssh2's lost forwarded-tcpip confirmation on EAGAIN. Teardown discards writes/returns EOF; descriptors
  close after cancellation handlers. See [performance](PORT_FORWARDING_PERFORMANCE.md) for budgets, rationale and measurement
  limits; buffers are per flow/session, never a global memory cap.

### Terminal behavior

- SSH worker owns PTY dimensions; retain latest valid authentication-time size/pixels. EAGAIN window-change packets keep
  original dimensions and finish before the newest request without blocking other I/O. Disconnect clears resize state;
  retired auth cannot install a PTY/clear replacement dimensions. Ghostty computes grid. Resize failure is diagnostic only.
- Application owns `TerminalCommandDraftController`, `CommandGenerationCoordinator` and `TerminalFindController`; apps
  provide context/validity/insertion. Generated commands are inserted, never submitted.
- Font family/size/follow-theme-size are device-local, outside `TerminalPreferences`, Settings journal and CloudKit. Seed
  missing local size from pre-upgrade local data before remote materialization; existing mirrors win. Ignore legacy remote
  font fields and omit outgoing fields. Themes/custom text (including authored fonts) still sync. Missing fonts fall back
  without deleting choice. Apply local overrides after theme/custom commands, resetting family lists; update surfaces in place.
- Desktop copy-completed-selection/right-click-paste default off and sync in the terminal record; mobile preserves without
  exposing/applying. Keep native surfaces. Copy only local completion; paste once on release through Ghostty clipboard/input
  capture. Remote mouse/Option-right-click stay Ghostty-owned; mouse reports never broadcast. Empty paste arms no capture;
  bracketed-paste classification spans chunks through terminator/ticket expiry.
- Host Shell Integration is Vault-synced Default/Enable/Disable (V22, older Hosts frozen). Each SSH attempt resolves destination
  override/global once before auth for bootstrap/History/generator/system info/directory actions. Live edits never inject or
  reconnect; new reconnects resolve again. Mobile integration/exit uses one ordered MainActor consumer retired on close/
  reconnect/expiration. Prompt markers are idempotent; Bash DEBUG excludes `__termind_*` helpers from History/busy state.
- History starts after authenticated start, retains optional remote status/duration (never receive-time inference), normalizes
  backslash continuation only and caps at 1,000 rows/Host. Both UIs show first line plus ellipsis.

### SFTP and external edits

- Domain owns `RemoteFile`, Application `RemoteFileSystem`/`MobileSFTPSessionModel`, Remote Infrastructure libssh2 protocols,
  Presentation symbols/kinds. Device-local History changes only after fresh successful listings/downloads, never stale/failed/
  cancelled/type-changed work.
- Generation-scoped `SFTPTransferSession` outlives panes. SFTP data work resolves one topology per admitted file: Channels Only
  opens sibling SFTP Channels, Connections Preferred silently probes the full route and falls back to siblings, and Smart uses
  Channels through 64 MB/64,000,000 bytes (including unknown sizes) before preferring connections. A failed silent probe degrades later work
  without replaying active operations; cancellation caches no failure. Browser control Channels stay independent. Terminal
  preflight donates a successful independent connection; only failed preflight uses the terminal's multiplexed PTY/SFTP
  libssh2 owner and fixes that generation to Channels. Closing the PTY does not retire transfers holding that transport.
  Durable trust refresh never promotes once-only trust.
- One process scheduler covers Workspace/terminal/edit transfers and Agent data operations. It defaults to 30 active files/ten
  per Host.ID (ranges 1–100 and 1–min(50, global)), rotating Hosts then Workspace/Agent-run/batch sources while retaining FIFO
  within a source. A Channel and an independent connection consume the same logical-file capacity. Cross-Host copy consumes one
  global slot and one slot on each endpoint Host. Browser and Agent metadata/control operations do not consume data slots.
  `SFTPSettingsModel` scheduling outlives Settings; new limits/topology affect queued work only. Pane close releases only its
  ownership; queued work retains the primary connection, paused work configuration/checkpoints but no connection.
- Checkpoints, references, acknowledged offsets and digests are memory-only. Pause/loss retains partial destinations; explicit
  resume verifies source/prefix. No ordinary staging/bookmarks/restart recovery or silent replay. Cancel/Host delete removes
  partials and reports failed cleanup. Mobile expiration pauses upload/download, cancels copies; desktop quit allows three seconds.
  Same-connection copies alternate bounded reads/writes, validate size/metadata/EOF and atomically commit temporary files.
- Shared planners retain directory-only batch destinations/mutation counts. In-app SFTP-to-SFTP drag/copy consumes the private
  remote payload before asking for its Finder file promise, streams directly between clients without local staging, and exposes
  exactly one `.copy` queue row per regular file. Apps own UI, cancellation/errors/refresh and deletion.
  `SFTPRemoteConflictResolver` validates recursive child paths, subtree mapping/Keep Both: upload blocks strict descendants; copy
  also blocks conflicting root. Desktop context menus snapshot reconciled selection; appearance never mutates it.
- Terminal drop preparation is cancellable/generation-scoped; late results cannot enqueue. Nonmodal notices cannot replace same-batch
  failures. Native browser alerts/conflict choices stay app-owned.
- One process-local Application external-edit model outlives browsers/Workspaces. Remote Infrastructure owns managed copies, streamed
  SHA-256, atomic-replacement observation and immutable upload snapshots. Upload is explicit; paused edit uploads retain staging until
  terminal completion. Dirty-only cards do not own edit lifetime; clean records remain reusable.
- Discard stops tracking but preserves local copy; next Open downloads anew. Running/preparing uploads cannot discard; paused uploads
  cancel/clean first. Desktop Keep Local Copy uses save panel/coordinated copy, not ShareLink, and checks edits before quit. Mobile
  promises no quit warning/restart recovery; paused uploads need explicit resume.
- Validate original kind/size/mtime/mode before write and rename, preserving permissions. Overwrite uses POSIX rename, falls back only
  if unsupported, never unlinks original on failure; non-overwrite never uses POSIX overwrite. This is best-effort, not atomic CAS.
  Missing/changed metadata needs confirmation; nonregular destinations fail closed. Acknowledge only uploaded snapshot digest so later
  saves remain dirty. Host removal/route edits invalidate records but preserve copies. All regular files use SHA-256.
- Native Quick Look/Open With remain app-owned and reuse managed copies; macOS invocation choices never change defaults. Mobile rejects
  retired/background late presentations but preserves active handoffs across deactivation. Same-format imports target valid nonbusy edit
  records, retain remote baseline and mark dirty; ordinary upload/conflict policy commits.

### Agent/MCP byte channels

- Agent SSH and the primary Agent SFTP subsystem share one pooled Host transport and one fair libssh2 owner; concurrent exec and
  SFTP work use separate Channels on it regardless of which tool connects first. Agent SFTP data work shares the process SFTP
  scheduler and resolves Smart/Channel-only/connection-preferred topology by the synced preference; metadata/control calls use
  Channels without consuming data capacity. Connection-preferred work may add silent SFTP transports, which retain the same
  180-second idle pool across conversations/MCP and fall back to Channels on the shared primary.
  `sftp_copy` belongs to Agent SFTP: regular trees to existing directories, browser conflict/merge policy and preserved sources.
  Cross-Host copies take two ordered endpoint leases; same-Host copies use two leases for Connections Preferred and one SFTP
  Channel for Channel-only/Smart-unknown work. Active exec/SFTP leases block idle sweeping; background commands
  retain only their Channel, not the whole transport. Started operations never replay. No model bytes/staging/scratch.
- macOS MCP exposes the same definition; Bearer/tool switches/Full access remain boundaries, auth uses external interaction. Stop awaits
  copies. Audit metadata/counts/endpoints/policy, never bodies. Stdio only forwards protocol; mobile has no local MCP listener.
- Separate loopback HTTP upload/download capabilities are ten-minute, session-bound 256-bit secrets for Host/path/intent, in headers only.
  Authenticate/atomically claim before body/network work. Ordinary MCP retains Bearer/4 MiB cap. Dedicated HTTP-neutral streams/leases use
  backpressure, no staging/scratch. No directory overwrite; failed cleanup reports temporary path.
- Upload commits only after exact length/incremental SHA-256. In-memory resume uses acknowledged remote offset, matching `Upload-Offset`
  and suffix Content-Length; reject parallel claims, verify prefix, never replay committed bytes. Lost responses cannot undo commit.
- Download ticket creation does no remote I/O. GET regular files only, no HEAD/bodies/query credentials; one `Range: bytes=N-` uses client
  saved length. Invalid range returns 416 without consuming ticket; resume rereads/verifies prefix/metadata before headers. Dedicated
  worker owns handles/queue; FSTAT fixes length and EOF revalidates bytes/size/mtime, not an atomic remote snapshot.
- Download pulls at most 64 KiB after each send. Success requires source validation, sent completion, checked close and lease release.
  Pre-header errors use safe JSON; post-header errors close without appended JSON. Clients must poll status and verify local size/hash;
  HTTP 200/Content-Length alone proves neither success nor persistence.
- Shared metadata/expiry policy, separate directional state/claims/errors/ordering. Four active slots, each direction at most 64 unfinished
  and 256 terminal records for thirty minutes. Live work blocks idle expiry; completion remains queryable. Disconnect/recoverable SSH
  failure pauses; explicit revocation cancels. Resume needs original active session/unexpired capability; exit loses both. Generation IDs
  reject old callbacks. Host/session retirement, stop/token rotation/direction disable revoke; release capacity after cleanup. Audits never
  include bytes/tokens. Upload expiry may clean partials; download allows valid Range after success.

## Callback isolation

Speech and service state is MainActor-isolated, external callbacks are not. Create explicitly Sendable callbacks in nonisolated factories;
actor-inherited closures can trap before dispatch. Recheck recording tokens after authorization. iOS realtime audio taps use nonisolated
factories/Sendable buffer handlers. Timers/workers enter explicit short MainActor methods; remote I/O remains async/detached.

## Agent runtime and security

### Providers

- Empty credential reference means anonymous; nonempty missing/empty/unreadable secret is an error. `modelSecret(for:)` applies consistently
  to discovery/probes/Chat/Guardian/title/compact/generator/Memory. Anonymous requests neither read secrets nor inherit unrelated errors;
  providers omit empty auth headers. Vertex requires its own service account/project/location.
- Name/URL hints are not prefilled input. Application materializes blanks at save: Automatic uses full OpenAI Responses URL; explicit
  protocols use their base. Nonempty input survives type changes; legacy empty runtime rows never infer public endpoints. Desktop uses
  buffers, mobile normalizes after conflict merging; viewing/editing never contacts providers.
- Vertex is an explicit generateContent option, independent of retained ordinary URL/key; leaving type disables without deletion, never
  fallback on missing credentials. Models are manual. AgentKit owns addresses/OAuth. Bound JSON import validates Google token URLs;
  plaintext stays transient/in `AISecretStore`. Two-reference edits compare originals and roll back if metadata fails; delete removes both.
  V19's separate backing freezes older providers; sync preserves omitted old-client fields, honors explicit clears/deletes, never cloud-syncs
  private keys or reconstructs V12-discarded data.
- User-selected HTTP/HTTPS/self-hosted endpoints require ATS arbitrary loads; HTTPS still uses normal trust. No local-network exception may
  override it. Local-network descriptions are localized; App Review notes explain user-owned HTTP servers.

### Execution and authorization

- AgentKit owns loop/gate/providers/MCP/host-neutral tools; Termind owns SSH/SFTP/pools/Vault/persistence/policy/UI. Built-ins precede additive
  `TermindAgentTools`, cannot be shadowed. `AgentToolServices`/`AgentSSHInteraction` keep auth out of durable events. `ChatSlashCommandRegistry`
  owns command semantics; composers inject actions. Termind prompt/plan policy stays cache-stable, presentation raw values stay persisted.
- `AgentRuntime` actor and context pipeline modify requests, not stored history. Schema validation precedes preflight/cards/hooks/authorization/
  execution; event channel serializes durable/UI events. Tool-incapable models get none; unknown purposes default to chat. Planning/acting
  have no count ceiling; finish/stop/hooks/errors terminate. Guardian is bounded and fails closed.
- Compact/title/generator buffer streaming (never force `stream: false`), require complete validated results/terminal SSE marker, cap raw
  responses at 16 MiB and discard partials on cancellation/malformed/premature EOF. Ordinary turns retry transient transport/service failures
  five times at 1/2/4/8/16 seconds using the same logical request, discarding partial UI. Tools dispatch only after complete responses, never
  replay on retry. Final failures are error rows, not assistant text. Caller-URL fetch/scratch_fetch are Ask; enabled search is pre-approved.
- Guardian is isolated/tool-free `.reviewing`, with per-conversation serialized in-memory full-to-delta review. Only direct user text/local
  question answers authorize. Stable policy/schema/cache prefixes; native JSON schema where supported, strict local validation otherwise.
  Unavailable/timeout/malformed/recursive/inconsistent review fails closed before execution. Explicit model wins; automatic selection prefers
  codex-auto-review, then version-ranked supported families, then Chat (see resolver/tests for exact ranking).
- Immutable hidden `AgentTurnContextSnapshot` captures facts/skills/plan/surface availability at submission/steer/edit. Replay uses original
  baseline/deltas; absent legacy context is unknown, not current UI. Leave session/mode clears; retry retains, fork copies, compact rebases.
  V16 adds independent replay backing, removed on deletion/truncation while older messages remain frozen.
- Project tool output once before `toolFinished`: bounded preview and scratch reference, retaining crash/replay metadata and paging offsets.
  Later completion never shortens earlier results; `sftp_read`/`scratch_read` report complete lines/truthful offsets.
- Terminal suggestions use latest delivered user snapshot, not focus. Surface availability is partial and does not restrict independent SSH/
  SFTP. Standalone Assistant can discover Hosts without sidebar attachment; ask only for ambiguity. App auth handles SSH prerequisites;
  `request_user_secret` is for command secrets. Suggestions create user-operated cards, never execute. Deterministic provider schemas/cache
  keys; cached tokens never double-count usage.
- Concurrent batches require every call parallel; preflight may tighten (`ssh_exec` proven-safe only, destructive MCP sequential). Answers stay
  model-ordered, including refusals/cancellation. Questions/approvals queue singly; hooks cannot remove structural authorization. Command
  classification unwraps bounded known syntax; unknown/complex/unsupported input fails closed as state-changing.
- Tool policy precedes permission mode: **Deny** always refuses; **Approve** needs no further approval; **Ask** goes to user or Guardian in
  Approve for me. Full access pre-approves Ask but never bypasses trust/secrets/schema/path/fetch/sandbox/capability boundaries. New MCP tools
  default Approve only when read-only and not destructive; rediscovery preserves explicit policy in both planning/acting.

### Skills, memory and durable data

- Skills are global app-managed packages/journal. Immutable application Creator/Installer merge only into runtime/catalog/reads, never Settings/
  persistence/sync. Reserved names cannot be shadowed; collisions remain visible/paused. New libraries are empty; old starters remain ordinary
  user records with identity/content/resources/deletions preserved.
- Acting-only Ask `skill_install` pins public GitHub directories to a commit, bounds/verifies bytes and rejects redirects/symlinks/submodules/
  incomplete packages. Reviewed memory staging binds source/files/name/invocation/library revision; commit package+intent atomically, no scripts/
  overwrite, available next run. Reads are bounded/paged; only SKILL.md instructs, references/frontmatter grant no permission. Mutations are
  revision-bound and running snapshots fixed. V18 backing preserves supporting files from legacy payloads; `load_skill` is replay-only.
- Hermes Memory is device-local/default-off. AgentKit owns tools/screening/learning/revocable snapshots; Application lifecycle/UI; Persistence
  alone GRDB. Separate database stores memory (2,200 Unicode scalars), user (1,375), frozen conversation snapshots/checkpoints/FTS5 history;
  SwiftData remains conversation source. Atomic tool writes/base-state-checked reviews; forks reference snapshots, planning searches only,
  skills retain approval, memory/credentials never sync.
- Disable revokes snapshots/cancels work but preserves storage. User-only Destroy persists disablement/unfinished marker, revokes leases, joins
  work, closes/removes owned DB directory; failure stays disabled/retries launch, stale writes rejected by generation. Other records/exports
  survive. Disabled startup never opens/creates DB; explicit re-enable can backfill and relearn from old chats.
- Tools never receive interactive PTYs: exec uses per-command Channels and files use exclusive leases from the Agent SFTP pool.
  Secret handles are single-use/run-tool-Host-purpose-bound;
  plaintext never reaches model/review/events/logs/SwiftData. Original arguments are projected only for pending local approval, never retained.
  Fetch requires public HTTP(S), DNS revalidation per redirect/restricted-origin reauthorization and sensitive-header redaction. MCP metadata
  only tightens safety.
- Per-conversation bounded `AgentScratchWorkspace` proves containment, rejects escape/`..`/symlinks and serializes path mutations. Pull/push
  bytes stay outside transcripts; previews are bounded, push approval binds size/digest/redacted head and rejects changed content. Persist after
  redaction/truncation. Launch marks unfinished runs interrupted, never replays; restore completed results and explicit unknown-outcome repairs,
  never assumes unanswered calls were undispatched.

## Assistant presentation

- Presentation owns summaries/status/previews/time/Markdown/disclosures; hosts inject Remote Infrastructure presenters without importing transport
  registry into Presentation. Protocol/persisted schemas remain unchanged. ListViewKit stays app-owned/allowlisted for large dynamic lists;
  bounded navigation/archive uses SwiftUI List. Native row/cache/edit/viewport lifetimes stay platform-owned.
- Mobile presentation revisions reconfigure only changed rows/heights, retaining hosting content. Measurement does not start timers; only active
  displayed content does. Deadlines never restart on reuse; completion defaults wait until the entire row exits unless reader chose disclosure.
  Desktop width changes retain lists/parsed Markdown and never follow tail. Full expansion is window-owned; Copy uses full sanitized projection.
- Approval callbacks idempotently stage the same card before response; queued events cannot erase denial irrespective of arrival order. Historical
  repair recognizes local presenter identity, never MCP/name-only matches. Bounded previews/scrollable arguments keep actions accessible without
  reading live skill/memory stores or changing authorization/results/persistence.

## Commerce, review invitations and metrics

- `ProAccessController` is app-wide. StoreKit metadata/verified transactions alone determine offers/access; permanent wins, trial/subscribed/grace
  grant access, metadata failures do not remove it. Foreground/minutely expiration checks. Presentation derives values, native paywalls navigate.
  Workspace composition/broadcast/batch open/multi-host snippets/local templates are free; sync/other Pro features use current entitlement.
  Product IDs, localized copy and release checks: [APP_STORE_COMMERCE.md](APP_STORE_COMMERCE.md).
- App-wide/device-local `AppReviewController` records attempts before StoreKit, never claims display. Automatic criteria: seven days, three active
  dates, five foreground Workspace minutes, three quiet seconds entering Vault/Settings; input/focus/navigation/sleep/modal cancels. Once/version,
  120-day cooldown including manual review. Tests/screenshots disable live requests; native observation remains app-owned.
- `ServerMetricsModel` shares one serial sampler/saved Host across windows/menu/mobile. Publish rows before secrets/network; detached workers do
  short MainActor steps, recheck cancellation after credential reads, clear secrets on pause/removal/quit. Active monitor owns interaction.
  Screenshot fixtures inject frozen values into production WindowGroup, never real discovery/samplers/config.
- Bound procfs/optional hardened nvidia-smi XML; partial failures preserve base data, invalid deltas unknown. Rates use remote uptime, process
  identity PID+start, RSS remote page size; never collect arguments/environment. Five-minute samples memory-only; order/pause/device choices persist.
  Process/filesystem detail sampling only while needed. Prefer physical network interfaces unless explicitly selected.
- Read-only/parallel/planning-safe `get_metrics` returns existing snapshots only: validated Host IDs, timestamps/staleness, null unknown/nonfinite,
  max 20 processes. It cannot start sampling/details/auth. Monitoring does not depend on AgentKit.
- Metrics sync excludes samples/secrets/prompts/UI preferences. Each monitor owns Journey/MFA across jumps; cards signal but never navigate. Leaving
  detail retains challenge; cancel pauses/returns that window to list. Retirement cancels queued responders, generation/request IDs isolate cleanup;
  temporary trust clears on pause/removal/config change. Free cap atomically three cards including paused, never delete on downgrade; Pro unlimited.
- Desktop status item/popover receives model explicitly; last window close retains app/monitors, Quit cancels. Sleep/inactive login independently
  suspend; resume only awake/active with Data Protection Keychain available. Native lifecycle stays in `TFM/Platform`.

## Settings replication

- Master iCloud and Vault/Metrics/Settings selections currently default **on** (`SettingsKey`); upgrades preserve explicit choices. Pro gates separate
  `TermindVaultV1`, `TermindMetricsV1`, compatibility-named `TermindAIConfigurationV1` coordinators. Each owns a `CloudSyncLifecycle`: serialized
  generations, consent, fetch-before-send, retry/reset/status. Zones/subscriptions/accounts/journals/engines/merge remain independent. Persistence
  alone owns journal models. Authorize secret upload only after successful current-engine fetch; pause/retirement revokes. Stale work cannot publish
  or clear replacements; injected transport enables deterministic tests.
- Frozen V13 Settings; V14 terminal, V15 Metrics journal/account/quarantine, V21 SFTP. Commit data+intent atomically, then mirror defaults; remote
  apply refreshes without echo. Separate records cover providers/models/MCP/skills/roles/search/terminal/custom text/SFTP limits. First SFTP row
  imports prior local values once, missing 15/5; future preparation uses persisted truth. `v1/sftp/default` uses `SFTPPreferencesItem` in same zone/
  V1 envelope so old clients ignore it before decode. Missing strategy decodes as Smart; new/missing records default to 30/10 while
  existing saved limits remain unchanged. Invalid limits/type mismatches quarantine. Running Agent snapshots remain fixed.
- Live role records sync explicit choices, not resolved fallbacks: nil generator = Same as Chat, nil Guardian = Automatic. Read legacy
  `securityReview`, migrate to canonical `guardian` without reusing system fields. Conversations/approval mode/last-used model/listener config/
  unrelated defaults stay local. Listener token is this-device-only Data Protection Keychain.
- `AISecretStore` migration needs verified account/cloud copy/durable local marker; reads never cache, deletion markers prevent resurrection.
  Custom MCP headers/terminal text are ordinary synced settings, explicit credentials never CloudKit. Tombstones/unresolved references survive
  partial fetch; cloud beats baseline. Duplicate skill names/MCP namespaces retain all data but only lowest UUID executes. Metrics hides records
  awaiting their Vault Host. Signed-device/deployment checks: [SETTINGS_SYNC_RELEASE.md](SETTINGS_SYNC_RELEASE.md).

## Mobile boundaries

### Adaptive/native UI

- One sidebar-adaptable TabView per window, five stable stacks: Vault/Metrics/Workspaces/Assistant/Settings. `MobileFeatureRegistry` injects one
  ordered ID/factory set and rejects duplicates. Adaptation never replaces the tree or loses routes/search/scroll/sheets/drafts/connections/runs.
  Metrics is independent; Vault shortcuts select it. Layout follows actual placement/container width, never device idiom.
- Toolbar policy derives once from tab placement/system vertical edge. Peer switchers are distinct from app tabs; search remains native/minimized
  without focus claims on pose/sidebar change. Save/duplicate guards/dirty dismissal/errors and stable sheets survive layout changes.
- With iOS 27.1 SDK/runtime, read division/occlusion ReservedRegions after safe-area/keyboard layout, including margins/RTL. Terminal uses largest
  unobstructed rectangle (top/leading ties), resizes existing Ghostty PTY and rejects invalid sizes. Assistant keeps transcript and interaction
  surfaces mounted across regions; Metrics retains panel sizes/table/sort/scroll, using fold regions or selected page. Pose never changes ownership.
- Application owns Host/Snippet operation state/sections; Presentation labels/history/drag type; apps native selection/menus/clipboard. Metrics enters
  via `MobileMetricsServices`, both apps' host/auth/background commands via Remote Infrastructure `AgentHostServices`.

### Workspaces and activity

- One SSH/SFTP session per mobile Workspace, no Welcome/pane composition even with Pro; Assistant independent. Peer switch retains connection,
  Recent opens on demand, cross-open retains live paths. Explicit close never retries; failures stay in Journey. Background expiration closes
  transports but retains intent; foreground resumes existing Workspaces.
- `mobile.workspaces.v1` persists ordered local descriptors only (ID/Host/kind/title/duplicate index), no commands/secrets/paths/content/transfers.
  Cold launch after Hosts loads Recent only, no sessions/history/network. MainActor open-by-ID reuses or registers/connects once across scenes;
  failure needs explicit retry. Save retains unopened entries/order. Read legacy arrays/v1, assign missing lowest-free indices and write envelope;
  only successful loads permit save. Corrupt/unknown bytes remain/write-blocked. Prune missing Hosts; close/exit/delete removes live+Recent entries;
  Close All preserves connection history. Titles reserve indices without renumbering. Host-delete outbox cancels related runtime/local history.
- One serialized Live Activity for current Workspaces only. Secret/command-free validated links select ID/list without restoring unrelated sessions;
  cold launch ends leftover activities but links may open saved entries. Explicit start intent waits for foreground; last current close clears it
  even with Recent. Foreground alone never recreates dismissed activity. Snapshot/queue is separate from observed stores and cannot keep SSH/Agent
  alive. Stale links explain unavailable; restoration cannot distinguish termination from force-quit.

### Scene interactions

- App-wide runtime/conversation store prevents duplicate runs; each scene owns navigation/commands/library selection/New Chat draft. Focused values
  route keyboards; per-window delegates consume quick actions once. Switching neither reconnects nor claims terminal focus; Find owns F3/Shift-F3
  and Escape only while active, otherwise Escape passes to Ghostty.
- Settings editors use explicit drafts; ephemeral probes cancel on config/editor changes and cannot revive discarded data. Secrets remain transient
  until atomic save/rollback. Mobile never starts local MCP. Archive persists before navigation/read-only until restored. Injected speech appends
  without send and cancels on interruption/conversation change/background. Finite background expiration cancels runs/drains events/closes Agent
  transports, never replays or auto-approves on return.
- Window drop interaction covers visible Workspaces: terminal routes files to uploads, text/links retain Ghostty behavior. Leaving restores original
  interaction/targets. File-provider data is copied inside callbacks into staging retained by queued transfers after navigation.
