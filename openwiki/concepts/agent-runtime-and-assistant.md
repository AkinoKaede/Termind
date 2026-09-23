---
type: agent runtime concept
title: Assistant, Agent Runtime, Skills, and Memory
description: How Termind assembles AgentKit into durable assistant conversations, applies approval and host-security boundaries, and manages skills, scratch workspaces, and device-local Hermes memory.
tags: [assistant, agent-runtime, approval, persistence, skills, memory, ssh, sftp]
sources:
  - id: openwiki-source-0e8cfe7d74554d8a17af60b7
    resource: repo://AgentKit/Sources/AgentKit/Runtime/AgentRuntime.swift
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-685b7f8e7dbcf91b4e2a50e2
    resource: repo://Frameworks/TermindApplication/Agent/AssistantConversationOperations.swift
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-160f180df5d3cb1457febfee
    resource: repo://Frameworks/TermindApplication/Agent/AssistantLibraryModel.swift
  - id: openwiki-source-1c48f72c0c7a3164d7d5c715
    resource: repo://Frameworks/TermindApplication/Agent/ConversationModel.swift
  - id: openwiki-source-b62626c07828480fcd2b71b7
    resource: repo://Frameworks/TermindApplication/Agent/ConversationTitleController.swift
  - id: openwiki-source-76220f10b4e23e3c61a811be
    resource: repo://Frameworks/TermindApplication/Agent/TermindAgentPolicy.swift
  - id: openwiki-source-7397a04f40a393c81b0ca52d
    resource: repo://Frameworks/TermindApplication/FeatureModels/MemoryModel.swift
  - id: openwiki-source-e14697ea11a99078be3adee9
    resource: repo://Frameworks/TermindPersistence/GRDBMemoryStore.swift
  - id: openwiki-source-28d6772acb1a409d29ff1973
    resource: repo://Frameworks/TermindPersistence/SwiftDataAgentRunRepository.swift
  - id: openwiki-source-1fc00d0407016efa5a0378eb
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSSHTools.swift
  - id: openwiki-source-0c82bf45bc197f879a54fd3a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift
  - id: openwiki-source-e1a028bd99d4dbe6d1e14f6a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentScratchTransferTools.swift
  - id: openwiki-source-1c845e5af67c400566be83bd
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AssistantToolRegistry.swift
  - id: openwiki-source-2a267454c356289bd66e8b40
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/PlanningSSHTools.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-6d759b4cb61f68a067dae42c
    resource: repo://FrameworkTests/AgentSteeringTests.swift
  - id: openwiki-source-247755d873c5d94b0a364217
    resource: repo://FrameworkTests/AssistantConversationOperationsTests.swift
  - id: openwiki-source-6ec3fb4cd6a582cdf278bab9
    resource: repo://FrameworkTests/AssistantExecutionControllerTests.swift
  - id: openwiki-source-a62bfbbc7de13a894444718b
    resource: repo://TermindMCPBridge/main.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-d44869be46c03fbd0ce9c64c
    resource: repo://TFI/Application/Agent/MobileAssistantModel.swift
  - id: openwiki-source-3dfad0e95bb7d66f292c20c9
    resource: repo://TFI/Features/AI/MobileAssistantConversation.swift
  - id: openwiki-source-a154b5d36ec59496392d45e4
    resource: repo://TFITests/MobileAssistantTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-76b1cdca4a02038756187f92
    resource: repo://TFM/Application/MCPServer/MCPServerTools.swift
  - id: openwiki-source-16db5d5459897d40fe080701
    resource: repo://TFM/Features/AI/ConversationTranscriptView.swift
  - id: openwiki-source-d35453512ef488d0cacdc06e
    resource: repo://TFM/Features/Assistant/AssistantView.swift
  - id: openwiki-source-49c5ca81284394384f3c3913
    resource: repo://TFMTests/AgentBuiltInToolAvailabilityTests.swift
  - id: openwiki-source-8f676dd306369e67985f3dd0
    resource: repo://TFMTests/AgentHostProtocolListingTests.swift
  - id: openwiki-source-715de8d16be5a3d06ae915ad
    resource: repo://TFMTests/AgentPersistenceTests.swift
  - id: openwiki-source-d57db929d0047db53dd73cdd
    resource: repo://TFMTests/AgentRuntimeTests.swift
  - id: openwiki-source-1d8dcc1fdf14c37b90cc9e07
    resource: repo://TFMTests/AgentScratchTests.swift
  - id: openwiki-source-7e117096f381ecc32caff068
    resource: repo://TFMTests/AgentSkillTests.swift
  - id: openwiki-source-8d265a8732f0af93c5d4e274
    resource: repo://TFMTests/MCPServerToolsTests.swift
