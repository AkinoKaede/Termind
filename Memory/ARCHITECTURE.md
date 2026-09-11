# Termind architecture

Termind uses one Xcode project with two app targets (`TFM` and `TFI`), six
static frameworks, three test targets, and the macOS-only MCP bridge. AgentKit
remains a versioned remote SPM dependency developed in the sibling repository.

## Dependency direction

- `Frameworks/TermindDomain` owns platform-independent values and rules. It may
  use AgentKit values, Foundation, and CryptoKit, never UI or concrete I/O.
- `TermindApplication` owns repository ports, Vault/AI feature models, secret interfaces,
  SSH configuration/preparation, SSH import preview, the outbox runner, and reconnect policy; it depends on Domain and AgentKit.
- `TermindInfrastructure` owns the memory repository, metrics parsers and StoreKit access.
  It depends on Application, Domain and Persistence. CloudKit Vault/Settings coordinators live here and share one implementation across both apps.
- `TermindRemoteInfrastructure` owns SSH/SFTP, key material, Keychain and remote sampling.
  It also owns scoped SSH import reads, forwarding and transfer execution.
  Its C libraries are linked only through this target. Keeping it outside the portable
  FrameworkTests dependency graph avoids Xcode promoting OpenSSL to an empty dynamic
  package wrapper during multi-host testing. It depends on Infrastructure, Application and Domain.
- `TermindPresentation` owns reusable SwiftUI content. It depends on Application and Domain,
  never on app targets, platform UI frameworks, transports or persistence.
- `TermindPersistence` owns every SwiftData model, frozen historical schema,
  migration plan, and the shared container factory. It depends on Domain,
  AgentKit, Application repository interfaces, and SwiftData, never an application target.
- `TFM` retains desktop feature models, adapters, views and application/window
  orchestration. `TFI` owns its native mobile entry point and scene navigation.
  Platform code can consume frameworks; frameworks cannot consume either app.

The frameworks have explicit public boundaries and do not re-export imports.
`Host` is explicitly imported from Domain where Foundation's same-named type
would otherwise make lookup ambiguous. Presentation of session-context chips
belongs to the desktop feature extension, not the domain value.

All SwiftData models and V1–V14 schemas have one definition in Persistence,
including sync journals' records and secret-location metadata. Platform adapters
can still access public persistent records during incremental extraction, but
feature views cannot access SwiftData or construct transports. Neither moving a
model nor renaming a target authorizes changing persisted entity identities,
fields, defaults, or historical schema meanings. Original-module V1/V14 database
fixtures test this boundary independently of newly generated stores.

`TermindPersistence.makeContainer` fixes the complete schema and migration plan.
Each app process owns one container shared by its scenes. The desktop keeps the
`Termind` store configuration and its existing local location; mobile uses an
Application Support store with the same schema and an in-memory container for tests. Store failures
never silently recreate a database. Keychain access is shared and explicitly configured
by each app. Both apps wire the shared CloudKit coordinators into the persisted journals;
TFI/TFI.entitlements and TFM/TFM.entitlements use the same CloudKit container and
bundle-derived Keychain access group. Signing environments remain target-specific.

Shared resources are copied into each app bundle. Localized framework strings
resolve against the host bundle; platform icons and metadata remain app-owned.
Build settings live in the single project, with SDK and deployment choices on
targets. The apps link static frameworks without embedding them dynamically.

`FrameworkTests`, `TFMTests`, and `TFITests` have separate root directories.
Framework tests run on macOS and iOS without importing either application.
Architecture tests enforce directory and framework boundaries and fail closed
when an expected source directory is missing or empty.

There is no generic Core directory. Types belong to their domain, application,
infrastructure, persistence, or presentation responsibility.

## State lifetimes

- Repository snapshots are application-wide and shared by every window.
- A window owns one top-level shell, quick-open, and context-panel state.
- Metrics is a fixed window destination below Welcome and above the Vault group.
- The shell always starts with `Vault` and `Assistant`; Settings is the final Navigator
  page after the dynamic SSH/SFTP Workspaces.
- Vault owns its navigation column, including quick-connect Recents, and routes
  for Hosts, Keychain, Snippets, Known Hosts, Welcome, and Host Editor. These routes never
  enter the Workspace deck.
- Known Hosts is an independent Vault card manager below Snippets. Host edits and
  deletion never move or remove trust records. Plain endpoints and OpenSSH `|1|`
  hashed endpoints use one matcher across all SSH callers. Hashed tokens retain
  their original `hostname` wire field; their `port` field is ignored because the
  port is part of the hashed input. No Host record is required to retain trust.
