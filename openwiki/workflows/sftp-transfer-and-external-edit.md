---
type: workflow
title: SFTP Transfer, Scheduling, and External Edit Workflow
description: How browser SFTP jobs are scheduled and resumed, how Agent SFTP leases reuse authenticated SSH connections, and how MCP uploads and external edits remain separate workflows.
tags: [sftp, file-transfer, ssh, scheduling, external-editing, lifecycle]
sources:
  - id: openwiki-source-46ef2fcd9e3aba751015021b
    resource: repo://Frameworks/TermindDomain/Transfers/SFTPPreferences.swift
  - id: openwiki-source-96c4e228b6057cf9d989eb04
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSFTPTools.swift
  - id: openwiki-source-0c82bf45bc197f879a54fd3a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift
  - id: openwiki-source-e1a028bd99d4dbe6d1e14f6a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentScratchTransferTools.swift
  - id: openwiki-source-f2860ea1e34da1a6d9ec1510
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/SFTPCopyTool.swift
  - id: openwiki-source-dd3df578da8881d8ba0638e6
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift
  - id: openwiki-source-f45e107ba4ae15ff23a99333
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SFTPClient.swift
  - id: openwiki-source-b9bae3a52f35a3a412f81e10
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift
  - id: openwiki-source-79d8ded739aa8dd4fa3f5cdf
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift
  - id: openwiki-source-cc90954475bbeee75514baf8
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPLocalUploadPlanner.swift
  - id: openwiki-source-b28dbb18976feec837ed23fe
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteConflictResolver.swift
  - id: openwiki-source-af958b0e71cef7f5910893cc
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteTransferPlanner.swift
  - id: openwiki-source-3adf61411195abda93bf88fc
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPResumeState.swift
  - id: openwiki-source-b347308e8c5cc6c0b0d29b7d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift
  - id: openwiki-source-c4b6e224fdbea6dcd393344d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift
  - id: openwiki-source-d92ce4bb378fe3506b55c85a
    resource: repo://FrameworkTests/SFTPRemoteConflictResolverTests.swift
  - id: openwiki-source-76b1cdca4a02038756187f92
    resource: repo://TFM/Application/MCPServer/MCPServerTools.swift
  - id: openwiki-source-396f97a332870d48c065d7e9
    resource: repo://TFM/Application/MCPServer/MCPUploadCoordinator.swift
  - id: openwiki-source-0260a25fb41739d94e23d2ea
    resource: repo://TFMTests/AgentConnectionPoolTests.swift
  - id: openwiki-source-83498f1ebb2addd4dded3bc1
    resource: repo://TFMTests/SFTPConcurrencySchedulerTests.swift
  - id: openwiki-source-bdee3a21bf24d48b877a78fe
    resource: repo://TFMTests/SFTPEditTests.swift
  - id: openwiki-source-53e2b2fd2e661123f63e69e1
    resource: repo://TFMTests/SFTPTransferContextTests.swift
