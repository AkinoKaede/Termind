# Termind architecture

One Xcode project contains macOS (`TFM`), iOS/iPadOS (`TFI`), shared static frameworks,
separate platform/framework test targets, and the macOS-only `termind-mcp` bridge.
`AgentKit` is a separately versioned package.

## Modules and dependency direction

| Owner | Responsibilities and dependencies |
| --- | --- |
| `TermindDomain` | Portable values/rules; Foundation, CryptoKit and AgentKit values only, no UI or concrete I/O. |
| `TermindApplication` | Repository ports, feature models, connection policy, SSH preparation/import previews, remote-file-system ports, sync/outbox use cases; depends on Domain and AgentKit. |
| `TermindInfrastructure` | In-memory repositories, metrics parsing, StoreKit, Vault/Settings/Metrics CloudKit coordination; depends on Application, Domain and Persistence. |
| `TermindRemoteInfrastructure` | SSH/SFTP, Keychain, keys, sampling, forwarding, transfers and scoped SSH imports; depends on Infrastructure, Application and Domain. C libraries stay outside the portable framework-test graph. |
| `TermindPresentation` | Reusable SwiftUI content/policy, Ghostty themes and `TerminalPreferences` bridge; depends only on Application and Domain. |
| `TermindPersistence` | All SwiftData models, frozen V1–V22 schemas, migrations and container construction; never depends on an app. |
| `TFM`, `TFI` | Native UI, adapters and lifetimes, organized into App, Application, Design, DesignSystem, Features, Infrastructure, Platform and UI. Frameworks never import apps. |

Use explicit public APIs and direct owner imports: no re-exported imports, forwarding aliases,
`Shared` type names or generic Core module. Shared resources are copied into both app bundles;
icons, metadata and signing remain platform-owned.

Persistence preserves entity identity, fields, defaults and historical semantics across code moves;
original-module V1/V14 fixtures guard migration. `makeContainer` fixes the complete schema/migration
plan, with one container per process shared across scenes. Failures never silently recreate stores.
macOS retains its `Termind` location; mobile uses Application Support and in-memory test stores.
Both apps use the same CloudKit container and bundle-derived Keychain access group.

Architecture tests fail closed on missing/empty production roots. Source checks cover only module
dependencies, native-list import allowlists, AgentKit type ownership and SwiftData ownership;
UI copy, source layout, call-site spelling, retired paths and component wiring require behavioral
coverage or visual review.

## State, navigation, and ownership

### Editing and saved values

Presentation supplies single-line horizontal layout and newline-to-space editing. Reads preserve
stored values; only edits normalize. App-owned paste adapters normalize before native controls
flatten breaks; native rename editors preserve marked text. Multiline content, secrets and existing
validation are unchanged; there is no migration or bulk cleanup.

Domain defines optional-name defaults used by form hints and Application saves: Host address,
Identity username, key algorithm (`Secure Enclave` for enclave keys), Host plus SSH argument,
provider protocol name, or model ID. Hints stay empty without their source, including an unselected
forwarding Host or unknown imported/replacement key algorithm. Nonempty names, even generated ones,
remain stored values; clearing requests a fresh default. Key generation/import/editing allow blank
names. Desktop autosave uses page-owned buffers; reopening shows saved values. Legacy/replicated
blank names materialize only on the next local record save, in its existing transaction; no schema
or sync payload changes. Mobile provider drafts merge raw model names before defaulting at Save:
explicit clearing conflicts with a concurrent rename; only a legacy blank becoming its default in
the latest record counts as unchanged.

### Windows, navigation, and lifetimes

- Repository snapshots/preferences are app-wide; shells, quick-open, search, navigation and context
  panels are window-owned. Feature Application models expose narrow intents over the shared Vault
  snapshot. `VaultStore` owns transactions; sessions receive only `RemoteSessionHostStore`.
- Quick Open claims search focus after mounting in its own active native window; closing retires
  pending focus requests. Its presentation releases toolbar Find and suspends terminal autofocus.
  Batch Startup's single Connect action opens selected SSH/SFTP Hosts as panes in one new Workspace;
  other Host menus retain their explicit layout choices.
- Each desktop scene owns a distinct `WindowModel`. The process coordinator routes UUID-scoped
  requests and weakly tracks native windows. New windows start at Welcome; Dock reopening preserves
  the destination, Metrics entry selects Metrics. Dock New Window uses the same factory, activates
  hidden/windowless apps and is disabled until that factory is ready. Restoration never reconnects
  or restores live Workspaces.
- New windows snapshot the source's ordinary content size once. Registration applies full-size
  content style before sizing to avoid accumulating titlebar height. Fullscreen Command-N opens
  Connect; explicit Quick Open New Window uses the source's pre-fullscreen size. Last-used ordinary
  size is device-local UserDefaults, frozen before termination teardown; fullscreen/auxiliary
  windows cannot replace it. Cold scenes use it only without a system-restored frame; multiple
  restored frames stay distinct. Positions remain system-owned; tests/demos use in-memory sizing.
- Command-W closes the selected Workspace's focused pane, removing an empty Workspace but retaining
  its window; otherwise it requests native dismissal. All user window-close paths use SwiftUI
  confirmation if that window owns any Workspaces, including hidden/disconnected ones. Cancellation
  preserves them; other windows are irrelevant. Shift-Command-W requests direct window dismissal;
  the last-window background policy still applies. Main-window registration clears SwiftUI's
  document-edited decoration without changing its confirmation condition or dismissal delegate;
  observation follows the attached native window and ends on detachment.
- Commands can move a Workspace intact to a registered destination window on MainActor. Navigator
  drags keep SwiftUI's UUID-string provider for ordering/composition; dropping outside creates no
  window. Moves preserve surfaces, transports, splits and session state without close history;
  empty sources show Welcome. Native closure disconnects only owned sessions, cancels pending moves
  and unregisters the window. Independent transfers/app services survive. Mounting never restarts
  attempted connection/authentication; explicit retry/reopen may.
- Paywalls stay pinned to one main window until dismissed. Speech belongs to a composer instance,
  so closing another view of the same conversation cannot cancel it.
- Desktop navigation starts with Vault/Assistant, places Metrics above Vault libraries, appends
  dynamic SSH/SFTP Workspaces and ends with Settings. Vault owns Hosts, Keychain, Port Forwarding,
  Snippets, Known Hosts, Welcome and editor routes. Settings data is app-wide; window-local Settings
  navigation remembers and restores the replaced destination.
- Desktop detail minimum is 360 points; Assistant reading maximum is independently 840. Opening
  Navigator grows the window as needed. Vault reserves a 280-point list, one-point divider and fixed
  320-point editor (including the embedded forwarding Journey), overlaying below 601 content points;
  the full-page editor fills available width and covered lists retain their last visible size. Editor/space
  transitions take 0.22 seconds, preserve content size and respect Reduce Motion. Metrics below 700 points uses
  a titlebar Status/Processes picker with hidden title; wider layouts show both panels/title.
  Covered panels retain size, table identity, sorting and scroll. Selection/width are window-local;
  changing server selects Status, while focusing search or narrowing during search reveals Processes.
  Compact Pause/Resume goes in More; macOS 15 search uses a toolbar popover. Resizing changes layout,
  never routes, editor identity, Workspace composition or monitoring ownership.
  Vault grouped forms retain native horizontal insets without expanding their scroll content; only
  vertical scrolling is allowed. The embedded Journey retains 16-point horizontal insets and a horizontal
  route scroller. Host integration uses a native labeled menu on both platforms, fitting narrow editors
  without widening them or clipping their footers.