- SSH folder imports stage selectable public metadata in a window-owned model;
  their actor-owned reader retains private keys until commit or cancellation.
  File picking and native drag-and-drop feed the same source validation and preview.
  File access is scoped to explicitly selected directories/files. Config parsing
  never executes commands. New credentials are written before a single Vault
  snapshot save and removed on failure. Existing records are never overwritten.
  Imported trust does not clear existing mismatch warnings.
- Assistant owns its conversation list through `AssistantLibraryModel`; conversations are
  not panes and do not participate in Workspace drag, split, close, or reconnect
  lifecycles.
- A workspace owns SSH/SFTP/serial panes plus its session-scoped assistant
  conversation. Workspace content is full width and has no left sidebar.
- Session models own live SSH/SFTP/serial resources and terminal/file-browser state.
- Settings uses app-wide preference storage but window-scoped navigation. It opens as a
  top-level window destination, remembers the content it replaced, and restores that
  destination when its index page goes back.
- App appearance is an app-wide UserDefaults preference, defaulting to the system.
  The app delegate owns `AppAppearanceController`, which applies changes through
  `NSApplication.appearance` so existing and new windows, native controls, and terminal
  surfaces inherit one appearance without rebuilding sessions. Following the system
  clears the override; explicit light/dark choices reuse the corresponding terminal theme.
- Opening at login is `SMAppService`'s registration, not a preference. The user can revoke
  it in System Settings without telling the app, so `LoginItemController` reads the system
  status every time Settings is shown rather than mirroring it into `UserDefaults`. Only
  *how* that launch behaves is stored here. A quiet login launch hides the app rather than
  suppressing its window, because a quiet login launch must not present an empty foreground window.

Repository data is persistent truth. Runtime connection state is kept in a
connection registry and is never persisted onto domain records.

SSH command history is created only after an authenticated shell-integration
start event. A matching completion event enriches that row with exit status and
the duration measured by the remote shell; both remain optional so interrupted
commands, old protocol events, and history migrated from older versions preserve
an honest unknown outcome. Duration is never inferred from client receive time,
because SSH buffering can deliver start and completion events together.

Feature views receive aggregate-facing Application Models rather than a generic
store API: `HostLibraryModel`, `CredentialLibraryModel`, `KnownHostsLibraryModel`, `SnippetLibraryModel`,
`ForwardingLibraryModel`, `TransferLibraryModel`, `AIConfigurationModel`,
`SkillLibraryModel`, `CommandHistoryModel`, and `ToolAuditModel`. Aggregates that share one persisted
vault snapshot still expose separate intent surfaces, so a feature cannot gain
unrelated write operations merely because its records are saved together.

The shared Vault transaction is isolated behind `VaultStore`. Feature facades
keep their backing aggregate private, and Terminal/SFTP sessions depend on the
narrow `RemoteSessionHostStore` port rather than the complete Vault mutation
surface.

Serial sessions are temporary and local: IOKit/termios discovery and descriptors
stay in Infrastructure, parameters live only with the open pane, and no serial
path is persisted or exposed as an Agent host.

Window navigation has one Navigator plus three tool sidebars: Assistant,
Snippets, and History. Dynamic SSH/SFTP containers are consistently named
Workspaces; “tab” is reserved for keyboard or native UI tab semantics. Vault
selection belongs to `VaultPageStates`, not to sidebar state.

## Speech authorization and callbacks

Speech service and coordinator state belong to MainActor. System authorization
callbacks can arrive on arbitrary queues; `SFSpeechRecognizer.queue` controls
recognition callbacks, not authorization callbacks. The speech authorization
handler is created in a nonisolated factory as an explicitly Sendable closure
that only resumes its checked continuation. The awaiting service returns to
MainActor to interpret the result. Moving work to the main queue inside an
actor-inherited callback is too late to avoid its entry isolation check.

Authorization does not own a recording session: the coordinator rechecks its
session token after waiting, so a cancelled request's late result cannot start
recording or affect a newer session.

## Agent runtime and security

The runtime is `AgentKit`, a separate package with no dependencies and no
knowledge of hosts, transports, or SwiftUI. What Termind keeps is everything
that reaches a machine or a person: the SSH and SFTP tools, the connection pool,
the Vault resolver, the SwiftData store, and every view.

The two meet at four seams, all additive:

- `AgentToolCatalog.registry(builtIn:additional:)`. The package's built-in tools
  are selected by `AgentToolGroup` — scratch, web, user interaction, planning,
  tasks, skills, MCP — and `TermindAgentTools` supplies ours after them, so a
  Termind name can never shadow a built-in and a remote MCP name can shadow
  neither.
