# Termind architecture

Termind is one Xcode project with macOS (`TFM`) and iOS/iPadOS (`TFI`) apps,
shared static frameworks, platform test targets, and a macOS-only MCP bridge.
The agent runtime is the separately versioned `AgentKit` package.

## Modules and dependency direction

- `TermindDomain` owns platform-independent values and rules. It may use
  Foundation, CryptoKit, and AgentKit values, but never UI or concrete I/O.
- `TermindApplication` owns repository ports, feature models, connection policy,
  SSH preparation/import previews, remote-file-system interfaces, sync/outbox
  coordination, and other use cases. It depends on Domain and AgentKit.
- `TermindInfrastructure` owns in-memory repositories, metrics parsing, StoreKit,
  and the shared Vault/Settings/Metrics CloudKit coordinators. It depends on
  Application, Domain, and Persistence.
- `TermindRemoteInfrastructure` owns SSH/SFTP, Keychain, key material, remote
  sampling, forwarding, transfers, and scoped SSH import reads. Its C libraries
  remain outside the portable framework-test graph. It depends on Infrastructure,
  Application, and Domain.
- `TermindPresentation` owns reusable SwiftUI content, presentation policy,
  Ghostty themes, and the `TerminalPreferences` bridge. It depends only on
  Application and Domain; native surfaces, transports, and lifetimes stay in apps.
- `TermindPersistence` exclusively owns every SwiftData model, frozen V1-V18
  schema, migration plan, and container factory. It never depends on an app target.
- `TFM` and `TFI` own platform UI, adapters, and lifecycle orchestration. Both use
  `App`, `Application`, `Design`, `DesignSystem`, `Features`, `Infrastructure`,
  `Platform`, and `UI`; frameworks never import either app.

Frameworks expose explicit public APIs and do not re-export imports. Apps import
canonical owner modules directly, without forwarding aliases or `Shared` type
names. There is no generic Core module.

Persistence preserves entity identities, fields, defaults, and historical schema
semantics even when code moves. Original-module V1/V14 fixtures guard migration.
`makeContainer` fixes the complete schema and migration plan; each process shares
one container across its scenes. Store failures never silently recreate data.
macOS retains the existing `Termind` store location; mobile uses Application
Support and an in-memory store for tests. Both apps use the same CloudKit container
and bundle-derived Keychain access group, with target-specific signing.

Shared localized resources are copied into each app bundle. Platform icons and
metadata remain app-owned. Framework, macOS, and mobile tests stay separate;
architecture tests fail closed when an expected production directory is absent or
empty. Source-based checks are limited to module dependencies, native-list import
allowlists, AgentKit type ownership, and SwiftData model ownership. They do not pin
UI copy, source layout, call-site spellings, retired paths, or shared-component wiring;
those concerns rely on behavioral tests or explicit visual review.

## State, navigation, and ownership

Single-line UI fields share Presentation's newline-to-space editing policy and
horizontal layout. Binding reads preserve stored values; only edits are normalized.
App-owned native rename editors apply the same policy without interrupting marked
text. Platforms inject app-owned single-line paste adapters so normalization happens
before native controls flatten individual line breaks. Multiline content and secrets
are excluded. Existing validation is unchanged. No persistence migration or bulk
cleanup is performed.

- Repository snapshots and preference models are application-wide. A window owns
  its shell, quick-open, search, navigation, and context-panel state.
- Desktop main scenes each own a distinct `WindowModel`. The process-owned main
  window coordinator routes UUID-scoped scene requests and weakly tracks native
  windows. Creating a window starts on Welcome; Dock reopening preserves the
  existing destination, while the Metrics entry explicitly selects Metrics.
  Restoring a scene never restores or reconnects live Workspaces.
- A Workspace can move intact to a new window through commands or a Navigator
  drag released outside visible app windows. Native drag cancellation and accepted
  internal drops never tear off. Private drag data carries no text/file export.
  The destination must register before the MainActor transfers ownership; moves
  preserve native terminal surfaces, transports, split geometry and session state,
  and do not enter close history. Empty source windows remain on Welcome.
  Native window closure explicitly disconnects only its owned sessions, cancels
  pending moves, and unregisters it. Independent transfers and application-owned
  services retain their existing lifetimes. Mounting a session cannot restart
  an attempted connection or authentication; explicit retry/reopen still can.
- Paywall presentation is pinned to one main window until dismissed. Speech input
  ownership belongs to a composer instance, not a shared conversation ID, so
  closing another view of that conversation cannot cancel the recording.
- Desktop navigation starts with Vault and Assistant, places Metrics above Vault
  libraries, appends dynamic SSH/SFTP Workspaces, and ends with Settings. Vault
  owns Hosts, Keychain, Snippets, Known Hosts, Welcome, and Host Editor routes.
- Desktop main pages share a 360-point detail minimum, independent of the
  Assistant's 840-point reading maximum. Opening the Navigator grows the window
  when necessary. Vault overlays its existing editor below 721 points and keeps
  the covered list mounted at its last visible size; Metrics stacks its existing
  detail and process views below 630 points. Resizing changes layout, never route,
  editor identity, Workspace composition, or monitoring ownership.
- Assistant conversations are owned by `AssistantLibraryModel`; they are not
  Workspace panes. A Workspace owns SSH/SFTP/serial panes and any session-scoped
  conversation. A session owns live transports and terminal/browser state.
- Assistant list ordering and pinning are metadata-only operations, independent
  of running, approval-waiting, or compaction state. Desktop drag and pin commands
  preserve the live conversation instance and commit ordering before publishing
  it. Archived chats cannot move, rename editors cannot drag, and archive/delete
  retain their active-run and compaction guards.
- Settings data is app-wide but its navigation is window-scoped. Opening Settings
  remembers and later restores the replaced destination.
- Feature-specific Application models expose narrow intent surfaces even when they
  share one Vault snapshot. `VaultStore` owns the transaction; sessions use
  `RemoteSessionHostStore`, never the full mutation API.
- Runtime connection state is never written onto domain records. Saved repository
  data is persistent truth; device-local enabled forwarding intent is UserDefaults
  state and is excluded from Vault/Metrics/Settings sync.
- Serial sessions are temporary and local. IOKit/termios objects remain in
  Infrastructure; serial paths and parameters are neither persisted nor exposed
  as Agent hosts.
- Workspace templates are Vault-synced domain values. They preserve a named
  SSH/SFTP/empty-pane split tree and divider fractions, while TFM alone maps
  those values to live Workspace sessions and UI. TFI carries the records for
  sync but exposes no template surface. Missing saved hosts restore as empty
  panes so the stored layout is never collapsed.