- `AssistantLibraryModel` owns standalone conversations, never Workspace panes. Workspaces own
  SSH/SFTP/serial panes and session-scoped conversations; sessions own live transports and
  terminal/browser state. Assistant ordering/pinning is metadata-only during runs, approvals or
  compaction: preserve instances and commit before publishing. Archived chats cannot move, rename
  editors cannot drag, and archive/delete retain run/compaction guards.
- Runtime connection/authentication/forwarding state stays in memory, never on domain records or
  in Vault/Metrics/Settings sync or UserDefaults. Serial sessions are temporary/local; Infrastructure
  owns IOKit/termios, and serial paths/parameters are neither persisted nor Agent hosts.
- Vault-synced Workspace templates store named SSH/SFTP/empty split trees and divider fractions.
  TFM alone maps them to live sessions/UI; TFI only carries records for sync. Missing Hosts restore
  as empty panes without collapsing the layout.

Known Hosts is independent of Host records: Host edits/deletes never change trust. Plain and OpenSSH
`|1|` hashed endpoints share a matcher; hashed records retain wire `hostname` and ignore separate port.

SSH imports recursively classify content into a window-owned, indexed public-metadata preview.
Imported identities require their selected keys; Hosts use an exact existing/selected imported
Identity or remain unbound. Selecting a Host never selects credentials. The actor reader retains
scoped descriptors/digests, never private-key text/passphrases; selected keys are reread transiently
at unlock/commit and changed sources fail closed. Picking/drop share scoped validation; config
parsing executes no commands. Commit creates credentials before one Vault save, cleans up on failure,
never overwrites records or clears an existing trust mismatch.

macOS appearance is global UserDefaults applied through `NSApplication.appearance`; System clears
it. Login launch reflects `SMAppService` on each Settings visit, with no mirrored preference; quiet
login hides the app without suppressing its window. macOS owns in-app language selection; mobile
uses Apple's per-app Settings with no stored/injected locale override.

Debug visibility and Logging preferences are device-local UserDefaults and never participate in
Settings sync. Both apps reveal the Debug section on the Settings index, immediately after Sync, by
triple-tapping the App version; on macOS it remains immediately before the Developer section.
Application and remote business objects receive SwiftLog `Logger` values through their constructors;
Termind never installs a process-global SwiftLog bootstrap. Infrastructure owns one lock-protected
writer shared by every logger label: saving defaults off, and when enabled one file is used for the
entire app launch. Disabling preserves and closes it; re-enabling resumes it; deletion recreates the
current empty launch file only while saving remains enabled. Files have no retention policy and are
exported or deleted without an in-app content viewer. Debug builds also emit the same sanitized lines
to stderr. Logged events and fields are stable English codes; each business-layer logging call supplies
only non-sensitive workflow metadata, never credentials, prompts, user/host/address/port/path identities,
remote output, process names or raw errors. Primary Metrics samples always log received byte size; their capped diagnostic
payload is logged only for incomplete or oversized samples, with the address section redacted.

## Remote sessions, terminal, and files

### Connection and authentication

SSH, SFTP, mobile Workspaces and Metrics share preparation/recovery policy. Host-key approval stays
inside the actual socket/libssh2 handshake-to-authentication attempt, never a discovery connection.
Generation tokens reject retired callbacks, credential results and retry timers.

Desktop SSH/SFTP share submission resolution and optional Identity/Host saving through
`RemoteSessionHostStore`. Explicit passwords win over selected-Identity lookup; custom input never
inherits an unselected Identity password. Selected credentials change only for explicit password
input; custom input reuses the Host's Identity. Identity/secret writes precede the separate Host
association. Sessions retain validation order, passphrase continuation, prompt/error state,
temporary credentials, transient Hosts and reconnect sequencing.

Keyboard-interactive uses the same authenticated opener for PTY, exec, SFTP, forwarding, key
installation and jump hosts. Its C callback waits only on the transport queue for an async,
cancellable responder showing literal server name/instructions/prompts/echo flags. Request IDs
separate rounds/connections. Answers are ephemeral: never autofilled, cached, logged or recorded
in Agent/MCP history. Empty answers are valid; zero-question rounds need no form. Waiting excludes
libssh2 network timeout; cancellation wakes the callback, cancels its responder and interrupts opening.

User connections own challenge queues; Agent runs use their interaction queue. macOS background/MCP
operations share the native authentication window with independently cancellable origins; stopping
MCP preserves app requests. Mobile has no app-owned authentication sheet. Forwarding/Metrics each
own Connection Journey challenges on both platforms, never the desktop external window.

Terminal drops and additional transfer connections forbid Termind credential/passphrase/MFA/host-key
forms, including jump-host fallbacks, but permit system key authorization such as Touch ID. Username-only
and SSH `none` remain eligible; connection success determines availability. Cancellation interrupts
opening; cleanup stays silent and reports failure if new interaction would be required.

Username-only identities allow empty credential lists: try SSH `none`, then advertised methods;
missing configured secrets and existing failure/retry semantics remain. Device-local Identity
`lastUsedAt` records successful saved-password/private-key reads for setup, not remote authentication.
Resolvers batch destination/jump/proxy reads; missing secrets and availability/editing reads do not
count. First access per Identity/process writes its SwiftData row directly, without Vault journal or
refresh; retries deduplicate. Vault sync strips this metadata and preserves it on remote application.

Welcome parses a bounded SSH command grammar without invoking a shell or reading OpenSSH config.
Exact saved aliases supply metadata; command overrides create session-owned route snapshots, including
unsaved jump Hosts and per-hop login hints. The snapshot drives authentication, Journey and reconnects;
no lookup may replace an overridden endpoint with the original saved Host. Routes remain bounded to
eight Hosts and reject cycles before copying aliases. Connect never saves Hosts or Identities. Explicit
Save copies changed records and adds necessary route prerequisites in one Vault transaction, rolling
back newly written passwords on failure. Original Hosts/Identities remain unchanged; ordinary saved
sessions retain their existing credential-save policy. Host-key decisions remain in the live handshake.

### Port Forwarding

Port Forwarding is an independent Vault library between Keychain and Snippets. Cards share Hosts'
two-row height and name/address/type/Host/runtime-state fields. Blank names preview/save Host plus
SSH argument, e.g. `AWS (-L)`; legacy blanks use that display fallback until saved. Host renames never
rewrite saved rule names. Rules retain Host references and save/delete in independent rollback-safe
transactions, outside Host editor drafts. V20 adds persisted palette color, freezes V1–V19 forwarding
entities and defaults legacy JSON to no color; existing Vault payload/identity carries it to both icons.