generated: { by: "openwiki/0.5.2", at: "2026-09-23T10:36:38.039Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T14:05:10.244Z
---

## Scope and operating model

SFTP file work is split deliberately: browser and application models prepare batches and own UI choices; `SFTPTransferCoordinator` owns queued transfer runtime, admission, progress, cancellation, and completion; `SFTPTransferContext` owns a generation-scoped authenticated primary connection; and `SFTPChannel` implements actual libssh2 file I/O. `SFTPClient` is only the connect/disconnect facade around its primary channel. This division lets standalone SFTP, browser transfers, terminal-drop transfers, and edits share atomic write, resume, and copy mechanics without sharing a pane lifetime. [^client-channel]

The important safety boundary is **no durable staging and no silent replay**. Checkpoints—temporary path, source identity, acknowledged offset, and SHA-256 state—live only in `SFTPResumeState` in the running process. A recoverable connection failure pauses instead of retrying; a user must explicitly resume, at which point the source and already-written prefix are verified. A restart therefore cannot recover or replay work. [^resume-state] [^coordinator-outcomes] [^channel-prefix]

A transfer can use one of three connection forms:

- **Saved** — create a fresh `SFTPClient` from an additional-connection snapshot and disconnect it after the transfer.
- **Context** — borrow a lease from a browser/terminal `SFTPTransferContext`, which can select a sibling channel, an additional silent connection, or the primary channel.
- **Borrowed** — use an existing externally owned channel, serialized by its borrowed-connection identifier so two jobs do not operate it concurrently. [^connection-forms] [^lease-selection]

## Browser paths: prepare, validate, enqueue

Browser actions are two-phase rather than mutating during drag/drop preparation:

1. An upload planner expands selected local roots into remote directories and regular-file jobs, then performs a remote preflight over all prospective directory and file targets. A remote-copy planner first obtains a remote manifest and performs the analogous preflight at the destination. The UI can show the resulting conflict count before a policy is chosen. [^upload-preflight] [^copy-preflight]
2. On the selected `TransferConflictPolicy`, the enqueue phase resolves directories first, transforms or suppresses descendants, resolves individual targets, and only then calls `enqueue` or `enqueueRemoteCopy`. `skip` suppresses the affected item/subtree; `replace` permits overwrite and recursively removes a conflicting destination directory; `keepBoth` chooses the next available extension-aware name and maps descendants under it. [^conflict-resolution] [^upload-enqueue] [^copy-enqueue]
3. The coordinator persists a queue row in `HostLibraryModel`, retains any managed context for that transfer, retains local security-scoped access while I/O runs, and publishes byte progress only while the row is still the matching running generation. [^enqueue-runtime] [^transfer-progress]

Conflict inspection precedes mutation. Preflight identifies conflicting directories and targets without creating, deleting, or queuing a transfer; directory resolution is the first operation allowed to mutate the destination. Recursive removal validates each listed child’s name and expected path before descending, then removes children before their parent, preventing a malformed server entry from redirecting deletion. [^conflict-preflight] [^safe-recursive-delete]

For a same-host remote copy, planning rejects copying a file onto itself and rejects a directory target within the source subtree before conflict handling. Cross-host work is still a direct SFTP-to-SFTP stream: it does not materialize a local intermediary. When endpoint channels share the same SSH transport, the implementation alternates bounded reads and writes; otherwise it relays bytes through an in-process socket pair while download and upload run together. Both paths validate source size/identity and write a temporary destination before rename. [^self-copy-guard] [^copy-streaming]

## Admission, fairness, and SSH topology

`SFTPConcurrencyScheduler` is process-wide admission for data operations. Capacity counts logical files, not connections or channels: a remote copy consumes one global slot and one per-host slot for each distinct endpoint. Metadata work is outside this data admission path. The scheduler rotates anchor hosts and then sources (`workspace`, `agentRun`, or `batch`), retaining FIFO order within each source queue; it grants only a request whose every endpoint remains below the per-host limit and whose exclusive borrowed resources are free. [^scheduler-contract] [^scheduler-fairness]

Preferences default to 30 global active files and 10 per host, constrain global to 1–100 and per-host to 1–50/not above global, and select `smart`, `channels_only`, or `connections_preferred`. Updating preferences drains queued work with the new values; an already-admitted permit retains its selected mode. In Smart mode, unknown sizes and sizes through 64,000,000 bytes use channels; only a larger known file prefers an additional connection. [^preferences] [^mode-selection] [^preferences-update]

```mermaid
sequenceDiagram
    participant Browser
    participant Coordinator
    participant Scheduler
    participant Context
    participant Channel
    Browser->>Coordinator: enqueue validated file job
    Coordinator->>Scheduler: acquire global host source permit
    Scheduler-->>Coordinator: permit and scheduling mode
    Coordinator->>Context: reserve slot and acquire lease
    alt channels only
        Context->>Channel: open sibling or serialize primary
    else connections preferred
        Context->>Channel: silently open additional connection
        alt silent open fails
            Context->>Channel: open sibling or serialize primary
        end
    end
    Coordinator->>Channel: upload download or copy
    Channel-->>Coordinator: completion or error
    Coordinator->>Context: release slot and transfer ownership
    Coordinator->>Scheduler: release permit
```

*Admission applies global/per-host fairness before a context chooses the concrete SSH channel topology.*

A context keeps the browser **control** channel independent where possible. `channelsOnly` opens sibling SFTP channels, falling back to a serialized primary lease rather than silently opening another connection. `connectionsPreferred` probes one additional connection without interaction; success marks the context connection-capable, while a non-cancellation failure marks it channel-capable for later jobs and leaves active work untouched. A cancelled probe does not cache that degradation. The special terminal preflight role can donate a successful independent connection to the first job; if independent preflight requires interaction, terminal work uses its PTY transport and fixes the generation to channels. [^context-topology] [^context-probe] [^terminal-preflight]

The coordinator acquires two endpoint leases in stable context-ID order for a remote copy and shares one lease when both endpoints are the same context. This avoids competing acquisition order and needless duplicate use of one transport. [^remote-copy-leases]

## Scheduling algorithm: admission is not transport capacity

The coordinator's `schedule()` creates an admission task for each eligible queued row, waits for any pending preference update, and calls `acquire`. Only after a permit arrives and the row/runtime still exists does it store that permit, reserve context slots, mark the transfer running, and ask for a channel lease. A row can therefore be **running but still waiting for a subsystem or serialized primary**; admitted file count is not the number of sockets currently transferring bytes. The permit remains held through channel acquisition, I/O and lease cleanup. `finish` releases context ownership and the active permit before scheduling again.

`nextEligibleRequest` is a two-level rotation, not one global FIFO:

```text
while active file count < globalLimit:
    visit anchor hosts starting after lastGrantedHost
    within each host, visit sources starting after that host's lastGrantedSource
    inspect only the head request of each source queue
    skip if any endpoint is at its per-host limit or an exclusive resource is busy
    grant the first eligible head; update host/source rotation cursors
    stop when no eligible head exists
```

Each request normalizes its endpoint set to include the anchor. A copy is anchored to its destination when available, while capacity is charged to both distinct endpoint Hosts. Workspace identity is the managed context's ID (destination context for a copy); otherwise the coordinator uses the batch ID. The Agent supplies an `agentRun` identity for scheduled data work.

This has three consequences:

- FIFO is preserved **within one source queue**. The scheduler can skip a blocked source to consider a different source/host, but does not look past that source's blocked head.
- Rotation is a grant-order fairness policy, not preemption or a bandwidth reservation. Long-running files keep their permits until release. Lowering limits cannot revoke active permits; it only delays future grants until capacity fits again.
- A remote copy consumes one global permit and one slot per distinct Host, regardless of whether it later needs one or two endpoint leases. A borrowed channel adds an exclusive resource ID so jobs cannot simultaneously use that same borrowed resource.

Tests make the policy concrete: after a workspace used the sole slot, a queued Agent source can precede more work from that workspace; another Host gets a turn before the previous Host; two workspace queues can split five same-host grants 3/2. These are controlled queued examples, not a guarantee that a later-arriving operation displaces an already active file.

### Smart mode is selected at grant time

The request retains its byte count, but `drain()` selects its mode using the **current preferences when admitted**. The returned permit's mode is immutable. The boundary is decimal **64,000,000 bytes** (64 MB), not 64 MiB: equal-to-boundary and unknown sizes use `channelsOnly`; strictly greater known sizes use `connectionsPreferred`. Mode decides the allowed topology preference, not extra file capacity.

## Topology decision table for a managed context

The full sequence lives in `SFTPTransferContext.acquire`; read it in order rather than treating the selected strategy as an unconditional socket-opening command. While an initial capability probe is in flight, other acquisitions wait for its result. After that, primary role and busy state determine reuse.

| Primary role | `channelsOnly` | `connectionsPreferred` |
| --- | --- | --- |
| `control` (browser) | Prefer a sibling subsystem, leaving the browser's control channel free. If sibling opening fails, wait for and serialize on the primary. | Try a silent additional connection unless capability already downgraded to channels; then try a sibling; final fallback serializes the primary. |
| `donatedConnection` (successful independent preflight) | Lease the idle preflight primary first; overlapping work uses siblings. | Lease the idle preflight primary first; overlap can open independent connections, then downgrade to siblings/primary after failure. |
| `ptyConnectionFallback` | Lease the idle SFTP primary on the PTY transport first; overlap uses siblings. | Starts with channel-only capability, so it does not re-probe extra connections for a large file while that primary generation is alive; uses primary/siblings. |

A context's capability is **unknown → connections** on a successful silent open, or **unknown/connections → channels** on a non-cancellation failure. The first unknown probe is serialized, but once connection capability is known later admitted jobs can attempt extra opens concurrently. Browser-context cancellation is checked before caching degradation; a cancelled probe does not condemn the generation to channel fallback. Successful sibling opening does not turn an unknown context into connection-capable.

These fallbacks include two distinct kinds of waiting:

1. `openSiblingChannel` can wait for the per-connection `SSHChannelBudget` before libssh2 ever tries initialization. A full local session budget is not automatically interpreted as failure, and does not cause the context to open a new socket by itself.
2. If sibling initialization actually fails, the context waits on `primaryBusy` and leases the primary serially. Context waiters are a dictionary resumed together by `wakeWaiters`; do not attribute the scheduler's FIFO guarantee to this fallback waiter mechanism.

A browser-context extra connection or sibling is leased for the operation and disconnected on release, rather than kept in a warm auxiliary pool. The context primary is retained by owner/transfer references. If it was closed after detach/pause, a later explicit resume can silently recreate a primary from its snapshot and resets capability; `channelsOnly` cannot conjure an already-authenticated transport that no longer exists. The saved form always opens a fresh client and the borrowed form always returns the external channel with a no-op lease release; neither runs the managed-context topology table.

### Worked connection/channel counts

Assume setup succeeds, no other files consume the stated limits, and the SSH session-channel budget permits the requested siblings:

| Scenario | Active logical files | Physical connections and SFTP subsystems |
| --- | --- | --- |
| Browser control primary, three files, Channels Only | 3 | One connection with its browser control subsystem plus three sibling data subsystems; the control channel is not a fourth file permit. |
| Donated primary, two files at exactly 64,000,000 bytes, Smart | 2 | One independent preflight connection; its primary subsystem plus one sibling. |
| Same donated primary, two files strictly above the threshold, Smart | 2 | The donated connection plus one silently opened connection; no sibling is needed on the successful path. |
| PTY fallback, three large files, Smart | 3 | The existing PTY connection with the terminal session channel plus three SFTP subsystems (the fallback primary and two siblings); no new connection probe. |
| Donated preflight, seven files, per-host limit 5, Connections Preferred | At most 5 | Initially the donated connection plus four additional connections; remaining files wait for permits. |

`SFTPTransferContextTests` checks the sibling/open counts, the threshold, a five-file terminal batch, and two contexts sharing a five-file Host limit. With `MaxSessions = 10`, a browser control channel plus ten admitted Channels Only files cannot all have sibling subsystems at once: the extra acquisition waits for a channel lease even though it already holds a file permit. This is an example of independent limits, not permission to silently exceed either one.

## Agent SFTP reuse is related, not identical

Agent SFTP does **not** borrow the browser's `SFTPTransferContext`. `SFTPToolDefinition` validates host and normalized absolute path in preflight, then routes the operation through `AgentToolSupport.withAuthenticatedSFTP` and `AgentSSHAuthenticationRegistry.withSFTP`. `sftp_read` and `sftp_write` request data admission (using bounded read size or UTF-8 write length); list, stat, mkdir, move, chmod and delete use the default metadata path without a file permit. `scratch_pull` and `scratch_push` also request data admission. `withSFTP` acquires a permit from the shared scheduler for `.agentRun(runID ?? invocationID)` only when requested and no permit was supplied, then authenticates and acquires a pool lease **inside** admission, releasing its owned permit on both success and failure. An externally supplied permit is not released by this wrapper. [^agent-tools] [^agent-admission] [^scratch-admission]

```mermaid
sequenceDiagram
    participant Tool as Agent Tool
    participant Registry as Auth Registry
    participant Scheduler
    participant Pool as Agent Pool
    participant SSH as SSH Connection
    Tool->>Registry: withSFTP with data flag and size
    opt data work without supplied permit
        Registry->>Scheduler: acquire agentRun permit
        Scheduler-->>Registry: mode and permit
    end
    Registry->>Registry: join authentication context for host
    Registry->>Pool: acquireSFTP with selected mode
    Pool->>SSH: reuse or open primary SFTP subsystem
    alt primary busy
        Pool->>SSH: lease idle auxiliary or open silent auxiliary or sibling
    end
    Pool-->>Registry: exclusive channel lease
    Registry->>Tool: run operation once
    Registry->>Pool: releaseSFTP
    opt owned permit
        Registry->>Scheduler: release permit
    end
```

*File admission and the Agent pool's exclusive channel lease are separate resources; acquiring a lease never replays the tool operation.*

The Agent pool retains **one primary SSH connection per Host across tool calls, runs and conversations**; exec and primary SFTP share its transport, and simultaneous initial exec/SFTP opens join rather than creating competing primary connections. The primary SFTP subsystem is opened once on that SSH connection. Reuse checks a route fingerprint (host, route hops, login identity, proxy, known-host fingerprints and destination charset); changing or deleting the route retires the old connection. The fingerprint deliberately does not read Keychain secrets: rotating a credential without changing login identity does not break an already authenticated session, but affects the next connection. A pane-backed temporary target stops resolving when its pane disappears. [^agent-primary] [^agent-route] [^agent-pool-tests]

`AgentConnectionPool.acquireSFTP` first obtains the primary and reuses an eligible idle record, preferring the least-recently-used idle one. In `channelsOnly`, only an idle primary record qualifies; overlap opens a sibling on the primary transport. If sibling opening actually fails (not cancellation), it polls until the primary is free and retries acquisition. In `connectionsPreferred`, an unknown Host capability uses a shared, interaction-forbidden extra-connection probe; success stores an auxiliary record and marks connections capable. Further overlap can silently open other auxiliaries. Failed silent setup downgrades to sibling channels, but unlike channel-only fallback, a sibling-opening failure on this path propagates. The initial shared-probe catch records channel capability *before* rethrowing cancellation; browser `SFTPTransferContext` instead checks cancellation before downgrading. No extra credential prompt is allowed for an auxiliary open. [^agent-lease] [^agent-probe] [^context-probe]

On release a pooled primary or auxiliary becomes idle, while an ephemeral sibling disconnects. Idle auxiliaries are swept independently; the primary and exec connection close together only after the Host has no active exec/SFTP leases and the 180-second idle timeout has passed (the app's sweep interval defaults to 30 seconds). Disconnect, route invalidation and `closeAll` cancel active SFTP lease tokens and close channels/connections; `SFTPError.notConnected` or `.connectionLost` evicts the Host after the operation fails, **not** by rerunning it. Authentication can retry a rejected connection attempt before the operation starts; overlapping attempts share a short-lived authentication context that is discarded after its last lease, not a persistent cache of custom passwords. [^agent-release] [^agent-sweep] [^agent-auth] [^agent-admission]

For an Agent `sftp_copy`, the tool obtains **one** destination-anchored global permit charged to both endpoint Hosts and passes it into each endpoint's `withSFTP`, so neither endpoint acquires another permit. A same-host copy in channel-only mode uses its one leased channel for both endpoints; other copies acquire source then destination leases and stream through `SFTPRemoteCopyOperation`. This differs from browser coordinator copy leases and from a pair of independent single-host Agent tools. [^agent-copy] [^remote-copy-leases]

MCP uploads are a separate HTTP ticket workflow, **not** browser queue rows or scratch files. `MCPUploadCoordinator` validates target path, byte count and SHA-256, issues a session-bound loopback PUT URL/token, and checks origin, token, body length and resumable offset before claiming the MCP transfer budget. `MCPServerTools` then runs `SFTPStreamUploadOperation` through the same Agent authentication/pool lease and scheduler with `schedulesDataTransfer: true`; cleanup uses another SFTP lease without data admission. A disconnected HTTP attempt or recoverable SFTP failure may pause a ticket for an explicit offset-matched retry while it is unexpired; integrity errors and cancellations clean up rather than silently replaying bytes. Ticket status and cancellation belong to the MCP coordinator, not `SFTPTransferCoordinator`. [^mcp-tickets] [^mcp-transfer] [^mcp-failure]

Do not copy browser-context assumptions wholesale into the Agent pool: browser auxiliaries are operation-scoped, Agent auxiliaries remain eligible for reuse, and MCP's HTTP budget/tickets are not scheduler permits. Focused pool tests verify one handshake across repeated execs, concurrent primary opens and exec/SFTP sharing, cancellation of one or the last connection opener, route retirement, idle sweeps and no replay of a command that already started. These tests cover primary reuse rather than exhaustively asserting every SFTP auxiliary-mode branch. [^agent-pool-tests] [^agent-lease]

## From a file lease to libssh2 turns

A sibling channel shares the same driver's transport identity. `SSHMultiplexedSFTPChannelOwner` serializes each raw libssh2 call on its SSH owner's queue, uses the encrypted buffer's bounded pass/backpressure, and returns to an async 2 ms retry sleep on EAGAIN. File fairness above does not imply strict round-robin ordering for every SFTP packet below. See [SSH Multiplexing and Scheduling](/openwiki/concepts/ssh-multiplexing-and-scheduling.md).

Copy's topology check is driver identity, **not merely equal Host IDs**. If both concrete `SFTPChannel` endpoints share it, `copyOnSharedTransport` alternates reads of at most 64 KiB with destination writes on the shared owner. Otherwise the socket-pair relay runs producer and consumer tasks concurrently; failure cancels the group and stops the relay. Stable lease acquisition order, the shared-driver fast path, and file-admission accounting solve different problems and should not be collapsed.

To compare with port forwarding, use [Forwarding Pool and Flow Dispatch](/openwiki/workflows/port-forwarding-pool-and-dispatch.md): forwarding prewarms a Host-level target and assigns accepted TCP flows to retained workers, rather than creating a connection-per-file lease. For terminal-to-SFTP cwd/availability prerequisites, use [Shell Integration](/openwiki/concepts/shell-integration.md).

## Transfer state, resume, cleanup, and ownership

The visible states are queued, running, paused, completed, failed, and cancelled. Pause before admission cancels the admission task and immediately changes to paused. Pause during I/O cancels the operation; recoverable connection errors also become paused except resume-validation failures, which are failed. Cancelled or failed non-paused work performs cleanup, while completed and paused work retain the checkpoint needed for their respective outcomes. [^transfer-control] [^coordinator-outcomes]

```mermaid
stateDiagram-v2
    [*] --> queued
    queued --> running: permit admitted
    queued --> paused: pause
    queued --> cancelled: cancel
    running --> completed: operation commits
    running --> paused: pause or recoverable loss
    running --> failed: nonrecoverable or validation failure
    running --> cancelled: cancel
    paused --> queued: explicit resume
    paused --> cancelled: cancel
    completed --> [*]
    failed --> [*]
    cancelled --> [*]
```

*The coordinator never transitions a paused transfer back to work without an explicit resume request.*

Uploads write to a generated remote `.termind-part-…` path with exclusive creation, validate the edit policy if present, and rename only after length/prefix checks; downloads write a local temporary path and replace/move it only after remote identity validation. Resume verifies the original source identity plus the SHA-256 prefix of the partial local or remote destination. A committed rename interrupted before bookkeeping can be recognized only by checking that the temporary is gone and the destination has the expected size and prefix. These checks make resume safe within the live process, rather than a claim that the remote protocol supplies compare-and-swap. [^channel-atomic-resume] [^channel-commit-recovery] [^channel-prefix]

Cancellation and terminal failure try to delete the local download temporary or remote upload temporary. If cleanup itself fails, the state is failed with `SFTPTemporaryFileCleanupError`, including the partial path; it is not silently hidden. Pausing intentionally retains the partial. [^cleanup]

Closing a pane is not transfer cancellation. `releaseOwner()` merely drops the pane’s ownership; queued and active jobs retain the context connection until their transfer references and active slots are gone. When a pause has released its transfer reference and the owner is gone, the unused primary is disconnected; a later explicit resume reopens silently from the snapshot. Conversely, `retire()` disconnects a failed primary and prevents it from being installed into a replacement browser generation. [^context-ownership] [^context-close] [^pause-ownership]

## External edit lifecycle

`SFTPEditService` is application-scoped and tracks one managed local copy per `(hostID, remote path)`. Opening validates that the target is a regular file, downloads it through the same coordinator into `TemporaryDirectory/TermindEdits/<UUID>/`, records a remote baseline/version and local SHA-256 digest, and returns the existing copy for a compatible repeated open. It stores route identity—not credentials—alongside the copy, and invalidates tracking if the host route or connection destination no longer matches. [^edit-open] [^edit-destination]

The service observes local copies and rechecks their digests. It uses file observation plus a one-second pass, with a forced full hash every 30 ticks, so editor atomic-save replacement and preserved timestamps are detected. Clean records remain reusable; cards represent dirty state rather than ownership of the copy. [^edit-monitoring]

```mermaid
sequenceDiagram
    participant User
    participant EditService
    participant Coordinator
    participant Remote
    User->>EditService: open regular remote file
    EditService->>Coordinator: queue download with version receipt
    Coordinator->>Remote: download managed copy
    Remote-->>EditService: committed remote version
    EditService-->>User: local editable URL
    User->>EditService: explicit upload
    EditService->>Remote: inspect current remote version
    alt changed or metadata unavailable
        EditService-->>User: request replace confirmation
    else validated or confirmed
        EditService->>EditService: snapshot local copy
        EditService->>Coordinator: queue upload with edit policy
        Coordinator->>Remote: validate then atomic upload
        Coordinator-->>EditService: committed version
        EditService-->>User: update baseline and digest
    end
```

*An edit upload snapshots local content and validates the remote version before the transfer is admitted; it is never an automatic save.*

Upload is explicit. Before taking an immutable local snapshot, the service hashes the current local copy and returns without work if its digest equals the last uploaded digest. It then reads the remote attributes: a changed baseline, a missing modification time, or an unconfirmed replacement returns `true` so the UI can request confirmation. Confirmation is tied to exactly the observed remote version and expires if it changes again. [^edit-conflict]

The upload’s `SFTPEditUploadPolicy` carries the expected version and original permissions. The channel validates the destination before creating its temporary file, preserves permissions on that file, validates again before rename, and fails closed for a non-file destination. On success, only the uploaded snapshot digest becomes acknowledged; an edit saved during the upload remains dirty and needs another explicit upload. [^edit-policy] [^edit-snapshot]

Discard is intentionally non-destructive to user work: it stops tracking and forgets digest observation but never deletes the editable copy. An active/preparing upload cannot be discarded. A paused upload is cancelled and cleaned first; if cleanup fails, the record remains so the error/partial path stays visible. Host invalidation cancels attached uploads and prevents new uploads while retaining the local copy. [^edit-discard] [^edit-invalidation]

## Operational guidance and focused verification

- Treat `SFTPPreferences` changes as future admission policy, not a way to tear down active transfers. Choose Channels Only for servers/routes where extra connections are undesirable, Connections Preferred for independent transfers when silent credentials are available, and Smart for the size-based default. [^preferences] [^preferences-update]
- Never add persistence for `SFTPResumeState`, transfer contexts, borrowed channels, or edit route credentials. The intended recovery behavior is a visible paused/failed state and an explicit user decision, not launch-time replay. [^resume-state]
- When changing planner or resolver code, preserve the sequence **preflight → user policy → directory resolution → target resolution → enqueue**. Moving deletion or directory creation into preflight would violate conflict validation before mutation. [^upload-preflight] [^upload-enqueue]
- When changing connection lifetimes, test both owner release and terminal transport fallback: a pane close must not interrupt retained work, but a last unused context primary must disconnect. [^context-close] [^pause-ownership]

Focused tests cover the materially risky cases: scheduler fairness across hosts/sources, cross-host capacity accounting, and the Smart threshold; topology fallback, cancellation of a silent probe, pane-close continuity, and resume after release; conflict mapping, cancellation points, and safe recursive delete; and edit confirmation, immutable snapshots, loss-to-pause, invalidation, observation of atomic saves, discard, and cleanup. [^scheduler-tests] [^context-tests] [^resolver-tests] [^edit-tests]

[^agent-tools]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSFTPTools.swift#L26-L75`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSFTPTools.swift#L79-L348`.
[^scratch-admission]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentScratchTransferTools.swift#L49-L61`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentScratchTransferTools.swift#L124-L146`.
[^agent-admission]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L989-L1057`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSFTPTools.swift#L626-L657`.
[^agent-primary]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1131-L1141`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1462-L1527`.
[^agent-route]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L492-L527`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1607-L1635`.
[^agent-lease]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1234-L1296`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1359-L1386`.
[^agent-probe]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1298-L1365`.
[^agent-release]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1368-L1386`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1529-L1562`.
[^agent-sweep]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1154-L1157`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1564-L1605`.
[^agent-auth]: `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L912-L926`; `Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift#L1059-L1128`.
[^agent-copy]: `Frameworks/TermindRemoteInfrastructure/Agent/SFTPCopyTool.swift#L93-L156`.
[^agent-pool-tests]: `TFMTests/AgentConnectionPoolTests.swift#L43-L186`; `TFMTests/AgentConnectionPoolTests.swift#L200-L342`.
[^mcp-tickets]: `TFM/Application/MCPServer/MCPUploadCoordinator.swift#L7-L28`; `TFM/Application/MCPServer/MCPUploadCoordinator.swift#L94-L195`.
[^mcp-transfer]: `TFM/Application/MCPServer/MCPServerTools.swift#L37-L81`.
[^mcp-failure]: `TFM/Application/MCPServer/MCPUploadCoordinator.swift#L231-L280`; `TFM/Application/MCPServer/MCPUploadCoordinator.swift#L329-L388`.

[^client-channel]: `Frameworks/TermindRemoteInfrastructure/SSH/SFTPClient.swift#L293-L387`; `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L120-L160`.
[^resume-state]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPResumeState.swift#L5-L75`.
[^channel-prefix]: `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L985-L1031`.
[^connection-forms]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L12-L24`.
[^lease-selection]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L721-L754`.
[^upload-preflight]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPLocalUploadPlanner.swift#L88-L103`.
[^copy-preflight]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteTransferPlanner.swift#L221-L260`.
[^conflict-resolution]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteConflictResolver.swift#L64-L118`.
[^upload-enqueue]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPLocalUploadPlanner.swift#L106-L161`.
[^copy-enqueue]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteTransferPlanner.swift#L267-L314`.
[^enqueue-runtime]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L237-L269`.
[^transfer-progress]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L531-L614`.
[^conflict-preflight]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteConflictResolver.swift#L29-L62`.
[^safe-recursive-delete]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteConflictResolver.swift#L121-L139`.
[^self-copy-guard]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPRemoteTransferPlanner.swift#L221-L230`.
[^copy-streaming]: `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L575-L705`.
[^scheduler-contract]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift#L29-L59`; `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift#L133-L150`.
[^scheduler-fairness]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift#L154-L219`.
[^preferences]: `Frameworks/TermindDomain/Transfers/SFTPPreferences.swift#L3-L46`.
[^mode-selection]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift#L169-L182`.
[^preferences-update]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L149-L165`.
[^context-topology]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift#L99-L188`.
[^context-probe]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift#L212-L233`; `TFMTests/SFTPTransferContextTests.swift#L232-L263`.
[^terminal-preflight]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift#L4-L16`; `TFMTests/SFTPTransferContextTests.swift#L23-L61`.
[^remote-copy-leases]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L624-L695`.
[^transfer-control]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L349-L413`.
[^coordinator-outcomes]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L583-L622`; `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L797-L819`.
[^channel-atomic-resume]: `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L354-L404`; `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L416-L483`.
[^channel-commit-recovery]: `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L807-L909`.
[^cleanup]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift#L415-L440`; `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPResumeState.swift#L62-L68`.
[^context-ownership]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift#L64-L97`; `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift#L266-L272`.
[^context-close]: `TFMTests/SFTPTransferContextTests.swift#L63-L108`.
[^pause-ownership]: `TFMTests/SFTPTransferContextTests.swift#L280-L298`.
[^edit-open]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L66-L140`.
[^edit-destination]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L16-L45`; `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L305-L325`.
[^edit-monitoring]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L142-L184`.
[^edit-conflict]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L236-L303`.
[^edit-policy]: `Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift#L836-L909`.
[^edit-snapshot]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L267-L295`; `TFMTests/SFTPEditTests.swift#L105-L120`.
[^edit-discard]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L205-L234`; `TFMTests/SFTPEditTests.swift#L232-L269`.
[^edit-invalidation]: `Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift#L186-L203`.
[^scheduler-tests]: `TFMTests/SFTPConcurrencySchedulerTests.swift#L7-L150`.
[^context-tests]: `TFMTests/SFTPTransferContextTests.swift#L129-L364`.
[^resolver-tests]: `FrameworkTests/SFTPRemoteConflictResolverTests.swift#L9-L167`.
[^edit-tests]: `TFMTests/SFTPEditTests.swift#L12-L269`.