- `AgentToolServices`, a typed bag a run carries to the tools it registered.
  `AgentSSHInteraction` travels in it, which is what keeps credential and
  host-key prompts out of the package's own protocols — and, structurally, off
  `AgentEventChannel` and out of durable history.
- `TermindAgentPolicy`, which owns the texts and judgements that are ours: the
  system prompt, the plan contract, and the `ssh_exec` rule injected into
  `AgentPlanModeHook.hostDecision`. The package ships neutral defaults for each
  and Termind's stay byte-identical to what shipped, because every provider
  cache is a prefix cache.
- `TermindAgentPresentation`, which extends the package's open card vocabularies
  with the values only we need — `sshConnecting`, `remoteFile`, and the rest.
  Their raw values are unchanged, so cards persisted before the split still
  decode and still render.

`AgentRuntime` is an actor holding a run's state — transcript snapshot, tool
registry, steering queue, secret broker — and the loop over it. Each phase of
the loop is a separate value it drives:

- `AgentContextPipeline` rewrites what is sent at the model boundary: tool
  results reordered to match the calls they answer, orphaned results dropped,
  older results trimmed head-and-tail, session context inserted in front of the
  turn it describes. It shapes only the request. Run snapshots and stored
  history keep everything.
- `AgentTurnDriver` streams one assistant turn and assembles its tool calls.
- `AgentToolScheduler` plans and runs the turn's batch.
- `AgentToolExecutor` takes one call through schema validation, preflight, the
  card, hooks, authorization, and execution, in that order.
- `AgentEventChannel` is the single ordered path for events, fanning out to the
  UI and to a serial durable recorder.

OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, and Gemini are
adapters at the LLM boundary. Models without tool capability receive no tools.
Stop cancels the active stream and actions that have not started; steering
messages are consumed at the next turn boundary.

Model purposes are `chat`, `embedding`, `rerank`, `image_generation`, and
`video_generation`. Only recognised purpose values from model discovery are
asserted as reported metadata. Unknown values, including Anthropic's `model`
object discriminator, leave catalog and name inference available and otherwise
default to chat. Only chat models enter conversation pickers. Persisted unknown
purpose strings also default to chat; there are no legacy purpose aliases.

A turn's tool calls run concurrently only when every call in it is marked
parallel; one sequential call makes the whole turn serial rather than being
fenced into its own segment. Concurrency is declared per tool and may be
overridden per call by preflight — `ssh_exec` is parallel exactly when
`CommandRiskClassifier` proves the command safe, the same evidence that decides
its safety. MCP tools are parallel by default; a server's destructive hint or
Ask First makes them sequential, so remote metadata can only tighten
concurrency, never grant it. Whatever the order of execution, results reach the
transcript in the order the model asked for them, and every call is answered
even when the turn is cancelled or refused — an assistant turn with unanswered
tool calls is rejected outright on the next request.

Approvals and agent questions are queued and presented one at a time. Run state
is derived from what is outstanding rather than asserted by whichever call moved
last.

Extension points, all additive: `AgentToolCatalog` registrations for tool definitions,
`AgentToolServices` for what a host lends them, `AgentLoopHook` for
`willExecute` / `didExecute` / `shouldStop`, `AgentContextTransforming` for the
model boundary, `AgentModelStreaming` for providers. Authorization is deliberately not among them — `AgentApprovalHandling`
is a structural stage of the executor that no configuration can remove, and
hooks run on either side of it.

Skills are the one exception to "tool output is data". A skill is a Markdown
procedure the user installed through Settings; only `SkillLibraryModel` writes
one, so no tool, MCP server or fetched page can add, edit or enable a skill.
That provenance is what lets `load_skill` return a body outside the
`<untrusted-data>` framing every other built-in result carries, and the system
prompt states the boundary: the instructions may be followed, whatever they then
cause to be read comes back through the ordinary tools and is untrusted as usual.
A skill authorizes nothing — imported `allowed-tools` is recorded and never
honoured, on the same footing as an MCP annotation. The catalog the model sees is
names and descriptions only, injected at the model boundary by
`AgentSkillCatalogInjection` rather than into the system prompt, for the
prefix-cache reason `AgentSessionContextInjection` states; bodies arrive only
through `load_skill`, which is `.locallyReadOnly` and therefore allowed in every
permission mode and while planning. The enabled set is snapshotted when the run
starts, like `isPlanning`, and is empty for a model without tool capability, so
the catalog never names a tool the run was not given. A loaded skill is exempt
from `AgentToolResultTrimming` — it is the procedure still being followed rather
than output already reasoned about — and bounded instead by
`AgentSkill.maximumBodyBytes`. `AgentSkillLibrary` ships starter skills that are
copied in once, tracked by a generation mark so a deleted one never returns; the
only way back is `resetToBuiltInSkills`, which replaces the library wholesale and
is confirmed before it runs.

