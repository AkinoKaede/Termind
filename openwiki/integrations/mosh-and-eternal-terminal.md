---
type: Reference
title: Mosh and Eternal Terminal
description: SSH-bootstrapped resumable terminal transports, checkpoint ownership, and foreground recovery. Explains Eternal Terminal connection confirmation and terminal-end safeguards.
tags: [terminal, mosh, eternal-terminal, recovery, ssh]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-17T17:19:40.811Z
sources:
  - id: openwiki-source-f009a1e2645a074589550c44
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/EternalTerminalEngine.swift
  - id: openwiki-source-30e2d23210ae2fee41669d43
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/MoshTerminalEngine.swift
  - id: openwiki-source-7f83ab23ea7d4eb08dabc616
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/ResumableTerminalClient.swift
  - id: openwiki-source-e4058ef2da4718e60a7a042d
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/ResumableTerminalStartup.swift
  - id: openwiki-source-79e6c1c879cf7dbc211647b6
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/TerminalTransportRoute.swift
  - id: openwiki-source-95fa11ff59d3a38d49da5c6f
    resource: repo://FrameworkTests/EternalTerminalResumeTests.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-28243bbeecc381626d39eeb6
    resource: repo://TFITests/MobileTerminalRestorationTests.swift
generated: { by: "openwiki/0.7.2", at: "2026-10-17T17:19:40.811Z" }
---

# Mosh and Eternal Terminal

Mosh and Eternal Terminal (ET) are alternative terminal transports authenticated through SSH. They do not replace auxiliary SSH services such as SFTP, Agent execution or forwarding. Transport recovery preserves a remote PTY; [Session Persistence](../concepts/session-persistence.md) separately controls the remote multiplexer session inside that PTY.

## Configuration and routing

Hosts enable transports individually and choose a default. SSH remains available; an unavailable default falls back to SSH. Mosh accepts an empty UDP port specification, one port or an inclusive ascending range within 1–65535. ET defaults to TCP port 2022. Tailscale-managed Hosts do not offer Mosh, but may offer ET.

Mosh bootstraps `mosh-server` through SSH, parses the returned UDP port and key, and then connects directly to that UDP endpoint. A successful SSH connection does not prove UDP reachability: the engine waits for server operations before announcing connection and fails after a bounded startup wait. Do not assume an SSH proxy or jump route tunnels Mosh UDP.

ET uses an SSH bootstrap executor to acquire credentials and a local TCP bridge to reach a routed socket. The socket route carries the configured proxy, jumps, network adapter, host-key constraints and authentication interaction policy. The vendor session connects to the local bridge rather than bypassing Termind routing.

## Connection lifecycle

```mermaid
flowchart TD
    Select[Select enabled transport] --> Validate[Validate options and engine availability]
    Validate --> Restore{Checkpoint supplied?}
    Restore -->|no| SSH[Authenticate SSH and prepare remote startup]
    Restore -->|yes| Recover[Restore existing protocol state]
    SSH --> Engine[Prepare and start engine]
    Recover --> Engine
    Engine --> Live[Publish output and connection state]
    Live --> Suspend[Suspend and checkpoint]
    Suspend --> Recover
```
The resumable transport lifecycle separates fresh SSH bootstrap from recovery of existing protocol state.

The resumable client owns transport state, queued lifecycle requests, maintenance and network monitoring. Engines own protocol-specific state. Engine availability is checked before wake, routing or bootstrap side effects. Failed preparation invokes engine rollback, disconnects bootstrap SSH and closes the client. Network recovery reuses protocol state rather than bootstrapping another shell.

A fresh startup may receive a backend-neutral PTY startup plan. Mosh appends its quoted shell command to server startup; ET sends a quoted `exec /bin/sh -c` command to its terminal. Restoration skips startup preparation because the restored transport already owns its PTY and attached remote session. Replaying startup would risk duplicate commands or duplicate sessions.

## Recovery and security

Recovery payloads contain protocol capabilities, not merely navigation state. Keep them within the encrypted local recovery store; do not put credentials or opaque checkpoint payloads in URLs or diagnostics. Recovery leases prevent an old owner from overwriting newer state. Consuming a disk checkpoint validates its identity and route and removes it before returning usable state; deletion failure must not produce a second owner.

