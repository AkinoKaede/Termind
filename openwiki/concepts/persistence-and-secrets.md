---
type: persistence and security concept
title: Persistent Data, Migrations, and Secrets
description: How Termind owns SwiftData and GRDB durable data, evolves compatible schemas, projects records through repositories, and keeps credentials in Keychain-backed and runtime-only boundaries.
tags: [persistence, swiftdata, grdb, migrations, keychain, secrets, security]
sources:
  - id: openwiki-source-685b7f8e7dbcf91b4e2a50e2
    resource: repo://Frameworks/TermindApplication/Agent/AssistantConversationOperations.swift
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-1c48f72c0c7a3164d7d5c715
    resource: repo://Frameworks/TermindApplication/Agent/ConversationModel.swift
  - id: openwiki-source-2d98a2885dc21f508f49b749
    resource: repo://Frameworks/TermindApplication/Agent/MemoryIndexedAgentRepository.swift
  - id: openwiki-source-dc7b363138921b0923d2dc2f
    resource: repo://Frameworks/TermindApplication/FeatureModels/ConnectionHistoryModel.swift
  - id: openwiki-source-4143deeb06ebc3198de62e2b
    resource: repo://Frameworks/TermindApplication/FeatureModels/HostLibraryModel.swift
  - id: openwiki-source-7397a04f40a393c81b0ca52d
    resource: repo://Frameworks/TermindApplication/FeatureModels/MemoryModel.swift
  - id: openwiki-source-cd830b9886c3f5d3d7181662
    resource: repo://Frameworks/TermindApplication/FeatureModels/NotificationSettingsModel.swift
  - id: openwiki-source-7ca30f0e781e8c2df826b47a
    resource: repo://Frameworks/TermindApplication/HistoryLimits.swift
  - id: openwiki-source-d5d0b5c98f2f54ae5e0beba1
    resource: repo://Frameworks/TermindApplication/MemoryDateAnnotations.swift
  - id: openwiki-source-4ddcdd630c9bc1c622a037df
    resource: repo://Frameworks/TermindApplication/SecretStoring.swift
  - id: openwiki-source-4f78037bc69b6dfc293aca3d
    resource: repo://Frameworks/TermindApplication/SSHConnectionTypes.swift
  - id: openwiki-source-cd3e43e60522274ce1f1908b
    resource: repo://Frameworks/TermindApplication/SSHSecret.swift
  - id: openwiki-source-1ca741e9f21312b87c75fa28
    resource: repo://Frameworks/TermindDomain/Settings/NotificationPreferences.swift
  - id: openwiki-source-36d16adefef02f0ed0cdc428
    resource: repo://Frameworks/TermindDomain/Settings/SettingsSyncTypes.swift
  - id: openwiki-source-1429ec01ac68a7770ce41977
    resource: repo://Frameworks/TermindDomain/Vault/CloudSyncSafety.swift
  - id: openwiki-source-e08ad235d9d92a20cf09290b
    resource: repo://Frameworks/TermindDomain/Vault/SyncRecordFormats.swift
  - id: openwiki-source-1d1f503a260f304a969fcee4
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncLifecycle.swift
  - id: openwiki-source-8a511ce5c3a76863609a6e6e
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncLifecycleSafety.swift
  - id: openwiki-source-8a2e7d4db4b334995f8eaf61
    resource: repo://Frameworks/TermindPersistence/AgentPersistence.swift
  - id: openwiki-source-ec0a64adad50721ec500ebc2
    resource: repo://Frameworks/TermindPersistence/AISecretStore.swift
  - id: openwiki-source-33d69cea4b24d60ab000a0cc
    resource: repo://Frameworks/TermindPersistence/AssistantChatCollaborationPersistence.swift
  - id: openwiki-source-969607b796e062c1bad0a301
    resource: repo://Frameworks/TermindPersistence/CloudSyncRecordStateStore.swift
  - id: openwiki-source-1366e71322413c98e0ac1534
    resource: repo://Frameworks/TermindPersistence/CloudSyncSafetyStore.swift
  - id: openwiki-source-e14697ea11a99078be3adee9
    resource: repo://Frameworks/TermindPersistence/GRDBMemoryStore.swift
  - id: openwiki-source-b6bc660c90f2801c69ff0df3
    resource: repo://Frameworks/TermindPersistence/HistorySyncPersistence.swift
  - id: openwiki-source-6bdc502f2e27478a98f042fa
    resource: repo://Frameworks/TermindPersistence/HistorySyncStore.swift
  - id: openwiki-source-fe1dc993163bb9ff61397be7
    resource: repo://Frameworks/TermindPersistence/HostPersistence.swift
  - id: openwiki-source-0e8ecbf3896cbf237a679d6a
    resource: repo://Frameworks/TermindPersistence/PersistentNotificationPreferences.swift
  - id: openwiki-source-303e34b5782a7a14e28cc9f8
    resource: repo://Frameworks/TermindPersistence/PersistentStoreLock.swift
  - id: openwiki-source-bcf5761569fe8b5098014524
    resource: repo://Frameworks/TermindPersistence/SettingsSyncStore.swift
  - id: openwiki-source-28d6772acb1a409d29ff1973
    resource: repo://Frameworks/TermindPersistence/SwiftDataAgentRunRepository.swift
  - id: openwiki-source-9eb2234b02897ade8e405374
    resource: repo://Frameworks/TermindPersistence/SwiftDataAISecretStore.swift
  - id: openwiki-source-99652f47d49074a45ef09dd7
    resource: repo://Frameworks/TermindPersistence/SwiftDataAssistantModelSelectionStore.swift
  - id: openwiki-source-4217f56e034013cb8704d525
    resource: repo://Frameworks/TermindPersistence/SwiftDataConnectionHistoryRepository.swift
  - id: openwiki-source-0b6ab59ec6a684de8101ff8e
    resource: repo://Frameworks/TermindPersistence/SwiftDataDeviceDirectoryRepository.swift
  - id: openwiki-source-63e25c47c9c7d38b354f4123
    resource: repo://Frameworks/TermindPersistence/SwiftDataHostRepository.swift
  - id: openwiki-source-bc351b6c699ff4bbf9f8c2b1
    resource: repo://Frameworks/TermindPersistence/SwiftDataVaultJournal.swift
  - id: openwiki-source-a0d614d618b11f103ec246ae
    resource: repo://Frameworks/TermindPersistence/SwiftDataVaultStore.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-8fda0c115d3df709fffe110c
    resource: repo://Frameworks/TermindPersistence/TermindSchemaV29HostModels.swift
  - id: openwiki-source-15e5026028d13d2202844f68
    resource: repo://Frameworks/TermindPersistence/TermindSchemaV33IdentityModels.swift
  - id: openwiki-source-33f99816db979bf169f1eab5
    resource: repo://Frameworks/TermindPersistence/TermindSchemaV45KeyModels.swift
  - id: openwiki-source-353d364de99f80858a5abfd5
    resource: repo://Frameworks/TermindPersistence/TermindSchemaV50SnippetModels.swift
  - id: openwiki-source-3cfc52217a7a6835b4bffac1
    resource: repo://Frameworks/TermindPersistence/VaultSyncPersistence.swift
  - id: openwiki-source-ba9bcaaf5c4be2ca83356c1a
    resource: repo://Frameworks/TermindPersistence/VaultWireV1Validation.swift
  - id: openwiki-source-65af64561fcb561a30da16fa
    resource: repo://Frameworks/TermindPersistence/VaultWireV2.swift
  - id: openwiki-source-6f8db123d550d9a8718c172c
    resource: repo://Frameworks/TermindRemoteInfrastructure/Security/KeychainSecretStore.swift
  - id: openwiki-source-017f5e2abe9b13df755a5322
    resource: repo://FrameworkTests/AgentReplayPersistenceTests.swift
  - id: openwiki-source-e2abe97c93dbb91be81b63e2
    resource: repo://FrameworkTests/AssistantChatCollaborationPersistenceTests.swift
  - id: openwiki-source-bf7a64e7c819eb9279e2f9e4
    resource: repo://FrameworkTests/CloudSyncLifecycleTests.swift
  - id: openwiki-source-40cfadc2320da9a292c64d26
    resource: repo://FrameworkTests/CloudSyncSafetyPersistenceTests.swift
  - id: openwiki-source-eb9518e5c7eb3782fa0cccc0
    resource: repo://FrameworkTests/CloudSyncSafetyTests.swift
  - id: openwiki-source-256e2b134a8446ea63b15585
    resource: repo://FrameworkTests/HermesMemoryTests.swift
  - id: openwiki-source-e722f35e92f0823055985cb7
    resource: repo://FrameworkTests/NotificationPreferencesTests.swift
  - id: openwiki-source-8428b9f5de49b8a561d93fa5
    resource: repo://FrameworkTests/PersistenceCompatibilityTests.swift
  - id: openwiki-source-ad1a1eea0aea739f2004d93a
    resource: repo://FrameworkTests/PersistentStoreLockTests.swift
  - id: openwiki-source-3b1e8e4540cb99cbbd7863f5
    resource: repo://FrameworkTests/SnippetColorTests.swift
  - id: openwiki-source-eaed8c88a9a3f24e3feb1f9c
    resource: repo://FrameworkTests/WebAuthnVaultMetadataTests.swift
  - id: openwiki-source-294dd6a8637abdafe40e9570
    resource: repo://Scripts/generate-v28-fixture.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-5b8c72c5373a41af34fa9fd4
    resource: repo://TFI/App/MobileStartupView.swift
  - id: openwiki-source-6c9f797fc6a1e7ce639b72b8
    resource: repo://TFI/App/TermindIOSApp.swift
  - id: openwiki-source-3f37062f55fb57a9f2e97f35
    resource: repo://TFI/Features/Vault/MobileVaultView.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
  - id: openwiki-source-d5cca6ff91d9aaa5da323b40
    resource: repo://TFM/App/DatabaseStartupGuard.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-0854be84b166268626a3cb08
    resource: repo://TFM/Features/Sidebar/WindowSidebarView.swift
  - id: openwiki-source-715de8d16be5a3d06ae915ad
    resource: repo://TFMTests/AgentPersistenceTests.swift
  - id: openwiki-source-1d1efb20e239b1f2142f6cb7
    resource: repo://TFMTests/SettingsSyncTests.swift
