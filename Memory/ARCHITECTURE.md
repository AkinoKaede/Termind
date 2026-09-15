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
- `TermindPersistence` exclusively owns every SwiftData model, frozen V1-V16
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
empty.

## State, navigation, and ownership

- Repository snapshots and preference models are application-wide. A window owns
  its shell, quick-open, search, navigation, and context-panel state.
- Desktop navigation starts with Vault and Assistant, places Metrics above Vault
  libraries, appends dynamic SSH/SFTP Workspaces, and ends with Settings. Vault
  owns Hosts, Keychain, Snippets, Known Hosts, Welcome, and Host Editor routes.
- Assistant conversations are owned by `AssistantLibraryModel`; they are not
  Workspace panes. A Workspace owns SSH/SFTP/serial panes and any session-scoped
  conversation. A session owns live transports and terminal/browser state.
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

Known Hosts is independent of Host records: editing or deleting a Host does not
change trust. Plain and OpenSSH `|1|` hashed endpoints share one matcher; hashed
records keep their wire `hostname`, and their separate port field is ignored.

SSH imports recursively classify files by content and stage only selectable public
metadata in a window-owned model. The actor reader retains scoped source descriptors
and content digests, never private-key text or passphrases; it rereads selected keys
transiently at unlock/commit and fails closed if a source changed. Picking and
drag-and-drop use the same scoped validation; config parsing never executes commands.
Commit writes new credentials before one Vault save, cleans them up on failure, never
overwrites existing records, and never clears an existing trust mismatch.

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
Transfers own dedicated connections and outlive browser closure; host deletion and
background expiration cancel them, and nothing is silently replayed.

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
changing focus does not change the active run's capabilities. Provider tool/schema JSON
is deterministic. Responses and Chat Completions requests use a conversation cache key
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

Skills are trusted procedures only because users install them through Settings;
tools, MCP servers, and fetched pages cannot write or enable them. `allowed-tools`
never authorizes actions. MCP annotations may seed the local approval policy for a
new tool, but cannot override a stored user choice. The model receives enabled names
and descriptions at the context boundary, then loads bounded bodies through the
read-only `load_skill`; downstream reads remain untrusted. The enabled set is fixed
per run. Built-ins seed once, deleted built-ins stay deleted, and reset replaces the
library only after confirmation.

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
access.

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

Conversations, approval mode, local MCP listener settings, and unrelated defaults do
not sync. Listener enablement, port, and tool selection remain UserDefaults; its token
uses a this-device-only Data Protection Keychain. Explicit provider/MCP credentials
use `AISecretStore` and migrate only after account verification, verified cloud copy,
and a durable local marker. Reads do not cache secrets; deletion markers prevent late
Keychain delivery from reviving cleared values. Custom MCP headers and terminal text
are ordinary synchronized settings, but explicit credentials never enter CloudKit.

Journals retain tombstones and unresolved references across partial fetches. Baseline
defaults yield to cloud records. Built-in skills keep stable IDs; customizations and
deletions survive migration. Duplicate skill names/MCP namespaces retain data, but
only the lowest UUID executes until resolved. Metrics keeps one versioned record per
host; records whose Vault host is absent remain hidden, and samples, prompts, secrets,
and UI preferences never enter its zone.

## Mobile boundaries

iPhone top-level order is Vault, Workspaces, Assistant, Settings; Metrics is a Vault
section. iPad uses Vault, Metrics, Workspaces, Assistant, Settings. Neither shows
Welcome. Each Workspace owns exactly one SSH or SFTP session; mobile never composes
panes, even with Pro. Assistant is independent. The title menu switches open peers
without connecting/focusing; More owns Rename/Close and cross-opening SSH/SFTP when a
live path exists. Explicit close never retries.

Initial connection failure and recovery stay in Connection Journey. Background-task
expiration closes transports but retains intent; foreground resumes existing
workspaces. Workspaces exist only for the current app process and are never restored
after relaunch. Within that process, Workspace titles hold the lowest free index for
their Host and connection kind; manual names retain the allocation, and closing the
Workspace releases it without renumbering peers. Host deletion runs the shared outbox
saga and cancels sessions, transfers, forwarding, and local history.

One serialized Live Activity represents all Workspaces with counts and up to six
distribution icons. Validated links open a Workspace or list and carry no secrets or
commands. It starts only in foreground, ends with the last Workspace, and cannot keep
SSH or Agent runs alive. Immutable activity snapshots are separate from observable
Workspace/Vault state; a user-dismissed activity is not resurrected by ordinary
foreground updates.

Mobile Settings exposes App, Terminal, SFTP, AI, and Sync. The macOS window-title
preference stays synchronized but has no mobile control; there is no Live Activities
settings page. AI manages Models, Skills, and MCP with explicit-save drafts. Network
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
registration owns stable identity, label, symbol, phone/iPad placement, ordering,
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
and the exported SFTP drag type. App targets retain native card/list composition,
selection, menus, and clipboard behavior.


### Assistant transcript presentation parity (2026-09-12)

TermindPresentation owns tool summaries, batch status semantics, bounded result previews, timestamp formatting,
Markdown sanitization/soft-break policy and the shared disclosure/deadline state. Hosts inject a resolved
AgentToolDetailPresenter from TermindRemoteInfrastructure; Presentation never imports the registry's transport
module. Tool protocol results, AgentKit versions and persisted schemas are unchanged.

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