Desktop Journey uses the Vault editor column, sizing/animation, 16-point horizontal margins, icon-only
log action and vertical scrolling. Editor/Journey fades preserve connections/challenges; other Journey
surfaces keep their default presentation. Successful saves close the editor and select the card;
failures retain drafts. Double-click starts/stops without inline action buttons. Desktop uses
window-owned multiple/marquee selection with Stop (disabled without active rules) and transactional
Delete. Start/retry always target one rule; neither platform has bulk start or Start All/Stop All.
Mobile pushes detail with trailing Start/Stop/Retry.

Only explicit actions create rule-running intent; launch, foreground and saved/synced edits never do.
After a listener has run, transport loss preserves that intent and silently recovers all active rules on
one shared Host connection. Retry delays are 1/2/5/10/30 seconds, capped at 30, reset after 60 stable seconds.
Recovery reuses an in-memory authenticated configuration with durable trust refreshed after initial login;
once-only trust and keyboard-interactive answers never authorize another connection. Like SFTP workers,
the complete route forbids app authentication/trust forms, permits system key authorization and does not
gate eligibility on saved credentials. Authentication/trust/interaction failures end recovery with an inline
error; only explicit Retry opens Journey again. Recovery shows Reconnecting and Stop, never Journey or alerts.
Initial failures still need manual Retry. Listener failure is rule-local; old TCP streams are not replayed.

Legacy enabled defaults are unused. Background expiration/termination stop resources and retries; navigation
owns neither transport nor prompts. Stopping one rule preserves peers; stopping the last cancels opening,
prompts and retries and releases credential snapshots. Host/jump-route edits and rule replacement stop affected
runs; authentication Continue/Save may continue its requested opening. Connection/rule generations reject stale
results, including pending listener completions, and replacement sessions await old transport/listener cleanup.
Disconnect returns only after socket cancellation handlers close descriptors. Local/SOCKS listeners use
SO_REUSEADDR to permit rebinding after closed streams enter TIME_WAIT, never SO_REUSEPORT or shared live binds.

Forwarding/jump bridges use DispatchSource readiness and exactly one serial queue per libssh2 session.
Stream pumps retain write chunks across EAGAIN, use a 256 KiB per-direction quantum and 256 KiB/session-pass
encrypted-read cap (including reads inside writes), and pause input at 2 MiB until below 1 MiB. A deduplicated
FIFO/2 ms slice provides fairness; half-close drains accepted bytes before EOF. Target DNS has at most four
workers; nonblocking TCP has a five-second deadline. Channel opens/remote listener starts retain and retry
session-wide library operation state. Receive callbacks and inner data loops honor the same slice deadline;
yielded work schedules a continuation without waiting for another socket edge. Local socket readiness
queues its own flow; transport/protocol progress still wakes peers. Remote channel admission runs before
and after bulk I/O so an exhausted slice does not consistently defer new connections.

Socket output batches up to 16 immutable chunks with nonblocking `sendmsg`; queued encrypted output has
a shared 256 KiB flush allowance across both ends of a pass. Complete encrypted-packet acceptance remains
mandatory. Channel input chunks are at most 32,700 bytes, matching the pinned libssh2 write clamp and
avoiding a separate packet for a 68-byte tail. Jump socketpairs request send/receive buffers of 256 KiB
on macOS and 64 KiB on iOS, best-effort and without shrinking larger defaults. This is kernel socket
capacity, separate from application watermarks and the encrypted-read allowance; no global sysctl changes.

After authentication releases the abstract context, public send/receive callbacks install an adapter
accepting whole encrypted packets with bounded backpressure between library calls, including generated
replies. This avoids the pinned libssh2 forwarded-tcpip confirmation losing channels on socket EAGAIN.
Teardown discards writes/returns EOF; descriptors close only after dispatch-source cancellation handlers.
Timers handle keepalive/protocol deadlines, never bulk polling. Count notifications fire only on changes,
including while starting.

### Terminal behavior

The SSH worker queue owns PTY dimensions: retain the latest valid authentication-time viewport, including
pixels, for initial creation. Window-change packets keep their original dimensions through EAGAIN, finish
before the newest request, and allow other I/O to progress. Disconnect/failure clears resize state; retired
authentication cannot install a PTY or clear replacement dimensions. Ghostty alone computes the grid.
Resize failures log diagnostics, discard that packet and permit later sizes; they never fail connections
or alert users.

Application's `TerminalCommandDraftController` owns requests, timeout/cancellation and bracketed paste;
`CommandGenerationCoordinator` adds model timeout, freshness and presentation. Apps supply context,
validity/insertion; generated commands are inserted, never submitted. `TerminalFindController` serves
desktop SSH/Serial and mobile SSH.

Font family/size/follow-theme-size are device-local UserDefaults, excluded from `TerminalPreferences`,
Settings journals and CloudKit. Before remote materialization, seed missing local size keys from the
pre-upgrade local blob or defaults; existing mirrors win. Ignore legacy remote font fields and omit them
from new payloads (older readers requiring them must upgrade). Theme/custom text still syncs, including
authored fonts. Empty family follows theme; unavailable fonts fall back without deleting selection.
Apps refresh native catalogs on Settings entry/foreground; Presentation owns local bindings/final Ghostty
configuration. Apply explicit overrides after theme/custom commands, resetting family lists first;
reconfigure live surfaces in place.

macOS SSH/Serial have default-off copy-completed-mouse-selection and right-click-paste settings in the
existing synced terminal record/defaults mirror; missing fields decode false. Mobile preserves without
exposing/applying them. Changes retain native views/surfaces. Only local selection completion copies.
Right-click chooses routing on press, pastes once on release through Ghostty clipboard binding inside
interactive input capture, retaining bracketed paste/broadcast. Remote mouse capture and Option-right-click
keep Ghostty handling; mouse reports stay outside broadcast capture. Empty paste arms no deferred capture;
bracketed-paste classification spans chunks through its terminator or existing short-lived ticket expiry.

Host Shell Integration is Vault-synced Default/Enable/Disable; V22 adds a column while
freezing V1–V21 Hosts and defaults legacy data to follow global settings. Both explicit-save editors place it after
Group (desktop Group & Tags), with a native menu ordered Default, Enable, Disable. Default follows the global
preference without changing persisted values. Each SSH attempt resolves
destination override/global preference once before authentication for bootstrap, History, Command Generator,
system info and directory actions. Live edits never inject scripts/reconnect/change that attempt; new/manual/
automatic reconnects resolve again. SFTP/forwarding route identity is unchanged.

Mobile integration/exit callbacks share one ordered session MainActor consumer, ended by close/reconnect/
background expiration. Authenticated installation and command completion establish prompt readiness;
later prompt markers are idempotent. Bash DEBUG fallback passes `BASH_COMMAND` and ignores `__termind_*`
helpers, preventing draft protocol traffic from creating History or marking the prompt busy.

Command History starts only after authenticated start. Remote exit status/duration are optional; duration
is never inferred from receive time. Backslash-continuation boundaries normalize to one space; other
newlines remain stored, while both UIs show first-line-plus-ellipsis. Limit: 1,000 rows per Host.

### SFTP transfers and external edits

`RemoteFile` belongs to Domain, `RemoteFileSystem` to Application, and libssh2 `SFTPClientProtocol` to Remote
Infrastructure; symbols/localized kinds belong to Presentation. `MobileSFTPSessionModel` owns paths, listings,
history, filters, mutations and stale-request state. Persisted device-local SFTP History records directories
only after fresh successful listings and files only after downloads; failed/cancelled/stale/missing/type-changed
operations never update it.