Tools never receive a reference to the interactive PTY. Server commands use a
dedicated SSH exec channel and file operations use run-scoped SFTP clients.
Vault secrets are resolved behind `AgentHostResolver`. User-entered secrets are
single-use handles bound to run, tool, host, and purpose; plaintext is passed
directly to the executor and is excluded from model input, reviews, events,
logs, and SwiftData. Fetch treats public HTTP(S) reads as locally read-only and
routes private or otherwise non-public unicast targets through the active
permission policy. DNS is revalidated on every redirect; a redirect that first
enters a restricted origin pauses for another authorization decision. Explicit
request headers follow every redirect, including cross-origin redirects, to
match `curl -H -L`; sensitive values are redacted from review, UI, and durable
history. MCP discovery retains schemas and annotations, but remote annotations
are risk hints rather than proof of safety.

`AgentScratchWorkspace` is a per-conversation staging directory under Application
Support, inside the sandbox container, named for the app that owns it
(`TermindAgentPolicy.scratchDirectoryName`) and deleted with the conversation
that owns it.
Paths are relative, `..` is refused rather than resolved, symlinks are refused even
when they point back inside, and every resolved path is proven to still be under the
scope; writes are bounded per file, per conversation, and by entry count. It is an
actor, so it is also the per-path mutation queue — a read and a write of the same
file in one batch serialize there rather than by taking the whole turn serial, which
is why every scratch tool is parallel. `scratch_pull` and `scratch_push` move bytes
between a host and the workspace without the bytes entering the transcript, so a
remote file can be pulled, edited and pushed back without a copy of it crossing the
model boundary in either direction; `scratch_edit` returns a unified diff rather than
the new file for the same reason. `scratch_search` recursively searches UTF-8 content
inside that same scope and returns bounded matching-line previews, so locating a small
region does not require reading a large staged file into the transcript. `scratch_pull` and `scratch_push` are Termind's rather than the package's,
precisely because they are the two ends that touch a host. The SFTP tools are
unchanged and know nothing about the workspace. Because a push is approved by
filename rather than by content, its
preflight puts the size, digest and a redacted head into the approval reasons, and
binds the approval to that digest through execution-only metadata so a file rewritten
while the user was deciding is refused rather than written.

The permission modes share structural validation but differ at the action gate.
Safety is a property of the call, established locally: `locallyReadOnly` for calls
proven to change nothing, `locallyContained` for calls that change only storage the
app owns, and `requiresAuthorization` for everything else. The first two are allowed
in every mode — a staging area that has to be approved into is not a staging area,
and dialogs nobody can act on teach the reader to click through the one that matters.

- Ask for approval executes locally proven read-only and contained calls and
  presents every other action to the user.
- Approve for me sends those same non-read-only actions to Security Review.
  Missing credentials, timeout, transport errors, or malformed review JSON fail
  closed and are persisted as review failures.
- Full access skips action approval and Security Review while retaining host-key,
  secret, schema, host/path, fetch protocol/header/address-classification,
  sandbox, and tool-capability boundaries.

Agent conversations, runs, visible messages, tool calls/results, and reviews are
stored in SwiftData after truncation and redaction. Launch marks unfinished runs
`interrupted`; history is restored but remote actions are never resumed or
replayed.

A process that dies mid-batch — force quit, crash, the OS reclaiming the app —
leaves tool calls that nothing answered, which the next request would be
rejected for. Restore closes that in two steps. Results are recorded as each
tool finishes but their transcript rows wait for the run's next snapshot save,
so `loadConversations` first materializes any recorded result whose transcript
row was never written. Whatever is still unanswered is answered at the model
boundary by `AgentUnansweredToolCallRepair`, which says the outcome is unknown
rather than that the tool did not run: the process died after the command was
dispatched, and a model told otherwise would repeat it.

## Pro purchases and trial access

`ProAccessController` owns application-wide StoreKit access and purchase activity.
The permanent non-consumable Pro product supports Family Sharing; the separate,
zero-price non-consumable trial does not. Trial eligibility comes from verified
StoreKit history, including revoked purchases, rather than current entitlements
alone. Resolution also includes the verified purchase/update being delivered because history caches may
lag behind that result. Concurrent refreshes await the latest resolution before purchase preflight proceeds.
The trial expires exactly 14 × 24 hours after `originalPurchaseDate`;
restores and repeated transactions never restart it. A valid permanent entitlement
always wins. Product metadata loading is independent of entitlement resolution,
and purchasing/pending approval does not replace existing access with an operation
state. The trial purchase path checks zero price, product type, sharing settings,
and availability of the permanent price before invoking the App Store.

