---
type: assistant runtime concept
title: Agent Runtime and Assistant
description: How AgentKit owns the neutral runtime while Termind assembles assistant execution, host tools, persistence, and UI across macOS and iOS.
tags: [assistant, agent-runtime, approval, persistence, skills, memory, ssh, sftp]
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-c8b26c87188ce3aa11dc622b
    resource: repo://Frameworks/TermindApplication/Agent/AgentPaneAccess.swift
  - id: openwiki-source-0dc45e296e0ec3d99731a2f2
    resource: repo://Frameworks/TermindApplication/Agent/AssistantChatCollaboration.swift
  - id: openwiki-source-685b7f8e7dbcf91b4e2a50e2
    resource: repo://Frameworks/TermindApplication/Agent/AssistantConversationOperations.swift
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-160f180df5d3cb1457febfee
    resource: repo://Frameworks/TermindApplication/Agent/AssistantLibraryModel.swift
  - id: openwiki-source-ce9687e1e441c1da9a8f908a
    resource: repo://Frameworks/TermindApplication/Agent/AssistantModelSelection.swift
  - id: openwiki-source-473020b86058efef90cbb715
    resource: repo://Frameworks/TermindApplication/Agent/CommandGeneratorService.swift
  - id: openwiki-source-1c48f72c0c7a3164d7d5c715
    resource: repo://Frameworks/TermindApplication/Agent/ConversationModel.swift
  - id: openwiki-source-b62626c07828480fcd2b71b7
    resource: repo://Frameworks/TermindApplication/Agent/ConversationTitleController.swift
  - id: openwiki-source-76220f10b4e23e3c61a811be
    resource: repo://Frameworks/TermindApplication/Agent/TermindAgentPolicy.swift
  - id: openwiki-source-7397a04f40a393c81b0ca52d
    resource: repo://Frameworks/TermindApplication/FeatureModels/MemoryModel.swift
  - id: openwiki-source-4b9f58eec58128055ac58b6f
    resource: repo://Frameworks/TermindInfrastructure/Agent/ContextAttachmentImporter.swift
  - id: openwiki-source-33d69cea4b24d60ab000a0cc
    resource: repo://Frameworks/TermindPersistence/AssistantChatCollaborationPersistence.swift
  - id: openwiki-source-e14697ea11a99078be3adee9
    resource: repo://Frameworks/TermindPersistence/GRDBMemoryStore.swift
  - id: openwiki-source-28d6772acb1a409d29ff1973
    resource: repo://Frameworks/TermindPersistence/SwiftDataAgentRunRepository.swift
  - id: openwiki-source-5b42af91dbdc738123786a99
    resource: repo://Frameworks/TermindPresentation/AgentToolPresentation.swift
  - id: openwiki-source-726b3d2d8e6b8e6e0b9ee479
    resource: repo://Frameworks/TermindPresentation/AssistantMessageBody.swift
  - id: openwiki-source-718a8dd6b4c7481c367a98e1
    resource: repo://Frameworks/TermindPresentation/TermindMarkdownParser.swift
  - id: openwiki-source-1fc00d0407016efa5a0378eb
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSSHTools.swift
  - id: openwiki-source-0c82bf45bc197f879a54fd3a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift
  - id: openwiki-source-ead8e57ca19639dd536b792d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentHostServices.swift
  - id: openwiki-source-59a6dc91233502e57398e06a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentPaneTools.swift
  - id: openwiki-source-e1a028bd99d4dbe6d1e14f6a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentScratchTransferTools.swift
  - id: openwiki-source-1c845e5af67c400566be83bd
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AssistantToolRegistry.swift
  - id: openwiki-source-7b0bd5b2df4c45dd572abbac
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/PlanningSSHExecRunTool.swift
  - id: openwiki-source-f976589f19e3ab05e6ea5a44
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/SSHExecControlTools.swift
  - id: openwiki-source-cd4e1048d6e972f3f86d27e3
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/SSHExecRunTool.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-6d759b4cb61f68a067dae42c
    resource: repo://FrameworkTests/AgentSteeringTests.swift
  - id: openwiki-source-32bb2b0bf7a39f2a4856d7bf
    resource: repo://FrameworkTests/AgentUserInputTests.swift
  - id: openwiki-source-b564fb5c588f5bcbd8ca96f9
    resource: repo://FrameworkTests/AssistantChatCollaborationEdgeTests.swift
  - id: openwiki-source-e2abe97c93dbb91be81b63e2
    resource: repo://FrameworkTests/AssistantChatCollaborationPersistenceTests.swift
  - id: openwiki-source-579d339703ac4d9a47649b91
    resource: repo://FrameworkTests/AssistantChatCollaborationReviewTests.swift
  - id: openwiki-source-247755d873c5d94b0a364217
    resource: repo://FrameworkTests/AssistantConversationOperationsTests.swift
  - id: openwiki-source-6ec3fb4cd6a582cdf278bab9
    resource: repo://FrameworkTests/AssistantExecutionControllerTests.swift
  - id: openwiki-source-ef5d9e4649b42631e4f4a5ec
    resource: repo://FrameworkTests/AssistantModelSelectionTests.swift
  - id: openwiki-source-aec5af6c3be13b44140585c2
    resource: repo://FrameworkTests/AssistantTranscriptPresentationTests.swift
  - id: openwiki-source-256e2b134a8446ea63b15585
    resource: repo://FrameworkTests/HermesMemoryTests.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-105d05d558f14996921a83f6
    resource: repo://Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
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
  - id: openwiki-source-0c46eadbd7a2db45099d59aa
    resource: repo://TFM/Features/AI/TranscriptNativeRows.swift
  - id: openwiki-source-d35453512ef488d0cacdc06e
    resource: repo://TFM/Features/Assistant/AssistantView.swift
  - id: openwiki-source-49c5ca81284394384f3c3913
    resource: repo://TFMTests/AgentBuiltInToolAvailabilityTests.swift
  - id: openwiki-source-8f676dd306369e67985f3dd0
    resource: repo://TFMTests/AgentHostProtocolListingTests.swift
  - id: openwiki-source-2ee11dbdba2a0afac50ee5c4
    resource: repo://TFMTests/AgentPaneToolsTests.swift
  - id: openwiki-source-715de8d16be5a3d06ae915ad
    resource: repo://TFMTests/AgentPersistenceTests.swift
  - id: openwiki-source-d57db929d0047db53dd73cdd
    resource: repo://TFMTests/AgentRuntimeTests.swift
  - id: openwiki-source-1d8dcc1fdf14c37b90cc9e07
    resource: repo://TFMTests/AgentScratchTests.swift
  - id: openwiki-source-7e117096f381ecc32caff068
    resource: repo://TFMTests/AgentSkillTests.swift
  - id: openwiki-source-78797a18dd3153d23a2c42e2
    resource: repo://TFMTests/ChatComposerStateTests.swift
  - id: openwiki-source-32734a5d0c7e053627a24d40
    resource: repo://TFMTests/ContextAttachmentImporterTests.swift
  - id: openwiki-source-8d265a8732f0af93c5d4e274
    resource: repo://TFMTests/MCPServerToolsTests.swift
  - id: openwiki-source-5a540932657f4174b82cb1eb
    resource: repo://TFMTests/TerminalSuggestToolTests.swift
generated: { by: "openwiki/0.7.2", at: "2026-10-17T17:19:40.811Z" }
verified:
  - by: openwiki/0.7.2
    at: 2026-10-17T17:19:40.811Z
---

# Agent Runtime and Assistant

Termind's Assistant is a durable conversation product built around a host-neutral agent loop. **AgentKit**, a separate Swift package, owns the model-provider adapters, run loop, context pipeline, approval gate, MCP client, generic built-in tools, secret broker, and generic scratch/skill/memory tool interfaces. **Termind** owns the app/device integration: SSH and SFTP tools and transport pools, live pane-inspection tools, Vault-backed host resolution, application policy and prompts, SwiftData conversation persistence, Hermes memory lifecycle, and the UI that renders events and collects approvals or SSH challenges. Neither the macOS nor the iOS app target implements the AgentKit provider loop: both assemble its shared runtime through `AssistantExecutionController` and `AssistantToolRegistry`.

