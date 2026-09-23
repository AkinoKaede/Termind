---
type: synchronization workflow
title: Settings, Vault, Metrics, and Cloud Sync Workflow
description: How Termind independently synchronizes Vault, Settings, and Metrics through CloudKit, including lifecycle gates, durable journals, account and environment transitions, conflict handling, and AI-secret upload authorization.
tags: [cloudkit, synchronization, settings, vault, metrics, secrets, swiftdata]
sources:
  - id: openwiki-source-dc7b363138921b0923d2dc2f
    resource: repo://Frameworks/TermindApplication/FeatureModels/ConnectionHistoryModel.swift
  - id: openwiki-source-7ca30f0e781e8c2df826b47a
    resource: repo://Frameworks/TermindApplication/HistoryLimits.swift
  - id: openwiki-source-9fbc733f79d51a7265ee9e4a
    resource: repo://Frameworks/TermindApplication/SettingsKey.swift
  - id: openwiki-source-1429ec01ac68a7770ce41977
    resource: repo://Frameworks/TermindDomain/Vault/CloudSyncSafety.swift
  - id: openwiki-source-a9afccb62e1c69e5a0fbf46c
    resource: repo://Frameworks/TermindDomain/Vault/VaultSyncTypes.swift
  - id: openwiki-source-1d1f503a260f304a969fcee4
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncLifecycle.swift
  - id: openwiki-source-4957f13c836c497e7ebe4656
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncPersistenceSafety.swift
  - id: openwiki-source-3effdff7f6b04e2a66d8f651
    resource: repo://Frameworks/TermindInfrastructure/Cloud/MetricsSyncCoordinator.swift
  - id: openwiki-source-04ef2b2f02773f8833db9a8b
    resource: repo://Frameworks/TermindInfrastructure/Cloud/SettingsSyncCoordinator.swift
  - id: openwiki-source-eaa9d39ab551840299164d96
    resource: repo://Frameworks/TermindInfrastructure/Cloud/VaultSyncCoordinator.swift
  - id: openwiki-source-1366e71322413c98e0ac1534
    resource: repo://Frameworks/TermindPersistence/CloudSyncSafetyStore.swift
  - id: openwiki-source-07774a741f517493204edd63
    resource: repo://Frameworks/TermindPersistence/MetricsSyncJournal.swift
  - id: openwiki-source-65a2da12a42f42fb0850078e
    resource: repo://Frameworks/TermindPersistence/MetricsSyncStore.swift
  - id: openwiki-source-8a05ed491f0965e8444981d6
    resource: repo://Frameworks/TermindPersistence/ModelContext%2BCommit.swift
  - id: openwiki-source-2dc6b29f02b74b32c0eb786e
    resource: repo://Frameworks/TermindPersistence/SettingsSyncJournal.swift
  - id: openwiki-source-6df73854db20ee83905a634c
    resource: repo://Frameworks/TermindPersistence/SettingsSyncJournalStore.swift
  - id: openwiki-source-9eb2234b02897ade8e405374
    resource: repo://Frameworks/TermindPersistence/SwiftDataAISecretStore.swift
  - id: openwiki-source-4217f56e034013cb8704d525
    resource: repo://Frameworks/TermindPersistence/SwiftDataConnectionHistoryRepository.swift
  - id: openwiki-source-0b6ab59ec6a684de8101ff8e
    resource: repo://Frameworks/TermindPersistence/SwiftDataDeviceDirectoryRepository.swift
  - id: openwiki-source-bc351b6c699ff4bbf9f8c2b1
    resource: repo://Frameworks/TermindPersistence/SwiftDataVaultJournal.swift
  - id: openwiki-source-a0d614d618b11f103ec246ae
    resource: repo://Frameworks/TermindPersistence/SwiftDataVaultStore.swift
  - id: openwiki-source-15e5026028d13d2202844f68
    resource: repo://Frameworks/TermindPersistence/TermindSchemaV33IdentityModels.swift
  - id: openwiki-source-3cfc52217a7a6835b4bffac1
    resource: repo://Frameworks/TermindPersistence/VaultSyncPersistence.swift
  - id: openwiki-source-87b90af0bd504e35083a8414
    resource: repo://Frameworks/TermindPresentation/VaultSyncStatusLabel.swift
  - id: openwiki-source-b8eae581ee8d4d73aa45f827
    resource: repo://FrameworkTests/CloudSyncCoordinatorLifecycleTests.swift
  - id: openwiki-source-bf7a64e7c819eb9279e2f9e4
    resource: repo://FrameworkTests/CloudSyncLifecycleTests.swift
  - id: openwiki-source-195e2cb735dfac7fb6dbda27
    resource: repo://FrameworkTests/CloudSyncSafetyFixture.swift
  - id: openwiki-source-40cfadc2320da9a292c64d26
    resource: repo://FrameworkTests/CloudSyncSafetyPersistenceTests.swift
  - id: openwiki-source-eb9518e5c7eb3782fa0cccc0
    resource: repo://FrameworkTests/CloudSyncSafetyTests.swift
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-4dbea0ff2808163cb4ecdd8f
    resource: repo://TFM/App/AppModel.swift
