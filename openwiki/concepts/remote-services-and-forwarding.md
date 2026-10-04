---
type: Remote service ownership
title: Remote Services and Forwarding
description: Ownership boundaries among terminal, metrics, Agent SSH/SFTP tools, and TCP forwarding; explains when connections can be reused and which interactions are allowed.
tags: [ssh, terminal, metrics, sftp, port-forwarding, agent, scheduling]
sources:
  - id: openwiki-source-5aa101e9f8e2906832f58121
    resource: repo://Frameworks/TermindApplication/Connections/SSHConnectionPreparation.swift
  - id: openwiki-source-1ebc16ba1a0b0955956023b5
    resource: repo://Frameworks/TermindApplication/Connections/TailscaleConnections.swift
  - id: openwiki-source-c62dc61fc50ab8273b4dcf9c
    resource: repo://Frameworks/TermindApplication/Metrics/MetricsSnapshot.swift
  - id: openwiki-source-ca49232858afa421bf33a03b
    resource: repo://Frameworks/TermindApplication/Metrics/ServerMetricsModel.swift
  - id: openwiki-source-21096ca5afd2c8baca7c623c
    resource: repo://Frameworks/TermindDomain/Connections/PortForwardingRule.swift
  - id: openwiki-source-5e7fb300dcdfa0227467d965
    resource: repo://Frameworks/TermindDomain/Metrics/ServerMetrics.swift
  - id: openwiki-source-eeeeca9ded05fd2db5c3240d
    resource: repo://Frameworks/TermindDomain/Transfers/MultiConnectionPolicy.swift
  - id: openwiki-source-1fc00d0407016efa5a0378eb
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSSHTools.swift
  - id: openwiki-source-0c82bf45bc197f879a54fd3a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift
  - id: openwiki-source-ead8e57ca19639dd536b792d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentHostServices.swift
  - id: openwiki-source-1c845e5af67c400566be83bd
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AssistantToolRegistry.swift
  - id: openwiki-source-6d31fde4399bc6391f30aaf0
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/GetMetricsTool.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-89716908f306ca7371832cce
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/PortForwardingController.swift
  - id: openwiki-source-dd3df578da8881d8ba0638e6
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift
  - id: openwiki-source-ab74624bdc6b7046d91bcbac
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHConnectionWorker.swift
  - id: openwiki-source-20118197848107cfa8e87aa9
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHForwardingConnectionPool.swift
  - id: openwiki-source-d371db64770fd2fcc301086b
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHMaxSessionsPolicy.swift
  - id: openwiki-source-600c0f7b9ebcdcb58b4a0d05
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHMetricsSampler.swift
  - id: openwiki-source-8c4abf5c09db535e2818e3c4
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHPTYChannel.swift
  - id: openwiki-source-b3ff2edaa14925d2360e5532
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/VaultSSHAgent.swift
  - id: openwiki-source-b9bae3a52f35a3a412f81e10
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift
  - id: openwiki-source-b347308e8c5cc6c0b0d29b7d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift
  - id: openwiki-source-c4b6e224fdbea6dcd393344d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift
  - id: openwiki-source-3e30aa6e30a48c32a2351518
    resource: repo://FrameworkTests/MetricsSyncTests.swift
  - id: openwiki-source-52a93fdcfe9295de26f2b72d
    resource: repo://FrameworkTests/SSHMetricsSamplerTests.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-d44869be46c03fbd0ce9c64c
    resource: repo://TFI/Application/Agent/MobileAssistantModel.swift
  - id: openwiki-source-13f2deff6904678799b19444
    resource: repo://TFI/Application/Metrics/MobileMetricsModel.swift
  - id: openwiki-source-a053f8c3524e81f98b0b0938
    resource: repo://TFI/Features/Metrics/MobileMetricsView.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-9e75ae93f5450c1993472c5d
    resource: repo://TFM/Features/Metrics/MetricsView.swift
  - id: openwiki-source-0260a25fb41739d94e23d2ea
    resource: repo://TFMTests/AgentConnectionPoolTests.swift
  - id: openwiki-source-23ab3fe73660b171f78763a4
    resource: repo://TFMTests/AgentToolPresentationTests.swift
  - id: openwiki-source-7cc9fc3d79582cde4157ce7a
    resource: repo://TFMTests/GetMetricsToolTests.swift
  - id: openwiki-source-7468ad597251e97aa63a1c55
    resource: repo://TFMTests/PortForwardingReconnectTests.swift
  - id: openwiki-source-0e1711c93b46fc372d856a21
    resource: repo://TFMTests/SSHAgentForwardingWireTests.swift
  - id: openwiki-source-ec3ec372dd69a7df3113c6b1
    resource: repo://TFMTests/SSHMaxSessionsPolicyTests.swift