Domain's `ProTrial` contains only date and history rules; StoreKit stays outside
Domain. Infrastructure's `TrialClock` persists a per-original-transaction maximum
observed date in UserDefaults. This best-effort rollback guard can only shorten a
verified trial and is never a second source of purchase eligibility. Legacy local
proofs, trial Keychain keys, and trial CloudKit records are neither read nor written;
previous trial users may claim the new IAP. Vault sync and credential storage remain
separate from commerce.

Trial expiration is rechecked on app activation and at most every minute while an
active trial is observed. Expiration disables gated features, but previously granted
workspace composition remains available for the current launch so an existing
workspace is not dismantled. A fresh launch has no such workspace grant. The review
demo only simulates expired access and cannot grant paid or trial access.

## Server metrics

Debug screenshot launches inject a frozen `ServerMetricsModel` into AppModel.
Its in-memory preferences never read or write saved monitor configuration, and
it cannot start samplers or host-key discovery. The metrics overview and detail
fixtures render the production views using deterministic, fictitious data.
Screenshot launches use the production WindowGroup with restoration disabled,
injecting only the demo model, language, and navigation state. There is no second
RootView or manual AppKit host to steal persistent terminal/transcript surfaces
or override the production toolbar style. The ready log includes the titlebar
height and backing scale for native geometry and resolution verification.
Window preparation waits for a visible key-capable window before sizing and activation; the ready
log records both focus conditions before capture. Vault captures clear the
initial disclosure-button focus without resigning the key window.

`ServerMetricsModel` is application-owned, with one serial SSH exec sampler per
monitored saved host. Metrics navigation and the menu-bar popover consume the
same observable rows. Rows are created synchronously from saved selections,
before credential resolution or networking starts, and expose connecting,
connected/collecting, live, paused, sleeping, and actionable failure states.
The menu-bar setting defaults on. Closing the last window keeps the process
alive while that setting or any enabled monitor requires it; explicit Quit
cancels monitoring. NSWorkspace sleep/wake and native window reopening belong
to TFM/Platform, not to the sampling coordinator.

Connection preparation snapshots route, identity, public-key and trust metadata
on MainActor. `SSHConnectionPreparation` resolves the Sendable secret store on a
detached worker: Keychain access must never block first paint or state updates.
Cancellation is checked again before connecting, so late credential results
cannot revive a paused monitor. Secrets remain memory-only, are never written
with selections or history, and are cleared when monitoring is paused/removed
or the app terminates. Known-host verification still gates every SSH connection;
interactive trust and authentication are presented in Metrics.

Linux procfs and optional `nvidia-smi -q -x` are read by Infrastructure with bounded
output and command deadlines. GPU failure does not erase base metrics. Servers without NVIDIA hardware omit
the GPU section entirely. Missing
values and invalid counter deltas remain unknown; remote uptime determines
rates. History is an in-memory five-minute window; only host/device selections
persist in local preferences. GPU identity uses NVIDIA UUID, and XML external
entities are disabled. There is no WidgetKit extension, App Group, remote agent,
or dependency on AgentKit for monitoring.

`get_metrics` gives the built-in Agent and the authenticated MCP server the same
read-only view of existing monitoring. `MetricsSnapshotReading` copies Sendable
values on MainActor; tools cannot admit hosts, start sampling, register detail
observers, or access authentication state through this port. A structured monitor
state accompanies the snapshot independently of localized UI text. The tool
validates host IDs against the Agent host listing; known unmonitored targets
return `not_monitored`. It is locally read-only, parallel, and allowed while
planning. MCP exports it by default and preserves the injected reader when tools
are disabled or re-enabled, under the existing server access and audit rules.

The default output contains core metrics and sample means/peaks over the available
points within the preceding five minutes, with actual bounds and per-metric valid
sample counts. Optional device, GPU, process, and filesystem sections expose only
already collected values; processes retain the existing CPU ordering and are
limited to 20 with explicit counts. Each section carries its own timestamp, age,
availability and stale flag (30 seconds, or 60 for filesystems). Failed sections
may retain older values without presenting them as fresh. Missing/non-finite
numbers are null. JSON uses UTC ISO 8601 timestamps, bytes, bytes per second, and
percent; process CPU remains 100% per core. This projection belongs to Termind's
Agent tools; monitoring itself still has no AgentKit dependency.