generated: { by: "codex", at: "2026-09-23T00:14:42.075Z" }
verified:
  - by: openwiki/0.5.2
    at: 2026-09-23T10:08:51.776Z
---

# Settings, Vault, Metrics, and Cloud Sync Workflow

Termind synchronizes three **independent categories** in the private `iCloud.com.akinokaede.termind` container: Vault records, application Settings, and Metrics selections. Each category has its own coordinator, private custom zone, subscription, `CKSyncEngine`, durable journal state, account binding, environment marker, pending queue, and status. The shared `CloudSyncLifecycle` supplies the safety protocol, but it does not make category state shared. Pausing Vault, for example, neither retires Settings/Metrics engines nor revokes Settings’ secret-upload authorization.

This workflow is CloudKit replication built around a SwiftData journal, not SwiftData’s CloudKit integration. `TermindPersistence` owns the journal models and the coordinator applies accepted remote envelopes back through the relevant persistence facade. Platform app models own coordinator lifetime and apply resulting snapshots to their runtime models.

## Categories, switches, and runtime ownership

| Category | Coordinator and zone | Content boundary | Default control |
| --- | --- | --- | --- |
| Vault | `VaultSyncCoordinator`; `TermindVaultV1`; `VaultItem` | Hosts, identities, SSH-key references, known hosts, snippets, forwarding rules, workspace templates, connection-history events, and the reusable device directory | `vault.sync.enabled` plus `icloud.sync.enabled` |
| Settings | `SettingsSyncCoordinator`; `TermindAIConfigurationV1`; `AIConfigurationItem`, `SSHPreferencesItem`, `SFTPPreferencesItem`, and `WorkspacePreferencesItem` | AI configuration, skills, search, terminal, SSH, SFTP, and workspace preferences—not credential material | `settings.sync.enabled` plus `icloud.sync.enabled` |
| Metrics | `MetricsSyncCoordinator`; `TermindMetricsV1`; `MetricsItem` | Persisted metrics selections, not samples or active monitoring | `metrics.sync.enabled` plus `icloud.sync.enabled` |

All master and category switches default on. A category is enabled only when the master `SettingsKey.iCloudSyncEnabled` and that category’s key are enabled; an absent preference uses its category default. `SettingsKey.migrateSyncPreferences(in:)` migrates the old Settings selection and derives an initial master choice without discarding explicit opt-outs.

`AppModel` starts all three coordinators only when the Vault-sync Pro capability is available, pauses all of them when entitlement is absent, and routes accepted remote snapshots to the corresponding app-wide models. On mobile, `MobileAppModel.reconcileSync()` starts them only while at least one scene is active and the same capability is available; otherwise it pauses them. This makes synchronization app-wide and entitlement/lifecycle-controlled rather than window- or scene-owned.

## Lifecycle: fetch before send

Every coordinator adapts its own journal to `CloudSyncLifecycleStore` and implements `CKSyncEngineDelegate`; the lifecycle owns the engine session and operation generation. It first checks the CloudKit account and user record, binds or requests confirmation for the account, prepares scoped safety state, resets incompatible CloudKit metadata when needed, commits a recovery checkpoint, creates an engine, restores only uploadable journal record names, ensures its zone exists, and fetches that zone. **No send is authorized until that fetch succeeds for the current engine.** Local edits still enter the durable journal while sync is paused or while the fetch is in progress.

<!-- openwiki: mermaid parse failed and this diagram was converted to a text fence so it does not break rendering. Fix the diagram source and restore the mermaid fence. Parser error: Heuristic: a semicolon inside a label breaks rendering; rephrase the label. -->
```text
flowchart TD
    Enabled{"Master and category enabled?"} -->|No| Paused["Paused; retain local journal"]
    Enabled -->|Yes| Account{"Account available and binding accepted?"}
    Account -->|No| Waiting["Wait for account or merge confirmation"]
    Account -->|Yes| Prepare["Prepare scope and persist recovery checkpoint"]
    Prepare --> Engine["Create engine; restore eligible queue; ensure zone"]
    Engine --> Fetch["Fetch with current engine"]
    Fetch -->|Processing failure| Retired["Retire engine; retain recovery and local edits"]
    Fetch -->|Successful completion| Gate{"Pending record blocked in this scope?"}
    Gate -->|Yes| Held["Retain local intent; exclude from uploads"]
    Gate -->|No| Provider["Recheck engine, scope and journal in provider"]
    Provider --> Send["Send eligible record"]
```