This split is a security boundary as well as a modularity boundary. A model proposes tool calls; it cannot type into a PTY or directly access Keychain material, stored credentials, the persistence store outside its tools. With pane inspection injected, it can request a read of an already open terminal's visible viewport through a Termind tool. The Xcode project resolves AgentKit as a remote Swift package (`AkinoKaede/AgentKit`, minimum 2.1.0); ordinary Xcode builds consume the resolved remote package, not the reference or sibling checkout. `Termind.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins release **2.1.0** at revision `0bf0b12dcb3b17e52f2157a260a86faddc748b41` for Xcode: changes to the sibling `../AgentKit` working tree do not change the built app. AgentKit is developed, tested and released independently in that sibling repository; ordinary Termind-side policy, SSH/SFTP registration, persistence and UI changes do not themselves imply an AgentKit release. When a change actually spans the package boundary, make and test the package change, tag and push its release, then update the Xcode `minimumVersion` and resolved revision in the same commit as the consuming Termind change. Build with `-onlyUsePackageVersionsFromResolvedFile` to avoid accidentally resolving newer packages.

## Responsibilities and assembly

The two native apps provide different surface adapters, not separate agent engines: desktop `AppModel` injects host services, pane access and a shared chat coordinator into `AssistantExecutionController`; mobile `MobileAppModel` creates `MobileAssistantModel`, which injects the same registry builder, repository and coordinator. Both paths eventually construct `AgentProviderClient` and `AgentRuntime` in the shared controller, handing its events to `ConversationModel`. The macOS MCP server is a separate external tool-execution surface, not the Assistant's provider loop.

`AgentHostServices.live` is the common host-stack composition boundary: it creates the resolver, connection pool, authentication registry and background-command service using the app's `RemoteConnectionCoordinator` and SFTP concurrency scheduler. Desktop passes those same instances to Assistant and the MCP server; mobile injects the bundle into `MobileAssistantModel`. Connection configuration and route fingerprints resolve through the host library, and the pool consults the host's agent-forwarding setting. This reuses the app's remote-connection infrastructure rather than constructing an Assistant-only transport backend. See [Platform Runtime](../architecture/platform-runtime.md) and [Remote Services and Forwarding](remote-services-and-forwarding.md).

```mermaid
flowchart TD
    Desktop["macOS AppModel"] --> Controller["Shared AssistantExecutionController"]
    Mobile["iOS MobileAppModel"] --> Adapter["MobileAssistantModel"]
    Adapter --> Controller
    Controller --> Registry["AssistantToolRegistry"]
    Registry --> Builtins["AgentKit generic catalog"]
    Registry --> Host["TermindAgentTools host capabilities"]
    Controller --> Runtime["AgentKit AgentRuntime and provider"]
    Runtime --> Conversation["ConversationModel event projection"]
    Runtime --> Repository["Termind run repository"]
    Desktop --> External["macOS MCP server tool surface"]
```

Native assistant composition: app targets inject device services, while the shared controller creates an AgentKit runtime and the separate macOS MCP server exports a restricted tool surface.

For file and image drop entrypoints, attachment import lifetimes, and the shared drop Overlay UI, see [File Drag and Drop Across TFM and TFI](../workflows/file-drag-and-drop.md).

`AssistantExecutionController` is the application entry point for a submitted turn. Before recording a new turn it rejects overlapping starts, archived/history-changing conversations, active compaction, unfinished attachments, and unauthorized use. When configured, `AssistantModelSelectionController.prepareForSend` first persists a valid per-conversation chat-model choice (or replaces an unavailable choice with the current default); a write error refuses capture without consuming the draft. Drafts are seeded with a model in memory, while restore backfills durable choices, and later Chat-role changes do not silently switch an existing valid choice. Accepted submission synchronously captures the composed prompt, images and context attachments; session, plan and surface context; chat model/provider/credential; reasoning and permission mode; search choice; skills and base registry; Guardian configuration; and memory/compaction preparation settings. Only then can asynchronous compaction or memory loading begin. Runtime assembly consumes this capture instead of re-reading mutable composer or configuration state after an await. A missing model or credential remains a captured failure even if Settings changes during preparation.

Termind creates a fresh `AgentRuntime` per run; `ConversationModel.start` owns its queued request and one event consumer. `ConversationModel` owns the live runtime and projects its events into visible messages, tool cards, approval and input queues, run summaries, and the authoritative model transcript. The visible message list is not replay history: tool calls and results are separately rendered as cards, so replay must use `transcript`. A composed user turn likewise has two texts: `authoredText` is the user's draft shown in the bubble, edit form and title input, while model-facing `text` also includes captured attachment blocks and an armed skill directive. Images and context attachments travel as structured payloads; `pendingPriorMessages` omits the final user turn because the request carries that prompt separately; integrated runtime tests confirm the prompt appears in saved messages.

The tool catalog and plan posture are captured at submission; AgentKit selects that captured catalog's executable mode-specific subset when the runtime starts. A tool-capable model receives the captured skill catalog, AgentKit built-ins, and Termind tools; a model without tool-call capability does not receive the skill/tool catalog. `AgentTurnContextSnapshot` is the persistable context portion of the capture: session facts, skill catalog text, plan posture, surface availability, and memory-session identity. It is not a durable copy of provider credentials or all runtime configuration. Surface availability follows the latest delivered user snapshot rather than mutable UI focus.

Termind composes the registry in this order:

1. AgentKit generic tools, including scratch, skill, memory, fetch/search, task, plan, secret, chat collaboration (`list_models`, `create_new_chat`, `list_chats`, `read_chat`, `send_to_chat`, `wait_chats`), and MCP support.
2. Termind's device and host tools: host/metrics discovery, the `ssh_exec_run` / `ssh_exec_output` / `ssh_exec_stdin` / `ssh_exec_cancel` / `ssh_exec_list` family, terminal suggestions, SFTP operations, the host-facing `scratch_pull` / `scratch_push` endpoints, and `list_panes` / `read_pane` when live pane access is injected.
3. Discovered MCP tools, which are additive and cannot shadow a built-in or Termind tool name. The integration regression checks first-registration-wins collision handling; do not infer other discovery or retry behavior from this ordering. Registry construction captures usable server configurations and bearer tokens, while execution still depends on authorization and tool policy.

