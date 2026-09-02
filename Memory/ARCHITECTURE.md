# Termind architecture

Termind is one application target, one unit-test target, and one first-party
package: `AgentKit`, developed in a sibling repository and consumed through SPM.
Inside the app target, directories describe dependency boundaries even though
Swift does not enforce them as separate modules. The package boundary *is*
enforced, which is the point of it.

## Dependency direction

- `Domain` contains platform-independent values and rules.
- `Application` contains repositories, feature state, use cases, events, and
  service protocols.
- `Infrastructure` implements persistence, security, SSH, and SFTP clients.
- `Features` contains SwiftUI presentation and sends intents to Application.
- `Platform/macOS` contains AppKit adapters.
- `App` constructs dependencies and owns application/window lifetimes.

There is deliberately no `Core` or generic shared layer. A value belongs to
Domain, orchestration and ports belong to Application, concrete I/O belongs to
Infrastructure, and presentation-only parsing or formatting stays with its
Feature. This prevents a catch-all directory from bypassing dependency review.

Domain must not import SwiftUI, SwiftData, AppKit, Ghostty, CSSH2, or OpenSSL.
Views must not construct network clients, access SwiftData/Keychain directly, or
coordinate cross-domain cleanup. Runtime side effects belong to application
services and durable outbox handlers.

The app remains one target, so `ArchitectureBoundaryTests` enforces the
framework and concrete-client restrictions that directory layout alone cannot —
including that no type AgentKit owns is redefined here.

## State lifetimes

- Repository snapshots are application-wide and shared by every window.
- A window owns one top-level shell, quick-open, and context-panel state.
- The shell always starts with `Vault` and `Assistant`; Settings is the final Navigator
  page after the dynamic SSH/SFTP Workspaces.
- Vault owns its navigation column, including quick-connect Recents, and routes
  for Hosts, Keychain, Snippets, Welcome, and Host Editor. These routes never
  enter the Workspace deck.
- Known Hosts management belongs to the Host Editor draft for both new and
  existing Hosts. Context-panel Host details are read-only.
- Assistant owns its conversation list through `AssistantLibraryModel`; conversations are
  not panes and do not participate in Workspace drag, split, close, or reconnect
  lifecycles.
- A workspace owns SSH/SFTP/serial panes plus its session-scoped assistant
  conversation. Workspace content is full width and has no left sidebar.
- Session models own live SSH/SFTP/serial resources and terminal/file-browser state.
- Settings uses app-wide preference storage but window-scoped navigation. It opens as a
  top-level window destination, remembers the content it replaced, and restores that
  destination when its index page goes back.

Repository data is persistent truth. Runtime connection state is kept in a
connection registry and is never persisted onto domain records.

SSH command history is created only after an authenticated shell-integration
start event. A matching completion event enriches that row with exit status and
the duration measured by the remote shell; both remain optional so interrupted
commands, old protocol events, and history migrated from older versions preserve
an honest unknown outcome. Duration is never inferred from client receive time,
because SSH buffering can deliver start and completion events together.

Feature views receive aggregate-facing Application Models rather than a generic
store API: `HostLibraryModel`, `CredentialLibraryModel`, `SnippetLibraryModel`,
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