Live foreground resume is distinct from cold restoration: the former resumes retained engine state after suspension, while the latter consumes saved state. Neither guarantees that a remote server is still alive. A failed transport recovery must not silently create another remote shell.

### Eternal Terminal foreground confirmation

On mobile, `resumeAfterBackground()` waits for the pending suspension/checkpoint save, invalidates the disk recovery record, and only then calls `resumeTransport()` on the retained session. Generation checks reject stale work; invalidation or resume errors become transport recovery failures. This avoids leaving a consumable disk checkpoint alongside the resumed live owner.

The resumable client publishes `.recovering` before calling the engine's resume operation. ET can keep its connection alive during suspension without emitting another vendor `.connected` event. `EternalTerminalEngine` therefore remembers the latest vendor connection state and, after `resumeFromApplicationBackground()`, explicitly emits `.connected` **only if that retained state is still `.connected`**. This confirms recovery without requiring new output or a duplicate vendor notification; it is not an unconditional success signal or a fresh server probe.

```mermaid
flowchart TD
    Resume[Foreground resume] --> Open{Locally open?}
    Open -->|no| Cancel[CancellationError]
    Open -->|yes| Vendor[Resume retained vendor session]
    Vendor --> Check{Still locally open?}
    Check -->|no| Cancel
    Check -->|yes| Retained{Latest vendor state connected?}
    Retained -->|yes| Confirm[Emit connected confirmation]
    Retained -->|no| Silent[No synthetic confirmation]
```
ET foreground confirmation uses the retained vendor state and checks local closure before and after the asynchronous resume call.

A disconnected, reconnecting, failed, never-connected, or ended session gets no synthetic confirmation. Lost connections require a subsequent vendor `.connected` event to report connectivity again. A locally closed engine throws `CancellationError`; foreground resume must not revive it.

### Terminal end is not recovery

ET maps vendor `.reconnecting` and `.disconnected` to recovery, `.failed` to failure, and `.sessionEnded` to terminal end. On terminal end it waits for its output reader to drain before emitting `.ended`. The resumable client publishes `.ended` and closes resources without replacing that terminal state with `.closed`.

Mobile workspaces retain the terminal during recovery rather than scheduling ordinary SSH reconnect. A connected confirmation completes the recovery journey; duplicate connected notifications do not repeat it. On `.ended`, the workspace clears foreground resume intent and its recovery lease, cancels pending suspension, discards saved recovery state, and handles a successful remote exit. Ended or closed workspaces ignore later transport state notifications, so a late connected event cannot reopen them. Recovery and failure alone do not request workspace closure.

## Ownership and extension seams

Domain owns Host options and recovery descriptors; Application owns startup plans and backend interfaces; Remote Infrastructure owns SSH routing, resumable clients and engines. Native workspaces retain terminal views and decide when to suspend, restore or detach. Add a transport through the engine registry and capability checks, not by adding protocol branches throughout native views.

## Verification

Review `ResumableTerminalEngineTests`, `TerminalTransportTests` and mobile restoration tests for startup, rollback, checkpoint validation and stale-owner behavior. These are test entrypoints, not a claim that this documentation update ran them. Real-server validation should separately exercise blocked UDP, ET route reconnection, foreground/background transitions and server-side session loss.

Focused regression coverage:

- [EternalTerminalResumeTests](../../FrameworkTests/EternalTerminalResumeTests.swift) checks retained-connection confirmation without a new vendor event, no confirmation after connection loss or before initial connection, and no revival after terminal end or local close.
- [MobileTerminalRestorationTests](../../TFITests/MobileTerminalRestorationTests.swift) checks recovery journey completion while retaining the terminal, duplicate-event handling, missing/incompatible checkpoint failure without opening a new shell, and exactly-once workspace closure on remote end for both transports.

See also [Ghostty Terminal Integration](../concepts/ghostty-terminal-integration.md), [SSH Session Lifecycle](../workflows/ssh-session-lifecycle.md) and [Session Persistence](../concepts/session-persistence.md).