The shared `AssistantChatCoordinator` implements AgentKit's chat catalog and coordinating interfaces for both native apps; `AssistantToolRegistry` injects it and the captured source context into AgentKit's generic chat tools, rather than defining a second set of platform-specific collaboration tools. The chat model catalog reports enabled Chat models and readiness without exposing credentials. See the [cross-chat delivery lifecycle](#cross-chat-collaboration-and-delivery) for its persistence boundary.

### Catalog, run mode, and surface availability

`TermindAgentTools` is the shared static registration point. Its injected environment supplies host resolution, metrics, connection/authentication pools, background commands, and optional scratch workspace **and live pane access**. Dependencies determine which capabilities can be constructed: `scratch_pull` and `scratch_push` need the workspace; `list_panes` and `read_pane` need `AgentPaneAccess`. `AssistantToolRegistry` returns an empty registry for a model without `toolCall`. A sending-surface Boolean is not a registration input: desktop and mobile use the same definitions, but their run captures may inject different live capabilities. Pane access is run-scoped, not stored on the conversation: app adapters enumerate open terminal panes across windows/scenes, expose only connected panes with a readable viewport in listings, and report a closed, disconnected or missing-surface pane instead of creating a connection. `list_panes` returns metadata (including active-window and originating-window-current flags), not text. `read_pane` reads a visible viewport without typing or changing focus; `pane_id` is required and can identify another open pane. Use the intended ID captured in session context or a prior result; list panes only to discover an unknown or unavailable target. It refuses missing/invalid/closed/unreadable targets rather than falling back and returns the viewport text supplied by the adapter with `truncated: false`. `ReadPaneTool` opts out of generic output truncation; it no longer imposes a 65,536-byte cap. Pane text is model-facing tool output, but the tool-card detail deliberately shows only pane name and ID, not the captured text. This read-only capability does not confer SSH/SFTP execution or terminal input.

```mermaid
flowchart TD
    Submit["App submits turn with pane access"] --> Capture["Controller captures registry"]
    Capture --> Capable{"Model can call tools"}
    Capable -->|No| Empty["Empty registry"]
    Capable -->|Yes| Injected{"Pane access injected"}
    Injected -->|No| Other["No pane tools"]
    Injected -->|Yes| Pane["Register list_panes and read_pane"]
    Pane --> Call{"Tool call"}
    Call -->|List| Metadata["List readable pane metadata"]
    Call -->|Read| Resolve["Validate required pane ID"]
    Resolve --> Readable{"Open connected readable surface"}
    Readable -->|No| Refuse["Return tool error"]
    Readable -->|Yes| Viewport["Return adapter viewport to model"]
    Viewport --> Card["Card shows name and ID only"]
```

Pane-tool path: registration depends on captured capability, but list/read consult the app's live pane state at execution time. The normal runtime schema and approval pipeline still applies.

AgentKit selects the executable registry for the run's mode. Planning retains discovery, metrics, SSH investigation, SFTP reads, `scratch_pull`, and injected pane listing/reading; remote SFTP mutations and `scratch_push` are acting-only, and Termind contributes no tools to reviewing. Planning and acting share the `ssh_exec_run` descriptor and schema, but planning uses a preflight that denies destructive commands. Acting asks for those commands; commands proven safe can be approved and run in parallel in either mode.

`terminalSuggestionsAvailable` is the application argument that captures the separate execution gate in `AgentTurnContextSnapshot.toolAvailability["terminal_suggest"]`. It does not remove or change the advertised tool schema:

| Surface | Terminal suggestion execution | Tool definitions |
| --- | --- | --- |
| TFM standalone Assistant | `false` | Shared Assistant catalog. |
| TFM Workspace Assistant sidebar | `true` | Shared Assistant catalog. |
| TFI standalone Assistant | `false` | Shared Assistant catalog. |
| macOS external MCP server | Not exported | Acting host subset, `request_user_secret`, and four HTTP transfer tools; no pane tools. |

This snapshot dictionary is a partial override: disabling terminal suggestions does not disable independent SSH/SFTP work. The MCP server explicitly selects acting definitions, then filters by its exported-name allowlist and disabled-tool settings. It excludes terminal suggestions, pane reading/listing, scratch, web, skill, plan and task tools; its four extra tools are `sftp_upload`, `sftp_upload_status`, `sftp_download` and `sftp_download_status`. The stdio bridge forwards requests to this server and registers no second tool set; TFI has no local MCP server. See [MCP Server and Bridge](../integrations/mcp-server-and-bridge.md) for the external authorization and byte-transfer boundaries.

## Turn lifecycle

Desktop sidebar, standalone Assistant, and mobile first sends use the same controller-owned capture path as subsequent sends. A first conversation is promoted into the library only after capture and local turn append succeed; the obsolete `startConversation`/`startDraftConversation` shortcuts were removed. Refused sends leave the draft, attachments, armed skill and ephemeral conversation unconsumed. Accepted composer sends fold attachments and an armed skill directive into the model-facing turn once, clear those composer payloads, and clear the submitted draft. Direct text sends and plan implementation also fold those payloads once but leave unrelated ordinary draft text alone.

Edits have a separate two-stage entry point: desktop and mobile UI call `prepareAgentEdit` synchronously before creating their UI `Task`. It preserves the original attachment payload and model-facing suffix while capturing fresh context and configuration for the replacement submission. `performAgentEdit` checks the capture identity before starting a tracked history task; persistence succeeds before the live edit is applied, and another identity check precedes runtime preparation. A cancelled or superseded prepared edit cannot later enter truncation or start a runtime.

At the AgentKit handoff, Termind supplies an `AgentRunRequest` with the captured prompt, context, prior transcript and permission mode, plus a repository and a shared `AgentEventChannel`. Termind's integration tests exercise streaming model turns, schema rejection before approval, tool-result replay and terminal snapshots; the precise internal order of AgentKit's writes relative to provider requests or the next tool round cannot be proven from this checkout of the resolved AgentKit package. Do not treat the diagram's runtime portion as a substitute for auditing that pinned release when changing its persistence ordering.

```mermaid
sequenceDiagram
    participant User
    participant Library as Assistant Library
    participant Conversation
    participant Controller
    participant Runtime
    participant Gate as Approval Gate
    participant Host as Termind Host Tool
    participant Store as SwiftData Repository

    User->>Controller: submit draft
    Controller->>Controller: validate and persist model choice
    Controller->>Controller: capture turn and runtime configuration
    Controller->>Conversation: mark preparing and append captured turn
    opt first send
        Controller->>Library: promote captured conversation
    end
    opt preparation needs compaction or memory
        Controller->>Controller: await captured compaction then memory session
    end
    alt capture stopped during preparation
        Controller->>Store: save interrupted snapshot
        Controller->>Conversation: project interruption if saved and retire preparation
    else captured model or credential missing
        Controller->>Store: save failed snapshot while preparation is owned
        Controller->>Conversation: project failure only if save succeeds
    else capture remains current
        Controller->>Conversation: queue runtime with captured request and registry
        alt queued stop before runtime start
            Conversation->>Store: save cancelled snapshot in separate task
        else event consumer starts runtime
            Conversation->>Runtime: start and consume events
            Runtime->>Store: persist run snapshots and durable events
            Runtime->>Runtime: stream provider turn
            Runtime->>Runtime: validate tool schema
            Runtime->>Gate: authorize when policy asks
            alt approved
                Gate-->>Runtime: allow
                Runtime->>Host: execute SSH or SFTP work
                Host-->>Runtime: bounded result
                Runtime->>Runtime: continue model loop with tool result
            else denied or review failure
                Gate-->>Runtime: deny
                Runtime->>Runtime: continue with refusal result
            end
            Runtime-->>Conversation: events and terminal state
        end
    end
    Conversation-->>User: messages and tool cards
```

Accepted-send lifecycle: model selection and capture precede asynchronous preparation. Interrupted and captured-failure saves belong to Termind's controller; queued prestart cancellation belongs to `ConversationModel`; AgentKit owns persistence once started. Edits first commit their history replacement before runtime preparation. The runtime's internal snapshot timing is not specified by this diagram.

### Preparation and cancellation ownership

`ConversationModel.isPreparingAgentRun` is distinct from `isStreaming`; `isAgentRunActive` combines them for activity guards. Preparation has no runtime that can accept steering, so it must not masquerade as streaming. When neither compaction nor memory loading is needed, preparation can hand off synchronously without an asynchronous preparation task.

Stop, controller-wide cancellation and mobile background expiration synchronously mark an ordinary preparation capture cancelled and prevent its runtime start. Cancellation cancels and joins tracked edit-history/preparation work before finishing its interrupted save; completion rechecks identity after the save so an older cancellation cannot retire a replacement capture. **Exception:** if a missing-model/credential failure is already in `savingFailure`, stop and global cancellation *join that in-flight failed save instead of replacing it with an interrupted snapshot*. The controller's save task retains its owners until completion; only a successful save projects the failed run and adopts a staged edit. A failed save presents an error, leaves staging intact, and retires preparation without claiming a durable failure. The concrete SwiftData truncation method checks cancellation before entering its synchronous transaction. These boundaries prevent a stopped or superseded preparation from later editing history or starting a runtime; they do not roll back a history transaction that already committed.

Archive/delete operations cancel and await pending preparation before their existing activity guards and persistence work. Manual compaction refuses preparation, while selecting another conversation leaves its preparation running. Automatic compaction uses the captured model/settings and the valid transcript available during preparation, with persistence preceding the live projection change.

### Streaming, steering, and cancellation

While a run is live, a further user message is queued as steering rather than starting another run. Termind makes it visible in the transcript on `steeringDelivered`; integration tests show delivery in the next model request and a saved snapshot, but the pinned package's exact write ordering is not visible here; if the run has already ended, the UI returns queued text and attachments to the composer. This prevents history from claiming that a message was delivered when it was not.

Steering captures the sending session context and updates only the `terminal_suggest` availability entry. It preserves other tool overrides, the fixed skill catalog and plan contract, and the memory-session identity. Queuing does not change `ConversationModel.activeContextSnapshot`; delivery does. If the conversation has no legacy snapshot, steering keeps that context unknown instead of filling it from current UI state. The persisted availability key remains `terminal_suggest`.

For an already-started runtime, stopping requests runtime cancellation, marks running cards interrupted in the presentation, and returns undelivered steering text. The runtime integration test shows an in-flight tool is cancelled; secret lifecycle is exercised in integration tests, but its precise disposal timing must be checked against the pinned AgentKit release. `stopAndWait()` requests preparation and active-run cancellation before awaiting preparation and the tracked run consumers; it does not wait to request runtime cancellation until preparation finishes.

The queued-runtime handoff has its own cancellation persistence path. `ConversationModel.start` installs an owner before scheduling its event consumer; if stop wins while that owner is still queued, it constructs a cancelled snapshot from captured request data, starts a separate repository save and `stopAndWait()` joins the consumer that awaits it. If the consumer has entered `AgentRuntime.start`, runtime cancellation and its terminal snapshot path take over. Thus a queued stop need not create a *running* snapshot or call the provider, but a successful queued-cancellation save is durable; the presentation may show cancellation before the save finishes, and the queued save currently swallows repository errors. Do not confuse this handoff with preparation interruption, which is an earlier, separately saved state.

```mermaid
flowchart TD
    Stop["Stop or stopAndWait"] --> Prep{"Preparation phase"}
    Prep -->|Ordinary| Invalidate["Invalidate capture and cancel tracked work"]
    Invalidate --> Join["Join history and preparation tasks"]
    Join --> Save["Save interruption and recheck identity"]
    Prep -->|Saving failure| Failure["Join existing failed save"]
    Stop --> Owner{"Runtime owner phase"}
    Owner -->|Queued| Queued["Save captured cancelled snapshot"]
    Owner -->|Starting or started| Runtime["Request AgentRuntime cancellation"]
    Stop --> Present["Settle presentation and return human steering"]
    Queued --> Consumer["Join retained event consumer"]
    Runtime --> Consumer
```

Cancellation has separate preparation and runtime owners: `stop` requests cancellation and settles presentation, while `stopAndWait` also joins their tracked work.

### Provider retry presentation

Provider retry policy remains AgentKit-owned, but Termind explicitly projects retry events. On `modelRetryScheduled`, `ConversationModel` clears the affected assistant bubble's partial text, reasoning and suggested commands, associates it with the reported run, keeps it streaming, and resets the streaming context estimate. `modelRetryRecovered` clears only matching retry progress; `messageFinished` clears it when the final message replaces the bubble. Desktop native rows and mobile conversation rows use `AgentWorkPresentation.reconnectingTitle` instead of cycling ordinary working labels while retry progress is present. This is an automatic-retry display, not a manual history Retry/Resume entry point, and does not establish the package's retry limits or persistence ordering.

### Context estimates and reported usage

`contextEstimate` is an incremental gauge, not a provider billing ledger. `usage` holds the newest turn's provider report rather than cumulative conversation spend; it is not persisted, so reopened conversations start with estimates until another report arrives. Without measured usage it estimates system prompt, captured tool schemas, conversation text, tool results and attachments. Attachment chips share the estimator's text divisor; images use a tile approximation. Provider usage supplies a measured total (`inputTokens + outputTokens`), but the category breakdown is still an estimate rescaled to sum to that total—not provider-reported attribution per category. Cached input is already part of the normalized input total, not an extra amount to add. Provider regressions cover empty-choice/candidate usage chunks, Anthropic cache-read/cache-creation normalization and cumulative-field merging by maxima rather than summation.

The conversation records schemas once during assembly instead of rebuilding a registry on each keystroke. Draft-text edits do not rebuild or change the history estimate; attachments do update it. Raw text and reasoning deltas become visible immediately while context-gauge publication is throttled, with final message events publishing the settled estimate. History editing clears stale measured usage and recomputes for the retained prefix and replacement. A context-window share is unavailable when the window is unknown and clamped when overfull. See the token and composer regressions below before changing this accounting.

### Explicit attachments: model payload versus reopenable source

Context is disclosed explicitly: output, selections and file contents become composer chips rather than silently riding along with a terminal session. For an imported non-image file, `ContextAttachmentImporter` keeps **validated extracted text** in `ContextChip.content` and **original bytes** in `sourceAttachment`. Text, PDF and modern Office extraction have validation and size checks; image-only PDFs are refused rather than OCRed. The import limits include 25 MiB per file and 200,000 extracted characters. Images follow a separate normalization path and become structured `AgentImageAttachment`s. See [file drag and drop](../workflows/file-drag-and-drop.md) for entrypoints and import cancellation.

`composeUserTurn` places non-image chip content in labeled blocks in model-facing `text`, preserves the ordinary draft as `authoredText`, and carries source bytes as `contextAttachments`. The controller freezes these fields before preparation and passes them as `prompt`, `authoredPrompt`, `promptImages` and `promptContextAttachments` to `AgentRunRequest`. Original document bytes are for reopening, not a substitute for validated extraction as model text. The repository stores attachment backing by message ID and restores it alongside replay/context backing; queued prestart cancellation also preserves these captured fields without calling the model.

The display projection does not send a large extraction through Markdown. Live bubbles retain authored text and chip references; restored bubbles use `authoredText` (or legacy `visiblePrompt`) and `visibleReferences`, matching stored attachments by kind and label. References retain an attachment handle for opening, not the extraction as bubble text. If historical markup has no original backing, a file reference falls back to an extracted-text attachment marked `isOriginalFile == false`, not a fabricated original PDF. On desktop, opening materializes the attachment's bytes under a private temporary directory with a sanitized filename; previous-session previews are removed on launch.

```mermaid
sequenceDiagram
    participant Importer as Attachment importer
    participant Composer
    participant Ctrl as Execution controller
    participant Runtime as AgentKit runtime
    participant Repo as SwiftData repository
    participant UI as Transcript projection
    Importer->>Composer: chip with validated extraction and original bytes
    Ctrl->>Composer: compose and capture accepted turn
    Composer-->>Ctrl: text, authoredText, images and contextAttachments
    Ctrl->>Runtime: captured AgentRunRequest
    Runtime->>Repo: snapshot with message payload and backing
    Repo-->>UI: restored messages and attachment backing
    UI->>UI: authored text and lightweight chip references
    UI->>UI: open retained bytes on explicit action
```

Attachment data flow: model-facing extraction and reopenable source remain distinct, while the bubble is only a display projection of the durable turn.

## Approval, secrets, and trust boundaries

Approval is evaluated after schema validation and tool preflight, before execution. Invalid arguments never reach the approval UI or the tool. The policy layer is stronger than permission mode:

- **Deny** always refuses the call.
- **Approve** executes without an additional approval prompt.
- **Ask** routes to the user under `askForApproval`, to Guardian under `approveForMe`, or is pre-approved by `fullAccess`.

`fullAccess` does not bypass schema validation, host-key trust, SSH authentication, secret binding, scratch containment, network/fetch restrictions, or tool-specific capability checks. Guardian review is only configured in `approveForMe`; it has a bounded timeout and failures, malformed output, inconsistent decisions, and critical-risk approvals fail closed. If the conversation disappears before a manual decision, the approval broker denies the request.

SSH authentication and host-key prompts are Termind interactions, not model-visible tool data. `AgentHostResolver` exposes public host metadata to `list_hosts`, but resolves Keychain-backed credentials into connection configuration without serializing them into tool results. Authentication context is normally shared only across overlapping attempts for the same destination (forwarding-enabled operations use isolated contexts); after successful authentication it clears staged submissions and cached secret-bearing configuration. Stale generations reject late callbacks and host-key decisions.

`request_user_secret` is only for command standard input, not SSH login. Its handle is scoped to run, tool, host, and stated purpose, single-use, and is removed from replay and durable history. Plaintext secrets must not enter model requests, Guardian review, events, logs, SwiftData, or Hermes memory.

### User questions and live approval presentation

`request_user_input` and `request_user_secret` use AgentKit's interaction interface and Termind's `ConversationModel` queue, not a new agent run. The former accepts at most three validated questions; an optional `timeout_seconds` is bounded to 1–1,800 seconds and defaults to five minutes. Requests are ordered by creation time, but only the visible head starts its deadline and owns answer drafts. Navigation between its questions does not reset that deadline. A question must be answered or explicitly skipped to advance; secrets cannot be skipped and use a separate draft that is cleared on submit, cancellation or timeout. Skipped questions are absent from the interaction response; `request_user_input` reports them to the model as null answers rather than silently losing the question. Cancellation and timeout discard partial drafts instead of returning partial answers.

Manual approvals have their own creation-ordered queue. Only its head can be answered; `requestApproval` holds the continuation and stages the card before the ordered event consumer drains `toolProposed`. A late approval notification cannot turn a denied card back into a waiting card. Stopping interrupts pending review/approval cards and resolves outstanding interactions rather than leaving a stale prompt. The live approval projection shows reviewable in-memory arguments, including the exact command, without attaching that projection to the durable card or model transcript.

```mermaid
sequenceDiagram
    participant Runtime
    participant Conversation
    participant Person as Assistant UI
    Runtime->>Conversation: request user input
    Conversation->>Conversation: enqueue by creation time
    Conversation-->>Person: display head and start deadline
    alt answered or explicitly skipped
        Person->>Conversation: submit answers
        Conversation-->>Runtime: answered response
    else timeout or cancellation
        Conversation->>Conversation: clear head drafts
        Conversation-->>Runtime: timed out or cancelled
    end
    Conversation-->>Person: show next head with new deadline
```

This interaction sequence describes the queue's per-head deadline, not the lifetime of a model turn or an approval decision.

## Host tools and plan mode

Termind tools operate through noninteractive per-command SSH channels and exclusive SFTP leases; they never type into the user's interactive terminal. `AgentConnectionPool` keeps a host-keyed multiplexed SSH connection across runs and conversations, with a 180-second default idle timeout, route-fingerprint invalidation and explicit disconnect/closeAll; SSH exec and the primary SFTP subsystem share it. `AgentSSHAuthenticationRegistry` normally shares temporary authentication only among overlapping attempts for the same host and releases it after the last lease. With agent forwarding enabled, each operation instead gets its own authentication context; it does not join the host-shared context. SFTP operations acquire an exclusive lease and release it even on failure; only acquisition/authentication retries, not the operation itself. Transfer work takes an SFTP concurrency permit. An `ssh_exec_run` connection-unavailable retry is allowed only before a command session opens; a running command is never replayed after an uncertain failure. Foreground commands close stdin and wait without a runtime timeout. Explicit background commands return only after confirmed startup and retain open stdin. Conversation-scoped handles support immediate cumulative output snapshots, input, local cancellation and listing; SSH model output keeps the latest complete lines within 64 KiB / 2,000 lines, with truncated output captured under a generated `<conversationID>/outputs/ssh-exec-<UUID>.txt` shared scratch path and capture failures made explicit. Finished results remain for ten minutes. Cancellation retires the local handle without confirming remote termination. `terminal_suggest` accepts only a command and creates a user-operated card without executing it. The schema rejects an `explanation` argument, the result contains command/risk/requires-user-action, and legacy explanation fields are not displayed. Suggested commands use the shared `SuggestedCommandCodeBlock`; permission and captured surface availability remain separate from rendering. The standalone Assistant can discover and target configured hosts even without a sidebar session or open PTY; session context is only an optional default target. Separately, `list_panes` and `read_pane` inspect *already open* local terminal viewports through the captured app adapter, including connected SSH, Telnet, and (on desktop) serial panes; they do not create a PTY or run a command. `list_hosts` lists enabled protocols without credentials, including Telnet-only hosts. SSH/SFTP execution requires SSH to be enabled; discovering a Telnet-only host does not provide an Agent Telnet execution capability.

Plan mode freezes at submission. It permits investigation, reads, and policy-allowed commands, but host-specific planning registrations refuse direct remote writes, deletes, and scratch pushes. A plan is drafted in scratch space and presented as the final action; presenting it does not itself suspend a run awaiting a decision.

Implementing a pending plan is a new captured submission. The controller clears the captured `planContract` before capturing the run so implementation is acting work, then appends the composed implementation prompt and resolves the plan as implemented. Refusal leaves the pending plan, planning state, attachments and armed skill untouched.

## Scratch workspace containment

Tool-capable conversations use `AgentScratchWorkspace.shared(applicationName:)`: a persistent device-local workspace shared across conversations, not a conversation isolation boundary. Use explicit task-specific relative paths and check existing files before overwriting. Generated output capture paths contain a conversation ID for organization, not access control. Scratch paths are normalized and bounded; escapes, absolute paths, parent traversal, control characters, excessive depth, and symlinks are refused. Entry and byte quotas are enforced before mutation.

The recommended remote-edit route is `scratch_pull`, local scratch editing/diffing, then `scratch_push`. File bytes remain outside the conversation/model transcript: pull reports metadata rather than file contents. Push is an Ask action; its preflight records bounded, redacted evidence and a digest. Execution re-reads the staged file and rejects it if its digest differs from the approved digest, so approval cannot be reused after content changes.

Forking and deleting conversation history do not copy or remove the shared scratch files. Conversation deletion deletes the durable graph and discards its secret handles; shared workspace lifetime is independent of conversation lifetime.

## Durable conversations, replay, and recovery

`SwiftDataAgentRunRepository` stores conversations, runs, messages, replay backing, attachments, tool invocations/results, reviews, ordering metadata, and compaction records. It writes messages by message ID rather than run ID, so replaying prior conversation history into later run snapshots does not duplicate historical rows. Tool event persistence is restricted to durable lifecycle events rather than streamed token deltas.

A saved context snapshot preserves historical session, skill-catalog text, plan and surface facts for replay and fork history. Explicit `startAgentRun` uses the last user turn's stored snapshot, or a neutral `AgentTurnContextSnapshot()` for legacy absent context rather than inventing facts from current UI state. This is context replay, not reconstruction of historical model/provider settings, credentials or skill-package bytes: the controller still captures the current runtime configuration. An edited submission deliberately captures fresh context instead of inheriting the historical snapshot. Restored nonterminal runs are interrupted rather than automatically executed again. The visible transcript surfaces inspected here do not expose a manual Retry/Resume action; any provider-level retry semantics are AgentKit-owned and must be verified in the pinned release.

Persisted text, tool arguments, titles and reasoning go through redaction. In particular, secret handles are replaced with expired lifecycle content on restore, and sensitive header values are redacted. **Original attachment bytes are a different storage boundary:** `PersistentAgentContextAttachments` encodes the captured attachments directly, without passing their bytes through `AgentPersistenceRedactor`. Do not assume that redaction of extracted prompt text sanitizes the original document retained for reopening.

Tool cards resolve their persisted presenter ID through the immutable presenter registry, combining AgentKit built-in presenters with Termind registrations. Cards predating those IDs use the closed legacy tool-name list and its `builtin.` IDs. Registration and surface-availability changes preserve those identities and the persisted context key; they do not require a SwiftData schema change. Presentation is a separate projection: localized action verbs, punctuation and lifecycle summaries do not rewrite the original call or result used for execution, approval or replay. Built-in JSON results can use a registered structured presenter or a generic fallback, while MCP keeps remote-defined JSON output and does not use local presenters. Local chat-collaboration tools are an exception to generic fallback: missing/malformed or failed details produce a safe unavailable-details message, and approval arguments require their presenter rather than exposing a generic argument dump. Tool summaries group by tool, state and knowledge action so mixed successes and failures do not read as one success. Display text previews use `AgentTruncateResult` with middle truncation, `AgentTruncateLimits.maximumBytes` and 120 lines, retaining the full transformed output for Copy. This UI preview is distinct from runtime output projection: the controller also configures `AgentToolOutputProjection` with the shared scratch workspace. Both platforms use shared `AssistantMessageBody` over MarkdownView, and `TermindMarkdownParser` delegates block parsing to MarkdownParser. Inline titles retain emphasis, code, link destinations and image alt text; the previous soft-break rewriting and local unsafe-link filtering adapters were removed. Native list ownership, row measurement and interaction remain platform-owned.

Compaction changes the **model-facing** transcript, not the scrollable display history. Its summary record is persisted before the live conversation applies it; after recovery the model receives a synthetic compaction summary plus recent messages while the user can still read the full original conversation.

### Cross-chat collaboration and delivery

AgentKit supplies the generic chat tool interfaces; Termind coordinates local conversations and the durable receipt. `create_new_chat` chooses an explicit available Chat model or the captured source model, persists the target's selection, and inherits the **captured** permission and plan mode. It does not inherit source session context, composer drafts, attachments or armed skill. `send_to_chat` refuses self-delivery, archived or history-changing targets and planning-to-acting sends (checking the target's effective running posture). Idle targets capture **their own** model and policy with no terminal-suggestion context, without consuming a human draft; active targets instead queue an origin-tagged steering message. Agent-origin user turns are not editable like ordinary human turns.