MetricsMenuBarController owns an AppKit NSStatusItem and NSPopover for the
application lifetime. The menu view receives its monitoring model and open
callback explicitly, rather than relying on a window scene's environment.
Preference notifications reconcile item visibility without writing defaults
back, preventing insertion/render feedback loops.

Metrics overview uses an adaptive grid of compact server cards. Per-window
selection opens a fixed two-column detail page. System panels scroll on the
left and the native process Table scrolls independently on the right; there is
no outer detail-page scroll view or trend tab. CPU breakdown, uptime, load,
free/cached memory and per-device traffic/I/O are displayed in separate panels;
GPU details join the left column only when hardware has been detected. Process counters are collected only while at least one window observes
that host's details; multiple windows still share the same sampler. procfs
process CPU is computed from adjacent process/system tick deltas (100% per
logical core), RSS uses the remote page size, and PID plus start time prevents
reused PIDs from inheriting prior counters. Process reads have separate output
and time limits so errors leave base metrics available. No command arguments
or process environment variables are collected.

Metrics uses ManagedCardPage/CardTile for the same surfaces, hover, native
selection, marquee, drag ghosts, and reordering contract as Hosts. Its local
monitor order is persisted independently of Vault host order and moving rows
does not reconnect them. Metrics opts into single-click activation; drag gestures retain the shared
reordering behavior and Shift-click extends selection without opening details.
Add Server is a window-toolbar creation action backed by the shared host chooser;
Show in Menu Bar lives only in Settings. The page does not duplicate its title
or creation controls inside the card canvas.

Both metrics routes use the shared titlebar search field: the overview filters
servers and the detail filters processes, with separate window-owned queries.
The process Table has PID first, user-selectable column sorting, and uniform
row backgrounds. Overview cards fill the available grid width and omit GPU
rows; GPU data belongs to the detail panels. Normal sampling has no redundant
Live badge. Free Memory is a contextual localization key, separate from the
commerce Free label. Native host-chooser row roots explicitly receive AppModel
because an independent NSHostingView does not inherit the parent environment.

Healthy metrics render no status/timer footer. Detail controls (pause/resume,
retry, device selection and removal) belong beside the toolbar Back button,
not in a duplicate server-name card. Add Server is overview-only. Connection
and authentication notices remain visible when action or waiting is required.

Overview cards reserve a fixed instrument-body height. Connecting, initial
sampling, paused and attention states replace that body with a centered status
instead of appending a footer or expanding authentication controls. Clicking
an authentication-required card opens ConnectionJourneyView, not metric detail.
Journey owns the familiar identity/passphrase and host-key UI; the metrics
coordinator retains the only transport owner. Temporary host-key acceptance is
scoped to that enabled monitor and cleared on pause/removal/configuration change.
Successful collection completes the Journey before displaying metrics. Rejection
pauses monitoring without accepting a key or creating a terminal workspace.

Filesystem panels are identified by mount point, with device path, filesystem
type and df capacity. mountinfo major:minor links the mount to per-partition
diskstats; whole-device totals still exclude stacked devices and partitions.
Capacity refreshes every 30 seconds only while details are observed, with its
own bounded command so failures do not discard base samples. Subdirectory bind
mounts and pseudo-filesystems are excluded (root overlays and Btrfs subvolumes
remain representable). Network metadata classifies sysfs-backed hardware versus
virtual interfaces. Hardware interfaces are expanded, virtual ones collapsed;
default aggregate traffic uses hardware when available and otherwise non-loopback
interfaces. Explicit user selections still override aggregation. TCP counters
are host-wide and the traffic ring compares transmitted and received bytes,
not link utilization.

The Termind menu-bar popover stacks servers vertically with horizontal
separator rules. Each row preserves the overview's horizontal instrument
layout through MetricsInstrumentBody, without CardTile backgrounds. Larger
fleets scroll vertically. Open and Quit are accessible icon buttons
in the upper-right corner. CPU steal is labeled virtualization wait in Chinese;
per-core process CPU semantics remain unchanged without an explanatory banner.

The menu popover has one continuous surface: header and rows use matching
content insets, separators span the full width, and the list has no nested
scroll background/edge effects. Pointer opening resets input modality and
clears AppKit's automatic first-button focus after presentation. Real keyboard
input keeps the normal accessible focus behavior.

Free metrics admission is capped at three added cards, including paused cards;
Pro and an active trial allow unlimited additions. The Application model checks
an injected live limit and inserts deduplicated batches atomically, so concurrent
windows and bulk selection cannot overrun the cap. Batch admission happens after
the chooser dismisses, before presenting the existing Pro paywall. Restored or
previously purchased configurations are retained rather than deleted on downgrade;
all retained cards count against future additions.