generated: { by: "pi", at: "2026-10-04T16:22:58.117Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-04T16:22:58.117Z
---


SSH is a shared transport substrate, not a single shared runtime. Terminal sessions, Metrics, port forwarding, SFTP, and Agent work can all use SSH, but each feature owns its own intent, connection lifetime, interaction surface, and recovery policy. Saved Hosts, forwarding rules, and Metrics selections describe intent; live sampler connections, authentication prompts, and forwarding listeners are not restored as connected runtimes. Explicitly saved identities or remembered host keys can be used on a later connection, unlike a one-time approval or an unpersisted submission. See [SSH session lifecycle](../workflows/ssh-session-lifecycle.md) for the general connection journey and [Agent runtime and assistant](agent-runtime-and-assistant.md) for Agent-specific transport ownership. For hardware-backed SSH credentials and their interaction boundary, see [SSH Security Key Authentication](ssh-security-key-authentication.md).

## Implementation deep dives

This page explains service ownership. Follow these guides when changing the actual algorithms:

- [SSH Multiplexing, Channel Admission, and I/O Scheduling](ssh-multiplexing-and-scheduling.md): distinguish a physical connection from its channels, trace exec/SFTP turns on the libssh2 owner, and understand readiness, retry buffers, and backpressure.
- [Shell Integration: Bootstrap, OSC Events, and Terminal State](shell-integration.md): follow probe/install timeouts, Bash/Zsh/Fish hooks, output filtering, cwd/home, command history, and compose state.
- [Port Forwarding: Multi-Connection Pool and Flow Dispatch](../workflows/port-forwarding-pool-and-dispatch.md): follow pool warm-up, accepted-socket assignment, single-worker remote forwarding, per-flow pumping, recovery, and teardown.
- [SFTP Transfer, Scheduling, and External Edit Workflow](../workflows/sftp-transfer-and-external-edit.md): follow file admission through context topology selection, extra-connection fallback, transfer completion, and edit ownership.

### The limits count different resources

| Control | Scope and accounting unit | It does not mean |
| --- | --- | --- |
| `SSHMaxSessionsPolicy` / `SSHChannelBudget` | A shared preference creates a separate FIFO lease budget for shell, exec, and subsystem channels on each physical connection. | A process-wide socket limit or a cap on forwarded TCP flows. |
| `SFTPConcurrencyScheduler` | One admitted logical file operation process-wide, with a slot on every distinct endpoint Host; obsolete borrowed-channel exclusivity was removed. | One permit per SSH channel/socket; a two-endpoint copy still consumes one global permit. |
| `SSHForwardingConnectionPool` | A Host-context target for physical connections; only local/dynamic registrations require auxiliary slots. | An SFTP file limit or multiple workers for one remote listener. |

These controls compose rather than replace each other. For example, an SFTP file can already hold its global/per-host permit while waiting for a session-channel lease on a busy primary connection.

## Service boundaries

| Service | Primary owner and connection shape | Interactive behavior | What it does not inherit |
| --- | --- | --- | --- |
| Interactive terminal | `SSHPTYChannel` opens a PTY and shell on its own authenticated connection. | Its connection journey may obtain trust, credentials, and keyboard-interactive answers. | It does not make those answers durable for later physical connections. |
| Metrics | Application-owned `ServerMetricsModel` runs one serial worker per enabled, available SSH Host selection on a dedicated sampler connection; `SSHMetricsSampler` performs bounded SSH exec requests. | Each `ServerMetric` owns its own `ConnectionJourney`, host-key authorization, and authentication queue; the mobile wrapper delegates to this same core model. | It does not start a terminal shell or use terminal environment variables/startup snippets. |
| Port forwarding | `PortForwardingController` shares a host-scoped forwarding transport among explicitly started rules; it optionally creates an `SSHForwardingConnectionPool`. | The first open can present the forwarding Journey. Recovery and auxiliary opens forbid interaction. | It does not persist a connected transport, listener, temporary password, passphrase, or once-only trust decision. |
| Agent SSH/SFTP | `AgentHostServices` supplies a Host resolver, authentication registry, background command owner and Host-keyed `AgentConnectionPool`; ordinarily exec and primary SFTP share its multiplexed connection. Agent-forwarded exec instead uses isolated per-call connections. | Tool invocations use the Agent's SSH interaction service, not a terminal or forwarding Journey. | It is not a TCP forwarding pool or an interactive PTY session. |

A `PortForwardingRule` is a portable saved description, not a listener. It identifies a Host and has `local`, `remote`, or `dynamic` (SOCKS5) kind, bind address/port, optional target address/port, label, and color. Dynamic rules deliberately erase target fields; a valid rule needs a nonblank bind host and port in `1...65_535`, while local/remote rules also require a nonblank target and valid target port. Rules remain independent of Host renames, but Host deletion removes its rules.

## Interactive terminal channels

`SSHPTYChannel` authenticates a connection, acquires a session-channel lease, opens a libssh2 `session` channel, requests an `xterm-256color` PTY, and then starts the remote shell. It owns terminal dimensions, byte conversion, output, and teardown. Closing the PTY retires its transport unless live SFTP channels still hold it; pending native exec closes alone no longer justify keeping it alive. Each external SFTP driver retains the PTY worker through asynchronous close without the owner retaining drivers. Worker deinitialization performs cleanup on its serial queue, synchronizing only when not already there. An SSH channel budget is therefore per physical SSH connection, rather than a process-wide limit.

`SSHMaxSessionsPolicy` supplies that per-connection `SSHChannelBudget` from the configured ceiling (default 10, valid range 1–100). PTY, exec, and multiplexed SFTP subsystem channels acquire FIFO leases from the same budget on a connection. A policy update changes live budgets and admits queued work when capacity permits; reducing the limit does not revoke active leases. Cancelling a queued request or closing the budget resumes it with cancellation. Direct/forwarded TCP channels, remote listeners, and jump bridges are forwarding mechanics, so they do **not** consume this OpenSSH-style session budget.

```mermaid
flowchart TD
    Policy["SSHMaxSessionsPolicy"] --> Budget["Per connection FIFO channel budget"]
    Pty["PTY shell"] --> Budget
    Exec["Exec command"] --> Budget
    Sftp["Multiplexed SFTP subsystem"] --> Budget
    Budget --> Lease["Channel lease"]
    Lease --> Open["Open session channel"]
    Tcp["Forwarded TCP and listeners"] -. "excluded" .-> Open
```

This diagram shows admission of SSH session channels; forwarding traffic bypasses the session-channel budget.

### Shell-only setup

Host environment variables are encoded using the connection charset and sent as SSH environment requests **after** the PTY request and **before** the shell starts. A server denial of an individual variable is non-fatal and reports only its name through the rejection handler; another environment-request error fails the connection. This behavior is intentionally PTY-only: exec, SFTP, Metrics, Agent, and forwarding channels do not inherit these values.

Shell integration is likewise a terminal concern. When enabled, the PTY channel queues `RemoteShellIntegrationBootstrap.startCommand` after shell startup. Its state machine suppresses its probe/install exchanges from terminal output where possible, preserves ordinary banner/prompt output, and becomes non-blocking if the remote probe is late or the user types. It is not a generic SSH bootstrap mechanism and must not be added to metrics, forwarding, Agent, or SFTP routes.

## Metrics: bounded exec sampling, not a login shell

`ServerMetricsModel` is the application-level owner, independent of windows. It persists ordered `MetricsSelection` configuration (Host ID, enabled state, disk and interface choices), not monitor connections or samples; missing Hosts stay selected but have no card/worker until available. On macOS `AppModel` constructs it with the connection coordinator's sampler factory and a Pro-dependent card limit; on iOS `MobileMetricsModel` wraps the **same `ServerMetricsModel` implementation**, delegating sampling, authentication, and retries to `core`, while setting its own Pro-dependent card limit. Admission and preference writes run through the core model, which rejects non-SSH Hosts and does not change runtime configuration if saving fails. UI windows share its card state; the desktop details page observes a Host only while visible outside its connection journey, and the mobile detail view uses the same observation interface.

`ServerMetricsModel` runs a detached serial worker for each enabled SSH Host with a generation guard. The worker resolves an SSH connection preparation with challenge-capable trust and keyboard-interactive handlers, connects a newly made sampler, then samples on a roughly two-second cadence. It publishes the base point first; GPU, filesystem, and process details are optional follow-up work. Filesystems are refreshed only while a detail view is observed and no more often than 30 seconds. On failure it disconnects and retries with exponential delays from 2 seconds to a 60-second cap; a failure needing authentication or an unsupported primary probe waits for attention instead of looping. Cancellation, disabled selection, sleep, stopped model, or a changed generation retires the work; periodic reconciliation notices Host/route/identity changes and invalidates its monitor. `snapshot(for:)` reads the existing monitor without starting collection, returning an explicit paused, sleeping, stopped, or awaiting-authentication state where applicable.

`SSHMetricsSampler` wraps its connection in `SSHExclusiveConnectionAdapter`, so its commands have exclusive use of that sampler connection. It uses bounded exec calls rather than a PTY: the primary Linux probe has an 8-second timeout and 256 KiB payload limit; filesystem and process probes use 5 seconds with 512 KiB and 1 MiB limits respectively. It recognizes exit status `42` as unsupported primary metrics and recognizes `42` or NVIDIA's `6` as no GPU; other nonzero, truncated, malformed, or oversized output is a read failure.

Remote shells can emit banners, OSC sequences, or exit-hook text around an exec command. The sampler wraps every command in `__TERMIND_METRICS_BEGIN__` and `__TERMIND_METRICS_END__` markers, parses only the enclosed payload, and permits a small framing allowance beyond the payload limit. Invalid primary-sample diagnostics redact the address section before logging and record sizes rather than treating raw remote output as safe telemetry.

Focused tests in `FrameworkTests/SSHMetricsSamplerTests.swift` verify that framing ignores shell preamble/trailer, that absent/truncated/oversized frames fail, and that unsupported/GPU exit codes retain their special meanings. `FrameworkTests/MetricsJourneyTests.swift` exercises background sampler callbacks, restored monitor reconciliation, independent prompts and retry behavior; `FrameworkTests/MetricsSyncTests.swift` checks that selections survive missing Hosts, sync across devices, and failed saves leave the runtime unchanged.

## Agent tools: host services, not terminal or forwarding sessions

The macOS `AppModel` and iOS `MobileAssistantModel` supply `AssistantToolRegistry.make` with the app's `AgentHostServices` components and a `MetricsSnapshotReading` implementation. **Tool registration is not remote connection ownership:** the app constructs the live Host resolver, Agent connection pool, authentication registry, and background-command owner once for its execution surfaces; making a registry for a conversation injects those existing services, rather than making a terminal, Metrics sampler, or forwarding controller. For tool-capable models the registry composes AgentKit built-ins, Termind's `TermindAgentTools`, and configured MCP tools (with bearer tokens resolved from AI settings); models without tool-call ability get an empty registry. The runtime owns scratch, web, planning, skills, and user-interaction groups, while Termind contributes host discovery, `get_metrics`, SSH exec/wait, SFTP, pane and scratch-to-host transfer tools. The runtime and app catalogs each register executable definitions and detail presenters; `TermindAgentTools.presenter(for:)` reads persisted presenter IDs, with a closed legacy-name fallback for old cards. The scratch workspace is keyed by conversation so staged files survive follow-up runs but stay isolated from other conversations. Plans are emitted through the ordered Agent event channel; `ssh_exec` alone is configured as a secret consumer, and its one-shot handles supply command standard input, **not** SSH login.

```mermaid
sequenceDiagram
    participant App as App shell
    participant Catalog as AssistantToolRegistry
    participant Tool as Termind host tool
    participant Auth as AgentSSHAuthenticationRegistry
    participant Pool as AgentConnectionPool
    participant Reader as ServerMetricsModel
    App->>Catalog: inject existing host services and metrics reader
    Catalog->>Tool: register tools for tool capable model
    alt get_metrics
        Tool->>Reader: snapshot for Host ID
        Reader-->>Tool: cached snapshot or monitoring state
    else ssh_exec or SFTP
        Tool->>Auth: request Host connection or SFTP lease
        Auth->>Pool: reuse or open authenticated Host transport
        Pool-->>Tool: exec connection or SFTP channel
    end
```

This shows why an Agent metrics read does not start a sampler and why Agent SSH/SFTP tools do not borrow terminal or forwarding transports.

`get_metrics` resolves an SSH-capable Host and reads `snapshot(for:)` from the injected metrics model; it neither connects nor refreshes samples. Its optional detail sections can be absent or stale, and its five-minute trend is based on cached history. `ssh_exec` instead authenticates via `AgentSSHAuthenticationRegistry`, then uses a non-PTY exec session from the Host pool. The risk preflight allows parallel safe commands but serializes commands it cannot classify safe; the libssh2 worker serializes actual session calls and applies the connection's session-channel budget. SSH login prompts come from the Agent interaction service. The authentication registry shares temporary credentials only among overlapping attempts for a Host and releases them after the last lease; the pool can reuse an authenticated Host connection across calls, runs and conversations until idle retirement or route invalidation. Concurrent cold opens for the same Host and route join one pending open; if the route changes, a cached transport is retired. A lost connection may be retried once **only before an exec channel opens**; a rejected channel or a command that already started is not replayed. SFTP operations acquire exclusive Agent channels and data transfers use the shared SFTP concurrency scheduler; overlap can use silent auxiliary connections or sibling channels. Neither that pool nor the snapshot reader starts forwarding listeners. Do not confuse TCP port forwarding with the Host's **SSH agent forwarding** switch: when that switch is enabled, Agent exec opens an isolated connection per call instead of reusing the Host pool and closes it after its exec lease, so the forwarded agent capability cannot persist across commands. The authentication registry also avoids sharing the temporary context in this mode. The ordinary pooled Agent exec path explicitly disables agent forwarding, as does the Metrics sampler. The per-connection `VaultSSHAgent` capability checks that the Host still permits forwarding, resolves keys only when used, and refuses signing that needs interaction when the connection policy forbids it. See [Agent runtime and assistant](agent-runtime-and-assistant.md) for run and approval policy and [SSH Multiplexing, Channel Admission, and I/O Scheduling](ssh-multiplexing-and-scheduling.md) for worker internals.

When changing this integration, check `TFITests/MobileAssistantTests.swift` for mobile tool availability and the no-tool-call gate, `TFMTests/AgentBuiltInToolAvailabilityTests.swift` and `TFMTests/AgentToolPresentationTests.swift` for catalog/presenter composition and restored cards, and `TFMTests/GetMetricsToolTests.swift` for snapshot-only, age and trend semantics. `TFMTests/AgentConnectionPoolTests.swift` covers reuse, concurrent opens, and agent-forwarded connection isolation; `TFMTests/SSHAgentForwardingWireTests.swift` exercises the shared host-services exec path and capability revocation on a live SSH connection.

## Forwarding: explicit intent and host-scoped runtime

A rule runs only after `PortForwardingController.start(_:)` validates the rule and confirms SSH is enabled for its Host. The controller creates or joins one `PortForwardingConnection` for that Host and route, computes an initial effective pool limit, and gives all active rules on that context the same Journey/authentication surface. A later app-supplied limit change updates that context and its connection pool. Starting a later rule on an already connected context installs only that rule. Stopping one rule unregisters it without disturbing peers; the final stop retires the context and its transport.

The visible rule state moves through `stopped`, preparation/trust/authentication/connecting stages, `starting`, `running`, reconnecting, or `failed`. Each rule start has a generation, and callbacks must match both the current context and generation. This rejects stale connection counts, delayed listener creation, and late open success after stop/restart or configuration retirement.

```mermaid
stateDiagram-v2
    [*] --> Stopped
    Stopped --> Preparing: explicit Start
    Preparing --> AwaitingTrust: host key needed
    Preparing --> AwaitingAuth: credential needed
    AwaitingTrust --> Connecting: approved
    AwaitingAuth --> Connecting: submitted
    Preparing --> Connecting: prepared
    Connecting --> Starting: SSH connected
    Starting --> Running: listener or rule installed
    Running --> Reconnecting: transport loss
    Reconnecting --> Running: silent recovery
    Reconnecting --> Failed: interaction required
    Failed --> Preparing: explicit Retry
    Preparing --> Stopped: Stop or invalidation
    Connecting --> Stopped: Stop or invalidation
    Starting --> Stopped: Stop or invalidation
    Running --> Stopped: last rule stopped
    Reconnecting --> Stopped: Stop or invalidation
```

This is the controller-facing forwarding lifecycle; a shared Host context can carry several rule generations concurrently.

### Connection pool and dispatch

On macOS, a Host-configured forwarding maximum is normalized to 1–64 (default 1) and capped by the app-supplied connection limit. Without Pro multi-connection access the effective limit is one; gaining or losing access updates existing contexts without changing the saved Host value. The macOS `.hostConfigured` policy uses `SSHForwardingConnectionPool` even at a one-connection target. iOS preserves the setting but uses a single-connection policy. In a pool, local/dynamic rules register on healthy slots behind one local listener per rule; accepted flows go to the least-loaded eligible slot with round-robin ties. Remote listeners remain on the primary connection. Auxiliary opens are limited to four at once and must install existing rules before becoming eligible. Transient slot loss retries at 1, 2, 5, 10, then 30 seconds, but a failure requiring interaction, trust, or credentials, or cancellation, does not automatically retry. These are transport availability policies, not restored listener intent; for slot promotion, socket dispatch and pumping details, use [Port Forwarding: Multi-Connection Pool and Flow Dispatch](../workflows/port-forwarding-pool-and-dispatch.md).

The first physical connection may use the forwarding Journey to collect host-key approval, credentials, or keyboard-interactive answers. Its recovery and every auxiliary connection are silent opens with interaction forbidden. Their reusable snapshot keeps route/network and identity references, not temporary passwords or passphrases. A remembered host key can permit recovery, but “continue once” trust cannot. If a silent open needs interaction, recovery fails/degrades rather than showing a form; an explicit Retry starts a new interactive Journey. Existing TCP streams are never migrated or replayed to a replacement worker.

A route/Host configuration edit, deleted/replaced rule, or explicit stop invalidates the relevant runtime. Cleanup cancels retry/open work, stops listeners before closing transports, and waits for cleanup where needed so an old bind cannot race a replacement. Local/dynamic listeners use `SO_REUSEADDR` to tolerate `TIME_WAIT`, not `SO_REUSEPORT` or live shared binds.

## Operational and change guidance

- Treat port-forwarding maximum connections as a throughput/concurrency control, not a universal latency improvement. The historical loopback results, their limits, and the intentionally single-worker remote-forwarding topology are documented in [Port Forwarding Benchmark Design, Results, and Reproduction](../operations/port-forwarding-benchmarks.md).
- Preserve readiness-driven, bounded forwarding I/O. The forwarding transport uses immutable queues and socket readiness; plaintext queues pause at 2 MiB per direction/flow and resume below 1 MiB, while encrypted output is bounded per SSH session. These are per-flow/session guardrails, not a global process memory cap.
- Do not merge service lifetimes merely because they share SSH primitives. A forwarding listener/pool, a terminal PTY, a metrics sampler, and Agent transport have different owners and retry/authentication boundaries.
- Test lifecycle changes with the focused forwarding suites. `TFMTests/PortForwardingReconnectTests.swift` covers shared-context reconnect, capped backoff, generation rejection, silent recovery, remembered versus temporary trust, and cleanup ordering. `TFMTests/PortForwardingFeatureTests.swift` covers rule normalization/validation, Host-route constraints, deletion cleanup, persistence behavior, and command rendering.

Tailscale-managed targets use a group-bound `SSHNetworkDialing` connection. A failed Tailnet dial does not fall back to the system network, and managed targets cannot be jump Hosts. Metrics retains Tailscale group identity in its selection and treats unavailable peers separately from durable monitor intent. `MultiConnectionPolicy` resolves saved SFTP/forwarding preferences against runtime availability: channels-only and one physical forwarding connection are the fallback, without changing saved preferences.