This diagram shows authorization and per-record eligibility, not a complete UI state machine. Pending edits and restrictions remain durable independently of displayed status; a blocked record does not revoke eligibility for compatible peers.

A lifecycle runs at most one tracked operation. It gives each operation an ID and only lets that ID clear the operation or publish an error. `pause()` or an account transition retires the engine: it changes the operation ID, cancels the task and engine operations, clears readiness, and removes the engine. Completion handlers and delegate events must also satisfy `lifecycle.accepts(engine)`, which requires identity with the current engine and an enabled category. Thus stale generations cannot publish status, provide a record batch, authorize uploads, or clear a replacement operation.

Retryable CloudKit errors—network failure/unavailability, service unavailable, rate limit, zone busy, and truncated results—leave the category in a syncing state for retry. A retryable zone-fetch failure keeps the engine but closes upload and secret authorization until another successful fetch. `notAuthenticated` becomes an unavailable sign-in status; other errors are failed. Terminal errors take precedence; otherwise quarantine yields a partially blocked status with separate uploadable-pending and blocked counts, not a false up-to-date result. A newer-format reason adds an update hint; corrupt data does not promise an update will repair it.

### Recovery before cursor advancement

Local schema V31 adds a recovery row and scoped quarantine storage without changing cloud zones or V1 envelopes. A new safety scope starts with recovery required, so its first preparation discards serialized engine state and fetches afresh. An interrupted operation leaves the same marker. Journal envelopes, local pending edits and restrictions are not discarded with the cursor.

Recovery intent is committed before constructing an automatically syncing engine and before fetch/send work. The lifecycle counts both explicit operations and automatic callbacks; an overlapping completion cannot clear the checkpoint or reopen fetch authorization early. A delegate processing or persistence failure rolls back and retires that engine. Its later successful callback fails the current-engine check rather than reauthorizing uploads. Retry creates a new engine from a fresh cursor when recovery remains required.

## Account, zone, and environment transitions

The journal persists serialized engine state, `boundUserRecordName`, `pendingUserRecordName`, and the last successful sync. Before creating an engine, the lifecycle compares CloudKit’s current user record name with the binding:

- With no binding or a matching account, it stores the current account and proceeds.
- With a different bound account, it records the new user as pending, reports `.accountChangeConfirmationRequired`, and does not create an engine or upload anything.
- `confirmAccountSwitchMerge()` imports legacy quarantine under the prior account/environment, resets journal state **before** binding the pending account, then retires and restarts. The account reset removes deletion tombstones, marks live records for upload, clears CloudKit system fields, serialized engine state, and last-success time. It therefore avoids carrying an old account’s deletions into the new account.
- CloudKit sign-out retires the engine and reports the category’s sign-in message. A different sign-in or switch accounts retires it and requires merge confirmation; a same-user sign-in can continue.

The current `TermindCloudKitEnvironment` bundle value is also compared with a category-specific `UserDefaults` marker. On change, the category keeps envelopes but requeues them, discards system fields/change tags and engine serialization, clears last-success time, saves, and records the new environment. This prevents Development metadata from being reused in Production. If CloudKit reports the category zone deleted or returns `zoneNotFound` from a save, the lifecycle similarly resets/requeues the journal, asks the engine to recreate the zone, and retains the account binding. The new quarantine rows are scoped by container, environment, account, zone and owner: resets neither erase an old replica's restrictions nor apply them to another replica.

## Journal and replication protocol

A journal is the durable outbox and merge authority for each category. Bootstrap creates baseline envelopes for an initial local snapshot. Local persistence writes compute only real differences, assign an ordered version using the installation writer ID, mark changed records `needsUpload`, and retain deletion tombstones. Because journaling happens independent of lifecycle readiness, edits made while disabled are accumulated and sent later; no-op saves do not advance versions.

Each pending envelope is encoded into a CloudKit record with envelope metadata (`formatVersion`, `kind`, `entityID`, `modifiedAt`, `counter`, `writerID`, and `isDeleted`) and a payload hash. The coding layer uses inline bytes below its limit and a local `CKAsset` for larger payloads. Journal-held CloudKit system fields are reused on subsequent saves and updated from fetched/saved records, enabling ordinary CloudKit optimistic concurrency.

