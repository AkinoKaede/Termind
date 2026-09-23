---
type: workflow
title: SSH, Telnet, Trust, and Workspace Session Lifecycle
description: Traces how Termind prepares SSH and Telnet connections, routes them through proxies and jump hosts, authorizes server identity, consumes credentials, and retires or restores live workspace sessions.
tags: [ssh, telnet, connection-lifecycle, host-keys, proxy, workspace, security]
sources:
  - id: openwiki-source-cb178f0d078ab3218679c80e
    resource: repo://Frameworks/TermindApplication/Connections/RemoteSessionConnectionController.swift
  - id: openwiki-source-5aa101e9f8e2906832f58121
    resource: repo://Frameworks/TermindApplication/Connections/SSHConnectionPreparation.swift
  - id: openwiki-source-4f78037bc69b6dfc293aca3d
    resource: repo://Frameworks/TermindApplication/SSHConnectionTypes.swift
  - id: openwiki-source-e980c605b1828a2d960bfd5e
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHConnection.swift
  - id: openwiki-source-ab74624bdc6b7046d91bcbac
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHConnectionWorker.swift
  - id: openwiki-source-8c4abf5c09db535e2818e3c4
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHPTYChannel.swift
  - id: openwiki-source-04973e11e30eed9faa5cb86b
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHRoutedSocket.swift
  - id: openwiki-source-1f7380cad037b68eb1bec322
    resource: repo://Frameworks/TermindRemoteInfrastructure/Telnet/TelnetConnection.swift
  - id: openwiki-source-7d8c92c7f508941f92360dcd
    resource: repo://FrameworkTests/SSHConnectionPreparationTests.swift
  - id: openwiki-source-2635e6aecc48e14adbb07b91
    resource: repo://FrameworkTests/SSHHostKeyAuthorizationTests.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-350d4a794cfef67e406ddf9b
    resource: repo://TFI/Infrastructure/MobileWorkspaceStore.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-9b78a7e39bfa08bea5192722
    resource: repo://TFITests/MobileWorkspaceStoreTests.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-85c3f954351f96433cb1fb4b
    resource: repo://TFMTests/ConnectionJourneyTests.swift
