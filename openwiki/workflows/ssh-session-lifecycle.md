---
type: workflow
title: SSH Session Lifecycle and Recovery
description: Traces host selection, one-shot SSH preparation, routed trust and authentication, transport ownership, and desktop and mobile workspace teardown. Distinguishes window sessions from app-owned Agent connections and mobile restoration intent.
tags: [ssh, telnet, connection-lifecycle, host-keys, proxy, workspace, security]
sources:
  - id: openwiki-source-b7659044185b653107841c20
    resource: repo://Frameworks/TermindApplication/Connections/RemoteSessionAuthenticationContinuation.swift
  - id: openwiki-source-cb178f0d078ab3218679c80e
    resource: repo://Frameworks/TermindApplication/Connections/RemoteSessionConnectionController.swift
  - id: openwiki-source-d69fe1c34dca9a13f42d2dbc
    resource: repo://Frameworks/TermindApplication/Connections/RemoteSessionHostStore.swift
  - id: openwiki-source-5aa101e9f8e2906832f58121
    resource: repo://Frameworks/TermindApplication/Connections/SSHConnectionPreparation.swift
  - id: openwiki-source-dc7b363138921b0923d2dc2f
    resource: repo://Frameworks/TermindApplication/FeatureModels/ConnectionHistoryModel.swift
  - id: openwiki-source-4143deeb06ebc3198de62e2b
    resource: repo://Frameworks/TermindApplication/FeatureModels/HostLibraryModel.swift
  - id: openwiki-source-7ca30f0e781e8c2df826b47a
    resource: repo://Frameworks/TermindApplication/HistoryLimits.swift
  - id: openwiki-source-4f78037bc69b6dfc293aca3d
    resource: repo://Frameworks/TermindApplication/SSHConnectionTypes.swift
  - id: openwiki-source-cd3e43e60522274ce1f1908b
    resource: repo://Frameworks/TermindApplication/SSHSecret.swift
  - id: openwiki-source-e67e20bc76b0da7e73bb5fac
    resource: repo://Frameworks/TermindApplication/Terminal/RemoteSessionBackend.swift
  - id: openwiki-source-c375092b23c70ace642fdbd7
    resource: repo://Frameworks/TermindApplication/Terminal/RemoteSessionCloseCoordinator.swift
  - id: openwiki-source-44f3b562f3c7b739d591cf92
    resource: repo://Frameworks/TermindDomain/Sessions/SessionPersistence.swift
  - id: openwiki-source-1fc00d0407016efa5a0378eb
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentBuiltInSSHTools.swift
  - id: openwiki-source-0c82bf45bc197f879a54fd3a
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentConnections.swift
  - id: openwiki-source-ead8e57ca19639dd536b792d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/AgentHostServices.swift
  - id: openwiki-source-10293d817ed22d85c49da66e
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/RemoteTmuxService.swift
  - id: openwiki-source-dd3df578da8881d8ba0638e6
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SFTPChannel.swift
  - id: openwiki-source-e980c605b1828a2d960bfd5e
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHConnection.swift
  - id: openwiki-source-ab74624bdc6b7046d91bcbac
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHConnectionWorker.swift
  - id: openwiki-source-87a3a38f6388c572528dc8c4
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHKeyboardInteractiveExchange.swift
  - id: openwiki-source-8c4abf5c09db535e2818e3c4
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHPTYChannel.swift
  - id: openwiki-source-04973e11e30eed9faa5cb86b
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHRoutedSocket.swift
  - id: openwiki-source-1f7380cad037b68eb1bec322
    resource: repo://Frameworks/TermindRemoteInfrastructure/Telnet/TelnetConnection.swift
  - id: openwiki-source-ffc9054d578eba7be684b885
    resource: repo://FrameworkTests/SessionPersistenceTests.swift
  - id: openwiki-source-ed4da67c229084479edcd999
    resource: repo://FrameworkTests/SFTPChannelLifetimeTests.swift
  - id: openwiki-source-7d8c92c7f508941f92360dcd
    resource: repo://FrameworkTests/SSHConnectionPreparationTests.swift
  - id: openwiki-source-6f2f3aed2218602847085f4d
    resource: repo://FrameworkTests/SSHConnectionWorkerLifecycleTests.swift
  - id: openwiki-source-2635e6aecc48e14adbb07b91
    resource: repo://FrameworkTests/SSHHostKeyAuthorizationTests.swift
  - id: openwiki-source-db40aa993661b07f1a9aff6d
    resource: repo://FrameworkTests/SSHInteractionPolicyTests.swift
  - id: openwiki-source-67f284756d9cb27d2bd3eda8
    resource: repo://FrameworkTests/SSHPTYChannelWorkerLifecycleTests.swift
  - id: openwiki-source-eaed8c88a9a3f24e3feb1f9c
    resource: repo://FrameworkTests/WebAuthnVaultMetadataTests.swift
  - id: openwiki-source-ce352ef072f1a174eebd877e
    resource: repo://Scripts/ssh-tmux-session-fixture.py
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-c1f5a86747a33d4e8472672c
    resource: repo://TFI/App/MobileWorkspaceSessionModel.swift
  - id: openwiki-source-d44869be46c03fbd0ce9c64c
    resource: repo://TFI/Application/Agent/MobileAssistantModel.swift
  - id: openwiki-source-3f37062f55fb57a9f2e97f35
    resource: repo://TFI/Features/Vault/MobileVaultView.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-350d4a794cfef67e406ddf9b
    resource: repo://TFI/Infrastructure/MobileWorkspaceStore.swift
  - id: openwiki-source-34542e0f07e1650e098824c7
    resource: repo://TFI/Platform/MobileBackgroundController.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-b360f8803ec98b554faad9bb
    resource: repo://TFITests/MobileWorkspaceSessionTests.swift
  - id: openwiki-source-9b78a7e39bfa08bea5192722
    resource: repo://TFITests/MobileWorkspaceStoreTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-7e796927b780e67cc73f6a5b
    resource: repo://TFM/Features/Terminal/SSHSessionModel.swift
  - id: openwiki-source-ee09ece1fddff7d72a2b5cf4
    resource: repo://TFM/Features/Workspaces/Pane.swift
  - id: openwiki-source-22b9fca540c3029c5ace451e
    resource: repo://TFM/Features/Workspaces/WindowModel.swift
  - id: openwiki-source-dad03c68d6b805a4170ffc02
    resource: repo://TFM/Platform/WorkspaceCloseConfirmation.swift
  - id: openwiki-source-cfbc34def649c94f760c5695
    resource: repo://TFMTests/AgentHostAuthenticationTests.swift
  - id: openwiki-source-73c75477db0674192248aa00
    resource: repo://TFMTests/AppTerminationTests.swift
  - id: openwiki-source-c15cd5bef4646aaf64df407e
    resource: repo://TFMTests/ConnectionHistoryTests.swift
  - id: openwiki-source-85c3f954351f96433cb1fb4b
    resource: repo://TFMTests/ConnectionJourneyTests.swift
  - id: openwiki-source-c40a8f8c27fd537db3a62965
    resource: repo://TFMTests/DesktopAuthenticationSubmissionTests.swift
  - id: openwiki-source-da61dbcdf7f720ccca8efaad
    resource: repo://TFMTests/RemoteSessionAuthenticationContinuationTests.swift
  - id: openwiki-source-b66a49647a50cd8651dc7fe2
    resource: repo://TFMTests/RemoteSessionWireTests.swift
  - id: openwiki-source-fc9dd746ee8dc0791104d397
    resource: repo://TFMTests/SSHPTYChannelLifecycleWireTests.swift
