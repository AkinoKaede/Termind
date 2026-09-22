---
type: architecture directory guide
title: Shared Framework Directory Responsibilities
description: Functional directory responsibilities across Termind's six shared frameworks and shared resources, including flat-root concerns and how policy, persistence, transport, and presentation collaborate.
tags: [architecture, directories, frameworks, domain, persistence, presentation, ssh]
sources:
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-96ab247f0823a449c632fdd9
    resource: repo://Frameworks/Resources/LinuxDistributionIcons.json
  - id: openwiki-source-9f18104a9eafdddd0b6ca08a
    resource: repo://Frameworks/Resources/LinuxDistributionIcons/SimpleIcons.DISCLAIMER.md
  - id: openwiki-source-859ed729b25c47286f7d5a83
    resource: repo://Frameworks/Resources/PrivacyInfo.xcprivacy
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-cb178f0d078ab3218679c80e
    resource: repo://Frameworks/TermindApplication/Connections/RemoteSessionConnectionController.swift
  - id: openwiki-source-4143deeb06ebc3198de62e2b
    resource: repo://Frameworks/TermindApplication/FeatureModels/HostLibraryModel.swift
  - id: openwiki-source-ced5c103bc80a375eeb8bcef
    resource: repo://Frameworks/TermindApplication/Repositories/VaultStore.swift
  - id: openwiki-source-d593fb9c62c3736497a39486
    resource: repo://Frameworks/TermindApplication/Transfers/RemoteFileSystem.swift
  - id: openwiki-source-f402125a513db26af8c36b3e
    resource: repo://Frameworks/TermindDomain/Credentials/Identity.swift
  - id: openwiki-source-9bd2b93db78747d6956c2405
    resource: repo://Frameworks/TermindDomain/Hosts/Host.swift
  - id: openwiki-source-3626532038772ef56874c17e
    resource: repo://Frameworks/TermindDomain/Shell/CommandRiskEngine.swift
  - id: openwiki-source-342a31db9c80b2ac86cc1442
    resource: repo://Frameworks/TermindDomain/Transfers/SFTPTransfer.swift
  - id: openwiki-source-1429ec01ac68a7770ce41977
    resource: repo://Frameworks/TermindDomain/Vault/CloudSyncSafety.swift
  - id: openwiki-source-96fe5b8bf5e51592ac0ec550
    resource: repo://Frameworks/TermindDomain/Workspaces/WorkspaceTemplate.swift
  - id: openwiki-source-4b9f58eec58128055ac58b6f
    resource: repo://Frameworks/TermindInfrastructure/Agent/ContextAttachmentImporter.swift
  - id: openwiki-source-4957f13c836c497e7ebe4656
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncPersistenceSafety.swift
  - id: openwiki-source-3effdff7f6b04e2a66d8f651
    resource: repo://Frameworks/TermindInfrastructure/Cloud/MetricsSyncCoordinator.swift
  - id: openwiki-source-04ef2b2f02773f8833db9a8b
    resource: repo://Frameworks/TermindInfrastructure/Cloud/SettingsSyncCoordinator.swift
  - id: openwiki-source-eaa9d39ab551840299164d96
    resource: repo://Frameworks/TermindInfrastructure/Cloud/VaultSyncCoordinator.swift
  - id: openwiki-source-3aa42bdd0f8eaf866f06599f
    resource: repo://Frameworks/TermindInfrastructure/Commerce/ProAccessController.swift
  - id: openwiki-source-ce0d1bf07660ad90431b6a2a
    resource: repo://Frameworks/TermindInfrastructure/LinuxMetricsParser.swift
  - id: openwiki-source-b2e6667d1d47df09577b9b52
    resource: repo://Frameworks/TermindInfrastructure/Logging/LaunchFileLogService.swift
  - id: openwiki-source-f18e361c4458ef5e475b60b6
    resource: repo://Frameworks/TermindInfrastructure/Speech/AppleSpeechTranscriptionService.swift
  - id: openwiki-source-ec0a64adad50721ec500ebc2
    resource: repo://Frameworks/TermindPersistence/AISecretStore.swift
  - id: openwiki-source-1366e71322413c98e0ac1534
    resource: repo://Frameworks/TermindPersistence/CloudSyncSafetyStore.swift
  - id: openwiki-source-e14697ea11a99078be3adee9
    resource: repo://Frameworks/TermindPersistence/GRDBMemoryStore.swift
  - id: openwiki-source-fe1dc993163bb9ff61397be7
    resource: repo://Frameworks/TermindPersistence/HostPersistence.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-2c20dfd15c3c8143bab58304
    resource: repo://Frameworks/TermindPresentation/AssistantTranscriptPresentationState.swift
  - id: openwiki-source-a9bb60a9c9cb331432c4de08
    resource: repo://Frameworks/TermindPresentation/IdentityFormSections.swift
  - id: openwiki-source-9f84e62524d638f4155e0c76
    resource: repo://Frameworks/TermindPresentation/LinuxDistributionIconCatalog.swift
  - id: openwiki-source-89c20ee8e0b6b93533722c5a
    resource: repo://Frameworks/TermindPresentation/SFTP/RemoteFile%2BPresentation.swift
  - id: openwiki-source-8185a608f0b79f1af097efbd
    resource: repo://Frameworks/TermindPresentation/Terminal/TerminalAppearance.swift
  - id: openwiki-source-d2d4c06f734241db3badc1f5
    resource: repo://Frameworks/TermindRemoteInfrastructure/Agent/TermindAgentTools.swift
  - id: openwiki-source-6f8db123d550d9a8718c172c
    resource: repo://Frameworks/TermindRemoteInfrastructure/Security/KeychainSecretStore.swift
  - id: openwiki-source-9c5b1553c1819d34c34b714b
    resource: repo://Frameworks/TermindRemoteInfrastructure/Security/SecureEnclaveKey.swift
  - id: openwiki-source-e980c605b1828a2d960bfd5e
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHConnection.swift
  - id: openwiki-source-d371db64770fd2fcc301086b
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSH/SSHMaxSessionsPolicy.swift
  - id: openwiki-source-7d9f0c3ee94cd4060d5507d8
    resource: repo://Frameworks/TermindRemoteInfrastructure/SSHImport/SSHImportReader.swift
  - id: openwiki-source-1f7380cad037b68eb1bec322
    resource: repo://Frameworks/TermindRemoteInfrastructure/Telnet/TelnetConnection.swift
  - id: openwiki-source-b9bae3a52f35a3a412f81e10
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPConcurrencyScheduler.swift
  - id: openwiki-source-79d8ded739aa8dd4fa3f5cdf
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPEditService.swift
  - id: openwiki-source-b347308e8c5cc6c0b0d29b7d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift
  - id: openwiki-source-c4b6e224fdbea6dcd393344d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferCoordinator.swift
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
generated: { by: "omp", at: "2026-09-22T05:22:55.650Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-22T05:22:55.650Z
---

# Shared Framework Directory Responsibilities

The six module roots live under `Frameworks`. Paths in each table are **relative to the named framework root**. All current functional child directories are covered; these modules mostly stop at that level. Persistence is flat, while Presentation and Application also contain substantial root-level functionality. The “root files” rows are real responsibilities, not proposed folders.

See the [Module Map](module-map.md) for build dependencies and [Native App Directories](native-app-directories.md) for the app-owned halves of these features.

## TermindDomain — values and rules

Domain describes what the system means, not how a database, socket, or native view implements it. Its directory names denote portable concepts.

| Directory | Responsibility |
| --- | --- |
| Root files | Shared saved-name normalization/defaulting and tag-color values. |
| `AI` | Model/provider form values, API-type selection, and model-editing rules. |
| `Agent` | External tool-call audit values; the generic agent loop remains in AgentKit. |
| `Commerce` | Pro feature and entitlement/access value types. |
| `Connections` | Connection history, forwarding rules, charsets, SSH preferences/host-key identity, and temporary serial configuration. |
| `Credentials` | Identity/key references, SSH key algorithm display values, and user-certificate parsing/validation. Not secret storage. |
| `Events` | Durable outbox-job values. |
| `Hosts` | Host/group metadata, protocol capabilities, deletion descriptions, detected distributions, shell-integration preference, and Known Hosts matching. |
| `Metrics` | Server, process, filesystem, and synchronization value types plus typed read failures. |
| `SSHImport` | Parse SSH configuration/import text into previewable records; parsing does not execute the configuration. |
| `Sessions` | Session context, remote-system/shell events, terminal preferences/custom configuration, local font preferences, Find values, and palette. |
| `Settings` | Settings-sync records and synchronization policy values. |
| `Shell` | Command history, shell syntax/quoting, remote command construction, and command-risk classification/rules. |
| `Snippets` | Snippet/package values and editing rules. |
| `Transfers` | Remote file/path values, permission drafts, SFTP preferences/history, and transfer state records. |
| `Vault` | Vault snapshots, record keys, mutations, synchronization values, replica-scope identities and compatibility status/reason values. |
| `Workspaces` | Saved workspace-template structure, including pane/split configuration rather than running sessions. |

**Boundary:** a secret reference is not the secret, a transfer record is not its worker, and a workspace template is not an authenticated runtime. Domain imports are constrained by architecture tests so these values do not acquire UI, storage, or transport implementation dependencies.

## TermindApplication — ports, coordination, and feature state

Application depends on Domain and AgentKit abstractions. It exposes the capabilities that concrete adapters implement and the state/operations both apps can reuse.

| Directory | Responsibility |
| --- | --- |
| Root files | Host/Vault/AI/skill/memory/preferences persistence ports; secret-store interfaces and in-memory helpers; SSH/Telnet requests, route/proxy/secret types; reconnect policy; language/settings keys and draft merging. |
| `Agent` | Conversation/composer/library state, Assistant execution assembly, title/command generation, attachments, slash commands, tool approval/presentation policy, and memory-indexed repository wrapping. It coordinates AgentKit rather than replacing its loop. |
| `Connections` | Route preparation and snapshots, external connection URLs, connection journeys, trust/MFA prompts, shared retry state, session host-store boundary, and plans for applying remote Vault changes. |
| `Events` | Outbox store contract, retry runner, and host-deletion handlers. |
| `FeatureModels` | Observable libraries/editing policy for hosts, credentials, Known Hosts, snippets, forwarding, histories, AI, skills, memory, SSH import, settings, expansion state, and review prompting. |
| `Logging` | Application log-management contract and disabled logging support. |
| `Metrics` | Sampling clock, snapshots/read interface, and shared server-monitoring model. |
| `Repositories` | History repository contracts, SSH-import batch/reader boundary, and Vault load/save/transaction coordination. |
| `Speech` | Speech-transcription service/events and coordination contract. Native microphone capture remains injected. |
| `Terminal` | Shared terminal Find controller; the native terminal view is not here. |
| `Transfers` | Remote-filesystem port and basic file operations, remote-edit model, and workspace upload-notice state. Bulk scheduling belongs to Remote Infrastructure. |

`HostLibraryModel` is broader than its name: it projects hosts, groups, identities, keys, snippets, forwarding rules, transfers, Known Hosts, and templates. Specialized feature models provide narrower operations over that shared data. Live connection status is kept separate from the saved Host values.

## TermindPersistence — one stored-model owner

This module currently has **no functional subdirectories**. Its root spans several concerns; the rows below are responsibility groups, not physical folders.

| Root-level responsibility group | What it owns |
| --- | --- |
| Schema and migration | Current SwiftData schema, frozen historical representations, migration plan, and the sole shared container factory. |
| Vault and histories | Persistent Host/credential metadata and related Vault records; command, connection, and SFTP history repositories. |
| AI, Agent, skills, and audit | Provider/configuration records, agent-run/message replay, tool-audit storage, skill packages, and persistence redaction. |
| Preferences and sync journals | SSH/SFTP/terminal settings, metrics/settings/Vault local stores, mutation journals, scoped upload restrictions, recovery checkpoints, and sync-facing persistence adapters. |
| Secret metadata/adapters | AI secret references and storage policy bridged to the injected Keychain service; not a plaintext secret database. |
| Memory | Actor-owned GRDB/SQLite memory state, conversation snapshots, session/message indexing, and full-text search. This is distinct from SwiftData's model container. |

The container factory selects the complete versioned schema and migration plan; platform roots choose its location and lifetime. It disables automatic SwiftData CloudKit storage because the explicit CloudKit coordinators use their own records and journals. No app feature or general infrastructure module may introduce a competing `@Model` owner.

Details: [Persistent Data, Migrations, and Secrets](../concepts/persistence-and-secrets.md).

## TermindInfrastructure — general concrete services

| Directory | Responsibility |
| --- | --- |
| Root files | In-memory host repository; Linux filesystem/process/server and NVIDIA metrics parsing; provider service-account file handling; skill-package import. Parsers do not own an SSH session. |
| `Agent` | Read/import context attachments and provide the live attachment-loading adapter. Host-executing tools belong to Remote Infrastructure instead. |
| `Cloud` | Shared CloudKit lifecycle, record coding and upload-safety gates; separate Vault, Settings, and Metrics coordinators using Persistence stores/journals. |
| `Commerce` | StoreKit products, entitlement refresh, purchase/restore flows, transaction observation, and Pro access state. |
| `Logging` | Launch-scoped file logging and log-file lifecycle. |
| `Speech` | Apple speech-recognition implementation plus an audio-input abstraction; each app supplies its native audio capture. |

This layer can use Persistence. It does not depend on either native app, and a CloudKit coordinator is not a screen-level settings model. The shared safety adapter projects scoped persistent restrictions and recovery state into the lifecycle; it does not merge the categories' engines, accounts, subscriptions or journals. V31 adds the safety storage locally, without changing the existing CloudKit record formats. Both received records and save-conflict replies use the same validation path before allowing a blocked record to become uploadable again.

## TermindRemoteInfrastructure — protocol and remote-operation machinery

| Directory | Responsibility |
| --- | --- |
| `Agent` | Host resolution and connection/authentication pools, background commands, SSH/SFTP/metrics/scratch-transfer tools, and registration/presenters alongside AgentKit built-ins. |
| `Logging` | Remote-service logging helpers and sanitization-facing formatting. |
| `SSH` | Socket/proxy/jump routing, handshake/authentication, libssh2 ownership and I/O scheduling, exec/PTY/SFTP channels, charset conversion, session-channel limits, metrics sampling, and forwarding pools/controllers. |
| `SSHImport` | Concrete SSH config/key-file reading, staging, and validated import access. Parsing rules live in Domain; import use cases live in Application. |
| `Security` | Keychain secret storage, Secure Enclave operations, and software key-file import. These mechanisms implement the higher-level secret/authentication boundaries. |
| `Telnet` | Telnet transport and negotiation, separate from SSH/SFTP capabilities. |
| `Transfers` | SFTP data-operation admission, per-session transfer contexts, upload/download/copy planning, streaming, conflict handling, resume state, rename operations, and external-edit local files/observation/upload lifecycle. |

`SSH` has multiple responsibilities because it is the protocol boundary, not just a terminal client. `Transfers` builds file-operation lifecycles on top of that boundary. **A logical file permit, an SSH session-channel lease, and a physical connection are different resources.**

The following diagram shows **collaboration**, not target dependencies. A solid arrow means “requests or uses”; a dashed arrow means an injected callback/result relationship. It summarizes representative paths without claiming all features share one live transport.

```mermaid
flowchart TB
    Native["Native session / browser / Assistant owner"] --> Policy["Application / connection and feature policy"]
    Native --> Transfer["Remote / Transfers"]
    Assistant["Application / Agent execution"] --> Runtime["AgentKit runtime and registry"]
    Runtime --> Tools["Remote / Agent host tools"]
    Tools --> Transfer
    Tools --> SSH["Remote / SSH channels and connections"]
    Transfer --> SSH
    Policy -.->|prepared request and feature-owned decisions| SSH
    SSH --> Security["Remote / Security"]
    SSH --> Host["Remote host"]
    SSH -.->|progress and challenges| Native
    Metrics["Remote / SSH metrics sampler"] --> SSH
    Metrics --> Parsers["Infrastructure / metrics parsers"]
    Parsers -.->|domain snapshots| Monitor["Application / Metrics"]
```

Keep trust/authentication interaction with the initiating feature. Additional silent connections and queued operations have different permissions and retirement rules from a user's interactive terminal. See [SSH Lifecycle](../workflows/ssh-session-lifecycle.md), [SSH Multiplexing and Scheduling](../concepts/ssh-multiplexing-and-scheduling.md), [SFTP Workflow](../workflows/sftp-transfer-and-external-edit.md), and [Assistant Runtime](../concepts/agent-runtime-and-assistant.md).

## TermindPresentation — shared content without native ownership

| Directory | Responsibility |
| --- | --- |
| Root files | SwiftUI forms and presentation values for hosts, identities, secrets, trust, connection journeys, forwarding, snippets, providers/models, skills, memory and sync; metrics panels/formatting; Assistant transcript/tool details and disclosure state; Markdown parsing and small input/drop/speech helpers. |
| `SFTP` | Remote-file type/icon/size presentation, transfer status formatting, SFTP settings fields, and edit-upload overlays. |
| `Terminal` | Terminal appearance/theme mapping and font-selection/settings content. Actual font discovery and native terminal mounting remain app-owned. |

Reusable content is not a shared screen controller. In particular, transcript presentation state does not own the Agent runtime, terminal appearance does not own a PTY, and an identity form does not access Keychain directly. Architecture tests prohibit native AppKit/UIKit, persistence, and remote-infrastructure dependencies here.

Details: [UI Design Principles](../concepts/ui-design-principles.md).

## Frameworks/Resources — bundle data, not code ownership

| Directory or root-level group | Responsibility |
| --- | --- |
| Root catalogs and metadata | App text and bundle-metadata localization; privacy manifest; model catalog snapshot/overrides and associated license; Linux-distribution icon mapping. |
| `Assets.xcassets/AccentColor.colorset` | Shared accent-color asset. |
| `Assets.xcassets/LinuxDistributions` | Distribution-specific `LinuxDistro-*.imageset` assets used by host/system presentation. |
| `LinuxDistributionIcons` | Upstream icon license and disclaimer material, separate from the actual image sets. |

Shared resources are compiled into product bundles; platform-specific icons stay in the apps. Resource consumers such as distribution icons and model catalogs should not create a new dependency on an app target. App localization and AgentKit localization have separate ownership.

## Cross-layer flow: edit, persist, synchronize, render

**Solid arrows describe the main action/data flow; the dashed arrow is the separately injected secret-storage path.** This is not an automatic SwiftData-to-CloudKit relationship.

```mermaid
flowchart TB
    Editor["Native editor + shared form content"] --> Model["Application / feature model"]
    Model --> Port["Application / persistence port"]
    Port --> Store["Persistence / local store and journal"]
    Store --> Sync["Infrastructure / Cloud coordinator"]
    Sync --> Cloud["CloudKit records"]
    Cloud --> Sync
    Sync --> Projection["Updated application projection"]
    Projection --> Editor
    Model -.->|secret reference operations| Secrets["Remote / Security Keychain implementation"]
```

The editor owns interaction, the model owns the operation, Persistence owns stored representation, and the coordinator owns synchronization lifecycle. Secret bytes follow their separate storage policy; they do not become ordinary Vault/Settings record payloads.

## Verification seams

- `ArchitectureBoundaryTests`: import direction, feature construction boundaries, and single SwiftData-model ownership.
- `FrameworkTests`: portable model/policy, persistence compatibility, sync, presentation, and shared-service behavior.
- Remote/session/transfer suites: transport, authentication, admission, cancellation, and recovery semantics.
- Native test targets: screen routing, runtime lifetimes, and platform integration; those contracts are not proven by shared value tests alone.

Return to the [Module Map](module-map.md) for ownership choices or the [Engineering Quickstart](../quickstart.md) for task-specific validation.