generated: { by: "codex", at: "2026-09-23T00:14:42.075Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T02:40:53.789Z
---

# SSH, Telnet, Trust, and Workspace Session Lifecycle

## Scope and ownership

A remote session is deliberately assembled in layers. Application code snapshots a route, identity choices, known-host expectations, and transient submissions into `SSHConnectionPreparation`; Remote Infrastructure opens the routed socket, completes each libssh2 handshake and authentication, then gives the feature an authenticated transport or protocol-specific client. `RemoteConnectionCoordinator` is the application-facing factory and one-shot connection boundary: it produces PTY, multiplexed SSH, or SFTP owners and disconnects an owner if its initial connect fails, so callers never receive a half-open session.

The session feature—not the coordinator—owns user-facing `ConnectionJourney`, host-key and keyboard-interactive queues, retry timing, and the decision to keep or discard a workspace. This separation is important: a terminal, an SFTP browser, Metrics, or forwarding can share preparation and transport policy without sharing UI lifetime or an interactive prompt.

```mermaid
sequenceDiagram
    participant Feature
    participant Prepare as SSHConnectionPreparation
    participant Opener as SSHConnectionOpener
    participant Route as SSHRoutedSocket
    participant Remote as Server or jump host
    Feature->>Prepare: resolve route and one shot credentials
    Prepare-->>Feature: SSHConnectionConfiguration
    Feature->>Opener: open authenticated connection
    Opener->>Route: open direct or routed socket
    Route->>Remote: proxy negotiate and SSH hop handshake
    Route-->>Opener: socket to destination
    Opener->>Remote: destination handshake and host key
    Opener->>Feature: request approval if necessary
    Feature-->>Opener: accept or reject
    Opener->>Remote: authenticate
    Opener-->>Feature: authenticated connection
```

*SSH preparation resolves data before transport opening; trust approval occurs on the actual handshake path.*

## Prepare the route and attribute proxies correctly

`SSHConnectionPreparation` is a MainActor-safe value snapshot whose potentially blocking Keychain resolution happens in a detached task before socket work begins. It requires a nonempty target route, resolves every jump before the target, and creates an `SSHRouteHopConfiguration` for each jump. A strict `.requireKnownHost` preparation fails if any route node has no expected key; `.allowChallenge` defers that decision to the live handshake. Credential lookup distinguishes an unavailable secret-store error from an absent credential, permits username-only identities to reach server authentication, and avoids reading a protected key before a required passphrase has been supplied.

Each node may carry a separate proxy configuration and proxy identity/submission. The proxy password is resolved independently from SSH credentials and becomes an `SSHTransportProxy` with `ownerHostID` set to the host whose proxy it is. This preserves a key UI and retry invariant:

- A proxy is **not** a `ConnectionJourney` endpoint.
- The first proxy belongs to **Local**; a proxy used after a jump belongs to the preceding authenticated SSH host.
- Proxy connect, proxy authentication, failure, and retry are displayed against that preceding endpoint. Only the subsequent host's SSH connection advances the route.

`SSHRoutedSocket` enforces the same physical order. It connects to the first jump through its proxy, authenticates that jump, opens a `direct-tcpip` channel to the next proxy or host, and repeats. A proxy after a jump negotiates over the bridge before the next SSH handshake. Proxy errors retain the owning host ID, letting the feature request the correct proxy-specific credentials rather than mislabeling the destination as the failing endpoint.

```mermaid
flowchart TD
    Start["Start route"] --> First{"Any jump hosts"}
    First -->|no| Direct["Open target socket through target proxy"]
    First -->|yes| JumpSocket["Open first jump through its proxy"]
    JumpSocket --> Hop["Handshake trust and authenticate jump"]
    Hop --> Bridge["Open direct TCP channel to next endpoint"]
    Bridge --> Proxy{"Next endpoint has proxy"}
    Proxy -->|yes| Negotiate["Negotiate proxy on bridge"]
    Proxy -->|no| More{"More jump hosts"}
    Negotiate --> More
    More -->|yes| Hop
    More -->|no| Destination["Handshake trust and authenticate target"]
    Direct --> Destination
```

*Each proxy is negotiated before the SSH session for the host it leads to, while journey attribution remains at the preceding endpoint.*

## Host-key authorization: persistent trust is independent of a Host

Known-host entries are endpoint trust records, not properties of a `Host` record. Editing or deleting a Host must not move or remove shared trust; multiple identities can be trusted for an endpoint. A temporary approval is held only in the live connection controller and is added to that attempt's expected identities without writing Known Hosts. A persistent approval writes the known-host entry **before** the pending attempt is resumed.

After each handshake, infrastructure observes the negotiated key algorithm and SHA-256 fingerprint. Authorization has a fixed precedence:

1. An optional URI-style `SSHHostKeyConstraint` is checked first. Its legacy MD5 match is an additional out-of-band constraint, not durable trust.
2. A matching expected Known Hosts identity succeeds with no authorizer call.
3. A mismatch against a nonempty expected set fails. Even a matching provisional constraint cannot override an existing, conflicting Known Hosts set.
4. For an unknown key, an authorizer may accept or reject an `SSHHostKeyChallenge`; absent an authorizer, unknown trust fails closed.

Thus a matching external-link fingerprint can reject the wrong server and can annotate a first-use prompt, but it cannot create, replace, or override persistent trust. This also means approval is made during the real handshake-to-authentication attempt, rather than by a separate discovery connection that could observe a different peer.

```mermaid
flowchart TD
    Seen["Observe handshake host key"] --> Constraint{"Constraint present"}
    Constraint -->|yes| Match{"Constraint matches"}
    Match -->|no| Reject["Reject mismatched host key"]
    Match -->|yes| Known
    Constraint -->|no| Known{"Expected set contains key"}
    Known -->|yes| Auth["Authenticate"]
    Known -->|no| Existing{"Expected set nonempty"}
    Existing -->|yes| Reject
    Existing -->|no| Prompt["Ask shared authorizer"]
    Prompt -->|accept| Auth
    Prompt -->|reject| Reject
```

*Known Hosts remains authoritative; provisional URI constraints only narrow what may be accepted.*

`SSHHostKeyAuthorizationCoordinator` exposes one pending decision to a session feature. Continue Once records temporary identity for that host; Trust and Continue persists it; disconnect rejects and clears a pending decision. Keyboard-interactive authentication follows the same ownership pattern: the C callback blocks only its dedicated transport queue while an async handler answers literal server prompts. A request ID and cancellation state ensure that a late responder cannot satisfy a later challenge; cancellation wakes the condition and shuts down the socket so libssh2 cannot continue with empty answers.

## Authentication and secret lifetime

A configuration carries credentials only for one physical connection attempt. Its `SSHSecret` values are shared mutable secret owners, so copies of the configuration can be invalidated together. `SSHConnectionConfiguration.clearSecrets()` clears target credentials, proxy password, and every jump credential. Public entrypoints defer that cleanup on both success and failure, and the authenticated opener also clears at its own transport boundary. Retrying resolves saved material again; a temporary password or key passphrase is not a reusable connection snapshot.

Credentials may be a password, software private key and optional passphrase, Secure Enclave key, or the marker `.interactionRequired`. Authentication tries the resolved configuration at the relevant hop or destination. When an operation forbids interaction, `SSHConnectionRequest.enforcingInteractionPolicy()` replaces credentials requiring a passphrase or user presence with `.interactionRequired`, clears software secret material, makes host-key authorization throw `SSHInteractionRequired`, and permits keyboard-interactive only when there are no prompts. This is how silent additional connections avoid unexpectedly displaying password, trust, MFA, Touch ID, or device-password UI.

Keyboard-interactive is available to routed hops and the target. It preserves host, port, username, connection ID, and round number in the challenge; answer count must exactly equal prompt count. Time spent waiting for the user extends the libssh2 callback budget, while answers themselves are transient and never a cache.

## Transport and channel ownership

An authenticated SSH connection has one serial libssh2 owner. `SSHConnection` is an actor facade over `SSHConnectionWorker`, whose private dispatch queue serializes all library calls. It can multiplex independent non-PTY exec channels and SFTP channels on the one authenticated session, while a channel budget limits SSH “session” channels. Exec commands use a private channel and an owned, zeroizing input queue, so a command's working directory or stdin does not leak into another command.

The worker's generation token invalidates socket events, timers, and scheduled pumps after cleanup. Disconnect increments that generation, cancels timers, fails outstanding commands, closes multiplexed SFTP channels and the channel budget, and closes the authenticated transport. Connection-level socket failure is reported once, then uses the same cleanup path. This establishes two related invariants: libssh2 is never entered concurrently, and a retired connection cannot have a stale event revive or mutate its replacement.

Feature models apply the same idea at the UI boundary. `RemoteSessionConnectionController.progressHandler(attemptID:isCurrent:)` forwards route progress to `ConnectionJourney` only for the current attempt. Mobile workspaces replace their UUID generation when connecting, backgrounding, exiting, or retiring work, and guard every asynchronous completion against it. Late connection, transfer-preparation, socket, and timer callbacks therefore cannot attach an obsolete transport, clear newer state, or enqueue work after explicit close.

### Continue into post-authentication mechanics

Authentication answers whether a transport may be installed. The next layer decides how its work progresses and how additional transports are obtained:

- [SSH Multiplexing, Channel Admission, and I/O Scheduling](/openwiki/concepts/ssh-multiplexing-and-scheduling.md) explains per-connection session leases, serial libssh2 ownership, exec state machines, SFTP retry turns, and buffer backpressure.
- [Shell Integration: Bootstrap, OSC Events, and Terminal State](/openwiki/concepts/shell-integration.md) follows the PTY-only probe/install exchange, shell hooks, charset-aware event filtering, history, cwd/home, and platform-specific prompt readiness.
- [SFTP Transfer, Scheduling, and External Edit Workflow](/openwiki/workflows/sftp-transfer-and-external-edit.md) explains file permits before channel acquisition, independent-connection preference, sibling/primary fallback, and detached transfer ownership.
- [Port Forwarding: Multi-Connection Pool and Flow Dispatch](/openwiki/workflows/port-forwarding-pool-and-dispatch.md) follows pool publication, local/SOCKS flow assignment, primary-only remote listeners, and the distinction between auxiliary repair and whole-context recovery.

## Retry, retirement, and workspace behavior

A connection failure before the first successful session remains a failed journey requiring an explicit user retry. Once a session has connected, `RemoteSessionConnectionController` can schedule recovery through `SessionReconnectController`; it pauses recovery for trust or authentication interaction and resets recovery state on disconnect. Retiring a session cancels prompt queues, rejects pending host-key approval, clears temporary trust, stops reconnect work, and hides the journey.

The platform rules intentionally differ:

| Situation | Desktop macOS | Mobile iOS and iPadOS |
| --- | --- | --- |
| Window or app restoration | Native scene/frame restoration restores window presentation, not live Workspace transports. Dynamic Workspaces are window-owned and are not reconnected simply because a window is restored. | `mobile.workspaces.v1` stores only ordered local descriptors containing workspace ID, Host ID, kind and title. Cold launch shows saved descriptors but creates no sessions, history, or network activity. |
| Reopen/select | Mounting a preserved desktop workspace does not repeat authentication; explicit retry or reopen may. Moving a workspace preserves its surfaces, transport, splits, and state. | Opening a descriptor reuses or registers one live workspace across scenes and makes at most one initial connection attempt; a failure needs explicit retry. Peer switching retains the live workspace. |
| Background/foreground | Desktop quit/close follows owned-session teardown; independent transfers and services have their own lifetime. | Background expiration closes transports but retains workspace intent. Foreground resumes existing workspaces when their recorded foreground-resume intent is set. |
| Explicit close | The owning window closes its own sessions; closing a pane removes empty workspaces without transferring ownership. | Explicit close removes the live and recent entry and never retries it. |

Telnet is intentionally a separate terminal transport rather than an SSH fallback. `TelnetConnection` opens direct TCP with `NWConnection`, or obtains a proxied socket through `TerminalSocketConnector`; its own UUID generation rejects stale Network and socket callbacks. It performs incremental IAC negotiation, NVT line conversion, terminal type and NAWS support, and applies the configured charset only to application data. Optional username/password automation responds to recognized prompts, consumes and clears the password after use, and falls back to manual interaction when the expected flow does not materialize. It has no SSH host-key verification, jump-host route, SFTP channel, or shell integration.

```mermaid
stateDiagram-v2
    [*] --> prepared
    prepared --> opening: connect
    opening --> waitingTrust: unknown key
    opening --> waitingCredentials: local or server challenge
    waitingTrust --> opening: accept and retry attempt
    waitingCredentials --> opening: submit one shot credentials
    opening --> authenticated: handshake and auth succeed
    opening --> failed: unrecoverable failure
    authenticated --> recovering: transport loss after first connect
    recovering --> opening: scheduled retry
    authenticated --> retired: close background expiry or owner teardown
    waitingTrust --> retired: reject or disconnect
    waitingCredentials --> retired: cancel or disconnect
    failed --> opening: explicit retry
    retired --> [*]
```

*The feature owns visible waiting, recovery, and retirement; transport resources are installed only after authentication succeeds.*

## Operational guidance and focused tests

When changing connection code, preserve these boundaries:

- Build only `SSHConnectionPreparation` snapshots from UI/store state; do not carry plaintext through retry state or reusable snapshots.
- Keep proxy submission and SSH submission separate, and preserve the proxy `ownerHostID` so the Journey stays on the prior endpoint.
- Do not make a URI fingerprint or temporary approval durable trust, and do not bypass authorization on a known-host mismatch.
- Put callbacks from sockets, timers, detached preparation, and authentication behind the current attempt/generation check before touching feature state.
- Have the owner that opened a client retire it on every failed connect and on explicit close; do not transfer a half-open client to a workspace.

The highest-value regression coverage is concentrated in `SSHConnectionPreparationTests` and `SSHHostKeyAuthorizationTests`: proxy attribution and one-shot proxy submission, missing proxy-password ownership, username-only and passphrase ordering, secret-read accounting, constraint-versus-Known-Hosts precedence, temporary versus persistent trust, and cancellation of pending trust. `ConnectionJourneyTests` validates endpoint progression, proxy attribution, pending-route behavior, retries, temporary host keys, multi-key trust, and the fact that editing a Host does not relocate Known Hosts. `MobileWorkspace`'s generation guards cover the platform-specific late-callback and foreground-resume boundary.

## Related pages

- [Platform runtime and lifetime ownership](/openwiki/architecture/platform-runtime.md)
- [Persistence and secrets](/openwiki/concepts/persistence-and-secrets.md)
- [Remote services and forwarding](/openwiki/concepts/remote-services-and-forwarding.md)
- [SFTP transfer and external edit workflow](/openwiki/workflows/sftp-transfer-and-external-edit.md)