Generation-scoped `SFTPTransferSession` outlives panes. Its first additional connection silently probes the
complete route: success becomes a worker/enables bounded concurrent silent opens; failure serially reuses the
authenticated browser connection. Later failures degrade pending work without replaying active operations.
Results are generation-local/in-memory; cancellation never caches failure. Terminal preflight supplies its
successful connection to the first transfer. Refresh durable trust after initial authentication, without
promoting once-only approval. Credential presence/persistence never gates eligibility or parallelism.

The app-wide queue defaults to 15 active files, five per Host.ID across all sessions; limits are 1–100 global
and 1–min(50, global) per host. `SFTPPreferences` normalizes; each app wires `SFTPSettingsModel` to scheduling
outside Settings view lifetime. Changes affect future scheduling, never active work. Closing panes releases
only their ownership; queued jobs retain the primary connection, paused jobs retain configuration/checkpoints
but release connections. Retired browser generations cannot replace snapshots. Same-connection copies alternate
bounded reads/writes, validate size/metadata/EOF, then atomically commit temporary files.

Terminal preflight/preparation is cancellable and generation-scoped; late results cannot enqueue. Drop errors,
including interaction requirements/mobile file-provider staging, use nonmodal upload overlays: failures stay
three seconds, queued notices two and cannot replace same-batch failures. New drops retire prior preparation/
notice timers. Browser alerts and conflict choices stay app-owned.

Checkpoints, file references, acknowledged offsets and incremental digests are memory-only. Pause/connection
loss retains partial destinations and releases connections; explicit resume verifies source and partial prefix
before seeking. Ordinary transfers add no staging, persistent bookmarks or restart recovery. Cancellation/Host
delete removes partials, reporting failed cleanup paths. Mobile expiration pauses upload/download and cancels
copies; macOS quit allows at most three seconds for async cleanup. Nothing replays silently.

Remote Infrastructure planners serve both apps' upload/download/copy preparation/enqueueing. Download batches
retain destinations independently of file jobs so empty trees are created; copy enqueueing reports directory
mutations for refresh even without files. Apps keep pending-state UI, cancellation/errors/completion refresh
and interactive deletion. `SFTPRemoteConflictResolver` shares subtree mapping, Keep Both, cancellation and
validated recursive child paths over `RemoteFileSystem`: upload preflight blocks strict descendants; copy
also blocks the conflicting root. Awaited copies retain created-directory counts. macOS file-row menus are
AppKit context-click snapshots after selection reconciliation; targets/items survive SwiftUI reconfiguration.
Menu appearance callbacks never change selection.

Each app has one process-local Application edit model independent of browsers/Workspaces. Remote Infrastructure
owns managed copies, streamed SHA-256, file/directory observation (including atomic replacement) and immutable
upload snapshots. Edit snapshots are the staging exception: pauses retain them, terminal completion removes
them. Upload is always explicit. Only dirty records appear in the shared floating bottom card; clean records
remain reusable. Full-height files scroll behind a separate rounded Liquid Glass (OS 26+) or native-material
backdrop with transparent rows; only scroll content gets a bottom inset, never a blank reserved safe area.

Discard stops tracking but preserves the editor's local copy; next Open downloads anew. Both row menus and
iOS trailing swipe expose it. Running/preparing uploads cannot discard; paused uploads cancel/clean first.
Apps own activation/background/termination and native open/preview. macOS ordinary edit-menu actions use an
app save panel/coordinated copy for Keep Local Copy, never ShareLink; macOS checks edits before quit. iOS
promises neither quit warnings nor post-termination recovery; background-paused uploads require explicit resume.

Edit uploads validate original kind/size/mtime/mode before writing and before rename, preserving permissions.
Overwrite uses OpenSSH POSIX rename, falling back to standard rename only if unsupported; non-overwriting
rename never uses it, and failure never unlinks the original as a workaround. This metadata guard is best-effort,
not atomic compare-and-swap. Missing/changed metadata or files require confirmation; nonregular destinations
fail closed. Success acknowledges only the snapshot digest, so later saves remain dirty. Host removal/route
edits invalidate records but preserve copies. All regular files use SHA-256 without extension allowlists.
Quick Look enables supported editing, receives in-place updates and owns temporary edited copies; different
formats export separately. Presentation owns the card; native adapters remain app-owned.

Open With reuses the managed copy. macOS discovers via UTType and launches the invocation's choice without
changing defaults. iOS keeps Quick Look primary and uses a Workspace-owned document controller, rejecting
retired/background late-download presentations in other Workspaces while retaining in-progress handoffs across
scene deactivation. Since receivers may edit independent copies, explicit same-format import targets an existing,
valid/nonbusy record, preserving remote identity/baseline and only marking dirty; normal upload/conflict policy commits.

### Agent and MCP file channels

Termind's acting-only `sftp_copy` uses Ask/sequential policy. It copies regular files/trees to an existing
directory, rejects unsupported descendants before writing, and shares browser manifest/conflict handling,
including directory merge/destructive type replacement. Sources remain intact. Batches are non-atomic;
failures disclose retained completed items/counts and the failed path. Two dedicated, unpooled, unswept SFTP
leases share the Agent authenticated opener and a cancellation token for caller/Host deletion/transport shutdown;
track them during opening and always disconnect. Credential retries stop after acquisition. Socket relays require
EOF/exact bytes before temp-file commit; cancellation unblocks sockets. No staging/scratch/model-visible bytes.

macOS MCP exports the same definition without scratch. Bearer/tool switches and Full access remain authorization
boundaries; credentials/host keys use external authentication. Annotations are state-changing, potentially
destructive, non-idempotent and open-world. Session/server termination cancels and awaits copies. Audit records
byte progress/final counts, endpoints and conflict policy, never bodies. The stdio bridge only forwards protocol;
mobile offers Assistant tools without a local MCP listener.

macOS also provides a separate loopback HTTP/SFTP byte channel. `sftp_upload` issues a ten-minute session-bound
256-bit capability for Host/full path/size/SHA-256/overwrite intent; `sftp_upload_status` exposes only that
session's bounded in-memory state. PUT authenticates the capability before consuming bounded body chunks with
socket backpressure; ordinary MCP retains long-lived Bearer and its 4 MiB body cap. Capabilities appear only in
headers, never query strings, durable audit or long-lived credentials. Remote Infrastructure owns the HTTP-neutral
stream/dedicated lease, with no staging/scratch. Exact bytes plus incremental full SHA-256 authorize EOF/commit;
directories cannot be overwritten, and failed cleanup reports the temporary path.

Interrupted uploads retain a memory checkpoint/remote partial. `upload_offset` counts acknowledged remote writes;
sequential retries require matching `Upload-Offset` and remaining-suffix Content-Length, rejecting parallel claims.
Digest includes verified prefix; committed bytes never replay. Lost HTTP responses cannot undo successful commits.
Live uploads prevent idle session expiry; retained success keeps idle sessions queryable thirty minutes. Upload
audit is metadata-only and independent of ticket-creation audit; no entitlement/schema/AgentKit change is required.