```mermaid
sequenceDiagram
    participant Source as Source run
    participant Coord as Chat coordinator
    participant Target as Target conversation
    participant Store as Collaboration store
    participant Repo as Run repository
    Source->>Coord: create or send with source run and call IDs
    Coord->>Store: look up existing receipt
    alt idle target or new chat
        Coord->>Target: capture incoming turn
        Coord->>Store: reserve queued receipt and creation relation if new
        Coord->>Repo: save origin tagged staged prompt
        Repo->>Store: confirm queued receipt with message commit
        Coord->>Target: insert if new and start preparation
    else active target
        Coord->>Store: reserve queued receipt
        Coord->>Target: queue origin tagged steering
        Target->>Repo: persist delivered message in runtime snapshot
        Repo->>Store: confirm receipt with message commit
    end
    Coord-->>Source: status and receipt ID
```

Cross-chat delivery: the durable prompt save is the acceptance boundary for an idle/new target; a queued steering message is not delivered until it enters the target transcript. The repository confirmation applies to SwiftData, while the in-memory store confirms from delivery callbacks.

A receipt is keyed by `(sourceRunID, sourceToolCallID)` and links source and target IDs to the incoming message ID. Repeating the same call returns its receipt/status instead of delivering a second prompt; `delivered` cannot be downgraded by a stale queued or undelivered write. The SwiftData repository inserts message-origin backing and upgrades matching queued receipts **in the same message-save transaction**, even when the receipt store and repository use different `ModelContext`s. For idle/new deliveries, a prompt save failure cancels preparation and marks the receipt undelivered; a later metadata write failure is nonfatal after the durable prompt. For active targets, an unaccepted or cancelled steering message becomes undelivered and **does not** enter the human composer. On restore the coordinator reconciles queued receipts against persisted transcript/display message IDs: a found prompt confirms delivery for stores without transactional confirmation, while an absent prompt with no live owner is undelivered. Retries after target deletion report historical receipt status, not a newly created chat.