On fetch, coordinators process only their zone and accepted record types. They decode and validate envelopes, quarantine malformed or unsupported payloads with their received bytes and structured reason, and merge valid envelopes in a persistence transaction. Valid remote system fields and quarantine removal participate in the same save; rejected records never replace normal outgoing-entry system fields. App notification follows successful application. A physical CloudKit deletion is not treated as a user deletion: if a local journal row still exists, it is marked for re-upload, but a compatibility restriction still prevents that recreation from being sent. Logical deletion is represented by an envelope tombstone.

Merge is deterministic: newer versions win; an older remote value causes the local value to be requeued. For equal versions whose payloads differ, encoded bytes provide a deterministic tie-breaker. Settings and Metrics additionally collapse multiple fetched versions of one key before deciding, so batch delivery order does not affect the result. A `serverRecordChanged` save failure runs the server record through the same validation path as a fetch. A supported envelope either establishes an identical local version as uploaded or requeues the winning local result; an unsupported envelope is quarantined instead of silently retrying a stale local payload. Successful sends clear `needsUpload` only if the journal still holds the sent version, so a newer local edit cannot be incorrectly acknowledged.

Vault projections deliberately remove device-local presentation metadata from envelopes: group and package expansion is normalized rather than synchronized. The live V33 Identity shape no longer contains `lastUsedAt` usage metadata. Settings likewise excludes explicitly device-local defaults such as debug/logging, review history, and terminal font family/size/follow-theme-size. Settings record-type compatibility is intentional: SSH, SFTP and workspace preferences use distinct types in the Settings zone so older clients can ignore newer records before decoding.

Connection history is an exception to “configuration-only Vault” by design: each event is an independent `connectionHistory` Vault key using the same `VaultItem` record type and V1 envelope. Existing local events bootstrap even after the original Vault bootstrap completed. Insert, end-time update, deletion and clear reconcile history rows with the journal in one transaction; logical deletions use ordinary envelope tombstones. Remote events may arrive before their referenced Host and remain stored but hidden until that Host exists. After local or remote merge, deterministic start-time/UUID ordering retains the newest 250 and journals tombstones for the overflow, allowing devices to converge. Launch-time pruning can discard overflow journal rows that never reached CloudKit; previously uploaded overflow receives tombstones. Platform views then choose a stable-source-device local projection or the complete synchronized event stream.

The reusable device directory is a separate replication stream in the same Vault category. Each `DeviceRecord` uses a `.device` payload keyed by the stable installation ID; its repository upsert and journal envelope commit together independently of the event repository. Platform activation refreshes the current system display name, and app models invalidate the directory cache when remote `.device` keys arrive. Device reconciliation creates or updates records but does not tombstone mappings merely because they are absent locally, and connection-event retention, per-Host deletion, or Clear History never removes them.

## Per-record compatibility restrictions

A scoped quarantine entry is an upload restriction, not only a diagnostic. It retains the received payload, encoded system fields, reason and identity. Its scope prevents a block for one account or environment from leaking into another. Legacy category rows are imported under their prior binding/environment before being removed in a successful local save; unknown historical ownership stays in a legacy scope.

There are three outbound checks:

1. **Journal eligibility:** return only unblocked pending names; keep the blocked row's `needsUpload` intent unchanged.
2. **Restored queue and batch:** remove blocked names from the engine's scheduling state, reject physical deletes, and synchronously materialize at most 250 eligible saves per request. Invalid or blocked pending entries do not consume that record limit. A batch uses no suspension between its final checks and handoff.
3. **Final record provider:** check current-engine readiness and the scoped restriction again, including the journal's outgoing-entry lookup. Lookup or persistence failure closes the category gate rather than treating an error as an empty restriction set.

An acknowledgement for an already blocked record does not clear its local intent. Local tombstones and console-deletion recreation follow the same restriction; neither can overwrite unknown remote data. Other records in the category can keep syncing, including while the UI reports a partial restriction. Local editing remains possible, but the pending change is not represented as successfully synchronized.

Only receiving supported data and successfully reconciling it removes a restriction. Merge, journal/system-field changes and quarantine removal commit together; failure restores the restriction. Retry, pause/resume, relaunch and clearing a terminal error do not unblock a record. Ordinary fetches still ignore unknown record types for independent future features; a conflict returned for an attempted known ID must be validated even if its type is unexpected.

### What this layer does not solve

Compatibility checks protect records that this client **detects** it cannot safely process. They do not preserve arbitrary extra fields silently ignored by typed `Codable` decoding, constrain binaries released before these checks, or provide general capability-version replay after every future app upgrade. The initial fresh fetch for a new V31 safety scope is not that broader replay mechanism. Keep independent future features in distinct record types where appropriate, distinguish absent values from explicit clears when extending shared records, and test actual new→old→edit→new binaries before promising lossless mixed-version writes.