generated: { by: "pi", at: "2026-10-04T14:45:13.763Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-04T14:45:13.763Z
---

# Persistent Data, Migrations, and Secrets

Termind separates durable *metadata* from secret material and live connection state. `TermindPersistence` is the sole owner of SwiftData models, schema history, migrations, and container construction; application and platform layers select the store location and inject contexts into repositories. Credentials are represented durably by non-secret references and storage provenance, resolved only through `SecretStoring`, and converted to wipeable runtime objects only for a physical SSH connection attempt.

This is a safety boundary, not merely a storage abstraction: plaintext credentials must never enter logs, sync payloads, `UserDefaults`, or ordinary persistence. Runtime authentication state is also excluded from domain records and restoration. See [System Boundaries and Dependency Ownership](../architecture/system-boundaries.md) for the framework ownership rules and [Assistant, Agent Runtime, Skills, and Memory](agent-runtime-and-assistant.md) for assistant-specific durable data.

```mermaid
flowchart TD
    Desktop["macOS composition root"] --> Lock["File store lease before open"]
    Lock --> Container["Process-wide SwiftData ModelContainer"]
    Mobile["iOS composition root"] --> Container
    Container --> SwiftData["Termind SwiftData store"]
    SwiftData --> Metadata["Hosts identities keys settings agent runs"]
    SwiftData --> References["Credential references and secret location metadata"]
    References --> Keychain["Keychain device or iCloud secret material"]
    Desktop --> GRDB["GRDB HermesMemory SQLite directory"]
    Mobile --> GRDB
    GRDB --> Memory["Memory entries reference dates and searchable history"]
    Keychain --> Resolver["SecretStoring resolution"]
    Resolver --> Runtime["SSHSecret one-shot runtime allocation"]
    Runtime --> Session["Live SSH session"]
```

This diagram distinguishes durable SwiftData and GRDB records from Keychain material and session-only secret allocations.

## Store ownership and startup

`TermindPersistence.makeContainer(inMemory:url:)` is the shared SwiftData entry point. It exposes the complete `TermindSchemaV51` schema, attaches `TermindMigrationPlan`, disables automatic SwiftData CloudKit integration, and rejects an in-memory store combined with a file URL. Both apps retain one container for their process and do not assemble feature-specific schemas. Desktop services commonly share `container.mainContext`; mobile creates dedicated `ModelContext(container)` instances for several repositories while sharing a vault context among host, connection-history and device-directory services.

**macOS file-store exclusivity:** Before `ModelContainer` can open or migrate a file-backed store, the factory creates the parent directory, canonicalizes the URL (symlinks and standardized file URL), and obtains an exclusive nonblocking `flock` on a stable adjacent `.lock` file. A different process holding the lease causes `PersistentStoreAccessError.inUse` before database or WAL access; other POSIX failures propagate. Never unlink the lock file: a process may already have the inode open. The factory weakly indexes active leases by canonical URL so multiple containers for the *same store in one process* share the lease; each container retains it until deallocation, when closing the descriptor releases the kernel lock (including after forced exit). Different stores and in-memory containers do not contend. This mechanism is macOS-only, not a cross-platform mobile file lock. [PersistentStoreLockTests](../../FrameworkTests/PersistentStoreLockTests.swift) cover blocked opens before migration, symlink aliases and last-container release, a separate process killed while holding the lock followed by intact Vault/journal reopening, and noncontending stores.

The desktop root opens the container during `TermindApp.init()`: normal launches use the factory's default file-backed configuration (no explicit URL), while DEBUG XCTest and screenshot demos select an in-memory container. Before normal open, `DatabaseStartupGuard` checks for another running instance of the same bundle identifier, including older versions that do **not** use the new lock; a busy store presents an alert and exits, while other open/setup errors are fatal rather than replaced with an empty database. It supplies `KeychainSecretStore` for live composition and passes the same container to the main and authentication-window scenes. A screenshot demo instead constructs demo models and returns before live repository wiring; XCTest uses an in-memory container but disables cloud coordinators (it still constructs a Keychain secret store). The mobile root creates its Application Support parent before opening `Termind.store`, or chooses an in-memory container and `InMemorySecretStore` when `inMemory` is set or hosts are injected. A supplied container overrides factory construction; otherwise mobile initialization throws on open failure rather than replacing the store. `TermindIOSApp` retains the startup result and `MobileStartupView` injects the container on success or shows an unavailable-data-store view on failure. Data availability is an explicit startup condition.

### Repository projections and atomic mutation

SwiftData rows are persistence representations, not the feature API. `SwiftDataHostRepository` projects `PersistentHost` and `PersistentHostGroup` into `HostLibrarySnapshot` values and publishes revisioned `AsyncStream` changes. Host upserts update or insert the row, then use one commit path that advances a database revision, records Vault mutation information, saves, and only then publishes the mutation. On failure it rolls the `ModelContext` back.

Deletion is a durable saga, not an immediate blind removal: `requestHostDeletion` atomically writes a pending-deletion marker, outbox jobs, and the revision. The snapshot hides marked hosts. Later steps remove dependent jump/snippet/history/forwarding references and finally remove host-owned identities, the host, and the marker. This lets a crash expose either the live host or a complete, resumable deletion intent rather than a partial state.

The platform projections differ around durable deletion. Desktop commits deletion before projecting removal and clearing connection history; mobile closes workspace/runtime dependencies before requesting deletion, with its outbox also clearing connection history. Command and SFTP browse history are memory-only per-session data, cleared by close rather than durable per-Host cleanup. Direct deletion of Tailscale-managed Hosts is rejected. Failure after runtime cleanup does not roll back those earlier effects.

Agent conversations use a separate SwiftData repository with similarly deliberate projections. `SwiftDataAgentRunRepository` stores run snapshots, messages, context/replay backing, tool invocations/results, reviews, compactions, and ordering. It deduplicates replayed earlier turns by message ID, sanitizes persisted text and tool-call JSON, and marks nonterminal runs interrupted when the repository is initialized. Loading orders transcript rows by run and sequence, then restores recorded tool results that were committed before the next transcript snapshot. V42 adds *sidecars*, rather than modifying historical message rows: a message origin records the source conversation/run/tool call and optional redacted title; a conversation-origin row records chat creation provenance; and a delivery receipt reserves the source run/tool-call pair. `SwiftDataAssistantChatCollaborationStore` reads and writes receipts and creation relations using fresh contexts from the shared container. When a new originated message is saved, its origin insertion marks matching queued receipts delivered in the **same snapshot save**; stale receipt saves or callbacks cannot downgrade a delivered receipt. Origin rows are removed along with message backing during edit/delete; the origin on a user message also prevents editing it as an ordinary user turn.

### Assistant history edits: one message boundary, one transaction

Restore and truncation share a canonical ordering: runs by `startedAt` then UUID; messages by that run order, then `sequence`, `createdAt`, role rank and UUID. Timestamps alone do not identify the cutoff. `truncateConversation` checks cancellation and validates an ordinary user replacement with a fresh ID that collides with neither a stored message nor a run before mutation. It removes the selected user message and the ordered suffix, including whole later runs. When the target run still has a prefix, that run and its retained messages survive: the summary becomes neutral `.completed`, clears its previous failure and ends at the last retained non-tool message. Editing its opening removes the target run only when no prefix remains.

Graph cleanup follows the same boundary. Removed messages lose their replay and context-attachment backing. Within a partially retained run, invocation source-message ownership takes priority, followed by call identity in retained/removed transcript rows; only unrecoverable ownership uses the conservative `createdAt >= target.createdAt` fallback. This covers both legacy rows and modern provider-native events persisted before their source-message snapshot. Results and reviews follow the deleted invocation IDs. Compactions are deleted only if their explicit boundary is among the removed message IDs, so retained-prefix records and nil-boundary fork bases survive. The generated title is cleared only when the opening user turn is removed. On load, raw run-local assistant calls supply missing legacy source IDs, and reconstructed deterministic tool-result messages receive run ownership before compaction projection; this lets the live model preserve the same graph through compacted history.

The replacement is inserted with its replay/attachment backing into a standalone, failure-free `.completed` staging run whose ID equals the replacement message ID. Staging must sort after the latest retained run, including an empty run: when the replacement timestamp ties or precedes that run's start, its run start becomes the retained start plus one millisecond. The message's own timestamp is not rewritten.

The first real snapshot whose final ordinary user turn is this staged replacement adopts it in the same `save` transaction. The staging predicate requires the same conversation, the same-ID user row, a completed run without failure, exactly one message and no invocation/result/review graph. Adoption changes only the staged row's run ID and snapshot sequence, retains its backing, deletes the staging run and retires the staging ID. Other historical rows included in replay remain attached to their original runs. The real run inherits at least the staging start time; later saves preserve that lower bound and clamp `finishedAt` when necessary. Failed and interrupted first snapshots use this same path, not a separate copy of the replacement.

The repository's in-memory retired-ID set includes the edited target run even when its prefix survives, all removed later runs, and adopted staging runs. `save` and durable-event `record` ignore retired IDs, preventing late work from rebuilding the discarded suffix. This is a repository-instance guard, not a new persisted tombstone or schema migration. Both truncation and snapshot save restore the previous retired-ID set and roll back their `ModelContext` changes if the transaction fails.

`AssistantConversationOperations` applies the live history edit only after the repository commits; invalid replacements and rejected writes leave history unchanged. Captured missing-model/credential failure now schedules a separate asynchronous save and **only then** calls `recordFailedRun` to adopt and publish the failed run; preparation remains active in its saving-failure phase until this finishes. Preparation cancellation that records interruption also saves its terminal snapshot before adopting and publishing the interrupted state. A save error appends a visible error rather than projecting a successful failed/interrupted adoption. This commit-before-projection rule does not make every stop a durability barrier: `ConversationModel`'s queued-before-start cancellation projects `.cancelled` when it launches a best-effort `prestartPersistence` task, and `stopAndWait` joins the consumer but the save error is swallowed. See [Assistant Runtime](agent-runtime-and-assistant.md) for runtime handoff. Shared replay tests reopen failed/interrupted adoption through a fresh context and cover queued cancellation and captured configuration failure; desktop and mobile fixtures compare same-run prefix history and provenance after edits. These fixtures do not inject a real disk-full or read-only SwiftData failure.

## Schema evolution: preserve the past exactly

Historical SwiftData model shapes are deliberately frozen. A `VersionedSchema` hashes the types it names, so retroactively editing a type used by an already shipped schema can make an installed store unopenable rather than migrated. The migration plan retains endpoints V1–V28, V30, V31, and V34–V51. Its recent path is V27→V28→V30→V31→V34→V35→V36→V37→V38→V39→V40→V41→V42→V43→V44→V45→V46→V47→V48→V49→V50→V51: all of these stages are lightweight except the V31→V34 custom history backfill. V29, V32, and V33 remain absent as migration endpoints. V35 adds native History journals and capability checkpoints; V36 removes the retired importer table; V37 adds scoped cloud record-presence and deletion-acknowledgement sidecars; V38 adds deletion-handoff causality and durable asset-cache cleanup work. V39 adds per-conversation assistant model selection (provider and model IDs, not credentials). V40 removes the retired per-category Vault, AI-configuration and Metrics quarantine tables while retaining scoped quarantine. V41 adds shared notification preferences; V42 adds assistant message/conversation provenance and durable collaboration delivery receipts; V43 adds public MCP OAuth configuration, V44 replaces the Host model, and V45 replaces the SSH key model to persist Security Key reference metadata, and V46 adds terminal keyword-highlight preferences, without changing historical model shapes. These are **local SwiftData schema versions**, not revisions to independently versioned CloudKit wire envelopes; the current local schema is V51. When a persisted shape changes, introduce a version-specific model and replace it only in the new schema; do not “clean up” an old model definition.

V28 is required for existing installed stores. Removing its endpoint made staged migration reject those stores with CoreData error `134504` (unknown model version). `TermindSchemaV28HostModels` restores the historical fields, defaults and model identity from the parent of `b0d35d24`; V30 retains its existing model types and order. Recovery uses the normal container factory and preserves the original database on an opening failure, rather than clearing or rebuilding it.

```mermaid
flowchart TD
    Fixture["Historical V28 fixture store"] --> Factory["makeContainer with V51 and migration plan"]
    Factory --> V28["Recognize frozen V28 endpoint"]
    V28 --> V30["Lightweight V28 to V30"]
    V30 --> V31["Lightweight V30 to V31"]
    V31 --> V34["Custom V31 to V34 device backfill"]
    V34 --> V35["Lightweight V34 to V35 journals and checkpoints"]
    V35 --> V36["Lightweight V35 to V36 retire importer"]
    V36 --> V37["Lightweight V36 to V37 record state"]
    V37 --> V38["Lightweight V37 to V38 handoff and cleanup"]
    V38 --> V39["Lightweight V38 to V39 model selection"]
    V39 --> V40["Lightweight V39 to V40 retire category quarantine"]
    V40 --> V41["Lightweight V40 to V41 notification preferences"]
    V41 --> V42["Lightweight V41 to V42 collaboration sidecars"]
    V42 --> V46["Lightweight V43 through V51 stages"]
    V46 --> Reopen["Open same migrated path again"]
```

The fixture-based path tests endpoint recognition, successive migration and reopening of the same on-disk data. The arrows show **local** stages only, not CloudKit wire-format upgrades.

Examples show why this matters:

- V1–V6 identity and SSH-key shapes remain represented by frozen types so their fields and defaults retain the historical schema checksum.
- V11’s provider model remains frozen while V12 changes address representation; legacy columns in the live provider model are folded on read to preserve the former endpoint behavior.
- V30 removes the obsolete persisted Known Host mismatch flag by replacing the V29 known-host model, while retaining hostname, port, algorithm, fingerprint, and date.
- V31 additively introduces scoped CloudKit quarantine and recovery models with a lightweight V30→V31 migration. The existing V1–V30 model shapes remain unchanged; the local schema increment does not change the V1 CloudKit envelope formats.
- V34 directly migrates released V31 stores to the Host/connection-history/device model types named V32 and the Identity type named V33, and adds workspace preferences. These type names do not imply intermediate released schema endpoints. Host and Identity replacements remove obsolete `lastUsedAt` columns. The custom migration preserves events, assigns the stable installation ID to their `sourceDeviceID`, and inserts a separate `DeviceRecord` for that installation. The event itself receives no hostname field, and the CloudKit envelope format remains V1.
- The V31→V34 compatibility test verifies retained Identity configuration and the independent Vault journal modification date, connection origin/backfill with no invented end time, and default workspace-preference journal bootstrap. Historical Host and Identity shapes retain the old columns solely for schema compatibility.

`PersistenceCompatibilityTests` opens original V1 and V14 fixture stores and a fixed historical V28 store. The V28 fixture was generated against the unmodified Persistence framework at `0dc173d4b1d190071d35bc66f80ebb767d8b950c`, not current models; `Scripts/generate-v28-fixture.swift` records its provenance and expected checksum and explicitly stores synthetic references, not a password or private key. The fixture uses a V28 host with SSH port and charset, ordered environment-variable name/value arrays, snippet and group IDs, an identity pointing to an SSH key and a Keychain reference, a known-host mismatch flag, a connection event without a device ID, and a preexisting Vault installation ID. The V28→V30 model preserves the old `port`, `identityID` and `charset` property names as SSH fields and supplies Telnet defaults; V30 replaces the known-host type to discard only the obsolete mismatch flag. V31→V34 backfills event origin from the installation ID and inserts a separate device row without synthesizing an end time. The fixture test copies the original store to a temporary path and calls the normal factory twice on that same path: each open asserts projected host settings, charset, identity/key references, ordered environment variables, snippets, Known Hosts, history and the installation ID/device row, plus workspace defaults after `prepare()`. This tests migration **and subsequent reopening**, not a newly created V28 store using today's model declarations; it does not test recovery from a deliberately failed open. `MobileAppTests` also constructs the app from the migrated disk container twice to cover startup and relaunch, checking host/identity projections and event origin. The suite retains V27, V30, V31 and current full-schema compatibility coverage, full-schema independent in-memory containers, and new-field defaults; `CloudSyncSafetyPersistenceTests` also migrates a V39 disk store through V40 to the current schema, checking that scoped fences and record presence remain while retired category quarantine tables are dropped. A V41 disk migration test checks that opening the current schema retains existing data and starts with empty collaboration sidecars. Treat these compatibility fixtures as a release contract when changing entities, defaults, migration stages, or storage enum raw values.

### Snippet color: local migration and independent wire evolution

V51 adds the latest `PersistentSnippet.colorTag` string with a no-color default and replaces the frozen `TermindSchemaV50SnippetModels.PersistentSnippet` only in V51. The frozen type continues to represent V1–V50. The migration/reopen test creates a real V50 disk store, retains Host/package/body/targets/order after upgrading, then saves a color and reopens again to verify durability.

Domain JSON accepts legacy missing or unknown color as `.none`, and duplication preserves color. Vault Snippet records read V1/V2 but write V2; V2 adds typed color to the frozen V1 payload, and V1 encoding rejects nonempty color to avoid lossy writes. Applying a newer legacy V1 Snippet can clear color to `.none`; both V1/V2 tombstones still round-trip. `SnippetColorTests` exercises these compatibility and journal paths without claiming signed-device CloudKit verification.

### Synchronized connection events and device directory

`SwiftDataConnectionHistoryRepository` stores each saved-host SSH, Telnet or SFTP attempt as an independent event with stable ID, Host ID, protocol, start time, `sourceDeviceID` and optional end time. Every insert/end/delete/clear reconciles the complete local event set with `HistorySyncStore` inside the same `ModelContext` commit, so a successful history mutation and its envelope or tombstone cannot diverge. The repository and remote-merge path sort by start time and UUID, then deterministically retain the newest 250. The History limits of 100 desktop rows and 50 mobile rows are presentation-only. `ConnectionHistoryModel` caches readable entries even when its initial retention trim fails, reporting the write error rather than hiding existing history; failed record/end/delete/clear operations report `storageError` without publishing a successful mutation. Its recent-host projection selects the newest local event per still-present saved Host, not the newest event from another device.

`SwiftDataDeviceDirectoryRepository` independently persists reusable `DeviceRecord` values that map installation IDs to mutable display names. Its upsert and `.device` journal envelope commit together. Device records are not dropped when a Host is deleted, History is cleared, or the 250-event retention rule prunes old events; this lets any feature resolve the current name for a stable installation ID. A system-name change updates one directory row, so all connection events and future consumers display the new name without event rewrites.

The old Host `lastUsedAt` column is not a replacement source for this timeline. The live Host and Identity model types selected by V34 both omit usage timestamps; neither Host nor Identity usage metadata drives connection History.

V35 added `PersistentHistorySyncEntry`, `PersistentHistorySyncState`, `PersistentHistoryImportState`, and `PersistentSyncCapability` without changing V34 domain models. V36 removes `PersistentHistoryImportState`: **current** `HistorySyncPersistence.prepare()` bootstraps native journals from current events and devices, not retired Vault History envelopes. In particular, opening a V31 or V34 store with an old Vault History tombstone does not transfer that tombstone, the old installation ID or the old bound account into the new journal. Do not restart the retired importer when extending sync. V35-on-disk and V31/V34 reopen tests exercise this boundary; Host/history rows and V31→V34 device backfill still migrate normally. Host deletion records History tombstones; ordinary configuration edits only record Vault mutations. A History tombstone is terminal for its event ID, so a late update cannot revive a cleared event.

## Notification preferences: local migration and Settings replica

V41 adds `PersistentNotificationPreferences` to the local SwiftData schema through a lightweight V40→V41 stage. It stores one JSON-encoded `NotificationPreferences` value under the `default` key; an older V40 store has no such row, so `SettingsSyncPersistence` creates the default on first load rather than reading notification settings from `UserDefaults`. `prepare()` bootstraps a Settings journal envelope for the preferences, including on stores whose older Settings bootstrap already ran. On macOS and iOS, the composition root prepares `SettingsSyncPersistence` and injects it into `NotificationSettingsModel` before the feature uses preferences.

The Settings replica carries the non-secret preference value as `v1/notifications/default` (`NotificationPreferencesItem` in CloudKit), independently of the local V41 schema number. Local edits validate a nonnegative terminal duration and commit both the row and journal intent before publishing the live model value. Remote envelopes are merged by journal version and materialized with the row in one commit, without calling the local mutation callback; an accepted deletion restores `NotificationPreferences()` defaults rather than deleting notification authorization state. `sftpMode` is optional when decoding older JSON and defaults to `.unfocused`, so adding that choice does not make existing values unreadable. This is a preferences record, **not** a credential channel: notification settings and references can sync, Keychain material cannot.

The shared `NotificationSettingsModel` does not treat a failed load as permission to prompt from defaults. It requests initial system authorization at most once for its lifetime and only when the loaded preferences need system delivery; a disabled setting or terminal bell-only delivery with assistant/SFTP disabled needs no prompt. Tests cover invalid and failed edits leaving the live value unchanged, remote records not echoing as local writes, V40 disk migration followed by a second open retaining both the new preference row and older workspace data, and the failed-load authorization gate.

```mermaid
flowchart TD
    Legacy["V40 disk store"] --> Migration["V41 lightweight schema stage"]
    Migration --> Row["Notification preferences row or defaults"]
    Row --> Prepare["Settings bootstrap creates journal envelope"]
    Prepare --> Cloud["Settings CloudKit replica"]
    Row --> Model["NotificationSettingsModel"]
    Model -->|"validated local edit"| Commit["Commit row and journal"]
    Commit --> Model
    Cloud -->|"accepted remote envelope"| Merge["Commit journal and materialized row"]
    Merge --> Model
    Model -->|"system delivery needed"| Authorization["One initial authorization request"]
```

Notification data is locally migrated as SwiftData state and separately replicated as a Settings envelope; authorization is a runtime decision, not a migrated secret.

## Cloud sync restrictions are durable local state

The safety and capability stores preserve these controls:

| Local record | Durable meaning |
| --- | --- |
| Scoped quarantine | Original payload bytes, encoded CloudKit system fields, structured failure reason and record identity; its presence prevents that record from being uploaded. |
| Decoder capability checkpoint | Records supported formats only after a successful full replay; expanded support forces scoped rereading before restrictions are cleared. |
| Recovery checkpoint | Whether the replica must fetch afresh rather than restore a possibly advanced CloudKit cursor after interrupted processing. |
| Record and replica state (V37) | Tracks observed cloud presence, confirmed or legacy physical deletions, and whether the replica has reconciled a full inventory independently of the engine cursor. |
| Delete handoff and asset cleanup (V38) | Remembers the exact handed-off delete incarnation across a crash and schedules category-owned cache directory removal after a committed purge. |

A replica scope includes container, environment, account, zone, owner and an optional consumer identifier. The record name is scoped within that boundary, so a restriction in one account or environment neither blocks nor clears the same name in another. Since V40, the active schema no longer includes the retired per-category quarantine rows; migration from V30 or V39 discards those tables rather than attributing their unscoped records to a new account. Existing scoped quarantine remains active and must not be cleared simply because an old table was removed.

A new scope begins with recovery required. `CloudSyncLifecycleSafety.persistent` binds the lifecycle to `CloudSyncSafetyStore` for recovery, capability and upload fences, while `CloudSyncRecordCoding.quarantine` saves either original JSON payload or a secure archive of a native record together with system fields. `CloudSyncRecordStateStore` filters pending mutations by the same quarantine boundary and retains deletion presence and causal handoff across engine resets. Its full-inventory reconciliation distinguishes a confirmed old delete from a newer explicit recreation, which must remain pending; a successful cloud delete acknowledgement clears only its matching incarnation. Cache purge work stays pending until the owned directory removal succeeds.  The coordinator discards serialized engine cursor state when recovery or replica upgrade requires a fresh snapshot (also when serialization is invalid), but retains local journal envelopes and pending edits. It commits the scoped recovery fence **before** creating an automatically syncing engine and before network work. `beginFetch` closes the upload gate and reasserts the fence; only after all overlapping fetches have succeeded does `finishFetch` complete inventory reconciliation and decoder capability, and authorize sending. Fetch failure leaves uploads fenced until a later successful fetch; a concurrently active send keeps recovery required until it finishes. A delegate persistence failure rolls back and retires that engine, so a later successful callback cannot reopen its upload gate.

Receiving a supported replacement reconciles the domain data, journal metadata and quarantine removal in one persistence commit. A failure rolls all of them back. Retry, pause, account/environment resets and relaunch are not generic quarantine-clearing operations. Physical deletion and tombstone handling preserve the same upload restriction. Native History/Device quarantine preserves a secure archive of the complete CKRecord alongside system fields; JSON-backed category records retain their payload bytes. Unsupported native records remain fenced in their own replica scope; the retired cross-zone History importer no longer supplies a new-zone target fence. These are local control records, not new cloud record types or a replacement secret store.

The on-disk safety tests cover V30→current and V39→current migration through V40 with retired quarantine tables dropped but scoped restrictions preserved, independent replica scopes, reopening an interrupted store with blocked and pending records intact, and rollback of a failed unblock. The compatibility suite additionally checks that reopening V35 drops only the retired importer table while retaining native device rows, envelopes and account binding; V31/V34 old Vault History journals are not imported into the native History journal. See [Settings and Cloud Sync](../workflows/settings-and-cloud-sync.md) for network gates and the limits of this first compatibility layer.

## Secret references, not secret persistence

A durable identity, SSH key, AI provider, or MCP record may contain `credentialRef` plus public/configuration metadata, but not the credential plaintext. The `SecretStoring` port separates string passwords from stored SSH-key credentials and resolves them by reference plus device/iCloud storage selection. Its runtime extensions turn fetched values into `SSHSecret` or `SSHResolvedKeyCredential`; `InMemorySecretStore` exists for tests and injected configurations, while app composition supplies Keychain storage.

SSH Security Key records are a deliberate exception to Keychain-backed private-key storage: the V45 SSH key row stores credential ID, P-256 public key, verification preference and presence flag, while the private key stays on the authenticator. `HostLibraryModel.upsert` validates the credential ID and 65-byte public key, disallows supplied secret material and replacement of a software key with the same ID, normalizes the label, clears `credentialRef`, sets `.external`, and rolls back the in-memory projection if persistence fails. Loading even an older hardware row marked `.thisDevice` or `.iCloud` normalizes it to `.external`. The `SSHRuntimeSecretResolving` overload for `SSHKeyRef` builds `.securityKey` directly from metadata without a Keychain read; availability reflects the presence of that metadata, **not** physical authenticator availability. Editing and deleting metadata likewise avoid Keychain calls. V2 Vault wire records serialize the reference, encoding `.external` as the frozen wire spelling `thisDevice`, then recovering `.external` for a Security Key on decode; software keys with external storage are rejected. V1 remains available for older categories and records; local schema V51 and per-kind cloud wire versions are different version axes. Vault sync can move this reference, but using it still requires the physical authenticator and a local WebAuthn interaction. [WebAuthnVaultMetadataTests](../../FrameworkTests/WebAuthnVaultMetadataTests.swift) exercise jump and destination resolution with a deliberately failing Keychain, round-trip and remote merge, legacy storage normalization, invalid external software storage, rollback, and V44 software-key migration/reopen. See [SSH Security Key Authentication](ssh-security-key-authentication.md) for registration, signing and portability limits.

Live `KeychainSecretStore` separates passwords/AI strings, software SSH keys and Secure Enclave handles by service within a configured access group in the Data Protection Keychain. It validates nonempty `termind.password.` or `termind.ai.` string references and `termind.key.` key references; invalid types and Keychain status errors propagate. `.iCloud` items use synchronizable, WhenUnlocked access; device and enclave items are non-synchronizable, WhenUnlockedThisDeviceOnly. `.external` has no Keychain service and cannot be stored there. Runtime reads decode software-key JSON into wipeable `SSHSecret` values and clear temporary byte buffers, while Secure Enclave reads return a handle; the editor's legacy typed credential API is separate from this runtime byte path. This is a Keychain storage location distinction, not SwiftData CloudKit replication.

AI secrets apply the same rule with an extra migration-location record. `PersistentAISecretLocation` stores only a reference, whether its secret is in iCloud, and a deletion marker. `AISecretStore` accepts only nonempty `termind.ai.` references; reads return no secret for pending deletions and otherwise ask Keychain directly. It never writes secret bytes to SwiftData.

For new AI secrets, iCloud use requires coordinator authorization plus both master iCloud and Settings-sync switches. A successful migration first writes and verifies the iCloud Keychain value, records `usesICloud`, then removes the device copy. Once a reference has migrated, later writes remain in iCloud even if the switches are disabled. Remote reference metadata marks the location as iCloud without treating an old device copy as authoritative. Deletion persists `pendingDeletion` before Keychain removal and retains that tombstone so delayed Keychain delivery cannot resurrect a secret.

## Runtime-only authentication material

A session receives resolved credentials, not a database record. `SSHCredentials` wraps password, private-key, and passphrase values in `SSHSecret`; `SSHConnectionConfiguration.clearSecrets()` clears target credentials, proxy secret, and jump-hop secrets while preserving non-secret network data and `SSHAuthenticationReference` provenance. The provenance contains IDs, username, and capability flags so later connections can re-resolve current Keychain material, but it does not retain a plaintext password or key.

`SSHSecret` owns a single non-copy-on-write byte allocation shared by its copies. It clears source `Data` when taking ownership, exposes its NUL-terminated bytes once through `withUnsafeCStringAndConsume`, wipes/deallocates the allocation before return, and rejects a second consumption. Explicit clearing is idempotent. Interaction-forbidden connection requests additionally replace credentials that require a passphrase or user-presence authorization with `interactionRequired`, so silent auxiliary work cannot prompt for or consume protected authentication material.

## GRDB Hermes Memory is a separate durable store

Hermes Memory does not share the SwiftData database. `GRDBMemoryStore` is an actor that lazily creates and exclusively owns a `memory.sqlite` queue and its directory, so constructing a disabled memory feature does no filesystem work. On first access it enables WAL and applies `hermes-v1` (memory state, legacy snapshots, review checkpoints, session/message history, FTS5 index, triggers and ordering index), then `hermes-policy-learning-v2` (drops the old snapshots table and adds durable learning activity and reviewed-correction checkpoints), then `hermes-reference-dates-v3` (adds per-entry last-reference dates). These GRDB migration names are independent of SwiftData and cloud wire versions.

Memory updates run in database writes. A review or correction is accepted only when its expected base `AgentMemoryState` still matches; otherwise it returns `nil` without recording the review or correction. Learning activity is keyed by conversation, event and kind, and review progress is committed with accepted operations. History replacement deletes no-longer-present sessions and only stores user, assistant, and tool messages after visible-text/JSON redaction. Session search uses trigram FTS when a query admits an FTS5 plan and a case-folded substring fallback for short terms; it tries matches for all terms before falling back to any term, across the whole result set rather than just one page. Memory search separately records last-reference dates only for returned existing entry IDs, taking the maximum date on repeat visits; memory-state saves prune dates for removed entries. Editable memory text strips generated UTC date annotations before saving, preserves IDs and creation dates for unambiguously matched entries, and rejects malformed date annotations. `close()` releases the queue; `destroy()` closes it first and removes the entire owned directory.

The focused Hermes tests prove disabled memory creates no files, memory state survives a close/reopen and V1 snapshots disappear without losing entries, stale background reviews cannot overwrite foreground changes, indexed history is searchable and removed with history replacement, reference dates survive reopen without invalidating review, and destroy revokes old access before a later enable can backfill retained conversation history.

`MemoryIndexedAgentRepository` wraps agent history rather than moving it into GRDB: it requests indexing only after a successful terminal run save, conversation creation, title change, truncation or deletion. `MemoryModel` loads the SwiftData-backed conversation projection through `AgentRunPersisting` and replaces the separate searchable memory history; disabled or suspended memory does not start that work. Reindexing coalesces changes while a task is running, and a memory search waits for the current indexing task. This is a derived local index, not a second authoritative copy of agent runs. The GRDB replacement compares redacted message IDs and content, not timestamps alone, so editing a turn with an unchanged timestamp still refreshes the index.

Suspension is not deletion. Mobile suspends memory when all scenes enter the background and resumes it on foreground return; desktop suspends it on termination. Suspension rotates a generation token, invalidates session contexts and access handles, and cancels index and review tasks. A resumed session receives a new access handle; an in-flight write that committed across suspension can still finish in GRDB, but its obsolete caller receives cancellation and the current generation reloads the committed state rather than publishing a stale result. On resume the model reloads memory state and schedules history indexing; a review computed before suspension cannot apply afterward. Disabling memory closes the store without erasing it. Destroy instead disables access, cancels and joins pending work, then removes the GRDB directory; a `hermesMemoryDestroyPending` preference keeps a failed destroy disabled and triggers a retry at next initialization. Re-enabling after a successful destroy can reindex conversations that remain in SwiftData, but cannot revive destroyed memory entries or old access handles.

```mermaid
flowchart TD
    History["SwiftData agent conversation commits"] --> Wrapper["MemoryIndexedAgentRepository"]
    Wrapper --> Gate{"Memory enabled and not suspended"}
    Gate -->|yes| Index["Load conversations and replace GRDB history"]
    Gate -->|no| Deferred["No indexing until enable or resume"]
    Index --> Search["Search waits for current index task"]
    Suspend["Suspend or destroy"] --> Invalidate["Invalidate generation and cancel work"]
    Invalidate --> Resume{"Resume or destroy"}
    Resume -->|resume| Index
    Resume -->|destroy| Delete["Close store and remove memory directory"]
```

Memory history indexing follows committed agent data; suspension invalidates consumers while destroy removes only the separate memory store.

## Change checklist

1. **Adding SwiftData data:** put the `@Model` in `TermindPersistence`, add it to the current schema, decide whether a new frozen schema/version and migration stage are required, and extend compatibility coverage.
2. **Changing an existing persisted shape:** preserve the old type and semantics; add a new version-specific model rather than editing a historical type. Test an actual prior store or fixture, including defaults and removed fields.
3. **Adding a repository mutation:** project persistent rows to application values, save related durable state atomically, roll back on failure, and publish observations only after a successful save.
4. **Adding a credential:** persist only a stable reference and non-secret provenance. Use `SecretStoring`/Keychain for material; exclude it from logs, CloudKit/sync records, `UserDefaults`, SwiftData/GRDB ordinary records, and reusable session snapshots.
5. **Passing a secret to transport:** use the runtime secret owner, clear it at every success, error, cancellation, and teardown boundary, and retain only non-secret identifiers when a reconnectable configuration is needed.

V47 adds Tailscale groups and local node state; V48 revises local node state; V49 removes command/SFTP history models from the current schema; V50 adds profile cleanup; V51 adds persisted Snippet colors. Tailscale group configuration is Vault data, while profile IDs, sign-in/cache state and cleanup markers stay device-local. Current Vault Host and Snippet writes use V2; SSHKey and HostGroup (including Tailscale configuration) write V3; reader capability and local schema versions remain independent.