Creation relations are a separate durable sidecar from individual message origins. `list_chats` batches creator relations per 20-chat page, defaults to excluding archived chats, and resolves the source's current title or the *matching creation message's* saved title if the source is gone; a later delivery does not change the creator, and a manual fork is user-created. `read_chat` pages visible (not replay) messages and recent tool summaries and receipts, using pages of up to 20 visible messages and a cursor with an optional one-based line offset. The coordinator returns message text without the old 8,000-character per-message / 40,000-character page caps; package-level output projection is a separate boundary. `wait_chats` validates targets and waits for a terminal or user-waiting state, but never treats an older completed run as ready while a new one prepares. It races target change against timeout and user interjection without stopping the target run.

### Message-boundary edits and replacement provenance

`AssistantConversationOperations.edit` validates an ordinary replacement user message before persistence and applies the live mutation only after truncation succeeds. An editable target must still be a non-compaction user row in the model-facing transcript with `origin == nil`; streaming, compaction, archive, history mutation and captured-failure persistence block editing. Ordinary preparation is deliberately supersedable. Origin-bearing cross-chat messages are not human-authored turns and cannot be edited, even though their transcript role is `.user`; SwiftData also rejects an origin-backed target independently of the UI guard.

**Tool activity in the removed suffix does not prevent editing.** Calls, results and cards are removed even for proposed, denied, read-only or completed tools; retained prefix tools keep their graph. This is a history replacement, not an undo of an executed SSH command, transfer or other external effect. SwiftData checks cancellation before its synchronous transaction and uses the same canonical order for restore and truncation: runs by start time then UUID, messages by run order then sequence, timestamp, role and UUID. The selected message and everything after it are removed, not automatically its entire run. For `opening → assistant → steering → assistant`, editing the steering turn retains the opening and preceding assistant/tool batch. The retained partial run becomes a neutral `.completed` summary with no old failure and ends at its last retained non-tool message; wholly later runs, including empty ones, are removed.