`sftp_download` issues the reverse capability for session/Host/full path/optional expected SHA-256 with no remote
I/O at creation. GET authenticates/atomically claims before connecting; regular files only, no query credentials,
bodies or HEAD. One open-ended `Range: bytes=N-` returns 206/Content-Range; out-of-bounds returns 416 without
consuming the ticket. Clients choose N from saved bytes, not server progress. Bounded prefix reread verifies
previous bytes before headers and reconstructs digest; changed metadata/prefix rejects resume. A dedicated
`SFTPDownloadStream` worker owns handles/native pointers/queue. FSTAT fixes declared size; EOF validates exact
bytes, final size and available mtime, without promising an atomic remote snapshot.

Download HTTP bodies pull at most 64 KiB after each previous send, never via SSE AsyncStream or staging.
SHA-256 covers transmitted bytes. Success requires source validation, completed sending, checked handle close
and lease release. Pre-header errors return safe JSON; post-header errors close without appended JSON/status
changes. Clients must poll `sftp_download_status`, verify local size/hash and finalize; 200/Content-Length alone
prove neither success nor local persistence.

Both directions compose shared MCP metadata/activity/retention policy for waiting/paused expiry and completion pruning,
but retain separate dictionaries, live states, claims, errors, streaming/cancellation and task ordering. Upload
expiry may spawn partial cleanup; download permits valid Range after success. They share four active slots;
each keeps at most 64 unfinished tickets (paused included) and 256 terminal records for thirty minutes.
Disconnect/recoverable SSH failure pauses; explicit revocation cancels. Retry requires the original active
session/unexpired capability; process exit loses checkpoints/capabilities. Generation IDs reject old callbacks.
Session/Host retirement, server stop, token rotation and direction disablement revoke live work; release capacity
only after cleanup. Download audit is separate from MCP ticket calls and contains endpoint/sent-byte/state metadata,
never bytes/tokens. The existing upload/stdio paths remain intact.

## Callback isolation

Speech state/services are MainActor-isolated; authorization callbacks may arrive anywhere. A nonisolated
factory must create an explicitly Sendable callback: actor-inherited closures can trap before dispatching.
Recheck the recording token after authorization to prevent revival. iOS Core Audio likewise creates realtime
taps in a nonisolated factory and calls only Sendable buffer/level handlers. Reconnect timers/metrics workers
enter explicit MainActor methods; remote I/O stays behind async/detached boundaries.

## Agent runtime and security

### Providers and configuration

Credentials are optional: empty references mean anonymous requests; nonempty missing/empty/unreadable secrets
are errors. `AIConfigurationModel.modelSecret(for:)` applies this to discovery, probes, Chat, Guardian, titles,
compact, Command Generator and Memory review. Anonymous resolution neither reads storage nor inherits unrelated
errors; ordinary AgentKit providers omit empty auth headers. Vertex still requires service account/project/location.

Forms show protocol Name/URL hints, never prefilled input. Domain defaulting materializes blank fields at
Application save: Automatic stores OpenAI's complete Responses URL; explicit protocols use OpenAI/Anthropic v1
or Google v1beta bases. Nonempty input never falls back/changes on type switch; legacy empty runtime rows never
infer public destinations. Desktop autosaves concrete values behind page buffers; mobile normalizes previews
and again after Save conflict merging. Reopen shows saved values; viewing/editing never contacts providers.

Explicit generateContent offers Vertex. Project, location (blank saves `global`) and service-account identity
are independent of retained ordinary URL/API key. Leaving the type disables Vertex without deletion; missing
Vertex credentials never fall back, and its models are manually added. AgentKit owns addresses/OAuth. Bounded
file/paste JSON validates trusted Google token URLs; plaintext stays in transient drafts/`AISecretStore`.
Two-reference edits compare originals and roll back all secret changes if metadata fails. Delete removes both;
disable removes neither. V19 adds independent `PersistentModelProviderVertexConfiguration`, freezing V1–V18.
Settings sync carries metadata/references, preserves Vertex fields omitted by older payloads, honors clears/deletes
and migrates both Keychain references; no private key enters CloudKit or reconstruction of V12-discarded data.

Both apps permit user-selected HTTP/HTTPS endpoints with ATS arbitrary loads for unknown/self-hosted domains;
HTTPS retains default trust, and no local-network ATS exception may override this. Local-network descriptions
are localized. App Store notes must explain user-owned HTTP servers the app cannot upgrade to HTTPS.

### Runtime, context, and authorization

AgentKit owns provider adapters, loop, approval gate, MCP client and host-neutral tools; Termind owns SSH/SFTP,
pools, Vault resolution, persistence, policy and UI. Additive seams:

- `AgentToolCatalog.registry(builtIn:additional:)` puts built-ins before `TermindAgentTools`; neither Termind nor
  remote MCP shadows them. `AgentToolServices`, including `AgentSSHInteraction`, keeps credentials/trust prompts
  outside AgentKit events and durable history.
- `ChatSlashCommandRegistry` owns command platforms, availability, options, current value and execution;
  composers inject only navigation/compaction/send/access actions.
- `TermindAgentPolicy` supplies prompt, plan contract and `ssh_exec` decisions with stable cacheable prefixes;
  `TermindAgentPresentation` supplies Termind cards with stable persisted raw values.

`AgentRuntime` is an actor; `AgentContextPipeline` changes model requests only, preserving stored history.
`AgentTurnDriver` streams, `AgentToolScheduler` batches, `AgentToolExecutor` validates schema then preflights,
creates cards, runs hooks, authorizes and executes; `AgentEventChannel` serializes UI/durable events. Adapters
cover Responses/Chat Completions, Anthropic Messages and Gemini. Models lacking tool capability get no tools;
conversation pickers show recognized chat purposes and unknown purpose values default to chat. Planning/acting
have no turn/tool-count ceiling; model finish, user stop, hook termination or errors end them. Guardian is bounded
and fails closed when unavailable/inconclusive.

Compact/titles/Command Generator use buffered results over streaming, never `stream: false`, applying only
validated complete results. Buffered SSE requires a terminal marker and caps raw response at 16 MiB; cancellation,
malformed data/premature EOF discard partials. Complete JSON remains supported; normal streaming policy is unchanged.
Ordinary turns retry only transient provider transport/service failures five times at 1/2/4/8/16 seconds, reusing
the logical message/request and discarding partial presentation. Dispatch follows complete responses, so retries
cannot replay tools. Retry progress is ephemeral; final failures persist as error rows, never assistant-authored text.
Callable `fetch`/`scratch_fetch` are Ask (`.ask`) for caller-selected URLs; enabled `web_search` is pre-approved and native
provider search cards record searches already performed.

Guardian is isolated `.reviewing`; ordinary tools default to `.planning`/`.acting`. The registry permits disjoint
same-name mode registrations with separate schemas/preflight/execution, but Termind registers no reviewing tools,
so Guardian is tool-free. Bounded full-to-delta in-memory channels serialize each conversation's reviews. Only direct
authored user text/local `request_user_input` answers authorize. OpenAI-shaped requests use `guardian:<conversation-id>`
cache keys and byte-stable policy/schema/tool prefixes. Declared support uses native JSON schema; otherwise validate
strictly locally. Unavailable/timed-out/malformed/recursive/policy-inconsistent decisions fail closed before execution.
Automatic Guardian prefers `codex-auto-review`, then highest numeric versions in `gpt-*-luna`, `claude-sonnet-*`,
`gemini-*-flash`, `deepseek-v*-flash`, `glm-*-flash` order, then resolved Chat. Matching ignores case and compares
numeric components (`0.11` > `0.8`); explicit assignment wins.