Known Hosts is independent of Host records: editing or deleting a Host does not
change trust. Plain and OpenSSH `|1|` hashed endpoints share one matcher; hashed
records keep their wire `hostname`, and their separate port field is ignored.

SSH imports recursively classify files by content and stage only selectable public
metadata in a window-owned model. Hosts, identities, and keys form an indexed preview:
an imported identity requires its selected key, while a host uses an exact existing or
selected imported identity and otherwise remains unbound. Selecting a host never selects
credentials. The actor reader retains scoped source descriptors and content digests,
never private-key text or passphrases; it rereads selected keys transiently at
unlock/commit and fails closed if a source changed. Picking and drag-and-drop use the
same scoped validation; config parsing never executes commands. Commit writes new
credentials before one Vault save, cleans them up on failure, never overwrites existing
records, and never clears an existing trust mismatch.

App appearance is a global UserDefaults preference applied by the macOS app
delegate through `NSApplication.appearance`; following System clears the override.
Opening at login reflects `SMAppService` on every Settings visit rather than a
mirrored preference. A quiet login hides the app without suppressing its window.
macOS owns an explicit in-app language preference. Mobile delegates language selection
to Apple's per-app Settings and never stores or injects its own locale override.

## Remote sessions, terminal, and files

SSH, SFTP, mobile Workspaces, and Metrics share connection preparation and recovery
policy. Interactive host-key approval remains inside the actual transport attempt:
the same socket/libssh2 session continues from handshake through approval and
authentication; callers never perform a separate discovery connection.
Generation tokens prevent callbacks, credential results, and retry timers from a
retired connection mutating its replacement.

An Identity's device-local `lastUsedAt` means its saved password or private key was
successfully read for connection setup, not that remote authentication succeeded.
Connection-specific resolvers batch those accesses across destinations, jump hosts,
and authenticated proxies; missing secrets and ordinary Keychain availability or
editing reads never update usage. The first access for each Identity in an app process
is written directly to its SwiftData row without entering the Vault journal or repository
refresh path. Later retries are deduplicated, and Vault sync strips this local metadata
while preserving it when applying remote Identity configuration.

The SSH worker's serial queue owns PTY dimensions. It retains the latest valid
viewport during authentication and uses it for the initial PTY request, including
pixel dimensions. Nonblocking window-change requests retain their original size
through EAGAIN; the pump finishes that packet before sending the newest viewport.
Other channel I/O continues so an earlier blocked write can finish. Disconnect and
connection failure clear resize state, and a retired authentication attempt cannot install a
PTY or clear its replacement's pending dimensions. Ghostty remains the source of
grid measurements; platform layout callbacks never compute remote rows or columns.
Window-change failures are diagnostic logs, not connection failures or UI alerts;
the failed packet is discarded while newer or subsequently requested sizes can proceed.

`RemoteFile` is a Domain value, `RemoteFileSystem` the Application port, and the
libssh2 `SFTPClientProtocol` its Remote Infrastructure implementation. File symbols
and localized kind names belong to Presentation. `MobileSFTPSessionModel` owns
path, listing, navigation history, filters, mutations, and stale-request state.

`TerminalCommandDraftController` owns draft requests, timeout, cancellation, and
bracketed-paste payloads. `CommandGenerationCoordinator` adds model timeout,
snapshot freshness, and presentation state. Platforms provide live context,
validity, and insertion only; generated commands are inserted but never submitted.
`TerminalFindController` is shared by desktop SSH/Serial and mobile SSH.

macOS SSH and serial terminals share two default-off mouse preferences: copy a
completed mouse selection and paste on right-click. They use the existing terminal
Settings sync record and UserDefaults mirror; missing fields in older records decode
as false. Mobile preserves the values without exposing or applying them. Preference
changes update the persistent native view without rebuilding its Ghostty surface.
Only a local mouse selection completion triggers automatic copying. A right-click
chooses its route on press and pastes once on release through Ghostty's clipboard
binding inside interactive input capture, preserving bracketed paste and broadcast
routing. Remote mouse capture and Option-right-click retain Ghostty's original
handling, and mouse reports never enter the broadcast input capture scope.
Empty clipboard pastes do not arm deferred input capture. A captured bracketed paste
retains its classification across callback chunks until its closing marker; an
interrupted sequence expires with the existing short-lived input ticket window.

Mobile SSH sends shell-integration and transport-exit callbacks through one ordered,
session-scoped MainActor consumer. Close, reconnect, or background expiration ends
it. Authenticated installation and command completion establish prompt readiness;
following prompt markers are idempotent. Bash DEBUG fallback passes `BASH_COMMAND`
and ignores Termind's `__termind_*` helpers so draft protocol traffic never creates
History rows or marks the prompt busy.

Command History begins only after an authenticated start event. Completion may add
remote exit status and duration; both remain optional and duration is never inferred
from client receive time. Explicit backslash continuations are stored with each
boundary normalized to one space; other line breaks remain part of the command while
desktop and mobile History rows show only the first line with an ellipsis. History is
capped at 1,000 rows per host.

SFTP History is device-local persisted truth shared across apps. Directories are
recorded only after a fresh successful listing and files only after download.
Failed, cancelled, stale, missing, or type-changed operations do not update it.
Transfers own dedicated connections and outlive browser closure. Upload/download
checkpoints, file references, acknowledged offsets and incremental digests live only
in memory. Pause and connection loss retain the destination partial file and release
the connection; explicit resume verifies the source and partial prefix before seeking.
Ordinary transfers add no source staging, bookmark persistence, or restart recovery. Cancellation
and host deletion remove partial files, reporting a path if cleanup fails. Mobile
background expiration pauses uploads/downloads and cancels remote copies; borrowed
session retirement still cancels its transfers. macOS termination gives asynchronous
cleanup at most three seconds, so an unreachable server cannot hold up quitting.
Nothing is silently replayed.
Desktop and mobile upload/download and remote-copy preparation and enqueueing use
Remote Infrastructure planners. Download batches retain their destination independently
of file jobs, so directory-only selections still create their empty directory trees.
Remote-copy enqueueing reports directory mutations so desktop refreshes also cover
copies without file jobs. App sessions retain pending-batch presentation, cancellation,
error handling, and completion refresh; interactive browser deletion stays app-owned.
Upload and remote-copy conflict resolution share one Remote Infrastructure resolver
over `RemoteFileSystem`. Upload retains strict-descendant preflight counting while
copy also suppresses the conflicting root itself. Both use the same subtree mapping,
Keep Both naming, cancellation checkpoints, and recursive child-name/path validation;
created-directory accounting remains available to awaited copy outcomes.