Tool cleanup follows ownership before time. Known source-message and run-local call identities distinguish retained prefix tools from removed suffix tools, with results and reviews deleted alongside removed invocations. Restore infers missing legacy source IDs from the raw assistant call grammar; deterministic recovered tool-result IDs receive run ownership. The live projection additionally uses retained result ownership and the full visible prefix when compaction has hidden raw messages from the model transcript. Only invocations/cards without recoverable ownership fall back to `createdAt >= target.createdAt`, conservatively including the exact cutoff. This includes legacy rows and modern provider-native events persisted before their source message reaches a snapshot. Compaction records are removed only when their explicit boundary message is removed; nil-boundary fork bases survive, and live compaction marks are rebuilt. Editing after a retained opening does not clear its title, even when that opening is compacted out of the model transcript; live plans at or after the cutoff are removed.

The replacement is durable before a runtime exists: its message ID also identifies an independent, completed, failure-free staging run containing that one user row and no tool graph. Its start time is placed after the latest retained run if clocks tie or move backward, including when the earlier retained run has no messages. On the first real snapshot containing that staged final user turn, `save` transactionally moves only the staged message to the real run, assigns its snapshot sequence, retains its attachments/replay backing, deletes the staging run and retires its ID. Historical messages replayed into the snapshot keep their existing owners and are not duplicated. Adoption preserves the staging start-time lower bound; subsequent snapshots cannot move it backward, and terminal time is clamped to that start when necessary.

`ConversationModel` mirrors adoption on `runStarted`, successfully saved captured failure, preparation interruption and queued prestart cancellation; `runFinished` retains the adjusted chronology. A committed failed, interrupted or prestart-cancelled replacement therefore has the real run's provenance rather than an abandoned staging summary. Preparation cancellation awaits the interrupted save and rechecks identity before adopting. Missing-model/credential failure instead holds preparation in a `savingFailure` phase: stop, archive and delete wait for its save; it calls `recordFailedRun` only after save success and retires preparation after success or error. A failed save leaves the staging owner intact and shows an error rather than claiming a durable failed run. The queued prestart path projects cancellation before its save completes; use `stopAndWait()` to join it. The persist-before-live contract above specifically concerns the history mutation boundary, not every transient presentation update.