Immutable hidden `AgentTurnContextSnapshot` captures session facts, skills, plan contract and surface-tool
availability at each submission/steer/edit; live surface state remains window-owned. Replay emits baseline then
changed blocks at original boundaries, treating absent legacy snapshots as unknown, never current terminal state.
Leaving session/mode explicitly clears it. Retry retains, fork copies, and compaction preserves facts with a new
baseline. V16 adds independent `PersistentAgentMessageReplay`; V1–V15 messages stay frozen, with backing removed
on deletion/truncation.

Project tool output once before `toolFinished`: bounded preview plus scratch reference for oversized data.
Result metadata retains projection for crash recovery and message backing for replay; later completions never
shorten earlier results. Paged reads retain continuation fields; `sftp_read` streams UTF-8 line windows and,
like `scratch_read`, reports complete lines and truthful next offsets.

Terminal suggestions have stable definitions across surfaces; executor availability uses the latest delivered
user snapshot before preflight, never focus changes. Surface availability is a partial override, not a catalog
or restriction on independent SSH/SFTP. Standalone Assistant has no default target without a session; `list_hosts`
discovers targets and questions are needed only for remaining ambiguity, never to require sidebar/terminal attachment.
App configuration/UI handles SSH login; `request_user_secret` is for command secrets, not SSH prerequisites.
Ordinary `ssh_exec` needs only `host_id`/`command`; suggestions create user-operated cards, never execution.
Provider schemas are deterministic. Responses/Chat use conversation cache keys without hostname restriction,
Anthropic short-lived system/message breakpoints, Gemini implicit caching. Usage never double-counts cached input.

A batch runs concurrently only if every call is parallel. Preflight can tighten: `ssh_exec` needs locally proven
safe classification, MCP destructive hints force sequential. Results stay model-ordered and every call gets an
answer after cancellation/refusal. Approvals/questions queue singly; state derives from outstanding work. Hooks
cannot remove structural authorization. Command classification recursively unwraps supported wrappers/static
nested commands with argument/subcommand rules; unknown tools/options/programs, excess complexity or unsupported
syntax fail closed to state-changing.

Each tool has policy before permission mode:

- Deny refuses in all modes while remaining model-visible; Approve needs no further approval.
- Ask for approval sends Ask to users; Approve for me sends it to Security Review. Missing credentials, timeout,
  transport failure or malformed review fail closed and are recorded.
- Full access pre-approves Ask but retains host-key/secret/schema/path/fetch/sandbox/capability boundaries.
- New MCP tools default Approve only with `readOnlyHint == true` and `destructiveHint != true`; otherwise Ask.
  Rediscovery preserves stored policy, even explicit Approve for destructive tools. MCP obeys policy in acting/planning.

### Skills, memory, and durable data

Skills are global app-managed packages; Settings imports/approved `skill_manage` use the same library/journal.
Immutable application Skill Creator/Installer merge into runtime snapshots, catalog, `/skill` and reads, never
Settings/persistence/sync. Reserved names cannot be shadowed/mutated; existing collisions stay visible and paused
until renamed. No starter seeding/Reset or shipped starter definitions/fixtures. Existing starters remain ordinary
user records, preserving disabled/unchanged content, resources, identities and sync; new libraries start empty.

Acting-only `skill_install` uses Ask/Guardian/Full access. AgentKit pins public GitHub directories to one commit,
bounds/verifies all bytes and rejects redirects/symlinks/submodules/incomplete packages. Run-owned memory staging
binds reviewed source/files/name to invocation/library revision; Termind atomically persists that package plus
Settings intent. No scripts/overwrite; availability starts next run. `skills_list` snapshots inventory;
`skill_read_file` provides bounded SKILL.md or paged reference resources. Only SKILL.md is instructional; supporting
files/frontmatter grant no permission. All mutations are acting-only/Ask/atomic/revision-bound; running snapshots
remain fixed. `load_skill` is historical presentation/replay only. V18 adds package backing while freezing V1–V17;
legacy sync records cannot erase supporting files.

Hermes Memory (持久化记忆 / 持久化記憶) is device-local/default-off. AgentKit owns values, screening, tools, learning and
revocable prompt snapshots; Application owns lifecycle/UI; only Persistence imports GRDB. Its dedicated Application
Support database stores global `memory` (2,200 Unicode scalars), `user` (1,375), frozen conversation snapshots,
learning checkpoints and FTS5 history. SwiftData stays the original conversation source; forks reference snapshots
without copying memory into SwiftData. Tool writes are atomic; background reviews transactionally compare base
state. Skills retain separate approval; memory/credentials never sync. Planning can search, never write memory.

Disable revokes access/snapshots and cancels learning/indexing but preserves storage. User-only Destroy persists
disablement/unfinished marker, revokes leases, cancels/joins work, closes GRDB and removes its owned directory.
Failure stays disabled/retries at launch; generations reject stale writes. Skills, original messages/results and
exports survive. Explicit enable creates a new store and allows full backfill, so old chats may reteach facts.
Disabled startup neither creates nor opens the database.

Tools never get interactive PTYs: exec uses dedicated channels and file tools run-scoped SFTP. User secrets are
single-use handles bound to run/tool/Host/purpose; plaintext never reaches model/review/events/logs/SwiftData.
Pending approval alone projects original arguments via the registered presenter for local inspection; never
record/reuse that projection after decision. Fetch allows proven public HTTP(S), revalidates DNS per redirect,
reauthorizes restricted-origin entry, follows explicit headers like `curl -H -L` and redacts sensitive values.
Remote MCP metadata may only tighten safety.

Each conversation owns a bounded Application Support `AgentScratchWorkspace` rejecting absolute escape, `..`
and symlinks, proving containment and serializing per-path mutation. Termind pull/push moves remote bytes outside
transcripts; edits return diffs, searches bounded previews. Push approval binds size/digest/redacted head and
rejects changed content. Conversations/runs/messages/tool calls/results/reviews persist after redaction/truncation.
Launch marks unfinished runs interrupted, never replaying actions. Restore materializes missing completed results;
unanswered calls get explicit unknown-outcome repair, never an assumption they were undispatched.

## Assistant presentation

Presentation owns tool summaries, batch status, bounded previews, timestamps, Markdown sanitization/soft breaks
and disclosure/deadline state. Hosts inject resolved `AgentToolDetailPresenter` from Remote Infrastructure;
Presentation never imports its transport registry. Protocol results/persisted schemas remain unchanged.

ListViewKit stays app-owned/allowlisted: macOS transcript, large SFTP lists, conversation library and tool sidebars;
iOS transcript/large SFTP lists through UIKit. Bounded navigation/archive pages use SwiftUI `List`. TFM retains
AppKit rows, Markdown caches and edit state; TFI hosts SwiftUI within its UIKit bridge. Presentation-only revisions
explicitly reconfigure mobile rows, invalidate only that height and retain `UIHostingConfiguration` content views.
Display/measurement purpose, Reduce Motion and scene activity cross the host boundary. Only displayed active
content starts timers/scanning; shared scan parameters/three-second reasoning deadlines never restart on reuse.
Work completion follows the shared default only after the entire row leaves the viewport, unless disclosure was
chosen by the reader. Desktop width changes reconfigure mounted rows/constraints/Markdown geometry without
replacing cached lists or following the tail; parsed Markdown survives width-dependent measurement changes.

