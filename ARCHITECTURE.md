# Termind architecture

Termind intentionally remains one application target and one unit-test target.
Directories describe dependency boundaries even though Swift does not enforce
them as separate modules.

## Dependency direction

- `Domain` contains platform-independent values and rules.
- `Application` contains repositories, feature state, use cases, events, and
  service protocols.
- `Infrastructure` implements persistence, security, SSH, SFTP, and LLM clients.
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

The project remains one target, so `ArchitectureBoundaryTests` enforces the
framework and concrete-client restrictions that directory layout alone cannot.

## State lifetimes

- Repository snapshots are application-wide and shared by every window.
- A window owns one top-level shell, quick-open, and context-panel state.
- The shell always starts with two pinned routes: `Vault`, then `Assistant`. Dynamic
  tabs after them are SSH/SFTP Workspaces only.
- Vault owns its navigation column, including quick-connect Recents, and routes
  for Hosts, Keychain, Snippets, Welcome, and Host Editor. These routes never
  enter the Workspace deck.
- Known Hosts management belongs to the Host Editor draft for both new and
  existing Hosts. Context-panel Host details are read-only.
- Assistant owns its conversation list through `AssistantLibraryModel`; conversations are
  not panes and do not participate in Workspace drag, split, close, or reconnect
  lifecycles.
- A workspace owns only SSH/SFTP panes plus its session-scoped assistant
  conversation. Workspace content is full width and has no left sidebar.
- Session models own live SSH/SFTP resources and terminal/file-browser state.
- Settings is a native singleton macOS `Settings` scene, outside window routing.

Repository data is persistent truth. Runtime connection state is kept in a
connection registry and is never persisted onto domain records.

Feature views receive aggregate-facing Application Models rather than a generic
store API: `HostLibraryModel`, `CredentialLibraryModel`, `SnippetLibraryModel`,
`ForwardingLibraryModel`, `TransferLibraryModel`, `AIConfigurationModel`,
`CommandHistoryModel`, and `ToolAuditModel`. Aggregates that share one persisted
vault snapshot still expose separate intent surfaces, so a feature cannot gain
unrelated write operations merely because its records are saved together.

## Agent runtime and security

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

Extension points, all additive: `AgentToolProviding` for tool sources,
`AgentLoopHook` for `willExecute` / `didExecute` / `shouldStop`,
`AgentContextTransforming` for the model boundary, `AgentModelStreaming` for
providers. Authorization is deliberately not among them — `AgentApprovalHandling`
is a structural stage of the executor that no configuration can remove, and
hooks run on either side of it.

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
Support, inside the sandbox container, deleted with the conversation that owns it.
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
region does not require reading a large staged file into the transcript. The SFTP tools
are unchanged and know nothing about the workspace. Because a push is approved by
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