SFTP external edits have one process-local Application model per app, independent of
browser/workspace lifetime. Remote Infrastructure owns managed local copies, streamed
SHA-256 checks, file/directory observation (including atomic-save replacement), and
immutable upload snapshots. Snapshots are an edit-specific exception to ordinary
transfers' no-staging rule; paused uploads retain them and terminal completion removes
them. Editing never automatically uploads. Only changed records appear in the floating
bottom overlay; clean records remain internal so repeated opens reuse their local copy.
The edit card overlays the full-height file viewport with native Liquid Glass on OS 26
and later, and native material on older systems. Its row container stays transparent and
the rounded glass is a separate backdrop, so file rows remain visible around and through
the floating card. Only the scroll content gets a bottom inset, so files scroll behind the
glass while the last row can still clear it; no blank safe-area region is reserved for the
card.
Discard stops tracking and preserves the local copy for any external editor; the next
remote open downloads a fresh copy. iOS exposes Discard through native trailing swipe
actions, and both platforms expose it in the row menu. Running/preparing uploads cannot
be discarded; paused uploads are cancelled and cleaned up before their record is removed.
Hosts own activation, background, termination and native preview/open adapters.
The macOS edit menu uses ordinary menu actions; Keep Local Copy delegates to an app-owned
save panel and coordinated file copy instead of embedding ShareLink in the native menu.
macOS checks edits before quitting; iOS cannot promise a quit warning or recovery after
process termination. Background expiration still pauses uploads, with explicit resume.

Edit upload policy validates the original destination's kind, size, modification time
and mode both before writing and immediately before remote rename, preserving its
permission bits on the temporary file. Overwriting commits use the OpenSSH POSIX rename
extension; standard rename is used only when the extension is unsupported. Ordinary
non-overwriting renames never use that extension, and failures never unlink the original
as a replacement workaround. This is a best-effort metadata guard, not atomic
compare-and-swap against unrelated remote writers. Missing metadata or changed/missing
files require explicit confirmation; nonregular destinations fail closed. Successful
commit acknowledges only the snapshot digest, so later saves remain dirty. Host removal
or route changes invalidate old records without deleting their editable local copies.
There are no extension allowlists: SHA-256 compares all regular-file contents. The iOS
Quick Look delegate enables native editing where supported, receives in-place updates
and takes ownership of temporary edited copies. Different-format copies are exported
separately instead of overwriting the original remote format. Shared Presentation owns
the dirty-file card; AppKit/UIKit and their lifecycle adapters stay in their apps.

Open With uses the same managed edit copy as ordinary Open. macOS discovers applications
by UTType and launches the one selected for that invocation without changing defaults.
iOS retains Quick Look as its primary action and uses a workspace-owned document
interaction controller for Open With; retired/background presentation requests cannot
surface a late download in another workspace. The controller survives scene deactivation
until an in-progress document handoff finishes. Receiving apps may edit an independent
copy, so mobile offers explicit same-format edited-copy import into an existing record.
Import preserves the original remote identity and baseline, rejects invalidated/busy
records, and only marks local changes; the existing explicit upload/conflict flow commits them.

`sftp_copy` is Termind-owned and acting-only in Assistant, with Ask/sequential
policy. It copies regular files and directory trees into an existing directory;
unsupported descendants fail before writes. Its awaited operation shares browser
manifest and conflict helpers, including directory merging and destructive type
replacement. Source data is never deleted. Batches are not atomic: failures retain
completed items and disclose the failing path and completed counts.
Two dedicated SFTP leases use the same authenticated connection opener as other
Agent tools, but are neither pooled nor idle-swept. Their shared cancellation token
is cancelled by host deletion, transport shutdown, or caller cancellation. Leases
remain tracked while opening and are always disconnected after use. Credential
retries apply only to acquisition, never to an operation that has started.
Socket-relayed copies require successful source EOF and an exact byte count before
the remote temporary file is committed. Cancellation shuts down the relay to unblock
socket I/O. No scratch staging, local temporary file, or model-visible payload is used.

The macOS MCP Server exports the same `sftp_copy` definition without a scratch
workspace. Its existing Bearer token/tool switches and Full access execution remain
the authorization boundary; SSH credentials and host keys still use external
authentication. The tool is annotated as state-changing, potentially destructive,
non-idempotent, and open-world. Session termination/server shutdown cancels and awaits
active copies. Audit consumes byte progress and final counts only, never file bodies;
the summary records both endpoints and the conflict policy. The stdio bridge remains
a protocol-only forwarder. Mobile exposes Assistant tools but no local MCP listener.

The macOS MCP server also owns a separate HTTP-to-SFTP byte channel. `sftp_upload`
issues a ten-minute, session-bound 256-bit capability bound to its MCP session, host,
full remote path, size, SHA-256, and overwrite intent. `sftp_upload_status` reads
only that session's bounded in-memory state. Upload PUTs authenticate their own
capability before consuming the body; ordinary MCP retains its 4 MiB body limit
and long-lived Bearer authentication. Both routes remain loopback-only. Capabilities
are headers, never query parameters, durable audit data, or long-lived credentials.

HTTP bodies are consumed in bounded chunks with socket-relay backpressure and no
local file staging or scratch access. Remote Infrastructure owns the HTTP-agnostic
stream operation and dedicated SFTP lease. Exact byte count and incrementally
verified SHA-256 authorize source EOF; only then may the remote temporary file be
closed and committed. Existing directories cannot be overwritten. Failed cleanup
reports the potentially remaining remote temporary path. Interrupted writes retain an in-memory checkpoint and a remote partial file.
Status exposes `upload_offset`, counting only acknowledged remote writes. A sequential
retry must send `Upload-Offset` equal to it and a Content-Length covering the remaining
suffix; parallel claims are rejected. The full-file digest includes the verified
prefix. Completed writes are never replayed. Session retirement, host deletion, tool disablement, server shutdown, and
token rotation cancel live work; active uploads prevent idle session expiry.
A completed remote commit stays successful even when its HTTP response is lost.
Retained upload completions also keep an otherwise idle session queryable for
thirty minutes; terminal records are globally bounded to 256 entries.
Metadata-only HTTP upload audit rows are independent of ticket-creation audit rows.
No sandbox entitlement, persistence schema, or AgentKit dependency change is needed.