Direct approval callbacks idempotently stage cards before responses. Queued proposed/approval events update the
same identity without erasing denial, regardless of MainActor arrival order. AgentKit owns UI-neutral skill/memory
result/approval projections. Presentation repairs historical summaries only for recognized local tool/presenter
identities, never MCP/unknown presenters matched by name. Compact previews share 600 characters/five rows across
the card and a scaled 180-point viewport. Window-owned full expansion survives reuse; Copy keeps the full sanitized
projection. Long approvals retain all live arguments in a scaled 240-point scroll region with actions outside.
Neither path reads live skill/memory stores or changes protocol results, authorization or persisted data.

## Pro access and review invitations

App-wide `ProAccessController` owns StoreKit. Permanent Pro is Family Sharing non-consumable; annual Pro is a
Family Sharing auto-renewable subscription. StoreKit supplies eligibility, free/billing periods, localized price,
expiration and renewal. Permanent wins; subscribed/trial/verified grace grants access, billing retry without grace/
expiration/refund/revocation does not. Metadata failure never replaces verified access; retired standalone-trial
transactions are ignored. Recheck expiration on activation and at most minutely while active.
`ProOfferPresentation` derives labels/disclosures/periods from values, never controllers; native paywalls own
purchase/navigation. macOS injects app-language lookup, mobile Apple's bundle lookup, independent of duration locale.

Desktop Workspace composition is free: splits, merge/reorder/duplicate, broadcast, batch open, multi-host snippets
and local templates never depend on StoreKit or sticky launch grants. Template iCloud sync/other Pro features use
current entitlement immediately.

One app-wide `AppReviewController` stores device-local first-use/active-days/version/attempts, never syncs or claims
display. Windows/scenes share surface policy; apps own native focus/input/pointer/lifecycle/modal observation.
Automatic review requires seven elapsed days, three active dates, five foreground Workspace minutes, then three
quiet seconds entering a Vault list or Settings index/App. Input/navigation/focus loss/sleep/modal cancels.
Persist attempts before StoreKit; once per marketing version and 120-day cooldown, restarted by manual review.
Tests/screenshot launches disable live requests.

## Server metrics

App-owned `ServerMetricsModel` shares one serial SSH sampler per saved Host across windows/menu bar/mobile.
Rows precede secrets/network and represent connecting/collecting/live/paused/sleeping/actionable failure.
Detached workers enter short synchronous MainActor state steps, never long-lived observable/host-store async
methods. Credential lookup/I/O stays off actor; recheck cancellation after lookup and clear secrets on pause/
removal/termination. Trust/credential interaction belongs to the active monitor. Screenshot launches inject frozen
in-memory metrics into the production WindowGroup with restoration off: no saved config, samplers or discovery.

Infrastructure reads bounded Linux procfs/optional hardened `nvidia-smi` XML. Base data survives GPU/process/filesystem
failure; invalid deltas are unknown. Rates use remote uptime, identity PID+start time, RSS remote page size; collect
no arguments/environment. Five-minute samples stay in memory; order/pause/device selection persists. Details alone
enable process/filesystem collection and capacity refresh. Default network aggregation prefers physical interfaces;
explicit selection overrides it.

Read-only/parallel/planning-safe `get_metrics` exposes existing Sendable snapshots to Agent/authenticated MCP,
validating Host IDs, preserving section time/age/staleness, using null for unknown/nonfinite values and limiting
processes to 20. It cannot add/sample/observe details/read auth; monitoring itself does not depend on AgentKit.

Metrics order syncs separately from Vault; layout/sort/search/detail navigation/menu visibility do not. Authentication
uses shared Journey while the coordinator owns transport. Each monitor supplies its own keyboard-interactive queue,
including jumps, never app sheet/external-window fallback. Cards signal auth without navigating; opening presents
Journey. Leaving details retains challenges; explicit cancellation pauses and returns that window to the list.
Retirement cancels queued/not-yet-enqueued responders; generation/request IDs isolate answers/cleanup. Temporary trust
clears on pause/removal/config change; rejection pauses. Free access atomically permits three cards including paused,
never deleting restored cards on downgrade; Pro/trial is unlimited.

macOS process-owned status item/popover receives the model explicitly. Last-window close keeps the app alive for
menu/monitors; Quit cancels. System sleep and inactive login independently suspend; resume only awake/active when
Data Protection Keychain is available. Native lifecycle, reopening, input and screenshot wiring stay in `TFM/Platform`.

## Settings replication

Master iCloud plus independent Vault/Metrics/Settings choices default on/on/off; disabling master preserves choices
and upgrades never re-enable. Pro gates independent `TermindVaultV1`, `TermindMetricsV1`, compatibility-named
`TermindAIConfigurationV1` coordinators. Each composes its own Infrastructure `CloudSyncLifecycle` for serialized
operations/generations, consent, engine creation, fetch-before-send, pause/retry, resets and status precedence.
Value-projected journal adapters preserve Persistence-only model/schema ownership. Zones/subscriptions/switches/
account bindings/journals/engines remain independent; categories own coding/quarantine/merge/version acknowledgements.
Settings authorizes secret upload only after successful current-engine fetch and revokes on pause/account retirement.
Old operations cannot clear replacements or publish late results; the internal transport seam enables offline
deterministic lifecycle tests.

Frozen V13 Settings shapes remain; V14 adds `PersistentTerminalPreferences`, V15 independent Metrics journal/account/quarantine,
V21 `PersistentSFTPPreferences`. Settings commits data/upload intent atomically. Separate records cover providers/models,
MCP clients, skills, roles, Web Search, terminal/custom text and SFTP limits. First SFTP row imports existing defaults
(including 3/2), missing values 15/5; preparation adds missing baseline even to bootstrapped stores. Later preparation
uses persisted truth, never reimports mirrors. `v1/sftp/default` uses distinct `SFTPPreferencesItem` in the same zone;
older clients ignore its type before decoding. Other settings retain `AIConfigurationItem`; both keep V1 envelopes.
Invalid limits/type mismatches quarantine at read. Local saves commit intent then mirror defaults; remote application
refreshes models without local echo. Last-used conversation model stays local; active Agent snapshots remain fixed.

Roles always have live synced records: nil Command Generator = Same as Chat, nil Guardian = Automatic; explicit Chat
syncs, resolved fallbacks do not. Accept legacy `securityReview` only at CloudKit read, migrate to `guardian` without
reusing system fields, write canonical IDs only. Conversations, approval mode, local MCP listener config and unrelated
defaults never sync. Listener switches/port/tools use defaults, token this-device-only Data Protection Keychain.
Provider/MCP secrets use `AISecretStore`; migration requires verified account/cloud copy/durable local marker. Reads
never cache; deletion markers prevent late Keychain resurrection. Custom MCP headers/terminal text sync as ordinary
settings; explicit credentials never enter CloudKit.