generated: { by: "codex", at: "2026-09-23T02:40:53.789Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T02:40:53.789Z
---

# Assistant, Agent Runtime, Skills, and Memory

Termind's Assistant is a durable conversation product built around a host-neutral agent loop. **AgentKit** owns the model-provider adapters, run loop, context pipeline, approval gate, MCP client, generic built-in tools, secret broker, and generic scratch/skill/memory tool interfaces. **Termind** owns the host-specific integration: SSH and SFTP tools and transport pools, Vault-backed host resolution, application policy and prompts, SwiftData conversation persistence, Hermes memory lifecycle, and the UI that renders events and collects approvals or SSH challenges.

This split is a security boundary as well as a modularity boundary. A model proposes tool calls; it does not gain direct access to a PTY, Keychain material, stored credentials, another conversation's workspace, or the persistence store.

## Responsibilities and assembly

`AssistantExecutionController` is the application entry point for a submitted turn. Before recording a new turn it rejects overlapping starts, archived/history-changing conversations, active compaction, unfinished attachments, and unauthorized use. Accepted submission synchronously captures the composed prompt, images and context attachments; session, plan and surface context; chat model/provider/credential; reasoning and permission mode; search choice; skills and base registry; Guardian configuration; and memory/compaction preparation settings. Only then can asynchronous compaction or memory loading begin. Runtime assembly consumes this capture instead of re-reading mutable composer or configuration state after an await. A missing model or credential remains a captured failure even if Settings changes during preparation.

A runtime is deliberately single-run. It owns one event stream and one event consumer. `ConversationModel` owns the live runtime and projects its events into visible messages, tool cards, approval and input queues, run summaries, and the authoritative model transcript. The visible message list is not replay history: tool calls and results are separately rendered as cards, so replay must use `transcript`.

The tool catalog and plan posture are captured at submission; AgentKit selects that captured catalog's executable mode-specific subset when the runtime starts. A tool-capable model receives the captured skill catalog, AgentKit built-ins, and Termind tools; a model without tool-call capability does not receive the skill/tool catalog. `AgentTurnContextSnapshot` is the persistable context portion of the capture: session facts, skill catalog text, plan posture, surface availability, and memory-session identity. It is not a durable copy of provider credentials or all runtime configuration. Surface availability follows the latest delivered user snapshot rather than mutable UI focus.

Termind composes the registry in this order:

1. AgentKit generic tools, including scratch, skill, memory, fetch/search, task, plan, secret, and MCP support.
2. Termind's host tools: host/metrics discovery, `ssh_exec`, terminal suggestions, SFTP operations, and the host-facing `scratch_pull` / `scratch_push` endpoints.
3. Discovered MCP tools, which are additive and cannot shadow a built-in or Termind tool name.

### Catalog, run mode, and surface availability

`TermindAgentTools` is the shared static registration point. Its injected environment supplies host resolution, metrics, connection/authentication pools, background commands, and an optional scratch workspace. Dependencies determine which capabilities can be constructed: `scratch_pull` and `scratch_push` need that workspace, while `AssistantToolRegistry` returns an empty registry for a model without `toolCall`. A sending-surface Boolean is not a registration input; equivalent dependencies produce the same definitions for desktop and mobile Assistant surfaces.

AgentKit selects the executable registry for the run's mode. Planning retains discovery, metrics, SSH investigation, SFTP reads and `scratch_pull`; remote SFTP mutations and `scratch_push` are acting-only, and Termind contributes no tools to reviewing. Planning and acting share the `ssh_exec` descriptor and schema, but planning uses a preflight that denies destructive commands. Acting asks for those commands; commands proven safe can be approved and run in parallel in either mode.

`terminalSuggestionsAvailable` is the application argument that captures the separate execution gate in `AgentTurnContextSnapshot.toolAvailability["terminal_suggest"]`. It does not remove or change the advertised tool schema:

| Surface | Terminal suggestion execution | Tool definitions |
| --- | --- | --- |
| TFM standalone Assistant | `false` | Shared Assistant catalog. |
| TFM Workspace Assistant sidebar | `true` | Shared Assistant catalog. |
| TFI standalone Assistant | `false` | Shared Assistant catalog. |
| macOS external MCP server | Not exported | Acting host subset, `request_user_secret`, and four HTTP transfer tools. |

This snapshot dictionary is a partial override: disabling terminal suggestions does not disable independent SSH/SFTP work. The MCP server explicitly selects acting definitions, then filters by its exported-name allowlist and disabled-tool settings. It excludes terminal suggestions, scratch, web, skill, plan and task tools; its four extra tools are `sftp_upload`, `sftp_upload_status`, `sftp_download` and `sftp_download_status`. The stdio bridge forwards requests to this server and registers no second tool set; TFI has no local MCP server. See [MCP Server and Bridge](../integrations/mcp-server-and-bridge.md) for the external authorization and byte-transfer boundaries.

## Turn lifecycle

Desktop sidebar, standalone Assistant, and mobile first sends use the same controller-owned capture path as subsequent sends. A first conversation is promoted into the library only after capture and local turn append succeed. Refused sends leave the draft, attachments, armed skill and ephemeral conversation unconsumed. Accepted composer sends fold attachments and an armed skill directive into the model-facing turn once, clear those composer payloads, and clear the submitted draft. Direct text sends and plan implementation also fold those payloads once but leave unrelated ordinary draft text alone.

Edits have a separate two-stage entry point: desktop and mobile UI call `prepareAgentEdit` synchronously before creating their UI `Task`. It preserves the original attachment payload and model-facing suffix while capturing fresh context and configuration for the replacement submission. `performAgentEdit` checks the capture identity before starting a tracked history task; persistence succeeds before the live edit is applied, and another identity check precedes runtime preparation. A cancelled or superseded prepared edit cannot later enter truncation or start a runtime.

Once the runtime begins, the submitted prompt is persisted as part of its running snapshot before model work. AgentKit streams a provider turn, emits ordered UI and durable events through a shared `AgentEventChannel`, validates any complete tool call, then schedules execution. Tool results are appended to the model transcript and persisted before the following model round. This preserves a grammatically answerable transcript even for refusal, cancellation, or failure paths.

```mermaid
sequenceDiagram
    participant User
    participant Conversation
    participant Controller
    participant Runtime
    participant Gate as Approval Gate
    participant Host as Termind Host Tool
    participant Store as SwiftData Repository

    User->>Controller: submit draft
    Controller->>Controller: validate and capture turn/configuration
    Controller->>Conversation: mark preparing and append captured turn
    opt first send
        Controller->>Conversation: promote captured conversation
    end
    Controller->>Controller: await needed compaction and memory
    Controller->>Controller: verify capture is still current
    Controller->>Conversation: start with captured request and registry
    Conversation->>Runtime: start through event consumer
    Runtime->>Store: save running snapshot
    Runtime->>Runtime: stream provider turn
    Runtime->>Runtime: validate tool schema
    Runtime->>Gate: authorize when policy asks
    alt approved
        Gate-->>Runtime: allow
        Runtime->>Host: execute SSH or SFTP work
        Host-->>Runtime: bounded result
        Runtime->>Store: record durable tool event
        Runtime->>Store: save transcript snapshot
        Runtime->>Runtime: next model round
    else denied or review failure
        Gate-->>Runtime: deny
        Runtime->>Store: save refusal result
    end
    Runtime-->>Conversation: ordered events and terminal state
    Conversation-->>User: messages and tool cards
```

This sequence shows an accepted draft submission and the persistence points after runtime handoff; edits first commit their history replacement before runtime preparation.

### Preparation and cancellation ownership

`ConversationModel.isPreparingAgentRun` is distinct from `isStreaming`; `isAgentRunActive` combines them for activity guards. Preparation has no runtime that can accept steering, so it must not masquerade as streaming. When neither compaction nor memory loading is needed, preparation can hand off synchronously without an asynchronous preparation task.

Stop, controller-wide cancellation and mobile background expiration invalidate preparation identity synchronously. Cancellation cancels and joins tracked edit-history/preparation work before finishing its interrupted save; completion rechecks identity after the save so an older cancellation cannot retire a replacement capture. The concrete SwiftData truncation method checks cancellation before entering its synchronous transaction. These boundaries prevent a stopped or superseded preparation from later editing history or starting a runtime; they do not roll back a history transaction that already committed.

Archive/delete operations cancel and await pending preparation before their existing activity guards and persistence work. Manual compaction refuses preparation, while selecting another conversation leaves its preparation running. Automatic compaction uses the captured model/settings and the valid transcript available during preparation, with persistence preceding the live projection change.

### Streaming, steering, and cancellation

While a run is live, a further user message is queued as steering rather than starting another run. It becomes visible and durable only at the next model boundary, when AgentKit delivers it to the model; if the run has already ended, the UI returns queued text and attachments to the composer. This prevents history from claiming that a message was delivered when it was not.

Steering captures the sending session context and updates only the `terminal_suggest` availability entry. It preserves other tool overrides, the fixed skill catalog and plan contract, and the memory-session identity. Queuing does not change `ConversationModel.activeContextSnapshot`; delivery does. If the conversation has no legacy snapshot, steering keeps that context unknown instead of filling it from current UI state. The persisted availability key remains `terminal_suggest`.

For an already-started runtime, stopping requests cancellation of runtime/tool work, discards run-scoped secrets, marks running cards interrupted in the presentation, and returns undelivered steering text. `stopAndWait()` joins preparation cancellation first, then requests runtime cancellation and waits for the event consumer before clearing live ownership.

The preparation guarantees do not eliminate the separate runtime handoff edge case: `ConversationModel.start` schedules its event consumer, and an immediate stop before that task calls `AgentRuntime.start` can prevent runtime startup without persisting a runtime snapshot. The ordering between `stopAndWait()` and this queued start remains a distinct boundary; do not infer universal cancellation durability from preparation tests.

## Approval, secrets, and trust boundaries

Approval is evaluated after schema validation and tool preflight, before execution. Invalid arguments never reach the approval UI or the tool. The policy layer is stronger than permission mode:

- **Deny** always refuses the call.
- **Approve** executes without an additional approval prompt.
- **Ask** routes to the user under `askForApproval`, to Guardian under `approveForMe`, or is pre-approved by `fullAccess`.

`fullAccess` does not bypass schema validation, host-key trust, SSH authentication, secret binding, scratch containment, network/fetch restrictions, or tool-specific capability checks. Guardian review is only configured in `approveForMe`; it has a bounded timeout and failures, malformed output, inconsistent decisions, and critical-risk approvals fail closed. If the conversation disappears before a manual decision, the approval broker denies the request.

SSH authentication and host-key prompts are Termind interactions, not model-visible tool data. `AgentHostResolver` exposes public host metadata to `list_hosts`, but resolves Keychain-backed credentials into connection configuration without serializing them into tool results. Authentication context is shared only across overlapping attempts for the same destination; after successful authentication it clears staged submissions and cached secret-bearing configuration. Stale generations reject late callbacks and host-key decisions.

`request_user_secret` is only for command standard input, not SSH login. Its handle is scoped to run, tool, host, and stated purpose, single-use, and is removed from replay and durable history. Plaintext secrets must not enter model requests, Guardian review, events, logs, SwiftData, or Hermes memory.

## Host tools and plan mode

Termind tools operate through noninteractive per-command SSH channels and exclusive SFTP leases; they never type into the user's interactive terminal. `terminal_suggest` creates a user-operated command card and never executes it. The standalone Assistant can discover and target configured hosts even without a sidebar session or open PTY; session context is only an optional default target. `list_hosts` lists enabled protocols without credentials, including Telnet-only hosts. SSH/SFTP execution requires SSH to be enabled; discovering a Telnet-only host does not provide an Agent Telnet execution capability.

Plan mode freezes at submission. It permits investigation, reads, and policy-allowed commands, but host-specific planning registrations refuse direct remote writes, deletes, and scratch pushes. A plan is drafted in scratch space and presented as the final action; presenting it does not itself suspend a run awaiting a decision.

Implementing a pending plan is a new captured submission. The controller clears the captured `planContract` before capturing the run so implementation is acting work, then appends the composed implementation prompt and resolves the plan as implemented. Refusal leaves the pending plan, planning state, attachments and armed skill untouched.

## Scratch workspace containment

Each tool-capable conversation has an `AgentScratchWorkspace` keyed by its conversation ID under Termind application support. It survives later runs in that conversation, but one conversation cannot read another's scope. Scratch paths are normalized and bounded; escapes, absolute paths, parent traversal, control characters, excessive depth, and symlinks are refused. Entry and byte quotas are enforced before mutation.

The recommended remote-edit route is `scratch_pull`, local scratch editing/diffing, then `scratch_push`. File bytes remain outside the conversation/model transcript: pull reports metadata rather than file contents. Push is an Ask action; its preflight records bounded, redacted evidence and a digest. Execution re-reads the staged file and rejects it if its digest differs from the approved digest, so approval cannot be reused after content changes.

A fork copies its scratch scope before creating the forked conversation and removes that new scope if persistence fails. Deleting a durable conversation removes its scratch scope after deleting the conversation graph; cleanup failure is reported separately because the durable deletion has already succeeded.

## Durable conversations, replay, and recovery

`SwiftDataAgentRunRepository` stores conversations, runs, messages, replay backing, attachments, tool invocations/results, reviews, ordering metadata, and compaction records. It writes messages by message ID rather than run ID, so replaying prior conversation history into later run snapshots does not duplicate historical rows. Tool event persistence is restricted to durable lifecycle events rather than streamed token deltas.

A saved context snapshot preserves historical session, skill-catalog text, plan and surface facts for replay and fork history. Explicit `startAgentRun` uses the last user turn's stored snapshot, or a neutral `AgentTurnContextSnapshot()` for legacy absent context rather than inventing facts from current UI state. This is context replay, not reconstruction of historical model/provider settings, credentials or skill-package bytes: the controller still captures the current runtime configuration. An edited submission deliberately captures fresh context instead of inheriting the historical snapshot. There is no manual Retry/Resume UI or automatic recovery execution; provider retry remains AgentKit-owned.

Persisted text, tool arguments, titles, reasoning, and attachments go through redaction. In particular, secret handles are replaced with expired lifecycle content on restore, and sensitive header values are redacted.

Tool cards resolve their persisted presenter ID through the immutable presenter registry. Cards predating those IDs use the closed legacy tool-name list and its `builtin.` IDs. Registration and surface-availability changes preserve those identities and the persisted context key; they do not require a SwiftData schema change.

Compaction changes the **model-facing** transcript, not the scrollable display history. Its summary record is persisted before the live conversation applies it; after recovery the model receives a synthetic compaction summary plus recent messages while the user can still read the full original conversation. Editing a user message truncates the target run and later runs atomically, creates the replacement turn, and removes compactions whose boundary was removed.

That durable edit boundary is still run-level, whereas the live model truncates from the target message. Editing a steering user message within a run can therefore leave earlier messages from that same run in the live model after persistence removed them. This existing durable/live mismatch is separate from stale-preparation cancellation and is not repaired by synchronous capture.

At repository initialization, every nonterminal persisted run becomes `interrupted`; Termind never replays unfinished execution automatically. Restore reconstructs completed tool cards and can recover a durable tool result that was recorded before its next transcript snapshot. If an outcome remains unknown, repair records an explicit unknown/refusal result rather than assuming a call was never dispatched.

```mermaid
stateDiagram-v2
    [*] --> Restored
    Restored --> Completed: terminal run stored
    Restored --> Interrupted: nonterminal run on launch
    Interrupted --> Ready: history and cards restored
    Completed --> Ready: history and cards restored
    Ready --> Preparing: accepted capture
    Preparing --> Running: current capture handed to runtime
    Preparing --> Interrupted: cancellation saved
    Preparing --> Failed: captured configuration unavailable
    Running --> WaitingApproval: Ask action pending
    WaitingApproval --> Running: allow
    WaitingApproval --> Running: denial result recorded
    Running --> Completed: terminal snapshot saved
    Running --> Cancelled: stop and cancellation snapshot
    Running --> Failed: error snapshot saved
    Cancelled --> Ready: next submitted turn
    Failed --> Ready: next submitted turn
    Completed --> Ready: next submitted turn
```

This state diagram distinguishes recovery from automatic resumption: interrupted work is visible and recoverable as history, never silently rerun.

Conversation metadata mutations are persistence-first. Archive clears pinning and prevents editing; after cancelling pending preparation, archive/delete remain guarded while streaming or compaction is active. Reordering commits the whole ordering update before changing the in-memory library. These rules avoid UI state claiming a history mutation that failed to save.

Automatic titles require a real nonempty assistant reply in the authoritative transcript, not a visible failure message. A completed reply can qualify even if the run is later stopped. Title generation resolves its configuration when it runs, independently of the submitted turn's frozen configuration. Automatic post-run memory review is stricter: it requires a `.completed`, non-planning run; preparation cancellation does not trigger it.

## Skills

Skills are global app-managed packages, not per-conversation data. Submission snapshots the enabled catalog and inventory before preparation, so subsequent Settings changes do not replace that run's captured catalog. This is not archival replay of package bytes. Reserved skill names cannot be shadowed, and collisions remain visible but paused.

A skill is procedure-bearing only when read through `skill_read_file` from its `SKILL.md`. Supporting files, package frontmatter, tool output, remote files, web pages, and MCP responses are untrusted reference data—not instructions or authorization. Skill installation is acting-only, revision-bound, and subject to normal tool approval; a skill cannot grant permission to execute a command, write a file, transfer data, or bypass other policy.

## Hermes device-local memory

Hermes memory is optional and disabled by default. AgentKit supplies the memory tools, screening/learning model, revocable session snapshots, and access interface. Termind supplies Settings and lifecycle management, while `GRDBMemoryStore` alone owns the memory database at `Termind/HermesMemory`; SwiftData remains the source of truth for conversations.

The GRDB store opens lazily, so disabled memory does not create or open its database. It keeps memory state, frozen per-conversation prompt snapshots, review checkpoints, a redacted conversation/message index, and an FTS5 search index. Conversation history is copied into this separate index only after successful relevant history changes; indexed text is redacted and compaction-only synthetic messages are excluded.

A memory session receives a frozen snapshot for its conversation. Memory reviews use a compare-and-apply base state, so a stale review cannot overwrite newer memory. Disabling memory invalidates sessions, cancels indexing and reviews, and closes the database while preserving stored data. Destroying memory first persists disabled/destroy-pending state, revokes contexts and joins ongoing work, then closes and removes the owned directory; failure remains disabled and is retried on a later launch. Memory and credentials are device-local and are not synced.

New submissions capture whether they have a memory-session identity before preparation awaits. Enabling memory afterward does not add a session to that captured turn. Disabling it remains a revocation boundary: `MemoryModel` invalidates existing contexts and rejects a late snapshot load from the old generation, so capture does not override a later disable.

## Focused verification

The focused tests establish behavior that is important when changing this area:

- `TFMTests/AgentRuntimeTests.swift` covers schema-before-approval/execution, approval mode routing, Guardian timeout/failure fail-closed behavior, single-use secret handles, steering delivery, tool cancellation, registry shadowing, and durable-event filtering.
- `TFMTests/AgentPersistenceTests.swift` covers redaction, interrupted-run recovery, replay deduplication, tool-result repair, deletion of the persistent graph, edit truncation, fork persistence, and compaction restoration.
- `FrameworkTests/AssistantExecutionControllerTests.swift` covers capture across a memory barrier, missing credentials, first-send guards and payload folding, plan implementation, edit persistence/cancellation barriers, superseded captures, navigation, compaction refusal, memory revocation, and neutral legacy context.
- `FrameworkTests/AssistantConversationOperationsTests.swift` verifies persistence-first archive/rename/order mutations, activity guards, and that immediate stop prevents a queued runtime's model call. That last test does not establish snapshot persistence for the runtime handoff gap.
- `TFMTests/AgentScratchTests.swift` verifies workspace containment, symlink refusal, inter-conversation isolation, quotas, and bounded reads.
- `TFMTests/AgentBuiltInToolAvailabilityTests.swift` checks exact Termind planning/acting/reviewing sets, the shared SSH schema with mode-specific preflight, and execution spies proving the surface gate blocks only terminal suggestions.
- `FrameworkTests/AgentSteeringTests.swift` and `TFITests/MobileAssistantTests.swift` check snapshot preservation, delivery timing, legacy unknown context, mobile send/steer availability, acting-mode plan implementation, and tool-incapable models.
- `TFMTests/MCPServerToolsTests.swift` checks the exported acting subset against shared descriptors, transfer tools and disabled calls; `AgentHostProtocolListingTests.swift` checks protocol-neutral discovery, and `AgentToolPresentationTests.swift` retains legacy presentation coverage alongside the persistence suite.

## Change guidance

When adding a tool, define a strict schema, choose an explicit tool policy and planning registration, validate/normalize inputs in preflight, and ensure the tool returns bounded/redacted data. Host mutations must remain behind the same authorization and trust checks whether invoked directly, through MCP, a skill, or a scratch workflow. Do not add a shortcut that serializes SSH credentials, secret input, raw scratch/remote file contents, or unredacted provider data to a transcript, event, log, SwiftData, or Hermes index.