`sftp_download` issues the reverse resumable HTTP capability, bound to the session,
host, full remote path, and optional expected SHA-256. Ticket creation performs no
remote I/O. GET authenticates and atomically claims before connecting; it supports
regular files only, with no query credentials, request bodies or HEAD. A single
open-ended `Range: bytes=N-` returns 206 and Content-Range, while an out-of-bounds
offset returns 416 without consuming the ticket. The client chooses N from its
actually saved bytes, not server send progress. A bounded prefix reread verifies
previously read bytes before response headers and reconstructs the full-file digest;
source metadata changes or prefix mismatches reject resumption. A dedicated SFTP lease opens a checked `SFTPDownloadStream`; the worker
owns its handle IDs, native pointers, and queue. FSTAT on the opened handle fixes
the reliable declared size, and EOF verifies exact byte count plus the final size
and available modification time. This is not an atomic remote-file snapshot.

The HTTP file-response body is pull-based, reading at most 64 KiB only after the
previous network send completes; it never uses the SSE AsyncStream or local
staging. SHA-256 covers actual transmitted bytes. A terminal success requires
source validation, full HTTP sending, checked handle closure, and dedicated lease
release. Pre-header failures return safe JSON; post-header failures close the
connection without appending JSON or changing the announced status. Clients must
poll `sftp_download_status`, compare local size/hash, and finalize their own file;
HTTP 200 and Content-Length alone are not proof of success or local persistence.

Upload and download share one four-active-transfer budget. Each direction retains
at most 64 unfinished capabilities (including paused attempts) and 256 terminal
records for thirty minutes. HTTP disconnect and recoverable SSH failure pause a
transfer; explicit revocation still cancels it. Retries require the original active
session and unexpired capability, and neither checkpoints nor capabilities survive
process exit. Generation IDs prevent old transport callbacks affecting a new attempt. Both
directions share session/host retirement, server-stop, token-rotation, and activity
boundaries; disabling one direction revokes it immediately. Capacity is released
only after cleanup. HTTP download audit rows are independent of MCP ticket calls
and retain only endpoint metadata, sent byte counts, and terminal state, never
file bytes or capability tokens. The existing upload and stdio bridge remain intact.

## Callback isolation

Speech services and coordinator state are MainActor-isolated, but authorization
callbacks may arrive on any queue. A nonisolated factory creates an explicitly
Sendable continuation callback; dispatching from an actor-inherited closure would
trap before its body runs. The coordinator rechecks its recording-session token
after authorization so a late result cannot revive a cancelled session.

iOS Core Audio taps follow the same rule: a nonisolated factory creates the realtime
tap block, which calls only Sendable buffer/level handlers. Reconnect timers and
metrics workers also enter explicit MainActor methods rather than relying on
inherited task isolation; remote I/O stays behind asynchronous/detached boundaries.

## Agent runtime and security

Model-provider credentials are optional on macOS and mobile. An empty credential
reference means anonymous requests; a nonempty reference whose secret is missing,
empty, or unreadable remains an error. `AIConfigurationModel.modelSecret(for:)`
shares this distinction across discovery, probes, Chat, Guardian, titles, compact,
Command Generator, and Memory review. Anonymous resolution never reads secret
storage or inherits another provider's storage error. Vertex still requires its
service account and a valid project/location. AgentKit omits empty authentication headers for ordinary providers.

Model-provider forms show protocol-specific Name and URL hints, not prefilled input.
A shared Domain policy materializes blank/whitespace fields at the Application save
boundary: Automatic stores OpenAI's full Responses URL; explicit protocols store
OpenAI/Anthropic v1 or Google v1beta bases. Nonempty input never falls back or changes
on a type switch. Runtime reads never infer public destinations for legacy empty rows.
Desktop keeps page-owned input buffers while saving concrete defaults immediately;
mobile previews a normalized copy and normalizes again after conflict merging at Save.
Reopening shows saved values. Merely viewing or editing a form does not contact a provider.

Explicit generateContent offers a Vertex AI toggle. Project, location (blank saves
as global), and service-account identity are independent of the retained ordinary
URL/API key. Leaving that type disables Vertex without deleting its configuration.
Missing Vertex credentials never fall back to an API key or anonymous access; Vertex
models are manually added. AgentKit owns address derivation and OAuth token exchange.
File/paste import validates bounded service-account JSON and trusted Google token URLs;
plaintext stays in transient drafts and AISecretStore. Two-reference credential edits
compare their original values and roll back all changed secrets on metadata failure.
Deletion removes both references; disabling Vertex removes neither.
V19 adds independent PersistentModelProviderVertexConfiguration backing without changing
V1-V18 entities. Settings sync carries only metadata/references, preserves existing
Vertex metadata when an older payload omits it, and respects explicit clears and deletes.
The existing Keychain migration covers both references; no private key enters CloudKit
configuration. Vertex data already discarded by V12 is not reconstructed.

Both apps accept user-selected HTTP and HTTPS model endpoints. Their ATS arbitrary
loads exception supports unknown user-configured domains, including local servers;
HTTPS keeps default certificate trust evaluation. No local-network ATS exception
may override that setting. Local-network usage descriptions are localized. App Store
review notes must explain that users configure arbitrary self-hosted model servers,
including HTTP endpoints which the app does not own and cannot upgrade to HTTPS.

`AgentKit` owns the provider adapters, loop, approval gate, MCP client, and built-in
host-agnostic tools. Termind owns everything that reaches its machines or people:
SSH/SFTP tools, connection pools, Vault resolution, persistence, policy, and UI.
The additive seams are:

- `AgentToolCatalog.registry(builtIn:additional:)`: AgentKit groups first, then
  `TermindAgentTools`; Termind and remote MCP tools cannot shadow built-ins.
- `ChatSlashCommandRegistry`: one registration owns a command's platforms,
  availability, options, current-value presentation, and execution. Desktop and
  mobile composers inject only host navigation, compaction, send, and access actions.
- `AgentToolServices`: typed host services, including `AgentSSHInteraction`, keep
  credentials and host-key prompts outside AgentKit events and durable history.
- `TermindAgentPolicy`: Termind's prompt, plan contract, and `ssh_exec` decision;
  stable prompt prefixes preserve provider caching.
- `TermindAgentPresentation`: Termind-only card values whose stable raw values keep
  persisted cards decodable.