## App Store review invitations

`AppModel` owns one `AppReviewController` for all windows. Its device-local
UserDefaults history records first foreground use, up to three distinct active
dates, requested marketing versions, and the last automatic or manual review
attempt. These records never enter Settings sync and never claim a review was
shown or submitted. A manual Settings link opens the write-review URL directly.

The controller requires seven elapsed days, three active dates, and five minutes
of foreground workspace time in the current launch. Only leaving a workspace
for a Vault list or the Settings index/App page can arm a three-second invitation.
Native focus, input, sleep and modal state are observed in TFM/Platform;
navigation, input, loss of focus or a blocking presentation cancels the invitation.
Returning to the foreground or dismissing a dialog does not re-arm it. The
SwiftUI presenter calls StoreKit only after the shared controller has persisted
the attempt. Each marketing version gets at most one request, with a 120-day
cooldown also restarted by the manual link. Test and screenshot AppModels default
to disabled controllers, and test-host launches never enable live requests.

## Settings replication

The iCloud page has one master preference and separate Vault/Settings selections.
Vault is selected by default; Settings is opt-in. Disabling the master preserves
both selections. Upgrading with Vault sync disabled keeps the master disabled.
Pro access gates both CloudKit coordinators, whose zones, subscriptions, account
bindings and journals are independent. Settings use `TermindAIConfigurationV1`; the
existing `TermindVaultV1` protocol is unchanged.

Shared `TerminalSettingsModel` and `CommandHistoryModel` live in Application, with
repository protocols there and their concrete SwiftData implementations in Persistence.
Theme palettes and custom-configuration parsing are pure Domain values; AppKit and UIKit
apply them through their native Ghostty adapters. Provider forms share Presentation content
and one atomic provider/endpoint mutation. Saving a provider never selects a conversation model.

`SettingsSyncPersistence` commits configuration and upload intent together in
SwiftData V14. V13 already exists in installed development stores: its
`PersistentAIConfigurationSync*` names and defaults stay frozen. V14 adds only
`PersistentTerminalPreferences`; the Settings rename preserves the original
CloudKit identifiers as well. Providers (including their models), MCP clients, skills, role
assignments, model selection, Web Search and Terminal preferences have separate
records. Terminal custom configuration text is included. Remote commits refresh
the application models without entering the local mutation path. Web Search and
Terminal preferences are migrated from UserDefaults once, then mirrored there
for existing runtime readers. Active agent runs retain their configuration snapshots.
Conversations, approval mode, local MCP listener settings and other app preferences
are excluded. Only explicitly selected settings are projected, never all defaults.

The journal retains tombstones and unresolved references across partial fetches.
Preexisting defaults use baseline versions and yield to cloud records. Built-in
skills use stable IDs; migration preserves customized skills and records deleted
built-ins. Duplicate skill names or MCP namespaces retain their data but only the
lowest UUID is eligible for execution until the conflict is resolved.

AI credentials use `AISecretStore`. First Settings sync checks the iCloud account
before migrating local Keychain entries. A verified cloud copy and durable local
storage marker precede local-copy cleanup. Migrated entries remain in iCloud
Keychain when configuration sync pauses. Production reads do not cache secrets;
missing synchronized credentials may arrive later. Pending credential deletion
markers prevent delayed Keychain deliveries from reviving a cleared value.
Explicit credentials stay out of CloudKit; custom MCP headers and custom terminal
configuration are ordinary user-authored settings. The private-account sync
adapter is the only additional trusted source of skill-library snapshots.

## Mobile presentation and workspace activities

The iPhone has four top-level destinations in order: Vault, Workspaces, Assistant, and Settings. Metrics has its own row/section inside Vault, separate from Keychain, Snippets and Known Hosts. iPad retains a sidebar ordered Vault, Metrics, Workspaces, Assistant, Settings; neither mobile layout has Welcome. Each mobile Workspace
owns one SSH or SFTP session; composition is never enabled by a purchase. Mobile
Assistant is independent and has no workspace sidebar or session-attached sheet.

Shared form content is mounted in the desktop work column and in mobile SwiftUI
sheets. Short mobile forms offer medium/large detents; complex forms use large.
Dirty drafts prevent interactive dismissal and survive size changes.