```mermaid
sequenceDiagram
    participant UI as Native Assistant UI
    participant Ctrl as Execution controller
    participant Ops as Conversation operations
    participant Repo as SwiftData repository
    participant Live as Conversation projection
    UI->>Ctrl: prepareAgentEdit synchronously
    Ctrl->>Ctrl: preserve authored suffix and attachments
    Ctrl->>Ctrl: capture fresh context and configuration
    UI->>Ctrl: performAgentEdit in UI task
    Ctrl->>Ctrl: check capture identity
    Ctrl->>Ops: tracked history edit
    Ops->>Repo: truncate selected user boundary
    alt transaction fails
        Repo->>Repo: rollback and restore retired IDs
        Repo-->>Ctrl: error without live history mutation
    else commit succeeds
        Repo->>Repo: keep prefix and stage replacement
        Repo-->>Ops: committed
        Ops->>Live: apply persisted replacement
        Ctrl->>Ctrl: recheck identity before preparation
        opt current capture produces a real snapshot
            Ctrl->>Repo: runtime or preparation terminal snapshot
            Repo->>Repo: adopt staged row and retire staging ID
        end
    end
    UI->>Repo: reopen conversation later
    Repo-->>Live: restore replay backing and owned tool results
```

Edit/replay boundary: durable truncation precedes the live replacement, and the real run adopts the staged row without duplicating retained history.

The repository instance retires the edited target run, removed later runs and adopted staging run so late snapshots or durable tool events cannot resurrect the discarded suffix. Truncation and snapshot save roll back SwiftData changes and restore the previous in-memory retired-ID set on error. These rules use the existing schema and Termind's Application/Persistence adapters, without changing AgentKit or its package pin. See [Persistent Data](persistence-and-secrets.md) for the storage contract.

### Restore and metadata

At repository initialization, every nonterminal persisted run becomes `interrupted`; Termind never replays unfinished execution automatically. Restore reconstructs completed tool cards and can recover a durable tool result that was recorded before its next transcript snapshot. If an outcome remains unknown, repair records an explicit unknown/refusal result rather than assuming a call was never dispatched.

```mermaid
stateDiagram-v2
    [*] --> Restored
    Restored --> Completed: terminal run stored
    Restored --> Interrupted: nonterminal run on launch
    Interrupted --> Ready: history and cards restored
    Completed --> Ready: history and cards restored
    Ready --> Preparing: accepted capture
    Preparing --> Queued: current capture handed to conversation
    Preparing --> Interrupted: cancellation save succeeds
    Preparing --> SavingFailure: missing model or credential
    SavingFailure --> Failed: save succeeds
    SavingFailure --> Ready: save fails and error shown
    Queued --> Cancelled: prestart cancellation save succeeds
    Queued --> Running: runtime starts
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

Preparation and run lifecycle: `SavingFailure` remains owned during stop until its save ends; the `Ready` arrow on save error means the guard is released, not that a failed run was persisted. Queued cancellation can be projected before its save finishes, so its arrow describes the durable-success case, not a guarantee of a committed state. Restored interrupted history is never silently rerun.

Conversation metadata mutations are persistence-first. Archive clears pinning and prevents editing; after cancelling pending preparation, archive/delete remain guarded while streaming or compaction is active. Reordering commits the whole ordering update before changing the in-memory library. These rules avoid UI state claiming a history mutation that failed to save.

Automatic titles require a real nonempty assistant reply in the authoritative transcript, not a visible failure message. A completed reply can qualify even if the run is later stopped. Title generation resolves its configuration when it runs, independently of the submitted turn's frozen configuration. Post-run memory *activity* is installed only for non-planning runs with a valid learning token: completed runs pass their accepted user-turn IDs, while tool activity may also be recorded for other run outcomes. A model-backed review is thresholded on accumulated turns or tools (or explicitly forced); preparation cancellation has no runtime activity callbacks.

## Skills

Skills are global app-managed packages, not per-conversation data. Submission snapshots the enabled catalog and inventory before preparation, so subsequent Settings changes do not replace that run's captured catalog. This is not archival replay of package bytes. Reserved skill names cannot be shadowed, and collisions remain visible but paused.

A skill is procedure-bearing only when read through `skill_read_file` from its `SKILL.md`. Supporting files, package frontmatter, tool output, remote files, web pages, and MCP responses are untrusted reference data—not instructions or authorization. Skill installation is acting-only, revision-bound, and subject to normal tool approval; a skill cannot grant permission to execute a command, write a file, transfer data, or bypass other policy.

## Hermes device-local memory

Hermes memory is optional and disabled by default. AgentKit supplies the memory tools, screening/learning model, revocable session context, and access interface. Termind supplies Settings and lifecycle management, while `GRDBMemoryStore` alone owns the memory database at `Termind/HermesMemory`; SwiftData remains the source of truth for conversations.

The GRDB store opens lazily, so disabled memory does not create or open its database. `MemoryModel.session` checks enabled and suspension state before awaiting storage session preparation, then rechecks the generation before exposing a context and access handle; a captured session ID is eligibility, not a guarantee that memory remains available. The GRDB store keeps memory state, review checkpoints and learning activity, and a redacted conversation/message index with FTS5 search. A migration **drops** the old per-conversation `snapshots` table rather than retaining frozen prompt copies. Conversation history is copied into this separate index only after successful relevant history changes; indexed text is redacted and compaction-only synthetic messages are excluded.

A memory session receives a revocable context and generation-bound access; memory state and indexed history remain in separate storage rather than a stored per-conversation prompt snapshot. Memory reviews use a compare-and-apply base state, so a stale review cannot overwrite newer memory. Disabling memory invalidates sessions, cancels indexing and reviews, and closes the database while preserving stored data. Mobile backgrounding and desktop termination also suspend memory, revoking existing contexts and access without deleting data; on mobile, background expiration separately requests cancellation of Assistant preparation and active runs before draining and closing host connections. Resuming memory reloads current state and schedules history reindexing. Generation checks reject stale access/results and prevent publishing stale writes into the current UI state; they are not a rollback of storage writes already in flight. Resume can reload current state after such a commit. Destroying memory first persists disabled/destroy-pending state, revokes contexts and joins ongoing work, then closes and removes the owned directory; failure remains disabled and is retried on a later launch. Memory and credentials are device-local and are not synced.

New submissions capture whether they have a memory-session identity before preparation awaits. Enabling memory afterward does not add a session to that captured turn. Disabling it remains a revocation boundary: `MemoryModel` invalidates existing contexts and rejects a late snapshot load from the old generation, so capture does not override a later disable.

## App-owned notifications and scene focus

Notifications are a separate app integration, not part of the AgentKit loop, title generation or Hermes callbacks. `ConversationModel.notificationEvent` reports completed/failed runs (including recorded preparation failures) and changes to the highest-priority pending interaction. Cancelled/interrupted runs do not emit completion notifications. Interaction classification covers questions, secrets, SSH authentication/passphrase and host-key challenges, MCP authorization, and then pending approval; informational SSH keyboard-interactive messages do not produce an attention request.

`AssistantNotificationCoordinator` observes conversations independently of mounted transcript views. It deduplicates by run or interaction ID, consumes suppressed events without replaying them when settings/focus changes, and rechecks preferences, observation ownership and the current interaction before asynchronous delivery. Replacing or resolving an interaction cancels/removes its old notification and unread marker. Unseen events increment the conversation's in-memory unread set independently of whether system delivery is enabled; reading clears it, and a fresh model does not restore those counts.

Both app adapters attach this coordinator to conversations. On mobile, `MobileAppModel` uses its weak scene registry to determine whether a conversation is showing, route notification opens to a suitable scene, and aggregate non-archived conversation unread counts with terminal completion counts for the badge. That scene integration is distinct from its run-scoped `AgentPaneAccess`: the latter enumerates live SSH/Telnet viewports, not notification content or a local MCP server.

```mermaid
sequenceDiagram
    participant Conv as ConversationModel
    participant Coord as Notification coordinator
    participant Scenes as App scene focus
    participant Service as Notification service
    Conv->>Coord: finished or interactionChanged event
    Coord->>Coord: deduplicate event identity
    Coord->>Scenes: query visibility and notification focus
    Coord->>Conv: mark unseen event unread
    opt preferences allow system delivery
        Coord->>Service: send with currentness callback
        Service->>Coord: recheck ownership and preferences
        Coord->>Conv: verify interaction still current
        Service-->>Scenes: notification opens assistant target
    end