`AgentRuntime` is an actor. `AgentContextPipeline` shapes only model requests;
stored history remains complete. `AgentTurnDriver` streams a turn,
`AgentToolScheduler` runs its batch, `AgentToolExecutor` performs schema validation,
preflight, card creation, hooks, authorization, then execution, and
`AgentEventChannel` serializes UI and durable events. Provider adapters include
OpenAI Responses/Chat Completions, Anthropic Messages, and Gemini. Models without
tool capability receive no tools; only recognized chat-purpose models appear in
conversation pickers, and unknown purpose values safely default to chat.
Ordinary planning and acting runs have no turn or tool-call count ceiling; they end
when the model finishes, the user stops, a hook terminates, or an error occurs.
Guardian remains separately bounded so unavailable or inconclusive review fails closed.
Compact, conversation titles, and Command Generator use AgentKit's buffered-result
interface over streaming transport, not `stream: false` requests. They collect
validated results before applying them and never expose intermediate fragments.
Buffered SSE responses require a terminal marker and are capped at 16 MiB of raw
response bytes; cancellation, malformed data, and premature EOF discard partial
results. Ordinary agent streaming retains its existing execution policy, and
providers returning complete JSON remain supported.
Each ordinary model turn retries only transient provider transport/service failures
five times at 1/2/4/8/16 seconds. A retry reuses the logical message and request,
abandons its partial presentation, and cannot replay a tool because tool dispatch begins
only after a complete model response. Retry progress is ephemeral; final run failures
remain durable and render as error rows rather than assistant-authored text.
AgentKit's callable `fetch` and `scratch_fetch` tools are `.ask` because each
contacts a caller-selected URL. Explicitly enabled `web_search` remains
pre-approved; a provider-native search card is a post-hoc record of a search the
selected model provider already ran.

Guardian owns Auto-reviewing as an isolated `.reviewing` agent posture. Ordinary
tools default only to `.planning` and `.acting`. The registry supports disjoint
same-name registrations with independent schema, preflight, and execution for
each run mode, but Termind currently registers no `.reviewing` tools, so every
Guardian request is tool-free. Its in-memory per-conversation channels serialize
reviews and retain a bounded full-to-delta transcript, while only direct authored
user text and locally captured `request_user_input` answers may establish authorization.
OpenAI-shaped requests use `guardian:<conversation-id>` as the stable prompt
cache key; fixed policy, schema, and tool prefixes remain byte-identical.
Structured Guardian decisions use provider-native JSON schema when the selected
model declares support and strict local validation otherwise. Any unavailable,
timed-out, malformed, recursively gated, or policy-inconsistent result fails
closed before the pending tool executes.
An unset Guardian role is Automatic: it prefers `codex-auto-review`, then the
highest numeric version in the `gpt-*-luna`, `claude-sonnet-*`,
`gemini-*-flash`, `deepseek-v*-flash`, and `glm-*-flash` families, in that
order, before falling back to the resolved Chat model. Matching is
case-insensitive and compares numeric version components (`0.11` is newer than
`0.8`). An explicit Guardian assignment always wins.

User messages carry immutable, hidden `AgentTurnContextSnapshot` metadata. Session
facts, skill catalogs, plan contracts, and surface-tool availability are captured on
submission, including steering and edits. Live surface state still belongs to the
window. Replay emits an initial baseline and then only changed blocks at their original
message boundaries; missing legacy snapshots are unknown, never reconstructed from the
current terminal. Leaving a session or mode emits an explicit clearing transition.
Retries retain their snapshot, forks copy it, and compaction retains context facts while
establishing a new baseline. V16 adds independent `PersistentAgentMessageReplay` rows;
V1-V15 message definitions remain unchanged. Deletion and truncation remove the backing.

Tool model output is projected once before `toolFinished`, including a bounded preview
and a scratch capture reference for oversized results. Result metadata preserves the
projection across crash recovery; message backing preserves it across replay. Earlier
results are never shortened merely because another tool finishes. Paged reads retain
their structured continuation fields. `sftp_read` streams UTF-8 line windows; it and
`scratch_read` report only complete returned lines and a truthful next offset.

Terminal suggestion definitions remain stable across surfaces. The executor checks
availability from the most recently delivered user snapshot before preflight; merely
changing focus does not change the active run's capabilities. Termind's stable system
prompt explains that surface availability is a partial override, not a tool catalog;
terminal suggestion availability does not restrict independent SSH/SFTP tools.
The standalone Assistant need not attach session context: no active session means
no default target, not an inability to execute. Discover targets with `list_hosts`
and ask only if the user's intended target remains ambiguous; no sidebar or
terminal connection is a prerequisite.
SSH/SFTP login is handled by the host configuration and app authentication UI.
`request_user_secret` is only for command secret input, not a prerequisite for SSH;
`ssh_exec` needs only `host_id` and `command` for ordinary commands. A terminal
suggestion creates a user-operated card and never constitutes command execution.
Provider tool/schema JSON is deterministic. Responses and Chat Completions requests use a conversation cache key
without hostname restrictions; Anthropic uses
short-lived system/message cache breakpoints, and Gemini retains implicit caching.
Cache read/write usage is normalized without adding cached tokens twice to input totals.

A batch is concurrent only if every call is parallel. Preflight may tighten this:
`ssh_exec` is parallel only when local command classification proves it safe; an MCP
destructive hint makes a call sequential. Results always enter the
transcript in model order, and every call gets an answer even after cancellation or
refusal. Approvals/questions are queued one at a time; state derives from outstanding
work. Authorization is a structural executor stage and cannot be removed by hooks.

Command classification recursively unwraps supported shell wrappers and static nested
commands, then applies argument- and subcommand-aware rules. Only explicitly proven
read forms are locally read-only; unknown tools, options, embedded programs, excessive
complexity, and unsupported shell syntax fail closed to a state-changing assessment.

Every call has an approval policy before the run's permission mode is consulted:

- Deny refuses every permission mode while keeping the tool registered and visible
  to the model; Approve runs without another approval step.
- Ask for approval sends Ask calls to the user. Approve for me sends them to Security
  Review; missing credentials,
  timeout, transport failure, or malformed review fails closed and is recorded.
- Full access pre-approves Ask calls but retains host-key, secret, schema,
  path, fetch, sandbox, and capability boundaries.
- A genuinely new MCP tool starts at Approve only when its remote
  `readOnlyHint` is true and its `destructiveHint` is not true; every other new
  tool starts at Ask. Rediscovery preserves the user's stored policy, including
  an explicit Approve choice for a destructive tool.