The iOS widget extension uses one ActivityKit activity for all workspaces, not one
notification or activity per workspace. Its bounded state contains counts and up to
six host system icons, resolved through the same distribution catalog as Vault,
with the focused session first and a list link for overflow. An unrecognized
system uses the server icon; SSH shell-integration updates refresh the artwork.
Each icon opens `termind://workspace/<UUID>`; the compact island opens the focused
session, while `termind://workspaces` opens the list. Links are validated and carry
no commands or credentials. A stale activity displays an instruction to check the
connections instead of asserting connectivity. Closing the last workspace ends it.
Activity starts, updates and ends are serialized, and starts require the foreground.

Live Activities do not keep SSH alive. The app requests finite background execution,
stops sampling and Assistant runs, and closes transports when that time expires.
Opening a session link restores its page and reconnects if necessary using normal
credential and trust gates; commands and tool actions are never replayed. Restoration
persists only descriptor IDs, host references, titles and session kinds.

Mobile transfer queues use the same coordinator as desktop and own dedicated connection
configurations. Closing a browser does not cancel those transfers. Deleting a host or
expiration of background execution cancels its work; no transfer is silently replayed.
Downloads are staged in a unique app-temporary directory and exported through the system
share sheet. Remote names are validated before becoming local path components.

Mobile host deletion records the existing deletion saga and starts the shared outbox
runner. Restored pending deletions are hidden before workspace restoration. The runner's
start/stop generation prevents a cancelled background loop from clearing a replacement
foreground loop. New port forwarding rules never start merely because they were saved.

Mobile Settings exposes full terminal themes, font controls, custom text, shell integration,
Vault/Settings sync, providers, model discovery and role assignments. The macOS window-title
preference remains in synchronized records but has no mobile control. Search belongs to each
workspace and uses Ghostty's search actions; history insertion uses the paste path without
appending Enter. Only authenticated integration events produce history rows; interrupted
commands retain unknown completion. App-wide history is bounded to 1,000 rows per host.

Mobile sync runs while a scene is active and Pro access permits it. Backgrounding pauses
both engines, retaining upload journals; foregrounding fetches again. Entitlement changes
reconcile the same gate. Remote host deletion closes its workspaces, cancels transfers and
forwardings, and clears local command history. Modified connections are disconnected rather
than automatically replayed. Mobile AI/Terminal edits preserve all other Settings record kinds,
including Skills and MCP configurations without mobile editors. Active chat requests retain
the provider/model/credential captured at start, and no Agent tools are registered.

Mobile navigation and Metrics reuse (2026-09-11):

- Transfers belongs to Workspaces. Host rows connect to SSH on a single activation and expose SFTP/edit/delete through a long-press context menu. SSH folder import is desktop-only; mobile retains private-key and certificate file import.
- Port forwarding rules belong to the host draft and commit with it. Only unchanged, saved rules can start; runtime start/stop and bulk controls are available inside that host editor.
- Keychain lists Keys before Identities. Identity notes remain preserved data without an editor field. Generation defaults match macOS: iCloud, Ed25519, ECDSA P-256, RSA 3072, AES-256 and 100 rounds; encrypted generation requires a matching confirmation. The shared bounded/scoped key-file reader accepts explicit private-key and certificate files.
- ServerMetricsModel, ServerMetric, MetricsClock and ConnectionJourney live in Application. Their samplers/discovery functions remain injected. Mobile delegates its collector to this shared model, including authentication, temporary trust, process/filesystem sampling and detail observer lifetimes.
- Metrics instruments/system panels, Journey route/checkpoint animations, and SSH decision forms live in Presentation. AppKit's keyboard monitor stays in TFM and is injected through ConnectionFormKeyboardAdapting; Presentation has no native UI imports.
- Metrics details show status and processes together at content widths of at least 700 points; narrower widths show a two-icon segmented switch. Width, rather than orientation or device model, determines the layout.
- Inline labeled mobile inputs align trailing. Standalone Port Forwarding Name and multiline editors align leading.

Mobile Settings mirrors the desktop category hierarchy with App, Terminal, AI, then Sync.
App owns appearance, language selection (effective on relaunch), runtime versions and support
links. AppLanguage and AppLocalization are shared Foundation-only Application values; native
relaunch remains macOS-owned. There is no Live Activities settings section. Opening a workspace
starts the activity, and the first foreground activation restores it for retained workspaces;
later foreground updates do not resurrect an activity dismissed by the user. OS authorization
still controls availability.

The mobile navigation shell uses device idiom: iPhone keeps its four tabs even in landscape,
while iPad uses NavigationSplitView's own width adaptation. Metrics' two-column breakpoint uses
the actual detail content width. An SSH terminal surface remains attached underneath the Journey,
so early output and viewport changes are retained while credentials or trust are presented.