```

Notification flow: app-owned focus and delivery policy consume conversation events without changing execution, approval or replay data.

## Focused verification

The focused tests establish behavior that is important when changing this area:

- `TFMTests/ContextAttachmentImporterTests.swift` checks retained UTF-16/PDF bytes versus extraction, modern Office extraction, legacy Office and image-only PDF refusal, and safe preview materialization. `ChatComposerStateTests.swift` checks attachment-only turns and legacy extracted-text fallback; `AgentPersistenceTests.swift` checks attachment backing restore and deletion, and `FrameworkTests/AgentReplayPersistenceTests.swift` reopens queued cancellation through a fresh repository with captured authored text, images, attachments and context intact.
- `TFMTests/AgentToolPresentationTests.swift` checks exact live approval arguments, localized lifecycle/action summaries, stable presenter metadata, mixed outcomes and byte/line-bounded previews with full Copy output. These are projection tests, not evidence that the execution result was truncated.
- `TFMTests/AgentRuntimeTests.swift` covers schema-before-approval/execution, approval mode routing, Guardian timeout/failure fail-closed behavior, single-use secret handles, steering delivery, tool cancellation, registry shadowing, and durable-event filtering.
- `TFMTests/AgentTokenUsageTests.swift` covers provider usage normalization, cumulative merging, measured-total rescaling, context-window shares, incremental/reference parity and draft edits that do not rebuild the gauge. `ChatComposerStateTests.swift` checks immediate raw-delta visibility with throttled context publishing and edits that remove downstream tools across every card lifecycle state.
- `TFMTests/AgentPersistenceTests.swift` covers redaction, interrupted-run recovery, replay deduplication, tool-result repair, graph deletion, same-run edit prefix/tool preservation, canonical equal-time ordering, empty retained runs, staging adoption, late-write rejection, fork persistence and compaction restoration. `ChatComposerStateTests.swift` checks the compacted live prefix, tool cards, title, plans and adopted run summaries.
- `FrameworkTests/AssistantChatCollaborationPersistenceTests.swift` checks atomic cross-context receipt confirmation, monotonic delivered state, and creation-relation reopen; `FrameworkTests/AssistantChatCollaborationReviewTests.swift` and `AssistantChatCollaborationEdgeTests.swift` check source/target isolation, retries, planning restrictions, bounded listing, receipt failures and wait/interjection races. `FrameworkTests/AgentReplayPersistenceTests.swift` checks failed/interrupted staging adoption and reloads through a fresh `ModelContext` and repository to verify durable provenance and replay backing.
- `FrameworkTests/AssistantExecutionControllerTests.swift` covers capture across a memory barrier, missing credentials, first-send guards and payload folding, plan implementation, edit persistence/cancellation barriers, failed/interrupted replacement provenance, superseded captures, navigation, compaction refusal, memory revocation, and neutral legacy context. Blocked and failing saves verify that captured failure keeps preparation owned through stop and archive/delete until save completion and only adopts staging on success. `FrameworkTests/AssistantModelSelectionTests.swift` checks draft model seeding, restored choices, unavailable-model repair, and persistence-first model selection.
- `FrameworkTests/AssistantConversationOperationsTests.swift` verifies persistence-first archive/rename/order/edit mutations, invalid edit rejection before repository calls, failed edits leaving the live prefix unchanged, and activity guards. Immediate `stopAndWait()` also verifies a persisted cancelled prestart snapshot with captured prompt and context but no provider/tool calls; a gated-save test verifies the join.
- `TFMTests/AgentScratchTests.swift` verifies workspace containment, symlink refusal, cross-conversation shared files and scratch survival after conversation cleanup, quotas, and bounded reads.
- `TFMTests/AgentBuiltInToolAvailabilityTests.swift` checks exact Termind planning/acting/reviewing sets **without injected pane access**, the shared SSH schema with mode-specific preflight, and execution spies proving the surface gate blocks only terminal suggestions. `TFMTests/AgentPaneToolsTests.swift` checks conditional pane registration by mode, required-ID validation and explicit-ID reads, disconnected/absent-surface refusal, untruncated viewport output, and cards that omit viewport text; `TFITests/MobileWorkspaceSessionTests.swift` exercises pane access across mobile scenes.
- `FrameworkTests/AgentSteeringTests.swift` and `TFITests/MobileAssistantTests.swift` check snapshot preservation, delivery timing, legacy unknown context, mobile send/steer availability, acting-mode plan implementation, and tool-incapable models. Mobile's SwiftData restore/edit fixture also verifies same-run prefix preservation and replacement provenance.
- `FrameworkTests/AgentUserInputTests.swift` checks timeout schema and defaults, question validation, navigation, head-only deadlines, skip/null semantics, cancellation and dedicated secret drafts. `FrameworkTests/AssistantTranscriptPresentationTests.swift` checks direct-approval/event races, denial display, structured presenter output and bounded previews; `FrameworkTests/HermesMemoryTests.swift` checks suspension/revocation, stale writes/reviews, index catch-up, destroy retry and lazy disabled storage.
- `FrameworkTests/AssistantNotificationTests.swift` checks completion/failure deduplication, cancellation of pending delivery on removal/stop, preparation failures without restore replay, focus/settings suppression, interaction classification, and unread/badge state independent of system delivery.
- `TFMTests/MCPServerToolsTests.swift` checks the exported acting subset against shared descriptors, transfer tools and disabled calls; `AgentHostProtocolListingTests.swift` checks protocol-neutral discovery, and `AgentToolPresentationTests.swift` retains legacy presentation coverage alongside the persistence suite.

## Change guidance

For runtime-ordering or AgentKit-owned retry/secret lifecycle changes, inspect the *resolved AgentKit package revision*, not the empty sibling directory; the Termind tests verify observable integration behavior, not all internal sequencing. For cross-chat changes, keep the AgentKit generic chat-tool interface separate from Termind's coordinator and preserve receipt atomicity, deduplication and per-target composer isolation. When adding a tool, define a strict schema, choose an explicit tool policy and planning registration, validate/normalize inputs in preflight, and ensure the tool returns bounded/redacted data. Register Termind-specific definitions and durable card presenters in `TermindAgentTools`, assemble them beside AgentKit built-ins in `AssistantToolRegistry`, and explicitly review the desktop MCP export allowlist rather than assuming an Assistant tool is externally available. For a live-device feature such as pane inspection, inject a run-scoped capability from each app adapter rather than persisting a view or assuming SSH host access implies a readable terminal viewport. Keep the model-incompatible catalog empty for models without `.toolCall`; if the feature requires new neutral runtime behavior, release and pin AgentKit before depending on it. Host mutations must remain behind the same authorization and trust checks whether invoked directly, through MCP, a skill, or a scratch workflow. Do not add a shortcut that serializes SSH credentials, secret input, raw scratch/remote file contents, or unredacted provider data to a transcript, event, log, SwiftData, or Hermes index.

Submission and steering capture the intended `pane_id` in session context. Command generation separately includes a bounded visible viewport (64 KiB, character-safe truncation) as untrusted context, excluding scrollback; the non-viewport context and response each retain an 8 KiB budget. It generates a command without executing it. Pane read/list card summaries preserve action and failure state, including older descriptors.