- MCP tools follow Deny, Ask, or Approve in both acting and planning runs.

Skills are global, app-managed packages. Settings imports and approved `skill_manage`
transactions use the same user library and Settings sync journal. Skill Creator and
Skill Installer are immutable application instructions merged into runtime snapshots;
they appear in the catalog, `/skill`, and read tools, but never in Settings, persistence,
or sync. Their reserved names cannot be shadowed or mutated. Existing user collisions
remain visible and paused until renamed. There is no starter seeding or Skills Reset.
Previously installed starter skills remain ordinary user-owned records, including
unchanged or disabled copies. Their identities, contents, resources, and sync behavior
are preserved without migration or special recognition; new installations start with
an empty user library. The old starter definitions and fixtures are not shipped.

`skill_install` is acting-only and uses the existing Ask/Guardian/Full Access boundary.
AgentKit resolves public GitHub skill directories to one commit, bounds and verifies
all downloaded bytes, and rejects redirects, symlinks, submodules and incomplete packages.
A run-owned in-memory staging area binds reviewed source, files and installation name
to the invocation; execution commits only those bytes against the reviewed library revision.
Termind alone persists the complete package and Settings sync intent in one transaction.
Installation executes no scripts, never overwrites an existing name, and becomes
available on the next run. `skills_list` snapshots
inventory, and `skill_read_file` reads bounded SKILL.md instructions or paged supporting
resources. Only SKILL.md is an instructional result; supporting files remain reference
data and no frontmatter grants permission. Mutations are acting-only, Ask, atomic, and
bound to the library revision reviewed at preflight. Running agents retain their starting
package snapshots; edits become available on the next run. The retired `load_skill`
name has historical presentation/replay support only. V18 adds independent package
backing while V1-V17 models remain frozen. Complete packages sync with existing skills;
legacy records without package fields cannot erase supporting files.

Hermes Memory (持久化记忆 / 持久化記憶 in Chinese) is a device-local, default-off feature. AgentKit owns generic memory
values, content screening, tools, learning, and revocable prompt snapshots; Application
owns lifecycle and UI state; Persistence alone imports GRDB. Its dedicated Application
Support database stores bounded global `memory` (2200 Unicode scalars) and `user`
(1375 scalars), frozen per-conversation snapshots, learning checkpoints, and the FTS5
history index. SwiftData remains the original conversation source. Forks retain the
snapshot reference, not a second copy of memory in SwiftData. Tool writes are atomic;
background reviews compare their base state transactionally before committing. Skills
always retain their separate approval boundary. Memory and credentials never sync.

Disabling memory revokes live access and prompt snapshots and cancels learning/indexing,
but preserves storage. Destroy is user-only: persist disablement and an unfinished-destroy
marker, revoke all leases, cancel and join work, close GRDB, then remove its entire owned
directory. Failed destruction remains disabled and is retried at launch. No stale task
can write through an old generation. Skills, original messages/tool results, and exported
files survive. Explicit re-enablement creates a new memory store and permits full history
backfill; old chats may therefore teach the agent the same facts again. Disabled startup
does not create or open a database. Planning can search history but cannot write memory.

Tools never receive the interactive PTY. SSH exec uses a dedicated channel and file
operations use run-scoped SFTP. User-entered secrets are single-use handles bound to
run/tool/host/purpose; plaintext never enters model input, reviews, events, logs, or
SwiftData. A live approval is the deliberate user-review boundary: while it is pending,
the local UI projects the invocation's original arguments through the registered tool
presenter so the person can inspect exactly what will run. That projection is neither
recorded nor reused after the decision. Fetch permits proven public HTTP(S) reads, revalidates DNS on every
redirect, reauthorizes entry into a restricted origin, follows explicit headers like
`curl -H -L`, and redacts sensitive values. Remote MCP metadata can tighten but never
relax local safety.

Each conversation has a bounded `AgentScratchWorkspace` under app-owned Application
Support. It rejects absolute escape, `..`, and symlinks, proves resolved containment,
and serializes mutations per path. Pull/push move remote bytes without putting them
in the transcript; these host-touching endpoints remain Termind-owned. Edit returns a
diff and search bounded previews. Push approval is bound to size/digest and includes
a redacted head, so changed content is refused.

Agent conversations, runs, visible messages, tool calls/results, and reviews are
stored after truncation/redaction. Launch marks unfinished runs interrupted and never
replays remote actions. Restore materializes completed results missing from the last
snapshot; remaining unanswered calls receive an explicit unknown-outcome repair so
the model cannot assume an action was never dispatched.

## Pro access and review invitations

`ProAccessController` owns application-wide StoreKit state. Permanent Pro is a
Family Sharing non-consumable; annual Pro is a Family Sharing auto-renewable
subscription whose introductory-offer eligibility, free period, billing period,
localized price, expiration, and renewal state come from StoreKit. Permanent access
wins over subscription access. Subscribed, introductory-trial, and
verified grace-period states grant Pro; billing retry without grace, expiration,
refund, and revocation do not. Product metadata failure never replaces verified
access. `ProOfferPresentation` derives purchase labels, disclosures, and period text
from value inputs, never from a StoreKit controller. Native paywalls retain purchase
and navigation state. macOS supplies explicit app-language lookup; mobile retains
Apple's bundle lookup, independently of the locale used for duration formatting.

The retired standalone trial product and its historical transactions are not recognized.
Entitlement expiration is checked on activation and at most minutely while active.
Current-launch workspace composition is not dismantled, but other Pro features and a
fresh launch receive no stale grant.

One app-wide shared `AppReviewController` stores device-local first-use/active-day/version/
attempt history, never syncs it, and never claims a review was shown. Desktop windows
and mobile scenes use the same surface-based policy; their platform adapters alone own
native focus, input, pointer, lifecycle, and modal observation. Automatic
requests require seven elapsed days, three active dates, and five foreground
workspace minutes, then a three-second quiet transition to a Vault list or Settings
index/App page. Input, navigation, focus loss, sleep, or modal presentation cancels
the attempt. Attempts are persisted before StoreKit, limited to once per marketing
version and a 120-day cooldown; manual review restarts the cooldown. Tests and
screenshot launches disable live requests.

## Server metrics

`ServerMetricsModel` is application-owned and shares one serial SSH sampler per saved
host across windows, menu bar, and mobile. Rows exist before secrets/networking and
represent connecting, collecting, live, paused, sleeping, or actionable failure.
Workers run detached and enter short, synchronous MainActor-isolated state steps; no
long-lived async method owns observable or host-store state. Credential lookup and remote
I/O stay off actor, and cancellation is rechecked after lookup. Secrets are cleared from
memory on pause/removal/termination. Known-host and credential decisions remain interactive
and scoped to the active monitor.