Journals retain tombstones/unresolved references through partial fetches; cloud beats baseline defaults. Application
skills stay excluded; user-owned starters/deletions survive migration. Duplicate skill names/MCP namespaces retain
all data but only lowest UUID executes. Metrics keeps one versioned record/Host, hides records without Vault Hosts,
and excludes samples/prompts/secrets/UI preferences.

## Mobile boundaries

### Adaptive navigation and native surfaces

Each window owns one sidebar-adaptable TabView with five stable stacks: Vault, Metrics, Workspaces, Assistant,
Settings. System adaptation never replaces the root tree; resizing preserves selection/children/search/scroll/
sheets/drafts/connections/transfers/runs/conversations. Metrics has one independent stack; Vault shortcuts select it.
`MobileFeatureRegistry` injects stable IDs/labels/symbols/factories and one tab/sidebar order; duplicate IDs fail
immediately, with no global singleton or separate shell switches.

Each feature stack derives toolbar policy from actual tab-bar placement/system preferred vertical edge; features
consume that single policy, never device capabilities. Workspace detail retains app tabs beside top/vertical bars;
bottom tabs hide in SSH/SFTP when vertical toolbar is unavailable. Workspace/Assistant use `rectangle.stack` peer
switchers at top/vertical bars, title menus elsewhere, distinct from app tabs. Assistant icon remains disabled with
no pinned/active chats; its title has no menu. One current chat enables switching, archives do not; library titles
remain. Metrics uses vertical labeled-icon menu or horizontal principal segmented picker, hiding both when panels
coexist. iOS 27 uses `ToolbarOverflowMenu`, older OS labeled menus. Save stays labeled with form progress. Native
minimized SSH/SFTP search stays in every placement; sidebar/pose changes never activate search or claim focus.

When built with the iOS 27.1 SDK, iOS 27.1 content reads active division/occlusion ReservedRegions after
safe-area/keyboard layout. Frames include
margins and follow SwiftUI's leading-origin convention, including RTL. Terminal/shortcuts/notices occupy the largest
continuous unobstructed rectangle, ties top then leading. Ghostty resizes the existing PTY and rejects invalid
viewports; session ownership survives pose. Assistant keeps one transcript and one scrollable interaction surface
mounted, including tasks/approvals/questions, placing them across fold regions or stacking with one region. Metrics
keeps both panels mounted at last valid sizes with list/sort/scroll identity, one per usable fold region or selected
page with one; without folds use the 700-point threshold. Region/native-identity tests preserve navigation, drafts,
focus and session ownership.

Save tasks, duplicate-submit prevention, dirty-dismiss confirmation and errors survive layout changes without
gating them. Stable sheet modifiers track window width. Cards use container width/one accessibility column;
SFTP breadcrumbs fit three or two trailing components. Device idiom never drives production layout. Navigation/
drafts stay memory-only and window-independent. Application derives Host/Snippet sections once; Presentation owns
History subtitles, Vault sync/transfer labels and exported SFTP drag type. Running labels distinguish upload/download,
completed labels upload/download/copy; other states use Domain labels. Apps retain native composition/selection/menus/
clipboard. Host Picker/Snippet operation state belongs to mobile Application; descriptors use Domain
`ConnectionHistoryEntry.Kind`, samplers enter via `MobileMetricsServices`, and both apps use Remote Infrastructure
`AgentHostServices` for host resolution/auth/connections/background commands.

### Workspaces, restoration, and activity

Mobile has no Welcome or pane composition, even with Pro: one SSH/SFTP session per Workspace, independent Assistant.
Peer switching preserves connections; Recent selection creates/connects on demand. More owns Rename/Close and
cross-open SSH/SFTP with live paths; explicit close never retries. Initial failure/recovery stays in Journey.
Background expiration closes transports but retains intent; foreground resumes existing Workspaces.

`mobile.workspaces.v1` stores ordered device-local descriptors (stable ID, Host ID, kind, title, duplicate index),
never commands/credentials/paths/terminal contents/transfers. After Hosts load, cold launch fills Recent only,
creating no sessions/connections/history. One MainActor open-by-ID reuses or registers/connects the requested entry,
preserving ID/history-once across scenes; failures need explicit retry. Current/unopened entries share one saved
order, and saving live instances must not discard unopened records.

Read legacy arrays/version-1 envelopes; missing duplicate indices get lowest free Host/kind indices in array order,
reserving explicit ones, then immediately write the envelope even if empty. Only successful loads allow saves.
Prune absent Hosts; corrupt/unknown-version bytes remain and block writes until successful load. Close/normal SSH
exit/Host delete removes current and unopened entries; Close All also clears Recent, not connection history. History
actions create new sessions and its section shows only when current/Recent are empty. Titles reserve indices across
both; manual names keep allocation and closing releases without renumbering. Shared Host-delete outbox cancels
sessions/transfers/forwarding/local history.

One serialized Live Activity represents current Workspaces only, counts and at most six distribution icons.
Validated secret/command-free links select ID/list without restoring unrelated sessions; cold launch ends leftover
activities but their URLs may restore a saved entry. Explicit open retains start intent until foreground permits;
last current close ends activity/intent even with Recent entries. Ordinary foreground cannot recreate a dismissed
activity after intent consumption. Immutable snapshots stay separate from observed Workspace/Vault state; start/
update/end share one queue and never keep SSH/Agent alive. Stale links show list/unavailable explanation. Restoration
cannot distinguish system termination from force-quit.

### Scene services and interactions

Settings exposes App, Terminal, SFTP, AI, Sync; synchronized macOS window-title setting has no mobile control and
Live Activities has no settings page. AI order: Models, Skills, MCP, Hermes Memory. Skills/MCP use explicit drafts;
ephemeral tests/discovery cancel on editor/config changes and cannot revive discarded drafts. Secrets stay in memory
until atomic save with rollback on metadata failure. Mobile never starts the local MCP listener.

Each scene owns navigation/commands and Assistant library, selection/New Chat draft; runtime/conversation store is
app-wide to prevent duplicate runs. Focused values route keyboard commands to that scene. Per-window delegates
consume Home Screen actions once; Connect is static and up to three dynamic history actions use the shared log.
History/quick actions display newest Host/kind rows without deleting events. Shared capabilities use desktop
shortcuts: navigation, connect/create, Find/Command Generator, close/switch, Assistant send/stop. Switching never
reconnects or claims terminal focus. UIKit owns F3/Shift-F3 and overrides Ghostty bare/Shift-Escape only during Find;
otherwise Escape passes through.

Agent runs outlive pages with independent conversation drafts/runs. Archive persists metadata before navigation
and stays read-only until restored. Injected attachment/speech services append speech without sending; interruption,
conversation change/background cancels it. Shared tools/permissions/secrets retain desktop-independent policy;
finite background expiration cancels runs, drains events, closes Agent transports and never replays/auto-approves
on foreground.

File drops share native routing/loading policy. Visible Workspace bounds register a window drop interaction;
terminal forwards files there instead of Ghostty local-path paste, while text/web links keep Ghostty behavior.
Leaving restores the original interaction/clears targets. File-provider data is copied inside callbacks to app
staging, retained by queued transfers after navigation.