generated: { by: "openwiki/0.7.0", at: "2026-10-15T22:50:00.588Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-15T22:50:00.588Z
---

# SSH Session Lifecycle and Recovery

For group-bound networking, managed Tailscale SSH, stable Host IDs and enrollment cleanup, start with [Tailscale groups, embedded nodes, and SSH](../integrations/tailscale.md).

## Scope and ownership

A remote session is deliberately assembled in layers. `RemoteSessionHostStore` can snapshot a route, identity choices, known-host expectations, and transient submissions into `SSHConnectionPreparation` for mobile workspaces and other preparation-based callers; the desktop terminal also has its own prompt-first path that builds `SSHConnectionConfiguration` from the store and staged credentials for each attempt. On desktop `AppModel.open(_:as:in:)` dispatches a saved Host to a window pane; `SSHSessionModel.connectIfNeeded(using:)` starts its pending mounted session, while explicit `connect(using:)` handles retry. On mobile `MobileWorkspace.connect()` takes one-use submissions, resolves preparation with `.allowChallenge`, installs trust, keyboard-interactive and Security Key callbacks on the request, then opens a PTY or SFTP client. Agent tools instead use the app-owned resolver, authentication registry and pool: their interactive connection preparation is not a desktop pane's `SSHSessionModel` path. Remote Infrastructure opens the routed socket, completes each libssh2 handshake and authentication, then gives the feature an authenticated transport or protocol-specific client. `RemoteConnectionCoordinator` is the application-facing factory and one-shot connection boundary: it produces PTY, multiplexed SSH, or SFTP owners and disconnects an owner if its initial connect fails, so callers never receive a half-open session.

The session feature—not the coordinator—owns user-facing `ConnectionJourney`, host-key and keyboard-interactive queues, retry timing, and the decision to keep or discard a workspace. This separation is important: a terminal, an SFTP browser, Metrics, forwarding, or an Agent tool can share preparation and transport policy without sharing UI lifetime or an interactive prompt. On desktop, `TermindApp` builds one `AppModel` for shared host data and services, but `WindowGroup` constructs a separate `WindowModel` for each window's dynamic workspaces and selection. Agent SSH connections are **not** borrowed from those workspace sessions: `AppModel` constructs `AgentHostServices.live` with the shared coordinator and registers its resolver, authentication registry, connection pool, and background-command owner with Assistant and MCP. Agent sessions can therefore survive a window's workspace closure until their own pool eviction or app cleanup. A temporary pane-backed Agent target is different: the resolver rechecks that its pane still exists before reusing a pooled connection, and a vanished pane makes the target invalid.

```mermaid
sequenceDiagram
    participant Feature
    participant Prepare as SSHConnectionPreparation
    participant Opener as SSHConnectionOpener
    participant Route as SSHRoutedSocket
    participant Remote as Server or jump host
    alt mobile or preparation based caller
        Feature->>Prepare: resolve route and one shot credentials
        Prepare-->>Feature: SSHConnectionConfiguration
    else desktop terminal
        Feature->>Feature: stage prompts and build attempt configuration from host store
    else Agent tool
        Feature->>Feature: resolve through Agent authentication registry and pool
    end
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

*Desktop and mobile workspace attempts and Agent tool attempts have distinct state owners; all authorize the server on the handshake path, not during host listing.*

## Prepare the route and attribute proxies correctly

`SSHConnectionPreparation` is a MainActor-safe value snapshot whose potentially blocking Keychain resolution happens in a detached task before socket work begins. Cancellation cancels that worker; if it has already returned a configuration, the awaiting task checks cancellation and clears its secrets before throwing. Partial resolution also clears any collected jump/target credentials and proxy passwords on failure. It requires a nonempty target route, resolves every jump before the target, and creates an `SSHRouteHopConfiguration` for each jump. A strict `.requireKnownHost` preparation fails if any route node has no expected key; `.allowChallenge` defers that decision to the live handshake. Credential lookup distinguishes an unavailable secret-store error from an absent credential, permits username-only identities to reach server authentication, and avoids reading a protected key before a required passphrase has been supplied. Desktop `SSHSessionModel.startConnection` instead checks missing proxy password, host password, protected-key passphrase, and username **before** taking one-shot submissions. It resolves selected or saved credentials, proxies, ordered jumps and expected keys from the host store, then opens a PTY with host-key and keyboard-interactive callbacks; credential errors route back to the failing host or proxy prompt rather than installing a failed transport.

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

Credentials may be a password, software private key and optional passphrase, Secure Enclave key, FIDO2 Security Key, or the marker `.interactionRequired`. Authentication tries the resolved configuration at the relevant hop or destination. Security Key credentials come from the key's Vault metadata rather than a Keychain private-key lookup, for both jumps and destination. An interactive request supplies a signing callback: the route and destination authentication exchanges use it to sign the SSH public-key challenge, with the current hop's host identity; cancelling the exchange wakes the waiting transport queue and ignores late signing results. When an operation forbids interaction, `SSHConnectionRequest.enforcingInteractionPolicy()` replaces credentials requiring a passphrase or user presence, including all Security Keys, with `.interactionRequired`, clears software secret material, makes host-key authorization throw `SSHInteractionRequired`, and permits only informational keyboard-interactive rounds (no prompts and not a Tailscale browser-approval banner). This is how silent additional connections avoid unexpectedly displaying password, trust, MFA, Touch ID, or device-password UI. See [SSH Security Key Authentication](../concepts/ssh-security-key-authentication.md) for registration, Vault metadata, signing and forwarding limits.

Keyboard-interactive is available to routed hops and the target. It preserves host, port, username, connection ID, and round number in the challenge; answer count must exactly equal prompt count. Time spent waiting for the user extends the libssh2 callback budget, while answers themselves are transient and never a cache.

Desktop terminal and SFTP models share `RemoteSessionConnectionController.continueAuthentication`. It re-resolves the prompt host through route → library → temporary destination and rejects an empty trimmed username without changing the prompt. The continuation has distinct branches:

- **Identity:** the selected identity supplies username and key selection when present; otherwise entered values are used. Stage the one-use SSH submission and model-specific username/route state, clear the prompt and resume the journey, then run the synchronous model-owned save policy if requested. Only a successful policy (or no requested save) invokes explicit connect. A failed credential save does **not** initiate another connection attempt: the model restores an error-bearing authentication prompt.
- **Proxy:** use the entered username rather than the selected identity's username. Save proxy authentication first if requested; only afterward stage the separate proxy submission, clear the prompt, resume and connect. A save failure leaves the original prompt and stages no proxy submission.
- **Protected-key passphrase:** merge through `passphraseSubmission` with the existing SSH submission, optionally saving the key passphrase. Success clears the prompt and connects; failure updates the existing prompt's failure message without connecting.

These synchronous callbacks are never retained. Host-key trust is a separate live-handshake continuation, not an identity submission or a new connection attempt.

`RemoteSessionConnectionController` centralizes attempt state: begin resets the journey and starts a pending route, finish accepts only the current token, and clear invalidates that token and route. Its live progress callback ignores replaced and cleared attempts. Transport recovery runs teardown before resetting the journey and invoking the model’s scheduled-state closure; the reconnect task does not own the transport or reconstruct secrets.

## Transport and channel ownership

An authenticated SSH connection has one serial libssh2 owner. `SSHConnection` is an actor facade over `SSHConnectionWorker`, whose private dispatch queue serializes all library calls. It can multiplex independent non-PTY exec channels and SFTP channels on the one authenticated session, while a channel budget limits SSH “session” channels. Exec commands use a private channel and an owned, zeroizing input queue, so a command's working directory or stdin does not leak into another command.

The worker's generation token invalidates socket events, timers, and scheduled pumps after cleanup. While a new connection is still opening, cancellation of its route or destination authentication also cancels the keyboard-interactive/Security Key exchange, interrupts its socket, and serializes opening-state cleanup. Disconnect increments that generation, cancels timers, fails outstanding commands, closes multiplexed SFTP channels and the channel budget, and closes the authenticated transport. Connection-level socket failure is reported once, then uses the same cleanup path. The worker also cleans up when its last reference is released: if release happens on its own queue it cleans up inline, otherwise it synchronously enters that queue. This avoids deadlocking on queue reentry while preserving serialized transport teardown. `SSHConnectionWorkerLifecycleTests` covers both release contexts. This establishes two related invariants: libssh2 is never entered concurrently, and a retired connection cannot have a stale event revive or mutate its replacement.

The PTY worker normally preserves its transport after terminal closure only while live SFTP channels remain, not merely because native exec CLOSE is pending. Prepared startup and managed-session inspection can explicitly retain the control connection; this is a separate owner intent, not a pending-exec lifetime extension. Each SFTP driver retains its worker through asynchronous cleanup, with no owner-to-driver cycle. Worker destruction cleans up on its serial queue and avoids synchronous self-reentry. `SSHPTYChannelWorkerLifecycleTests` covers queue release, `SFTPChannelLifetimeTests` covers retained cleanup, and opt-in `SSHPTYChannelLifecycleWireTests` uses an unacknowledged exec CLOSE to check transport retirement and final SFTP-sibling closure.

Feature models apply the same idea at the UI boundary. `RemoteSessionConnectionController.progressHandler(attemptID:isCurrent:)` forwards route progress to `ConnectionJourney` only for the current attempt. Desktop `SSHSessionModel` checks its `connectionAttemptID` after PTY connect and in exit and integration callbacks; if post-connect installation fails it disconnects the new actor. Mobile workspaces replace their UUID generation when connecting, backgrounding, exiting, or retiring work, and guard every asynchronous completion against it. Late connection, transfer-preparation, socket, and timer callbacks therefore cannot attach an obsolete transport, clear newer state, or enqueue work after explicit close.

### Continue into post-authentication mechanics

Authentication answers whether a transport may be installed. The next layer decides how its work progresses and how additional transports are obtained:

- [SSH Multiplexing, Channel Admission, and I/O Scheduling](../concepts/ssh-multiplexing-and-scheduling.md) explains per-connection session leases, serial libssh2 ownership, exec state machines, SFTP retry turns, and buffer backpressure.
- [Shell Integration: Bootstrap, OSC Events, and Terminal State](../concepts/shell-integration.md) follows the PTY-only probe/install exchange, shell hooks, charset-aware event filtering, history, cwd/home, and platform-specific prompt readiness.
- [SFTP Transfer, Scheduling, and External Edit Workflow](sftp-transfer-and-external-edit.md) explains file permits before channel acquisition, independent-connection preference, sibling/primary fallback, and detached transfer ownership.
- [Port Forwarding: Multi-Connection Pool and Flow Dispatch](port-forwarding-pool-and-dispatch.md) follows pool publication, local/SOCKS flow assignment, primary-only remote listeners, and the distinction between auxiliary repair and whole-context recovery.

## Agent SSH connections are not workspace sessions

`list_hosts` exposes public Vault host metadata and live temporary targets from desktop panes; it does not return credentials. Agent SSH and SFTP tools require an SSH-enabled target, and a closed temporary pane fails target resolution rather than legitimizing a lingering pooled connection. The desktop resolver obtains temporary SSH configuration from the pane when needed. Merely listing a connected pane does not give a tool its PTY: `ssh_exec` opens a dedicated non-PTY exec channel over an **Agent-owned** connection.

For an unpooled host, `AgentSSHAuthenticationRegistry` leases a per-host `AgentSSHAuthenticationContext` only while overlapping operations connect. The resolver requests missing proxy credentials, identity and protected-key passphrase in route order **before** opening the socket, then uses the attempt's callback to ask for host-key approval at handshake and literal keyboard-interactive answers during authentication. Saved Hosts can persist an explicitly saved identity or trust decision; Continue Once remains attempt-scoped, and temporary targets cannot persist trust from an Agent card. Concurrent exec and primary SFTP openings join one authentication prompt and one pending connection. Cancellation removes an individual waiter and cancels its prompt when no waiters remain; generation checks prevent old failures or late answers from overwriting newer attempts. A rejected credential can prompt again for the failing hop or proxy, but successful authentication consumes the submitted secrets. For a proxy with an unavailable saved password, the prompt keeps `proxy.username` even if its selected password identity is missing; an unsaved answer overrides the proxy only for this attempt, while Save updates the Vault proxy identity and username. Identity and protected-key passphrase are separate prompts: entering a passphrase merges into the staged identity submission, retaining its password fallback. The registry drops the context after its last connecting lease: a later physical connection must resolve saved credentials or ask again, not reuse a previous Custom password.

`AgentConnectionPool` keys reusable authenticated connections by Host ID and an in-memory route fingerprint (route, identities, proxies, known-host keys and destination charset), not by run or window. Fingerprinting reads no Keychain secrets: changing a saved secret without changing identity affects the **next** connection, whereas changing route or trust invalidates reuse. Concurrent misses coalesce into one open; cancelled or superseded opens cannot publish late sockets. The primary SFTP subsystem and exec commands share the pooled transport; exclusive SFTP leases may use silent auxiliary connections or sibling channels as scheduling allows. Idle sweeping defaults to 180 seconds and spares active exec and SFTP leases; host deletion and app termination explicitly close the pool. This is distinct from the feature-owned terminal, SFTP, and forwarding lifetimes described in the linked pages.

```mermaid
sequenceDiagram
    participant Tool as Agent SSH tool
    participant Registry as Authentication registry
    participant Resolver as Host resolver
    participant Pool as Agent connection pool
    participant Server as SSH server
    Tool->>Registry: connectionContext for host
    Registry->>Pool: check pooled connection
    alt no reusable connection
        Registry->>Resolver: resolve proxy identity and passphrase in route order
        Resolver-->>Registry: one attempt with trust callbacks
        Registry->>Pool: open with attempt request
        Pool->>Server: handshake and authorize host key
        Pool->>Server: authenticate
        alt credential rejected
            Registry->>Resolver: retry failing hop or proxy with retained username
            Resolver-->>Registry: new one shot attempt
            Registry->>Pool: open replacement connection
            Pool-->>Registry: authenticated transport
        else authenticated
            Pool-->>Registry: authenticated transport
        end
        Registry->>Registry: clear staged secrets
    else reusable connection
        Pool-->>Registry: pooled transport
    end
    Registry-->>Tool: connection
    Tool->>Pool: acquire exec lease
    Tool->>Server: run non PTY command channel
```

*The Agent shares its own transport across tools, not a workspace's interactive session; prompts and one-use secrets belong to the connection attempt.*

`ssh_exec` preflight classifies safe commands for parallel execution and asks approval for unproven commands, which run sequentially. Optional secret stdin is consumed from a handle bound to the run, host, tool and purpose; it is not an SSH login credential. Its reporting deadline includes connection setup. If setup is still pending, it returns `connecting` and starts **no** command; if an already-started command exceeds the deadline, `AgentBackgroundCommands` adopts its session and output under a handle for `ssh_wait`, while the shared connection stays available. A dead pooled connection can be retried once only if no command channel opened; never replay an operation that might have had effects.

## Managed remote sessions: selection, ownership, and PTY startup

Session persistence is opt-in per Host (also supported by Tailscale host preferences): defaults are disabled, backend `.tmux`, and `onConnect: .ask`. Enabled policies are Ask, Create Managed, and Plain Shell. These settings are not transport persistence: reconnect still authenticates a new SSH connection. The live registry currently maps `.tmux` to `RemoteTmuxService`; another backend must implement probe, listing, reference validation/matching, creation, launch, and termination through `RemoteSessionBackend`.

Both platforms configure the PTY startup callback before connecting. After SSH authentication, `SSHPTYChannel.connectPrepared` exposes a generation-bound command executor. The coordinator probes and lists through serial control exec operations **before acquiring the terminal channel lease**, allowing startup with `MaxSessions=1`. A returned `SSHPTYStartupPlan` becomes a PTY exec startup command; a nil plan selects the ordinary shell path. Terminal size, environment and optional runtime integration are configured by the transport, rather than typing attach commands into an already-running foreground application.

`RemoteSessionCoordinator` distinguishes three outcomes:

- **Create:** creates a reference with an ownership UUID only after the backend confirms the same remote owner. Explicit one-shot commands require a new session when persistence is selected. An uncertain create retry reuses its token only for the same launch intent (host, endpoint, username, backend, command, integration and environment).
- **Attach:** accepts a currently listed descriptor but sets no ownership token, even if the remote session was originally created by Termind. Attaching does not acquire permission to kill it.
- **Plain Shell:** clears attachment and creation state. Plain policy without a recovery reference bypasses probing. Unsupported backend, probe/create failure, or missing recovery target offers an explicit choice rather than silently falling back or replacing the session.

A recovery reference is versioned backend data, not a stored command. Before reattachment the coordinator validates the backend representation and requires the saved Host ID, endpoint and username to match the attempt. tmux additionally matches session ID, creation time, server PID and, for managed references, the ownership marker. Missing references force selection even under Create Managed; unsupported reference versions fail before probing. Generation checks prevent late creation from publishing ownership over a newer attempt. Reattachment does not replay the startup command.

```mermaid
flowchart TD
    Authenticated["Authenticated SSH transport"] --> Policy{"Recovery reference or persistence selected"}
    Policy -->|no| Plain["Ordinary shell startup"]
    Policy -->|yes| Registry["Resolve backend and validate reference"]
    Registry --> Probe["Probe and list using control exec"]
    Probe --> Valid{"Saved reference matches current target"}
    Valid -->|yes| Reattach["Launch existing session without command replay"]
    Valid -->|no| Choice{"Policy or explicit selection"}
    Choice -->|create| Create["Create and confirm ownership token"]
    Choice -->|attach| Attach["Use listed session without ownership"]
    Choice -->|plain shell| Plain
    Choice -->|retry| Registry
    Choice -->|cancel| Cancel["Invalidate attempt and close locally"]
    Create --> Plan["PTY startup plan"]
    Attach --> Plan
    Reattach --> Plan
    Plan --> PTY["Acquire terminal lease and start PTY"]
    Plain --> PTY
```

*Selection and remote control precede terminal channel admission; recovery never treats a name alone as identity.*

### tmux safety and operating requirements

The current backend requires tmux 3.3 or newer. It distinguishes missing tmux, unsupported version, timeout, malformed/truncated output and ownership mismatch. Session names are encoded as data in the versioned listing response and shell arguments are quoted. Managed names are compact digests of the token, not the ownership credential. Guarded attach uses the exact session ID without `-d` or `-A`, so another client is not evicted. Termination verifies the identity/owner condition remotely and requires the `TERMIND_ENDED` response; a name prefix never authorizes termination.

### Explicit close is not disconnect

Only `TerminalTeardownIntent.explicitClose` ends managed sessions. `RemoteSessionCloseCoordinator` filters out unowned attachments, deduplicates by recovery identity (ignoring changed display metadata), and immediately attempts termination without an initial confirmation. A failure does **not** grant permission to remove the workspace: the failure prompt offers Cancel, retry End Sessions, or Disconnect Only. Retry retains partial progress and operates only on remaining sessions. Cancel retains the local workspace and recovery reference, though releasing the terminal for control may already have disconnected its interactive client.

Desktop `WindowModel` and mobile `MobileAppModel` authorize against ownership snapshots. Before killing, the feature releases its terminal channel, lists sessions, then rechecks the live channel, attachment and current owner. Remote matching must succeed. After awaiting authorization, desktop compares workspace and pane ID sets; mobile compares the affected owners' ordered workspace IDs. Added or moved work cannot be swept into an older close action. Handoff cancels pending mobile close authorization.

```mermaid
sequenceDiagram
    participant UI as Close action
    participant Owner as Window or mobile app
    participant Close as Close coordinator
    participant Session as SSH session feature
    participant Backend as Remote backend
    UI->>Owner: explicit close targets
    Owner->>Owner: capture ownership snapshot
    Owner->>Close: close managed references
    Close->>Session: terminate each unique owned reference
    Session->>Session: release terminal for control
    Session->>Backend: list and match identity
    Session->>Session: recheck owner channel and reference
    Session->>Backend: guarded terminate
    alt termination fails
        Close-->>UI: failure prompt for remaining sessions
        UI->>Close: cancel or retry or disconnect only
    end
    Close-->>Owner: allowed or denied
    Owner->>Owner: revalidate snapshot
    opt allowed and snapshot unchanged
        Owner->>Session: disconnect and remove local workspace
    end
```

*Failed termination keeps close recoverable; permission applies only to the captured ownership snapshot.*

| Event | Managed remote-session behavior |
| --- | --- |
| Explicit pane/workspace close | End owned sessions first, or use explicit Disconnect Only after failure. Unowned attachments only disconnect. |
| Desktop native window dismissal | `closeForWindow()` cancels close authorization, remembers reopen state and disconnects clients, preserving remote sessions and references. |
| Application termination | Desktop passes `.applicationTermination`; shared service cleanup does not kill managed sessions. |
| Mobile suspension or transport loss | Retain recovery reference, retire transport, and authenticate again when recovery/resume is allowed. |
| tmux detach or unverified exit | Preserve reference and show disconnected/detached state; do not auto-create a replacement. |
| Verified remote end | Clear attachment and require selection next time. Only exit code zero **and** confirmed absence close the local terminal automatically. A nonzero end remains visible. |

On a successful PTY exit with an attachment, both feature models inspect the backend before deciding whether the session ended. Inspection failure is unknown, not absence. Transport failure after prior success instead uses scheduled reconnect, which validates the reference on the next physical connection.

Sources: [coordinator and backend contract](../../Frameworks/TermindApplication/Terminal/RemoteSessionBackend.swift), [close coordinator](../../Frameworks/TermindApplication/Terminal/RemoteSessionCloseCoordinator.swift), [tmux implementation](../../Frameworks/TermindRemoteInfrastructure/SSH/RemoteTmuxService.swift), and [behavioral tests](../../FrameworkTests/SessionPersistenceTests.swift).

## Retry, retirement, and workspace behavior

Opening a saved host on desktop goes through `AppModel.open(_:as:in:)`: it installs the window's history callbacks, optimistically sets terminal host status to connecting, and asks that window to create a new SSH, Telnet or SFTP pane/workspace (or a chosen batch layout). The pane's status then drives `HostLibraryModel`'s per-connection status projection: a connected sibling wins over connecting, reconnecting or failed siblings. A connection-history event is recorded **at pane opening**, not after authentication; only saved hosts are recorded, with kind and source device ID. Closing the pane ends that event without deleting it; moving or reparenting a pane does not end its session or history. Recents derive from latest events, deduplicated by saved Host ID, and the local-only projection filters by stable device ID (events with a missing or different device ID are not local). Clearing history leaves Host records and credentials untouched. The history model trims to a global 250 entries, including on load; a failed write reports `storageError` instead of inventing a successful history event. Desktop single-host, batch and snippet openings install the same window history callbacks, so these pane kinds follow the same opening/closing rule.

For a desktop SSH pane, an explicit launch command takes precedence over the Host's startup snippet. Each attempt resolves the current snippet when no explicit command is pending. On the plain-shell path it is submitted once readiness permits; managed creation instead passes it into backend startup, and attachment or reattachment clears local pending commands without typing or replaying them. Disconnect discards both pending commands. Mobile uses the same precedence and startup-plan distinction; reopened connection intent does not replay prior one-shot commands.

A connection failure before the first successful session remains a failed journey requiring an explicit user retry. Once a session has connected, `RemoteSessionConnectionController` can schedule recovery through `SessionReconnectController`; it pauses recovery for trust or authentication interaction and resets recovery state on disconnect. Retiring a session cancels prompt queues and Security Key signing, rejects pending host-key approval, clears temporary trust, stops reconnect work, and hides the journey. Desktop explicit disconnect also invalidates the attempt, drops staged authentication and proxy submissions, cancels the connection task and disconnects its PTY. During transport opening, cancellation shuts down the route/authentication exchanges and socket and disposes of the opening state; the SSH worker's generation guard prevents stale events from reviving a closed connection.

On mobile, each native scene session has an **in-process** `MobileWorkspaceSessionModel`; `MobileAppModel` owns the collection and active history IDs. `addWorkspaces` records saved-Host history, publishes the live object and eligible in-memory descriptors, then connects. These descriptors are not written to defaults. Transient external-link workspaces have neither saved descriptors nor saved-Host history. Failure and suspension leave the history event open; an authorized close ends it and removes the live object and descriptor. Repeated selection of a live object returns that object, including after a failed first attempt; retry is explicit. Reopen constructs a fresh runtime from connection intent without replaying a one-shot snippet, initial directory or SFTP path. Normal plain-shell exit closes locally; managed exit follows the verified-end rules above.

The platform rules intentionally differ:

| Situation | Desktop macOS | Mobile iOS and iPadOS |
| --- | --- | --- |
| Window or app restoration | Native scene/frame restoration restores window presentation, not live Workspace transports. Dynamic Workspaces are window-owned and are not reconnected simply because a window is restored. | `MobileWorkspaceStore.retire` removes `mobile.workspaces.v1` and `mobile.recentlyClosed.v2` at app initialization, including malformed bytes, without migration or replacement cache. Ordinary cold launch has no restored workspaces or recently-closed records and creates no transport or history attempt. Saved Hosts and unrelated settings remain. |
| Reopen/select and scene ownership | Mounting a preserved desktop workspace does not repeat authentication; explicit retry or reopen may. Moving a workspace preserves its surfaces, transport, splits, and state. | Within the same process, selection reuses the owning scene's live object. Links to another owner activate its native scene. Scene disconnect alone preserves ownership while its native session exists. Reconciliation against `UIApplication.shared.openSessions` hands orphaned live objects, descriptors, order and unread state to an active scene without reconnecting or recording history; no persistence commit is involved. A late explicit discard still closes only the originating scene's handed-off workspaces. |
| Background/foreground | Native window close can be vetoed before any teardown; accepted closure retires only that window's workspace sessions, not app-wide Agent connections, transfers, or services. Quit checks workspaces across windows and pending external edits before shared shutdown and a bounded native termination reply. | Only when all tracked scenes are backgrounded does a background task begin: sync, metrics and outbox are paused and external-edit monitoring is disabled. Its expiration requests workspace suspension, stops forwarding, pauses transfers and cancels Assistant runs; Assistant subsequently closes Agent background commands and pooled connections after conversation drains. An active scene ends the task, resumes only workspaces that recorded foreground-resume intent, rechecks edited files, reconciles sync and restarts metrics/outbox. Returning before expiration leaves a healthy connection intact. |
| Explicit close | The owning window closes its own sessions; closing a pane removes empty workspaces without transferring ownership. | Explicit close removes that workspace's live and recent entry and never retries it; deleting a saved Host also removes its live and unopened records across scenes. |

Mobile recently-closed intent is shared across scenes **only in this process**. A native disconnect is not discard: when no active replacement exists, orphan recovery waits. A window close request keeps workspaces until native discard, and a rejected native close retains them.

Activity recovery is a separate, bounded route—not restoration of the retired defaults snapshot. `rebuildActivityWorkspace` validates version, source workspace ID, saved Host and supported connection kind, then publishes a **new workspace ID** before authentication. An in-process source-to-rebuilt map coalesces repeated deliveries across scenes. A retained Live Activity payload may supply a decoded SSH recovery reference for the same Host; the destination URL contains only limited connection intent and never the ownership reference or a command. Rebuild sets `requiresSelection`, so missing identity cannot silently apply Create Managed. Old ID-only links, deleted Hosts, unsupported versions/kinds and command-bearing links cannot guess a connection. Cold launch cannot recover an arbitrary prior workspace unless valid activity recovery intent is available.

These changed boundaries are asserted by [MobileWorkspaceStoreTests](../../TFITests/MobileWorkspaceStoreTests.swift), [MobileWorkspaceRestorationTests in MobileAppTests](../../TFITests/MobileAppTests.swift), and [MobileWorkspaceSessionTests](../../TFITests/MobileWorkspaceSessionTests.swift). In particular, the legacy-named `oldSnapshotsAreClaimedOnceWithIdentityAndOrderPreserved` now asserts deletion and **empty** scenes; its name is not evidence of migration.

### Native window close versus application Quit

Window dismissal is vetoed by `WorkspaceWindowCloseDelegate.windowShouldClose`, attached through the native registration view—not by a SwiftUI dismissal dialog that also participates in Quit. The proxy first respects the existing native delegate's veto, forwards its other delegate methods, and guards reentrant confirmation. An empty or already-closed window needs no workspace warning; a populated window requires explicit destructive confirmation, with Cancel as the Return-key default. Cancelling preserves its model and transports and allows a later close request. Only actual native closure reaches `MainWindowCoordinator`'s `willClose` handling and `WindowModel.closeForWindow()`, which idempotently retires that window's workspace connections.

Quit has application-wide scope. `AppDelegate.applicationShouldTerminate` returns `.terminateLater` and prevents duplicate admission while it checks `AppModel.hasOpenWorkspaces` across all registered, nonclosed windows. If any contains workspaces, it first asks the application-specific destructive confirmation; then it rechecks external edits and may ask a second pending-upload warning. Cancelling either check replies false and resets the pending-termination flag **before** cleanup begins.

After approval, `AppModel.shutdownForTermination()` marks the app terminating and returns the same cleanup task on repeated calls. It cancels pending Assistant preparation and stops all stored conversations, disconnects window workspaces and stops metrics, forwarding, transfers and other app services; it waits for preparation/conversation, MCP and SFTP drains before closing Agent background commands, then the Agent pool and Tailscale. Assistant admission is fenced once termination starts. The delegate saves the main-window size and replies to macOS exactly once when cleanup completes or after the three-second fallback; the deadline bounds the reply, not a guarantee that every drain finished. `applicationWillTerminate` invokes the same shutdown path. Closing the last window does not necessarily quit: the metrics menu setting or running metrics can keep the app and its app-owned Agent services alive. No live workspace transport is reconstructed by native scene restoration.

```mermaid
sequenceDiagram
    participant OS as macOS
    participant Delegate as AppDelegate
    participant App as AppModel
    participant Windows as WindowModel
    participant Services as Assistant MCP SFTP and Agent
    OS->>Delegate: request quit
    Delegate-->>OS: terminateLater
    Delegate->>App: check workspaces across registered windows
    alt user cancels workspace warning
        Delegate-->>OS: reply no and allow later request
    else workspace confirmation accepted or none needed
        Delegate->>App: recheck external edits
        alt user cancels pending upload warning
            Delegate-->>OS: reply no and allow later request
        else quit accepted
            Delegate->>App: shutdownForTermination
            App->>Windows: close workspaces and transports
            App->>Services: cancel preparation and stop runs MCP and SFTP
            Services-->>App: drains complete
            App->>Services: close background commands then pool and Tailscale
            alt cleanup finishes first
                Delegate-->>OS: reply yes once
            else three second deadline
                Delegate-->>OS: reply yes once
            end
        end
    end
```

*The native quit reply is bounded; cancelling at the pending-edits warning does not start teardown.*

Telnet is intentionally a separate terminal transport rather than an SSH fallback. `TelnetConnection` opens direct TCP with `NWConnection`, or obtains a proxied socket through `TerminalSocketConnector`; its own UUID generation rejects stale Network and socket callbacks. It performs incremental IAC negotiation, NVT line conversion, terminal type and NAWS support, and applies the configured charset only to application data. Optional username/password automation responds to recognized prompts, consumes and clears the password after use, and falls back to manual interaction when the expected flow does not materialize. It has no SSH host-key verification, jump-host route, SFTP channel, or shell integration.

```mermaid
stateDiagram-v2
    [*] --> prepared
    prepared --> opening: connect
    opening --> waitingTrust: unknown key
    opening --> waitingCredentials: local or server challenge
    waitingTrust --> opening: approve current handshake
    waitingCredentials --> opening: submit one shot credentials
    opening --> authenticated: handshake and auth succeed
    opening --> failed: first attempt fails or trust is rejected
    opening --> retired: explicit close cancels socket and attempt
    authenticated --> recovering: transport loss after first connect
    recovering --> opening: scheduled retry when allowed
    authenticated --> retired: plain shell exit or verified successful managed end
    authenticated --> detached: managed session still exists or inspection unknown
    detached --> opening: explicit reconnect with reference validation
    authenticated --> suspended: mobile background expiration
    opening --> suspended: mobile expiration during active flow
    suspended --> opening: foreground with resume intent
    waitingTrust --> retired: disconnect
    waitingCredentials --> failed: cancelled signing fails current journey
    waitingCredentials --> retired: disconnect
    failed --> opening: explicit retry
    failed --> retired: explicit close
    retired --> [*]
```

*The feature owns visible waiting, recovery, and retirement; transport resources are installed only after authentication succeeds.*

## Operational guidance and focused tests

[SessionPersistenceTests](../../FrameworkTests/SessionPersistenceTests.swift) verifies disabled defaults, no-probe plain policy, command-once creation, unowned manual attachment, lost/unsupported references, stale creation/selection rejection, verified-end exit semantics, passive teardown, close deduplication and partial-progress retry. These are behavior assertions, not evidence inferred from test names. The opt-in [RemoteSessionWireTests](../../TFMTests/RemoteSessionWireTests.swift) exercises actual multi-client attachment, resize, detach/restore, owned-only termination, abrupt SSH loss without startup replay, and shell configuration loading. [ssh-tmux-session-fixture.py](../../Scripts/ssh-tmux-session-fixture.py) uses a disposable Lima/nerdctl Debian container, loopback SSH, ephemeral keys and pinned fingerprint without editing user SSH configuration. Run with `--max-sessions 1` for admission/degradation and `--max-sessions 8` for runtime acceptance; pass its metadata via `TEST_RUNNER_TERMIND_TMUX_FIXTURE` to `xcodebuild` as shown in the script. These wire tests are opt-in, not assumed to run in ordinary unit coverage.


When changing connection code, preserve these boundaries:

- Build only `SSHConnectionPreparation` snapshots from UI/store state; do not carry plaintext through retry state or reusable snapshots.
- Keep proxy submission and SSH submission separate, and preserve the proxy `ownerHostID` so the Journey stays on the prior endpoint.
- Do not make a URI fingerprint or temporary approval durable trust, and do not bypass authorization on a known-host mismatch.
- Put callbacks from sockets, timers, detached preparation, and authentication behind the current attempt/generation check before touching feature state; clear secrets if preparation is cancelled after resolving them.
- Have the owner that opened a client retire it on every failed connect and on explicit close; do not transfer a half-open client to a workspace. Do not tie the Agent pool's life to a workspace, window, or Assistant turn.
- When changing Agent authentication, preserve the separation between temporary per-opening secrets and reusable route-fingerprinted transports; cancel the final prompt waiter, close late opens, and never replay a command after its channel started.

`WorkspaceCloseConfirmationTests` distinguishes window and Quit scopes, verifies Cancel is the default, checks workspace detection across registered windows, and exercises native veto, retry, delegate forwarding and empty-window bypass. `AppTerminationTests` checks repeated shutdown drains resources once, blocks Assistant admission after shutdown, orders background-command and pool closure after drains, and races cleanup against the fallback without duplicate replies. `RemoteSessionAuthenticationContinuationTests` checks identity stage/save/connect ordering and proxy save-before-stage behavior, including no connect on save failure. `DesktopAuthenticationSubmissionTests` runs SSH/SFTP entrypoints against failed saves, blank usernames, selected versus custom credentials, protected-key passphrase continuation and temporary-host saving.

`SSHInteractionPolicyTests` checks silent Security Key blocking on both target and jumps, rejection of trust and prompted keyboard-interactive UI, current-identity additional-connection resolution and one-use secret invalidation. `WebAuthnVaultMetadataTests` proves hardware credentials for both target and jump resolve with a secret store that throws on Keychain access, and checks Vault metadata persistence and sync. `SSHConnectionWorkerLifecycleTests` releases the worker on and off its serial connection queue to catch teardown deadlocks. `ConnectionHistoryTests` checks attempt-time ordering, 250-entry retention, SwiftData persistence and clearing, source-device identity, end-on-pane-close, saved SSH/SFTP opening and deduplicated recents; it also verifies that clearing a host's histories leaves its Host and another host's events intact. `MobileWorkspaceSessionTests` covers independent scene ownership, retirement of old snapshots, in-process live handoff without new history, late discard, and native-session-aware reconciliation. `MobileWorkspaceRestorationTests` checks empty relaunch, activity rebuild deduplication and invalid-link rejection; `MobileWorkspaceStoreTests` checks deletion of even malformed legacy data and exclusion of recovery capabilities from URLs. `MobileAppTests` also checks explicit retry, plain SSH exit and background expiration/foreground resume. `MobileCardTests` checks saved SSH/SFTP history starts on open and ends on close. The highest-value regression coverage is concentrated in `SSHConnectionPreparationTests` and `SSHHostKeyAuthorizationTests`: proxy attribution and one-shot proxy submission, missing proxy-password ownership, username-only and passphrase ordering, secret-read accounting, constraint-versus-Known-Hosts precedence, temporary versus persistent trust, and cancellation of pending trust. `ConnectionJourneyTests` validates endpoint progression, proxy attribution, pending-route behavior, retries, temporary host keys, multi-key trust, and the fact that editing a Host does not relocate Known Hosts. `MobileWorkspace`'s generation guards cover the platform-specific late-callback and foreground-resume boundary. `AgentHostAuthenticationTests` exercise proxy username retention with a missing password identity, password-plus-protected-key passphrase merging, shared exec/SFTP opens, prompt-waiter cancellation, host-key decisions, stale generation failures, post-success secret consumption, and non-replayed SFTP failures. For mobile expiration, inspect `MobileBackgroundController`'s lease behavior as well: expiration calls cancellation synchronously, retires a valid UIKit task exactly once, and treats a failed or synchronous `beginBackgroundTask` as expiration rather than leaving work assumed protected.

## Related pages

- [Platform runtime and lifetime ownership](../architecture/platform-runtime.md)
- [Agent runtime and Assistant](../concepts/agent-runtime-and-assistant.md)
- [Persistence and secrets](../concepts/persistence-and-secrets.md)
- [SSH Security Key Authentication](../concepts/ssh-security-key-authentication.md)
- [Remote services and forwarding](../concepts/remote-services-and-forwarding.md)
- [SFTP transfer and external edit workflow](sftp-transfer-and-external-edit.md)

Tailscale-managed peers use the group-bound dialer and control-service host keys. They authenticate a selected remote username through Tailscale SSH, carry no ordinary SSH credential list, and cannot be jump Hosts; failed Tailnet dialing never falls back to system networking. Peer identity is scoped to its group, and sign-in/cache/profile cleanup remain device-local. Command and SFTP browse histories are session-local memory snapshots retained on reconnect and cleared on close. Shared non-PTY exec scheduling now resides in `SSHMultiplexedExecChannelOwner`, used by `SSHConnectionWorker` and PTY-owned history reads under the same queue and channel budget.