## Settings references and secret authorization

Settings records carry credential **references**, never secret material. After accepting a remote provider or MCP-server envelope, `SettingsSyncCoordinator` calls `AISecretStore.acceptRemoteReferences`, marking those references as iCloud-backed so an old device-local copy cannot override a delayed iCloud Keychain value.

Secret migration is coupled to the Settings lifecycle, not merely to a preferences toggle:

1. A current Settings engine must successfully fetch its zone.
2. Only then does `CloudSyncLifecycle` invoke the Settings `authorizeUploads(true)` callback and set `isReadyToSend`.
3. Before a send and when its change-batch delegate is asked for records, `SettingsSyncCoordinator` migrates references found in provider, Vertex, and MCP configuration.
4. `AISecretStore` permits new iCloud copies only when that authorization is true and both master and Settings switches remain on. It verifies a copied iCloud value before recording the iCloud location and removing the device copy.
5. Pausing, account retirement, an active or failed fetch, or delegate persistence failure leaves or returns authorization to false. Therefore a stale engine cannot migrate/upload secrets merely because Settings was once enabled.

The store retains pending-deletion markers before deleting Keychain values and never reads them again as live secrets; this prevents late Keychain delivery from resurrecting a deleted credential. Once a reference is known in iCloud, later writes stay there even if a switch is turned off, while newly created secrets under a disabled or unverified workflow remain device-local.

## Operations and extension guidance

CloudKit deployment is separate from a passing local build. Deploy and validate the private container schema in Development and Production, preserving category zone names, record types, and subscription IDs; deploy `SFTPPreferencesItem` before clients upload it. Run signed-device checks across multiple devices on one account and explicitly test offline edits, per-category and master pause/resume, delayed Keychain delivery, account switching, and Pro expiration. See [CloudKit Schema Deployment and Signed-Device Release Readiness](/openwiki/operations/cloudkit-release-readiness.md) for the full release matrix and [Build, Validation, Localization, and Dependency Release Operations](/openwiki/operations/build-test-and-release.md) for ordinary build gates.

When adding a synchronized category, do not share an existing coordinator or journal. Create a category-owned zone/subscription/record type and persistence journal/state, give it an independent scope in the shared quarantine/recovery store, and supply coordinator record coding, delegate handling, enable/environment keys and lifecycle adapters. Preserve fetch-before-send, scoped journal eligibility, queue pruning and final provider checks in every `nextRecordZoneChangeBatch` implementation. Decide which fields are truly portable before adding them to envelopes; normalize or omit device-local runtime/UI metadata, and keep credentials in Keychain behind references.

When evolving a record, retain decode compatibility and validation. Unsupported or malformed records must be quarantined and prevented from uploading rather than partially applied, and a migration that changes a record identity must clear incompatible system fields and engine state. Do not turn a physical console deletion into silent data loss; retain tombstone semantics within the envelope protocol.

## Focused verification

- `FrameworkTests/CloudSyncLifecycleTests.swift` verifies fetch gating, accumulated local changes, retry behavior, operation/engine retirement, account confirmation/reset ordering, environment and zone resets, and error-status precedence.
- `FrameworkTests/CloudSyncCoordinatorLifecycleTests.swift` verifies category isolation and confirms that Settings secret authorization follows a successful fetch and is revoked on account retirement.
- `CloudSyncSafetyTests` runs all three real coordinators behind fake transport, checking actual batches/providers, conflict quarantine, compatible peers, tombstones/recreation, retry/restart, failed-unblock rollback and status hints.
- `CloudSyncSafetyPersistenceTests` checks scoped isolation, on-disk interrupted-state reopening, V30→V31 migration and legacy quarantine import. Lifecycle cases also exercise recovery checkpoints and overlapping automatic/manual callbacks.
- `TFMTests/SettingsSyncTests.swift` covers local mirrors, Settings journal/merge behavior, independent toggles, device-local exclusions, wire compatibility, and AI secret migration/deletion behavior.
- `TFMTests/VaultSyncTests.swift` covers stable envelope names, tombstones, deterministic merge/requeue behavior, local metadata exclusion, large payload assets and corruption rejection, and environment resets.

For persistence ownership and Keychain boundaries, see [Persistent Data, Migrations, and Secret Boundaries](/openwiki/concepts/persistence-and-secrets.md). For app-wide coordinator construction and platform lifecycle behavior, see [Platform Runtime, App Composition, and Lifetimes](/openwiki/architecture/platform-runtime.md).