Screenshot launches inject a frozen, in-memory metrics model into the production
WindowGroup with restoration disabled. It never reads saved monitor configuration,
starts samplers, or performs host-key discovery.

Infrastructure reads bounded Linux procfs and optional hardened `nvidia-smi` XML.
Base metrics survive GPU/process/filesystem failure; invalid deltas remain unknown.
Rates use remote uptime, process identity uses PID plus start time, RSS uses remote
page size, and no process arguments/environment are collected. Five-minute samples
are in memory; ordered monitors, pause, and device selection persist. Filesystem
capacity refreshes only while details are observed. Network defaults prefer physical
interfaces, with explicit selection overriding aggregation.

`get_metrics` exposes an existing monitor's Sendable snapshot to Agent and the
authenticated MCP bridge. It cannot add hosts, sample, observe details, or access
auth state. It is read-only, parallel, planning-safe, validates host IDs, preserves
section timestamps/age/staleness, uses null for unknown/non-finite values, and limits
processes to 20. Monitoring itself does not depend on AgentKit.

Metrics order syncs independently of Vault order; local layout, process sorting,
search, detail navigation, and menu-bar visibility do not. Detail observation alone
enables process/filesystem collection. Authentication opens the shared Connection
Journey while the metrics coordinator retains transport ownership. Temporary trust
is cleared on pause/removal/configuration change; rejection pauses the monitor.
Free access admits at most three cards (paused included), atomically and without
deleting restored cards after downgrade; Pro/trial access is unlimited.

The macOS status item/popover is process-owned and receives its model explicitly.
Closing the last window keeps the process alive while the menu item or monitors need
it; Quit cancels monitoring. System sleep and an inactive login session independently
suspend monitoring; collection resumes only after the system is awake and the session
is active, when the Data Protection Keychain is available again. Native lifecycle,
window reopening, input modality, and screenshot fixture wiring remain in `TFM/Platform`.

## Settings replication

iCloud has one master switch plus independent Vault, Metrics, and Settings choices.
Vault/Metrics default on, Settings off; disabling the master preserves selections,
and upgrades do not re-enable it. Pro gates three independent coordinators:
`TermindVaultV1`, `TermindMetricsV1`, and the compatibility-named
`TermindAIConfigurationV1`.

V13 Settings entity names/defaults are frozen; V14 only adds
`PersistentTerminalPreferences`; V15 adds the independent Metrics journal/account/
quarantine. Settings persistence atomically commits data and upload intent. Separate
records cover providers/models, MCP clients, skills, roles, Web Search, and terminal
preferences/custom text. The most recently selected conversation model remains
device-local. Remote commits refresh models without
re-entering local mutation. Active Agent runs keep their starting snapshot.
Every model role has a live synced record: a nil Command Generator assignment means
Same as Chat and a nil Guardian assignment means Automatic, while Chat's explicit
selection is synced normally. Resolved fallback models remain local. The legacy
`securityReview` record ID is accepted only at the CloudKit read boundary, migrated
to `guardian` without reusing its record system fields, and all new writes use the
canonical ID.

Conversations, approval mode, local MCP listener settings, and unrelated defaults do
not sync. Listener enablement, port, and tool selection remain UserDefaults; its token
uses a this-device-only Data Protection Keychain. Explicit provider/MCP credentials
use `AISecretStore` and migrate only after account verification, verified cloud copy,
and a durable local marker. Reads do not cache secrets; deletion markers prevent late
Keychain delivery from reviving cleared values. Custom MCP headers and terminal text
are ordinary synchronized settings, but explicit credentials never enter CloudKit.

Journals retain tombstones and unresolved references across partial fetches. Baseline
defaults yield to cloud records. Application skills stay outside synchronized records; previously installed starters
remain user-owned, and user deletions survive migration. Duplicate skill names/MCP namespaces retain data, but
only the lowest UUID executes until resolved. Metrics keeps one versioned record per
host; records whose Vault host is absent remain hidden, and samples, prompts, secrets,
and UI preferences never enter its zone.

## Mobile boundaries

Mobile navigation follows each window's horizontal size class, defaulting to compact.
Compact windows use native Vault, Workspaces, Assistant, Settings tabs, with Metrics
inside Vault. Regular windows use the native Vault, Metrics, Workspaces, Assistant,
Settings sidebar. Only a width-class change rebuilds the navigation branch; ordinary
resizing does not reset it. The current feature is retained, but child pages, searches,
scroll positions and unsaved forms may reset. Metrics reopens at its list in the new
layout; server details are not restored, and leaving Metrics prevents later restoration.
The outer scene and app models survive both branches: rebuilding never restarts live
connections, transfers or Agent runs, or creates a new Assistant conversation.

A window-owned save gate defers navigation reconstruction during an editor save.
The latest width is applied after success, or after failure feedback is acknowledged
or dismissed. Separate windows never share that gate. Sheets follow the presenting
window's width using stable presentation modifiers, even while navigation rebuilding
is deferred. Cards use container width and one column at accessibility text sizes;
SFTP breadcrumbs fit three or two trailing components to the available space.
Device idiom is not a production layout input. These states are memory-only.

Neither layout shows Welcome. Each Workspace owns exactly one SSH or SFTP session; mobile never composes
panes, even with Pro. Assistant is independent. The title menu switches open peers
without reconnecting existing sessions; a restored entry connects on its first selection.
More owns Rename/Close and cross-opening SSH/SFTP when a live path exists. Explicit close never retries.

Initial connection failure and recovery stay in Connection Journey. Background-task
expiration closes transports but retains intent; foreground resumes existing
workspaces. Mobile saves device-local Workspace descriptors (stable ID, Host ID, kind,
title, duplicate index and list order) under a versioned UserDefaults key. Relaunch
restores disconnected entries after loading Hosts; selecting an entry consumes its
first-open intent once across scenes and starts a fresh connection. Restoration itself
never connects or records history. Commands, credentials, paths, terminal contents and
transfers are excluded. Missing Hosts are pruned; unreadable snapshots are retained
and cannot be overwritten during that process. Close, normal SSH exit and Host deletion
remove saved entries. Workspace titles hold the lowest free index for
their Host and connection kind; manual names retain the allocation, and closing the
Workspace releases it without renumbering peers. Host deletion runs the shared outbox
saga and cancels sessions, transfers, forwarding, and local history.

One serialized Live Activity represents all Workspaces with counts and up to six
distribution icons. Validated links open a Workspace or list and carry no secrets or
commands. It starts only in foreground, ends with the last Workspace, and cannot keep
SSH or Agent runs alive. Immutable activity snapshots are separate from observable
Workspace/Vault state; a user-dismissed activity is not resurrected by ordinary
foreground updates or descriptor restoration. Startup reconciles an existing activity
only after descriptors have loaded, preserving its focused ID when available. A stale
link with no matching entry opens the Workspace list with an unavailable explanation.

Mobile Settings exposes App, Terminal, SFTP, AI, and Sync. The macOS window-title
preference stays synchronized but has no mobile control; there is no Live Activities
settings page. AI lists Models, Skills, MCP, then Hermes Memory; user skills and MCP use explicit-save drafts. Network
tests/discovery use ephemeral snapshots, cancel on editor/config changes, and cannot
repopulate discarded drafts. Secrets remain in memory until atomic save and roll back
on metadata failure. Mobile does not start the local MCP listener.

Each mobile scene owns one navigation/command model and one Assistant library model,
including its selected conversation and New Chat draft. The app-wide Assistant runtime
and conversation store remain shared so active runs are never duplicated. The scene
model is published as a focused value, so hardware-keyboard commands never operate
another iPad window. Home Screen quick actions enter through a per-window scene
delegate, are consumed once by that scene's navigation model, and never target another
iPad window. Connect is static; up to three dynamic history actions derive from the
shared event log. Workspace History and those actions keep the newest display row per
Host and connection kind without deleting duplicate persisted events. Mobile
uses the macOS shortcuts for capabilities that exist on both platforms: navigation,
connection/creation, terminal Find and Command Generator, Workspace close/switch,
and Assistant send/stop. Workspace switching never reconnects the session or claims
terminal focus. The UIKit terminal surface owns F3/Shift-F3 and replaces
Ghostty's bare/Shift-Escape commands only while Find is presented; otherwise Escape
continues to the terminal unchanged.

Mobile Agent runs belong to the app, not the visible page. Conversations retain
independent drafts/runs; archiving persists metadata before navigation and becomes
read-only until restored. Attachment parsing and speech are injected services; speech
appends without sending and cancels on interruption, conversation change, or
background. Mobile shares desktop-independent tool registration and permission/
secret interaction, but finite background expiration cancels runs, drains events,
closes Agent transports, and never replays or auto-approves work on foreground.

ListViewKit is an app-owned implementation detail: macOS uses native bridges for the
streaming transcript, large SFTP lists, conversation library, and tool sidebars; iOS
uses one UIKit bridge for transcript and large SFTP lists. Bounded navigation and
archive pages remain SwiftUI `List`. Shared frameworks never import ListViewKit, and
architecture tests own its allowlist.

Mobile workspace file drops use one upload policy for native routing and payload
loading. The visible workspace marks its bounds for a window drop interaction;
the terminal adapter forwards file drops to that destination instead of Ghostty's
local-path paste, while text and web links keep Ghostty's behavior. Leaving the
destination restores the original interaction and clears targeting. File-provider
representations are copied within their callbacks into app-owned staging before
upload preparation; queued transfers retain those files after navigation away.

Mobile top-level destinations are registered in `MobileFeatureRegistry`. A
registration owns stable identity, label, symbol, compact/regular placement, ordering,
and its destination factory. The root shell renders that catalog and does not
maintain separate tab, sidebar, and destination switches. Registries are injected
values rather than global singletons, and duplicate feature IDs fail immediately.

Mobile Workspace descriptors use Domain's `ConnectionHistoryEntry.Kind` as the
single SSH/SFTP kind vocabulary. Host Picker and Snippet operation state live in
the mobile Application layer rather than beside their views. Live Metrics samplers
enter through `MobileMetricsServices`, while both app shells obtain Agent host
resolution, authentication, connections, and background commands from the shared
Remote Infrastructure `AgentHostServices` composition.

Application derives flattened Host and Snippet sections once for both platforms.
Presentation owns the shared command-history subtitle, Vault sync status label,
SFTP transfer status labels, and the exported SFTP drag type. Transfer labels distinguish
upload/download while running and upload/download/copy on completion; other states
reuse the generic Domain label. App targets retain native card/list composition,
selection, menus, and clipboard behavior.

### Assistant transcript presentation parity (2026-09-12)

TermindPresentation owns tool summaries, batch status semantics, bounded result previews, timestamp formatting,
Markdown sanitization/soft-break policy and the shared disclosure/deadline state. Hosts inject a resolved
AgentToolDetailPresenter from TermindRemoteInfrastructure; Presentation never imports the registry's transport
module. Tool protocol results and persisted schemas are unchanged.

TFM retains native AppKit rows, Markdown caches and message editing state. TFI retains SwiftUI content inside
its UIKit ListViewKit bridge. A row's presentation revision can change without its data changing: the mobile
bridge reconfigures that row explicitly, invalidates only its height, and retains its UIHostingConfiguration
content view. Display/measurement purpose, Reduce Motion and scene activity cross that hosting boundary.
Only displayed active content starts timers or scanning; the shared scan parameters and three-second reasoning
deadlines cannot restart merely because a row is recycled. Work completion follows the shared default only
after the whole row leaves the viewport, unless the reader has already chosen its disclosure state.

The direct approval callback stages a tool card idempotently before accepting a response. Queued tool-proposed
and approval-requested notifications update that identity without erasing an already recorded denial. This keeps
UI state independent of whether the event channel or the direct interaction reaches MainActor first.

Skill and memory tools own their UI-neutral result and approval projections in AgentKit.
Presentation repairs their historical summary semantics only for recognized local tool/presenter
identities. Their compact result preview shares a 600-character/five-row budget across the entire
card and a scaled 180-point viewport. Full-detail expansion is independent, window-owned transcript
state and survives row reuse; Copy retains the full already-sanitized projection. Unknown presenter
IDs and MCP tools never opt into this policy by name. Long approvals instead retain all live
arguments in a scaled 240-point scroll region with actions outside it. Neither preview path reads
live skill/memory storage or changes the original protocol result, authorization, or persisted data.

Desktop transcript width changes reconfigure mounted rows without replacing the
cached list or following the tail. Reused row constraints and Markdown geometry
track the current content width even when message identity and text are unchanged;
parsed Markdown remains reusable independently of width-dependent measurements.
