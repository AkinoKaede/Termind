---
type: testing strategy
title: Behavioral Boundaries and Fixtures
description: Route observable behavioral changes to focused regression suites and deterministic fixtures. Distinguish persistence and restore boundaries, context accounting, language migration, independent close and Quit vetoes, and deliberate native-presentation opt-ins.
tags: [testing, regression, fixtures, architecture, persistence, commerce, navigation, ui]
sources:
  - id: openwiki-source-ed77bc20b48d193bace3dde6
    resource: repo://.gitmodules
  - id: openwiki-source-8037e2358a2c4f9b2c722a11
    resource: repo://AGENTS.md
  - id: openwiki-source-5f99e8af445e073ffe9bc257
    resource: repo://Frameworks/TermindApplication/Agent/AssistantExecutionController.swift
  - id: openwiki-source-9b6177e37e7dd97d0cb1adee
    resource: repo://Frameworks/TermindApplication/Terminal/TerminalFindController.swift
  - id: openwiki-source-1d1f503a260f304a969fcee4
    resource: repo://Frameworks/TermindInfrastructure/Cloud/CloudSyncLifecycle.swift
  - id: openwiki-source-fe1dc993163bb9ff61397be7
    resource: repo://Frameworks/TermindPersistence/HostPersistence.swift
  - id: openwiki-source-303e34b5782a7a14e28cc9f8
    resource: repo://Frameworks/TermindPersistence/PersistentStoreLock.swift
  - id: openwiki-source-7a9c6d90cba4ebd1d1398673
    resource: repo://Frameworks/TermindPersistence/TermindPersistence.swift
  - id: openwiki-source-b347308e8c5cc6c0b0d29b7d
    resource: repo://Frameworks/TermindRemoteInfrastructure/Transfers/SFTPTransferContext.swift
  - id: openwiki-source-017f5e2abe9b13df755a5322
    resource: repo://FrameworkTests/AgentReplayPersistenceTests.swift
  - id: openwiki-source-e2abe97c93dbb91be81b63e2
    resource: repo://FrameworkTests/AssistantChatCollaborationPersistenceTests.swift
  - id: openwiki-source-247755d873c5d94b0a364217
    resource: repo://FrameworkTests/AssistantConversationOperationsTests.swift
  - id: openwiki-source-6ec3fb4cd6a582cdf278bab9
    resource: repo://FrameworkTests/AssistantExecutionControllerTests.swift
  - id: openwiki-source-bf7a64e7c819eb9279e2f9e4
    resource: repo://FrameworkTests/CloudSyncLifecycleTests.swift
  - id: openwiki-source-d785833dd230253fdc4946d7
    resource: repo://FrameworkTests/CloudSyncPhysicalDeletionTests.swift
  - id: openwiki-source-195e2cb735dfac7fb6dbda27
    resource: repo://FrameworkTests/CloudSyncSafetyFixture.swift
  - id: openwiki-source-40cfadc2320da9a292c64d26
    resource: repo://FrameworkTests/CloudSyncSafetyPersistenceTests.swift
  - id: openwiki-source-eb9518e5c7eb3782fa0cccc0
    resource: repo://FrameworkTests/CloudSyncSafetyTests.swift
  - id: openwiki-source-b7edf1d892ee300ba46cecd4
    resource: repo://FrameworkTests/HistorySyncTests.swift
  - id: openwiki-source-aa17b5491058eab1bbe5d01f
    resource: repo://FrameworkTests/HostEditorBindingsTests.swift
  - id: openwiki-source-e722f35e92f0823055985cb7
    resource: repo://FrameworkTests/NotificationPreferencesTests.swift
  - id: openwiki-source-8428b9f5de49b8a561d93fa5
    resource: repo://FrameworkTests/PersistenceCompatibilityTests.swift
  - id: openwiki-source-ad1a1eea0aea739f2004d93a
    resource: repo://FrameworkTests/PersistentStoreLockTests.swift
  - id: openwiki-source-d4dc435e4e9f6262c9e07564
    resource: repo://FrameworkTests/ProPaywallStateTests.swift
  - id: openwiki-source-01fd62d857f198c9f92cb8a5
    resource: repo://FrameworkTests/RetiredTerminalHighlightingTests.swift
  - id: openwiki-source-35e54ff3f3ad9f3931b11be7
    resource: repo://FrameworkTests/RevenueCatCommerceTests.swift
  - id: openwiki-source-3b1e8e4540cb99cbbd7863f5
    resource: repo://FrameworkTests/SnippetColorTests.swift
  - id: openwiki-source-db40aa993661b07f1a9aff6d
    resource: repo://FrameworkTests/SSHInteractionPolicyTests.swift
  - id: openwiki-source-bb65493b0fd5bf5957736cd6
    resource: repo://FrameworkTests/SyncRecordEvolutionTests.swift
  - id: openwiki-source-e568ada11d31632da3ad26c7
    resource: repo://FrameworkTests/TerminalFindControllerTests.swift
  - id: openwiki-source-eaed8c88a9a3f24e3feb1f9c
    resource: repo://FrameworkTests/WebAuthnVaultMetadataTests.swift
  - id: openwiki-source-294dd6a8637abdafe40e9570
    resource: repo://Scripts/generate-v28-fixture.swift
  - id: openwiki-source-27d6a8d3b199ecf35f59fafb
    resource: repo://Scripts/swiftdata-repository-declarations.sh
  - id: openwiki-source-cd0be716a2446029f345525a
    resource: repo://Termind.xcodeproj/project.pbxproj
  - id: openwiki-source-cd81b8b97e761c0120fdfccb
    resource: repo://Termind.xcodeproj/xcshareddata/xcschemes/TFI.xcscheme
  - id: openwiki-source-906678adb91c2fce2d3fcaed
    resource: repo://TFI/App/MobileAppModel.swift
  - id: openwiki-source-9c78befae6b387426c603305
    resource: repo://TFI/Application/Workspaces/MobileWorkspaceDescriptor.swift
  - id: openwiki-source-0ffab0ae6452f870ce4a0efe
    resource: repo://TFI/Features/Commerce/MobileProView.swift
  - id: openwiki-source-492f738896225c6b3acf7d2f
    resource: repo://TFI/Features/Workspaces/MobileWorkspace.swift
  - id: openwiki-source-f7aa24af0100c1767226879a
    resource: repo://TFI/Features/Workspaces/MobileWorkspaceSearchModifier.swift
  - id: openwiki-source-350d4a794cfef67e406ddf9b
    resource: repo://TFI/Infrastructure/MobileWorkspaceStore.swift
  - id: openwiki-source-34542e0f07e1650e098824c7
    resource: repo://TFI/Platform/MobileBackgroundController.swift
  - id: openwiki-source-c128ba4d61fc5b0e803b6ec1
    resource: repo://TFI/UI/Components/MobileToolbarSearch.swift
  - id: openwiki-source-5147eea728b12cb304c33011
    resource: repo://TFITests/KeyWindowTestTrait.swift
  - id: openwiki-source-b822b041afbf829d09a8555a
    resource: repo://TFITests/MobileAppTests.swift
  - id: openwiki-source-a154b5d36ec59496392d45e4
    resource: repo://TFITests/MobileAssistantTests.swift
  - id: openwiki-source-c9618f94f83d3b529a9860e1
    resource: repo://TFITests/MobileBackgroundControllerTests.swift
  - id: openwiki-source-c32ed562101f11a0c3c89663
    resource: repo://TFITests/MobileCardTests.swift
  - id: openwiki-source-16ec96bd78162e7e62effd0e
    resource: repo://TFITests/MobileConnectionPickerTests.swift
  - id: openwiki-source-7341d7b266d976d7aac5d161
    resource: repo://TFITests/MobileEditorToolbarTests.swift
  - id: openwiki-source-aadb94da40ccad1f082ce451
    resource: repo://TFITests/MobileHardwareKeyEditorRenderingTests.swift
  - id: openwiki-source-2c7245a9a1462a5a8d09b739
    resource: repo://TFITests/MobileMetricsJourneyTests.swift
  - id: openwiki-source-a8fe0369546b05fdb8d24cb6
    resource: repo://TFITests/MobileOperationConfirmationTests.swift
  - id: openwiki-source-282855f9369e6dc0c3447dc8
    resource: repo://TFITests/MobileSettingsPortTests.swift
  - id: openwiki-source-b6fae59344747785dee252f3
    resource: repo://TFITests/MobileTerminalSearchTests.swift
  - id: openwiki-source-4be25dd014939527fac996f5
    resource: repo://TFITests/MobileTerminalUploadMenuTests.swift
  - id: openwiki-source-5636c5d112b9e5b2266c3058
    resource: repo://TFITests/MobileVaultFeatureTests.swift
  - id: openwiki-source-11c91698354a4f95be3c4654
    resource: repo://TFITests/MobileWorkspaceMenuTests.swift
  - id: openwiki-source-2e344ef3e7cfe79ec821941e
    resource: repo://TFITests/MobileWorkspacePresentationTests.swift
  - id: openwiki-source-b360f8803ec98b554faad9bb
    resource: repo://TFITests/MobileWorkspaceSessionTests.swift
  - id: openwiki-source-9b78a7e39bfa08bea5192722
    resource: repo://TFITests/MobileWorkspaceStoreTests.swift
  - id: openwiki-source-205304536d13b39bf2e7e666
    resource: repo://TFITests/Screenshots/MobileCardRenderingTests.swift
  - id: openwiki-source-cc27a76170a8c672a70e388a
    resource: repo://TFITests/Screenshots/MobileConnectionJourneyRenderingTests.swift
  - id: openwiki-source-d5cca6ff91d9aaa5da323b40
    resource: repo://TFM/App/DatabaseStartupGuard.swift
  - id: openwiki-source-6570374eaac2e0278fa84640
    resource: repo://TFM/App/TermindApp.swift
  - id: openwiki-source-766dc23f16ac26a41a5b5c22
    resource: repo://TFM/Features/Commerce/ProPaywallView.swift
  - id: openwiki-source-cfbc34def649c94f760c5695
    resource: repo://TFMTests/AgentHostAuthenticationTests.swift
  - id: openwiki-source-715de8d16be5a3d06ae915ad
    resource: repo://TFMTests/AgentPersistenceTests.swift
  - id: openwiki-source-23ab3fe73660b171f78763a4
    resource: repo://TFMTests/AgentToolPresentationTests.swift
  - id: openwiki-source-d3d065330c730839f5cc6112
    resource: repo://TFMTests/ArchitectureBoundaryTests.swift
  - id: openwiki-source-78797a18dd3153d23a2c42e2
    resource: repo://TFMTests/ChatComposerStateTests.swift
  - id: openwiki-source-1ec6004f796c8c008740f13b
    resource: repo://TFMTests/ChooserInteractionTests.swift
  - id: openwiki-source-c15cd5bef4646aaf64df407e
    resource: repo://TFMTests/ConnectionHistoryTests.swift
  - id: openwiki-source-e6490dc6a3e86e39aa4323fc
    resource: repo://TFMTests/DatabaseStartupGuardTests.swift
  - id: openwiki-source-f87ee787c830f08478c25410
    resource: repo://TFMTests/KnowledgeToolRenderingTests.swift
  - id: openwiki-source-47dc468698b2904f0004ee04
    resource: repo://TFMTests/MCPUploadTests.swift
  - id: openwiki-source-c7d015a20982da4e8b0599d1
    resource: repo://TFMTests/MetricsJourneyRenderingTests.swift
  - id: openwiki-source-da61dbcdf7f720ccca8efaad
    resource: repo://TFMTests/RemoteSessionAuthenticationContinuationTests.swift
  - id: openwiki-source-9973cf687c50c9e4a1095c83
    resource: repo://TFMTests/RemoteSessionConnectionControllerTests.swift
  - id: openwiki-source-53e2b2fd2e661123f63e69e1
    resource: repo://TFMTests/SFTPTransferContextTests.swift
  - id: openwiki-source-fc9dd746ee8dc0791104d397
    resource: repo://TFMTests/SSHPTYChannelLifecycleWireTests.swift
  - id: openwiki-source-835d474e3dc193359dcfbb0b
    resource: repo://TFMTests/TerminalContextMenuTests.swift
  - id: openwiki-source-960109cd5bc0de7a879c1e16
    resource: repo://TFMTests/VaultSyncTests.swift
  - id: openwiki-source-a08489338be00125d646c77e
    resource: repo://TFMTests/VisibleWindowTestTrait.swift
generated: { by: "openwiki/0.7.0", at: "2026-10-10T23:08:14.218Z" }
verified:
  - by: openwiki/0.7.0
    at: 2026-10-10T23:08:14.218Z
---

# Behavioral Boundaries and Fixtures

Termind uses Swift Testing to test a behavior at the layer that owns it, rather than treating the test tree as a second implementation. `FrameworkTests/` protects portable framework contracts; `TFMTests/` exercises macOS composition, native interaction, and remote-session behavior; `TFITests/` protects iPhone/iPad composition, scene behavior, and mobile presentation. The targets use `@Suite`, `@Test`, and `#expect`.

A useful regression test establishes an observable invariant at an integration seam: what is persisted and migrated, which credentials and prompts may cross a connection boundary, when a resource remains alive after a UI owner disappears, or which state is shared versus scene-local. Avoid testing private mechanics merely because they exist. Test real transports or windows only when the contract requires them; otherwise inject a small in-memory repository, secret store, responder, client, or actor-backed harness.

```mermaid
flowchart TD
    Change["Changed behavior"] --> Owner{"Who owns the contract"}
    Owner --> Shared["Shared framework contract"]
    Owner --> Desktop["macOS composition or interaction"]
    Owner --> Mobile["Mobile app or scene behavior"]
    Shared --> FrameworkTests["FrameworkTests fixture-based regression"]
    Desktop --> TFMTests["TFMTests integration or rendering regression"]
    Mobile --> TFITests["TFITests integration or rendering regression"]
    FrameworkTests --> Scope["Run focused suite then affected target"]
    TFMTests --> Scope
    TFITests --> Scope
```

This flow selects the narrowest test target that owns the behavior, then expands validation only as the affected product surface requires.

## Suite ownership and seams

### Shared frameworks: durable rules and ports

Use `FrameworkTests` for behavior intended to remain identical across macOS and mobile: value/rule behavior, repository and persistence adapters, migration compatibility, settings synchronization, host-key policy, and presentation-independent controllers. These tests should normally run with deterministic in-memory state or a temporary directory and should not import an app target.

Persistence tests are compatibility tests, not just encode/decode checks. `PersistenceCompatibilityTests` opens historical fixture stores through `TermindPersistence.makeContainer`, verifies retained records, checks migration outcomes, and confirms independent in-memory containers expose the full shared schema. The seam is the public `@MainActor` container factory in Persistence: it configures the V52 schema with the migration plan and `cloudKitDatabase: .none`, taking either a disk URL or `inMemory: true` (not both). The platform entrypoint chooses the storage and retains the container; tests should create a fresh container for independent in-memory state and a temporary disk URL for reopen checks. When changing a SwiftData model, migration, or repository behavior, cover the old-store input and the post-migration contract; do not limit coverage to a newly created store.

Checked-in `FrameworkTests/Fixtures/V1.store` and `V14.store` also check that stores created under the original app module open with their group (and V1 provider) intact. The fixed `FrameworkTests/Fixtures/V28.store` covers the installed-store regression that produced CoreData `134504` when V28 was missing from the migration plan. `Scripts/generate-v28-fixture.swift` records source commit `0dc173d4b1d190071d35bc66f80ebb767d8b950c` (the parent of `b0d35d24`) and schema checksum `hh/HY7td7OFShC/UhxiuwAlJuf8IZOWsZm7U7VqLaSs=`. It must run against that historical Persistence framework: reconstructing a store from current models could hide a changed historical checksum. The checked-in store contains only synthetic data, with WAL contents consolidated through SQLite's backup API.

`version28FixtureMigratesAndReopensWithoutLosingData` copies that store to a temporary directory, migrates through V28→V30→V31→V34→V35→V36→V37→V38→V39→V40→V41→V42→V43→V44→V45→V46→V47→V48→V49→V50→V51→V52, releases the container and opens it again. Both passes check host/group values, GB18030 charset, identity/password-storage/key references, ordered environment variables, startup snippet, Known Hosts, connection history and installation-ID backfill, plus workspace defaults. V25/V26 defaulting, V27, V30 and V31 migration checks remain alongside it. V35→V36 drops the retired history importer table while retaining native History on reopen; V36→V38 adds cloud-presence and delete-handoff state; V39 adds assistant model selection, V40 removes the retired per-category quarantine tables while retaining scoped quarantine, V41 adds shared notification preferences, and V42 adds agent-message and conversation provenance plus collaboration delivery receipts. V43 adds MCP OAuth configuration, V44 updates the Host model, and V45 adds SSH Security Key metadata, and V46 adds terminal keyword-highlight preferences. A V41→V42 disk migration fixture checks that existing groups survive and the new collaboration sidecars start empty; separate collaboration fixtures verify monotonic delivery receipts across SwiftData contexts and creation relations after disk reopen. V29, V32 and V33 stay absent from the migration plan.

On macOS, a separate `PersistentStoreLockTests` seam checks the **lifetime around** that factory, not merely successful SwiftData open. For a disk configuration `makeContainer` acquires an advisory lock on a stable `.lock` sibling **before** `ModelContainer` can open or migrate the store; a failed lease throws `PersistentStoreAccessError.inUse` without touching even a sentinel store or creating its WAL. A canonicalized URL (including symlink aliases) shares one process-local lease across simultaneously open containers; Objective-C association keeps it alive until the last container closes. The lock file stays on disk; closing the descriptor releases the kernel lock, including after forced termination. The tests hold and release real containers, use an independent Python `flock` process to simulate contention and forced exit, reopen to verify Vault host/key records, and check that other store URLs and in-memory containers do not contend. The desktop `DatabaseStartupGuardTests` exercises the separate compatibility guard: before opening a real store, the app refuses another running instance of its bundle even if that older instance does not acquire the new lock. These tests do not simulate a true crash during migration or guarantee that other platforms implement the macOS lock.

```mermaid
sequenceDiagram
    participant App as macOS startup
    participant Guard as Startup guard
    participant Factory as Container factory
    participant Lock as Store lock
    participant DB as SwiftData
    App->>Guard: Check other app processes
    Guard-->>App: No other instance
    App->>Factory: Open disk container
    Factory->>Lock: Acquire lease before database access
    Lock-->>Factory: Lease acquired
    Factory->>DB: Open or migrate V52 schema
    DB-->>Factory: ModelContainer
    Factory-->>App: Container retaining lease
```

The two desktop startup checks precede database access; in-memory containers bypass the file lease.

Agent replay persistence demonstrates the same principle for durable runtime state: an in-memory `SwiftDataAgentRunRepository` must restore frozen context and tool result projection without duplicating replay backing across subsequent snapshots, and deletion must remove that backing. A fixture should deliberately model the timing boundary it protects—for example, recording a tool result before the following run snapshot—rather than requiring a live provider. Replay tests additionally verify that a queued cancellation adopts an edited staging turn with its authored text, images, attachments and frozen context in a fresh SwiftData context; a captured configuration failure adopts only after the failed snapshot saves. A synthetic V15 store reloads without inventing historical context or replay rows.

Hardware-key compatibility belongs at both the shared and mobile seams. `WebAuthnVaultMetadataTests` uses a `NoKeychain` that throws on secret access: connection preparation resolves destination and jump security-key metadata without Keychain reads; an in-memory Vault save and V2 envelope round-trip apply into a **second** in-memory container, retaining external storage and editable verification preference. Legacy hardware storage decodes as external, while a software key cannot claim external storage. A throwing persistence port verifies failed upserts/deletes leave the prior key untouched; a synthetic V44 disk software-key store migrates through V45 to the current schema and reopens twice. These tests do not exercise a physical authenticator or CloudKit delivery. `MobileVaultFeatureTests` covers the actual mobile editor and app assembly: WebAuthn generation/import, invalid reference rejection, Keychain-independent metadata versus software-key private material and saved passphrases, host duplicate/group cleanup and forwarding edit behavior. Use its in-memory app fixtures for mobile editor semantics, the shared metadata suite for wire/schema/security invariants, and `MobileHardwareKeyEditorRenderingTests` for a deliberately opted-in key-window check.

### Assistant history: compare live state, backing rows and restore

A message edit inside one run needs a fixture such as `opening → assistant/tool batch → steering → assistant/tool batch`, not just one user turn per run. The regression boundary spans several owners:

- `AgentPersistenceTests.sameRunTruncationPreservesThePrefixAndAtomicallyAdoptsTheReplacement` uses equal timestamps and deliberately reversed UUID order. It restores a compacted conversation through the production store and operations, then checks the retained prefix, neutral completed summary, title, attachments, replay rows, invocations/results/reviews and compaction bases. A legacy prefix invocation has no stored source ID and a later timestamp; its known call ownership must still preserve it and restore its source message ID. This fixture does not seed an unknown native-tool-like invocation at the cutoff; do not infer that coverage from the prefix case. Real running/completed snapshots must adopt staging once without changing historical owners, and late old snapshots/events must not regrow the suffix.
- `editingALaterRunOpeningKeepsAnEarlierEmptyRunBeforeTheReplacement` checks an earlier retained run with no messages and a replacement clock older than the retained run. Live and restored staging order must agree. Ordinary replay fixtures give genuinely later runs a later start time instead of relying on random UUID tie order.
- Shared `AgentReplayPersistenceTests` parameterizes the first real replacement snapshot as `.failed` or `.interrupted`. It checks the single surviving message/run/replay backing and reloads with a new `ModelContext` and repository over the same in-memory container to verify provenance, terminal state, failure and frozen context. This is fresh-context visibility, not a disk-relaunch test.
- `ChatComposerStateTests.editingSteeringKeepsCompactedSameRunPrefixAndLegacyToolOwnership` checks full visible-prefix retention even when model history is compacted, alongside tool cards, title, plans, compaction records/marks and run-summary chronology through `runStarted`/`runFinished`. Mobile's `swiftDataRestoreAndEditPreserveASameRunPrefixOnMobile` exercises the same repository/store/operations path and compares live and restored message ownership.

Application error and timing fixtures complement those real SwiftData checks. `AssistantConversationOperationsTests.invalidReplacementNeverCallsPersistence` rejects a non-user replacement without invoking truncation; `truncationFailureLeavesInMemoryHistoryUnchanged` throws from a rejecting repository and keeps both visible messages and transcript unchanged. In `AssistantExecutionControllerTests`, `manualCompactionIsRefusedWhileRunPreparationIsActive` holds the memory snapshot barrier and verifies no compaction activity starts; `editFailurePreservesHistoryButUsesTheSynchronouslyCapturedReplacement` checks that rejected truncation preserves history while the attempted replacement retains captured host and plan context. `cancellationAfterSuccessfulEditAdoptsTheInterruptedRunProvenance` holds memory preparation after the edit commits, then checks that the interrupted real run owns the replacement rather than its staging ID. These port-level failure seams do not inject disk-full or read-only failure into a real SwiftData transaction; its rollback path must not be described as fault-injection tested. The repository's truncation catch does call `context.rollback()`, restores its previous `deletedRunIDs` fence and rethrows. `AgentPersistenceTests.truncationRejectsAMessageOutsideThePersistedConversation` separately checks a real persisted-target rejection leaves the original message intact; it is not a failing-save test.

Use the boundary that the assertion needs as its wait condition. `beginFailedRunPersistence` constructs a failed snapshot and starts a repository-save task, but keeps preparation active and does **not** project `.failed` into the live conversation until `save` succeeds; on save failure it appends an error message instead. `missingModelFailureStaysOwnedUntilSaveAndAllCancellationPathsJoinIt` and `missingCredentialAfterMemoryPreparationProjectsOnlyAfterSaveCompletes` block the first save and verify stop, cancellation, and projection ordering. `credentialAddedAfterCaptureDoesNotReviveTheTurn` and `selectingAnotherConversationDoesNotCancelPreparation` check live `.failed` after preparation and additionally wait for the recording repository's failed snapshot. The fixture's `waitUntilSnapshot(state:)` checks existing snapshots or suspends an actor-owned continuation; `save` records the attempt before resuming matching waiters. A recorded attempt is **not** proof of a completed save: use `completedSnapshots` or the joined preparation where completion is the contract. This does not prove durability across the separate queued-runtime immediate-stop handoff.

```mermaid
sequenceDiagram
    participant User as Conversation
    participant Controller as Assistant controller
    participant Repo as Run repository
    User->>Controller: Send captured turn
    Controller->>User: Mark failure persistence in progress
    Controller->>Repo: Save failed snapshot
    alt Save succeeds
        Repo-->>Controller: Completed
        Controller->>User: Record failed run and retire preparation
    else Save throws
        Repo-->>Controller: Error
        Controller->>User: Append assistant error and retire preparation
    end
```

The captured preparation-failure boundary is the repository save, not merely entry into the recording fixture's `save` method. The real SwiftData queued-cancellation fixture additionally asserts **zero provider calls**, one `.cancelled` real run, removal of the staging summary, captured payload restoration and `.fullAccess` persistence. Both queued cancellation and captured configuration failure check that the real run starts no earlier than staging, finishes no earlier than its start, and bounds the replacement's message clock. Wait on `stopAndWait()` before constructing the fresh repository; a live cancellation flag alone does not establish completed persistence.

`archiveAndDeleteWaitForCapturedFailurePersistence` additionally waits on the blocked save before mutating metadata or deleting the conversation. `capturedFailureSaveOutlivesReleasedControllerAndConversationHandles` releases both external references while the save is held, then checks completion before they deallocate. These tests protect ownership through the persistence handoff, not process-crash durability. The controller's `failedReplacementSaveCannotBeSupersededOrMutatedBeforeItCompletes` holds a failed-run save after truncation: edit/fork cannot bypass the pending preparation, and after release the failed real run takes the replacement's ownership. `failedSnapshotSaveRetiresPreparationWithoutAdoptingStaging` injects a save error at the repository port instead: the staging owner remains, no failed summary is adopted, an assistant error appears, and no save completes. When changing edit/cancel ordering, also run `cancelledPreparedEditCannotEnterHistoryMutation`, `supersededPreparedEditCannotEnterHistoryMutation`, `cancellationDuringEditJoinsHistoryWorkBeforeRecordingInterruption`, and `supersededPreparationIgnoresAnOlderCancellationCompletion` to keep stale operations from mutating the new history.

### CloudKit compatibility: test prohibited uploads, not just decoding

The safety fixture substitutes only the CloudKit transport. It uses the production Vault, History/Device, Settings and Metrics coordinators, journals, record coding, synchronous batches and final record providers. The same cases run for all five record families (Vault, History, Device, Settings and Metrics):

- Receive a future-format record with a pending local edit and verify its original bytes and pending intent survive, while a compatible peer still reaches the outgoing batch.
- Feed already-queued saves and deletes through the batch seam; neither may bypass the record restriction. Physical deletion, tombstone re-observation and recreation races have separate cross-category coverage in `CloudSyncPhysicalDeletionTests`: keep handed-off incarnations distinct from newly created ones, avoid stale acknowledgements, and persist delete-handoff causality through a disk reopen.
- Return an unsupported `serverRecordChanged` record, then retry and pause/restart without removing the restriction.
- Compare fetched winners with older or same-version losing records: only a winning fetch clears the pending journal, engine queue and stale batch snapshot. Inject a pre-save failure to prove that data/journal mutation and quarantine removal roll back together.
- Distinguish malformed payloads from recognized newer formats in status hints. Ignore unknown record types on ordinary fetch, but validate a conflict returned for an attempted known record ID.

Disk-backed `CloudSyncSafetyPersistenceTests` separately create synthetic V30 and V39 stores and open them through the current V52 container, traversing V40 retirement of per-category quarantine tables. V30 retains an existing group and adds the scoped quarantine schema; V39 inserts retired per-category rows and a current scoped block, then checks group, scoped block and cloud-presence state after migration. It does **not** assert import of legacy quarantine payloads into scoped quarantine. The interrupted-fetch fixture runs all five record categories: it begins a fetch, receives an unsupported record and stops before `didFetchChanges`; a fresh disk container must still find the original quarantined bytes, recovery fence and pending journal intent. The blocked record stays out of outgoing entries while one compatible peer remains uploadable. Deletion-handoff sidecars are also reopened. The five-category journal test checks that identical upload acknowledgements and system-field updates do not dirty SwiftData, but actual state transitions do; redundant writes should not be mistaken for progress. Scope tests vary container, environment, account, zone and owner independently.

`CloudSyncLifecycleTests` is a separate deterministic **port-level** fixture, not a disk store or live CloudKit test. Its `LifecycleFixture` wires `CloudSyncLifecycle` to an in-memory journal, fake `CloudSyncTransport`/`CloudSyncEngineSession`, injectable save/lookup failures and continuation gates. `start` first commits a recovery fence, checks account and zone, creates the engine, reconciles pending mutations, then completes a fetch before authorizing sends; a failed first fetch retains the fence, and retry on the same engine only sends after a successful fetch. Overlapping explicit fetch/send transitions retain recovery until both finish; automatic fetch-failure callbacks likewise keep uploads closed. Retirement invalidates late operations and delegate callbacks; failed persistence or lookup must not turn into an authorized upload. The suite additionally verifies detached fetch/send and cancellation do not inherit the CloudKit delegate task-local context, a shared 250-item limit across saves and deletes, refusal of unjournaled deletes, and no quota consumption by invalid pending changes. These are controllable contract checks, not evidence of delivery by iCloud. For zone purge or encrypted-data reset, start with `CloudSyncPhysicalDeletionTests.destructiveZoneReasonsPurgeOnlyTheActiveReplicaAndCannotResendOldSnapshot`: it checks active-scope projection/safety cleanup and no resend while preserving another account's fence. `assetPurgeFailureRetiresSyncAfterDurableProjectionPurge` covers the failed-cleanup boundary.

Connection-history coverage adds a V31-to-V34 disk migration, History native-field/merge/tombstone tests, event start/end lifetime checks, stable local-device filtering and deterministic retention of 250 stored events. Migration and sync tests also verify the independent generic device directory: old events receive the installation ID, a separate `DeviceRecord` is created, and changing that record's name updates resolution without rewriting events. Desktop tests distinguish local Welcome Recents from the 100-row all-device sidebar projection. Mobile tests distinguish local per-Host Recents and host-only quick actions from the 50-event Vault History page, including preferred SSH/Telnet activation, disabled protocol actions, device-name search and multilingual light/dark screenshots. Serial remains outside the connection-history enum and mobile workspace routes. `MobileConnectionPickerTests` is serialized. Picker model, latest-five local-host deduplication, protocol availability, disabled historical events, 50-event page and Telnet workspace assertions do not make a key window. The multi-host picker navigation test explicitly gates on `TERMIND_MOBILE_UI_TESTS`; the toolbar navigation tests also create a key window through `withNavigation` but currently have no such test condition, so do not assume the whole suite is skipped by default. Test notification-preference behavior independently in `NotificationPreferencesTests`: a held authorization request is made only once across concurrent scenes and reactivation, disabled or bell-only preferences avoid the initial system authorization request, and failed preference load must not request permission using defaults. Its in-memory Settings sync fixtures check notification-record round-trip, remote update without echo, stale-version rejection and tombstone reset; a synthetic V40 store upgraded through V41 reopens with new notification preferences while retaining prior workspace preferences. These do not request production notification permission or test CloudKit delivery.

The same direct V31-to-V34 fixture verifies that removing Identity usage metadata preserves Identity configuration and its independent Vault journal modification date, and that workspace preferences bootstrap with defaults. The V35 store fixture confirms retired importer removal and native History/Device continuity on repeated open. V32 and V33 are not distributed migration endpoints.

These tests do not prove unknown-field round trips through an actual historical binary, Production schema deployment, or signed-device delivery. Keep those checks in [CloudKit Release Readiness](../operations/cloudkit-release-readiness.md); a fake transport passing is not evidence that iCloud has delivered a record.

### macOS: composition, security, and resource lifetime

`TFMTests` owns desktop composition and native interaction seams. `ArchitectureBoundaryTests` is an executable source-boundary check, not a compiler-enforced dependency graph. Its restrictions are **per module**: Domain excludes platform UI, storage, networking, security and commerce imports; `TermindApplication` excludes implementation-framework imports, SwiftData and concrete I/O construction; macOS `Features` excludes persistence/transport imports and concrete constructors. Mobile `Application` excludes UI, SwiftData, GRDB and Persistence; mobile `UI` excludes Persistence and RemoteInfrastructure; mobile `Features` excludes concrete I/O construction. Shared frameworks cannot import app targets or platform-only APIs, `TermindPersistence` cannot import infrastructure, and `TermindPresentation` stays clear of platform, storage, StoreKit and implementation imports. Apply the corresponding rule when adding a module or relocating code, rather than assuming one blanket prohibition applies everywhere.

The suite also keeps `StoreKit` out of the Infrastructure commerce adapter, confines Firebase SDK imports to Infrastructure, and checks production plists start with diagnostics collection disabled. Its targeted source checks keep forwarding/authentication ownership out of broad UI/app layers and require additional-connection owners to retain reference-only snapshots rather than full connection configurations. It additionally scans for `@Model` outside Persistence and uses the SwiftSyntax-backed `Scripts/swiftdata-repository-declarations.sh` parser to reject **declarations** of `SwiftData*Repository` elsewhere without mistaking references, strings or comments for ownership violations. It checks app-local `AppStrings` redeclarations and a bounded list of AgentKit-owned type names, limits `ListViewKit` imports to approved native-list workloads, and keeps the forwarding benchmark independent of the app/test target. It scans CloudKit delegate files for lifecycle batch/provider/quarantine/conflict calls, and checks that `CloudSyncLifecycle` keeps its 250-record boundary without SwiftData or Persistence imports. These are source-level guardrails (mostly literal import/token checks), not proof of runtime behavior: run the CloudKit safety and lifecycle fixtures for blocked uploads and recovery. Run this suite when moving code, changing dependencies or persistence ownership, or crossing AgentKit and CloudKit boundaries.

Security-sensitive tests should make the boundary explicit with a memory secret store and an authentication responder, never production secrets. `AgentHostAuthenticationTests` verifies that one-use credentials can configure an SSH/SFTP attempt without mutating the Vault unless saving was requested; it also covers route-order prompting for a jump host and destination, prompt/connection coalescing for concurrent work, cancellation before SFTP opens, rejected-credential retry, and stale authentication generations. These are safety contracts: a future refactor must not persist an ephemeral secret, merge unrelated challenges, or let an old callback erase newer authentication state.

`RemoteSessionAuthenticationContinuationTests` covers shared SSH/proxy continuation ordering: credentials stage before the model’s save policy, failed saves never connect, proxy submissions use the entered trimmed username, and disconnect clears one-use maps. `RemoteSessionConnectionControllerTests` holds retry sleep to check teardown before journey/retry, cancellation on disconnect, route → library → temporary-destination host lookup, and rejection of progress from replaced or cleared attempts. These deterministic tests do not open real connections.

The complementary shared `SSHInteractionPolicyTests` covers noninteractive follow-on connections. An `SSHAdditionalConnectionSnapshot` retains route and authentication references rather than credential material, and an interaction-forbidden request must not surface host-key or keyboard-interactive UI. Protected-key credentials become an interaction-required marker while a password fallback remains usable; runtime `SSHSecret` values are consumable once and clearing a copied connection configuration invalidates every credential copy.

SFTP transfer tests use a controlled `TransferChannelHarness`, a `TransferChannelClient`, and temporary files instead of a real server. They establish lifecycle and scheduling behavior that is easy to regress in UI work:

- Closing a desktop pane releases its UI ownership but lets queued transfers retain the authenticated connection until work completes; cancellation releases the final connection.
- A silent independent connection is donated when available. If it requires interaction, upload falls back to the PTY connection; it must not fall back after cancellation or a retired generation.
- Scheduler capacity remains bounded across contexts for the same host. Fallback from extra connections to sibling channels does not increase capacity, and a PTY fallback does not retry independent connections for large files.
- Additional connections use the forbidden interaction policy, so detached/background work cannot open an authentication prompt.

Those tests are intentionally actor-driven and use polling only to wait for observable harness state. Prefer this style for races: hold the transfer at a known point, make the ownership transition, then release it and assert the terminal state and disconnect count.

For tool-card changes use `AgentToolPresentationTests`: the registered tool's argument projection appears in approval detail (including submitted command/input, not a claimed secret-redaction guarantee), while unknown tools get generic fields. Check the composed AgentKit-plus-Termind presenter ID catalog for collisions, restored and legacy cards for equivalent detail, and old descriptor metadata for safe defaults before relying on a new presentation field. Batch and long-output fixtures cover mixed lifecycle states, Unicode preview bounds and full-copy content; avoid replacing structured detail with an untested JSON string.

For Ghostty menu changes, test the app seams: `TFMTests/TerminalContextMenuTests.swift` checks AppKit blank-space and selection menus, Paste on Right Click/Option behavior, live upload availability and late pane teardown; `TFITests/MobileTerminalUploadMenuTests.swift` checks the native Photos/Files group and disabled states. The mobile suite also checks localized editing actions before Upload and system AutoFill, for both unselected and selected menus. It is serialized but constructs menus offscreen, without a key window or the mobile UI gate.

Package gesture/selection validation remains a separate **upstream-package step**, not locally inspected or executed coverage here. Ghostty comes directly from `Lakr233/libghostty-spm`; there is no local maintenance submodule to initialize. Inspect the selected package's source/tests for direct-touch, indirect-pointer and dispatch behavior rather than assuming the removed fork's paths. Termind owns grouping/localization through separate `touchMenuItems(for:)` / `touchSelectionMenuItems(for:)` overrides; app composition tests do not establish package internals. See [Ghostty Terminal Integration](../concepts/ghostty-terminal-integration.md) and [Ghostty Dependency Updates](../operations/ghostty-fork-maintenance.md).

For MCP upload changes use `MCPUploadTests` with the real coordinator and streaming operation, a fake SFTP client and controlled clock. Protect ticket/run scope and capacity, acknowledged-offset resume and full digest, bounded streaming/backpressure, timeout/cancellation and cleanup residue, revocation on disable, conflict policy and queryable terminal status. `actualHTTPRouteStreamsAboveTheMCPBodyLimit` additionally runs a loopback HTTP server for fresh and resumed bodies larger than the ordinary MCP limit; a passing fake SFTP upload does not establish interoperability with a real remote server.

### Mobile: app state, scenes, and device-local restoration

`TFITests` owns `MobileAppModel` composition and mobile scene behavior. Mobile app tests build `MobileAppModel(inMemory: true)` or supply dependency seams, which permits assertions over the actual shared schema and repositories without using the user's database or Keychain. Representative tests verify that scenes share durable conversations while navigation, selected conversation, and composer drafts stay scene-local; shared SwiftData history is observable from fresh repositories over the same container.

`MobileAppTests.startupLoadsVersion28DataAfterMigrationAndRelaunch` uses the same historical V28 fixture, explicitly included in the TFITests resource phase. It constructs the app twice with a disk container supplied through `MobileAppDependencies.testing` and verifies host, charset, identity reference and history projections. This covers migration plus app initialization and reopening; it is an in-process integration test, not an automated device installation or OS process relaunch.

External connection URLs are another ownership boundary: opening one creates an ephemeral workspace and does not create a Vault host or saved workspace descriptor. Conversely, closing all workspaces disconnects each live workspace and is repeatable. Background-expiration tests provide a controlled connection service and cover resume intent, foreground recovery, and rejection of retired callbacks. A lifecycle change must preserve the appropriate one of these contracts rather than merely asserting that a view updates.

`MobileWorkspaceStoreTests` protects the device-local restoration format. The store contains connection intent only—workspace descriptor identity, host reference, title and kind—not credentials, commands, duplicate indices or live session state. Its current v2 snapshot maps persistent scene session IDs to descriptor lists and holds legacy unassigned descriptors until ownership is bound. It reads legacy arrays and v1 `workspaces` into `unassigned`, preserving IDs, titles and kinds while ignoring legacy duplicate indices; **load does not rewrite bytes**. `MobileAppModel.workspaceSession(for:)` consolidates unassigned and prior-session descriptors into the first native scene, saving the whole snapshot before accepting ownership; a failed save fences that scene from claiming the records. The store rejects malformed or unknown-version data, empty session keys and duplicate descriptor IDs across owners. A failed load blocks later saves until a successful load; invalid saves leave previously valid bytes unchanged. Startup reports unreadable restoration data without overwriting it on later workspace mutations. App-level restoration tests check dormant order across launch, lazy one-time activation and owner routing, removal on close/host deletion, and that reopening does not replay a snippet or initial directory. These are in-process launch simulations with injected connection services, not an OS relaunch. Add a format-transition and corruption fixture when changing the snapshot: silently replacing unreadable restoration data with an empty list loses recoverable user state.

```mermaid
flowchart TD
    Bytes["Saved device-local bytes"] --> Load{"Store load valid"}
    Load -->|No| Fence["Report error and block saves"]
    Load -->|Yes| Pending["Keep unassigned and scene descriptors"]
    Pending --> Bind["First native scene binds all descriptors"]
    Bind --> Save{"Whole snapshot saved"}
    Save -->|No| Fence
    Save -->|Yes| Dormant["Restore dormant workspace entries"]
    Dormant --> Select["Explicit selection opens connection"]
```

The restoration fixture tests the save-before-ownership boundary separately from explicit live connection activation.

`MobileWorkspaceSessionTests` isolates scene-session routing with an injected app fixture: assistant notification targets prefer a matching active scene and otherwise keep a hidden owning scene rather than hijacking another scene's selection; transfer clicks wait for scene activation and are consumed once. Additional router cases check that newer assistant clicks win and that stale activation-failure callbacks cannot reset a newer request. A matching owner can be activated without displaying its conversation prematurely; these are routing/model checks, not UIKit presentation assertions. Use these model/router tests for navigation ownership before reaching for a key-window test. `MobileBackgroundControllerTests` replaces UIKit's background-task platform to drive expiration synchronously. The tests check stale/repeated callbacks end each lease at most once, reentrant expiration during `begin` retires the returned old identifier without overwriting a newly begun lease, and an invalid identifier expires once without an `end` call. Use these for lease mechanics; `MobileAppTests` covers foreground recovery and retired workspace callbacks at the app boundary.

`MobileCardTests` exercises card policy offscreen: adaptive column thresholds and accessibility sizing, bounded tag display and stable card heights measured with `UIHostingController.sizeThatFits`, plus in-memory app/repository checks for saved-host timestamps and host/identity/key draft-color persistence. These tests do not call `makeKeyAndVisible`. Use the separately serialized `MobileCardRenderingTests` for screenshot output: its `TERMIND_CARD_SCREENSHOTS` guard returns without capture by default, and the capture path creates and restores a key `UIWindow` across English/Chinese locales and light/dark appearances. Run that suite only with its screenshot opt-in and parallel testing disabled; offscreen sizing is not a substitute for key-window interaction coverage.

### Terminal Find and mobile search: cancellation is a lifecycle contract

Start with always-on `FrameworkTests/TerminalFindControllerTests.swift`. It injects binding-action and focus closures rather than Ghostty or UIKit. The retained-query test checks the actual search/navigation/end action sequence and one focus return across dismiss/reopen. Empty-query navigation opens Find without issuing a navigation action. The shared native-dismissal regression calls `dismiss(restoringFocus: false)` twice: Find closes, emits exactly one `end_search`, and never requests terminal focus. Reopening restarts the retained query; a later ordinary dismissal returns focus once. This protects idempotence and responder ownership, not just fixture values. Resize tests suspend engine search while retaining UI state, edit the query during suspension, resume only the latest query, suppress navigation and ensure closing during resize cannot reopen search.

The production seam is `TerminalFindController`: it retains query independently of presentation, restarts a nonempty query on a closed-to-open transition, and ignores dismissal when already closed. `MobileWorkspaceSearchModifier` binds SSH/Telnet search to that controller and translates native closure into `dismiss(restoringFocus: false)`; SFTP binds directly to `sftpChannel.query` instead. The workspace supplies Ghostty binding execution and terminal focus through closures.

UIKit's `MobileToolbarSearchController` owns one `UISearchController`. Configuration defers synchronization out of the SwiftUI update; during dismissal it blocks presentation synchronization and text/submission callbacks until `didDismissSearchController`. Cancel resigns the search responder and publishes closed presentation before deactivation. This prevents a SwiftUI update from reopening the integrated toolbar mid-dismissal or erasing the retained query. Keep that lifecycle boundary intact rather than replacing search controllers to reset them.

```mermaid
sequenceDiagram
    participant Native as Native search UI
    participant Bridge as Toolbar search bridge
    participant Find as Terminal Find controller
    participant Surface as Terminal surface
    Native->>Bridge: Cancel search
    Bridge->>Bridge: Mark dismissing and resign responder
    Bridge->>Find: Publish closed without restoring focus
    Find->>Surface: end_search once
    Bridge->>Native: Deactivate search
    Native->>Bridge: didDismissSearchController
    Bridge->>Bridge: Allow synchronization again
    Find->>Surface: Restart retained query on next presentation
```

Native dismissal owns the responder transition; shared Find ends search without competing for terminal focus.

Run the separately **serialized, opt-in** `MobileTerminalSearchIntegrationTests` (declared in `TFITests/MobileTerminalSearchTests.swift`) only for the UIKit seam:

- SSH Find is opened and closed three times for native Cancel, programmatic dismissal, and terminal-focus-then-native Cancel. Assertions check active state, first responder, retained text and model presentation; clearing text must leave Find presented before re-entering the query.
- SFTP filtering closes and reopens three times with its retained filter. Clearing the filter must not deactivate search, and cancellation must release the responder without clearing `sftpChannel.query`.
- SSH and SFTP journey begin/hide transitions keep the **same** search controller, active text while the journey appears, and closed state after cancellation. SSH additionally retains the same attached terminal view and can reopen Find with its query after the journey hides.

Its fixture uses an in-memory app, a standalone workspace and a key `UIWindow`, mounts the production search modifier and SSH terminal surface, restores the prior key window and disconnects on teardown. The journey fixture simulates its overlay and uses a text projection for SFTP, not the full file browser. A separate full-`MobileWorkspaceView` SSH fixture repeatedly reopens Find with empty, matching and missing queries and checks native surface, output and upload generation retention. Cancel is invoked through the search-bar delegate and UIKit settling uses timed waits. These are native presentation regressions, not real SSH/SFTP connection or physical button-tap tests.

`MobileWorkspaceMenuTests` is also serialized and gated by `TERMIND_MOBILE_UI_TESTS`. It resolves native menus in a key window to verify opened/dormant workspace order in title and icon switchers, removal of conversation unread indicators after reading, and lifecycle actions: Rename is nondestructive, Close is destructive, and a separately grouped Close Others appears only when multiple workspaces can close; Close All is absent. Use it for observable menu changes, not as a substitute for search lifecycle or scene-routing tests. See [Mobile UI](../architecture/mobile-ui.md) for presentation ownership and [Engineering Invariants](../architecture/engineering-invariants.md) for safe-change rules.

### Native Metrics connection journey: distinguish policy from presentation

For a keyboard-interactive Metrics change, run the shared `FrameworkTests/MetricsJourneyTests.swift` and `MetricsKeyboardInteractiveTests.swift` for connection/prompt ownership before spending a native window run. `TFITests/MobileMetricsJourneyTests.swift` instead mounts the real `MobileRootView` and Metrics detail in a **key** `UIWindow`, using an injected actor `MetricsSampling` implementation to issue a two-field PAM-style challenge without opening SSH. It checks that the prompt stays in Metrics across detail navigation and compact/regular widths, does not become a segmented control or a separately presented controller, retains its challenge through navigation, survives accessibility text, and on field submission returns to live Metrics with exactly one connect and the submitted answers. It captures English and both Chinese locales at multiple widths and large type into attachments and a temporary directory. The corresponding macOS `MetricsJourneyRenderingTests` is explicitly `.requiresVisibleWindow` and checks the local Metrics route versus external authentication, detail resizing and Escape cancellation in a key `NSWindow`.

The mobile Metrics suite is `.serialized` and **key-window-gated** through `.requiresKeyWindow`. First use deterministic shared tests, then explicitly run `TFITests/MobileMetricsJourneyTests` with `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1`, an available simulator and parallel testing disabled. Without `TERMIND_MOBILE_UI_TESTS=1` in the host these cases are skipped; default green results do not establish native presentation. `MobileConnectionJourneyRenderingTests` uses key windows but gates the entire serialized suite, including interactive authentication, with its separate `TERMIND_JOURNEY_SCREENSHOTS` opt-in. These native tests validate presentation and injected challenge handoff, not real SSH/CloudKit delivery.

### Mobile settings ports: prove propagation and rollback without a cloud engine

`MobileSettingsPortTests` constructs `MobileAppModel(inMemory: true)` and tests that changing shared SFTP preferences updates transfer limits and strategy immediately—even without opening Settings—and that an applied remote snapshot updates the same coordinator. The small direct `SFTPTransferCoordinator` test verifies invalid limits clamp to usable values. The test app's active scene must not start Vault, History, Device or Settings cloud engines. For provider editing, injected `AISecretStoring` and `AIConfigurationPersisting` failures show that a failed secret write leaves the draft and avoids metadata persistence, and a metadata failure restores the previous secret. A concurrent model refresh survives editing, remote deletion cannot be resurrected by an open draft, and controlled discovery ignores a late response after cancellation or provider deletion. Run these ordinary, no-key-window tests before any settings UI rendering suite.

### Context accounting: compare an incremental projection with its reference

Run `AgentTokenUsageTests` when changing provider usage parsing or the context gauge. Cached input is a subset of the total for OpenAI/Google, but Anthropic's input total adds cache-read and cache-creation counts. Empty-choice or absent-candidate usage chunks must still parse; streaming Chat Completions requests ask for usage while buffered requests omit `stream_options`. Cumulative usage merges by per-field maximum rather than summing chunks.

The estimator separates system prompt, schemas, conversation, tool results and attachments. Measured input-plus-output rescales the parts to sum exactly to the displayed total; unknown context windows produce no share and overfull shares clamp to one. `incrementalTrackerMatchesTheReferenceEstimator` compares streaming/upsert, measurement and removal against the reference estimator. `conversationSnapshotTracksAttachmentsHistoryEditsAndUsage` checks the production `ConversationModel` projection after attachments, tool completion, edits, compaction, usage and fork. `composerDraftEditsNeverRebuildTheContextEstimate` protects a different contract: 100 draft revisions over 300 historical messages neither rebuild nor change the estimate. These are accounting and invalidation regressions, not tokenizer accuracy or live-provider billing validation.

### Language migration: verify stored policy and resolved copy separately

Use `AppLanguageTests` without a window gate. Explicit choices write canonical `en`, `ja`, `zh-Hans` or `zh-Hant` to `AppleLanguages`; Follow System removes that override. Legacy Simplified Chinese identifiers migrate both the preference and override to `zh-Hans`. Unknown values and legacy Traditional Chinese preference identifiers remain unchanged and follow system; this differs from **system locale resolution**, where Traditional Chinese regional locales resolve the Traditional catalog. The suite checks separate Chinese fallback, Japanese interpolation, selected-language relaunch notices, ordered forwarding arguments and catalog plural rules. A catalog-only check is not evidence that an already-running native view changes language without relaunch.

### Window close and Quit: independent scopes, independent vetoes

`WorkspaceCloseConfirmationTests` is serialized but **offscreen**: it constructs `NSAlert` and `NSWindow`, injects confirmation results and invokes delegate methods without making a key or visible window. Do not opt it out merely because it uses AppKit. It checks distinct application/window copy, Cancel as Return's default, an explicit destructive second-button response as the only approval, all-registered-window workspace aggregation, and an empty window closing without confirmation. A cancelled window close preserves the workspace and can be retried; the forwarded delegate can independently veto before confirmation, unrelated delegate callbacks forward, and detach restores the original delegate.

Production Quit is owned separately by `TermindApp.applicationShouldTerminate`: it returns `.terminateLater`, asks the application-scoped workspace confirmation, then rechecks pending SFTP edits and may veto again before starting shutdown. A window-close delegate test does not exercise that app termination path. For shutdown ordering, `AppTerminationTests` holds terminal persistence and verifies cancellation of every stored conversation before waiting, then background-command and connection closure after drains, with repeated cleanup occurring once. `SheetApplicationTerminationTests` checks offscreen mounting/moving/removal restores each window's original modal termination policy. Only `SheetQuitInteractionTests` deliberately makes windows key, focuses sheet fields and sends native Command-Q; it is serialized and `.requiresVisibleWindow`, using a cancelling delegate so the test host does not terminate. Use that opt-in for native Quit reachability, not as proof of real production shutdown or remote paywall layout.

## Focused additions: drafts, confirmations and resource retirement

- `SnippetColorTests` checks tolerant legacy JSON, unsaved draft isolation, duplicate color, V1/V2 wire/tombstone behavior and a real V50 upgrade through V51 to the current V52 schema followed by saved-color reopen.
- `RetiredTerminalHighlightingTests` opens V46/V51 disk stores, upgrades/reopens to verify other preferences survive while retired tables and uploads disappear, and ignores malformed legacy conflict/deletion records without blocking active Settings.
- `HostEditorBindingsTests` exercises creation callbacks without changing existing selections, independent SSH/Telnet custom/none choices, proxy default-port transitions and no recreation of a removed proxy.
- `MobileWorkspacePresentationTests` checks importer dismissal-before-result and once-only target consumption, and preview/export sequencing without UIKit windows.
- `MobileOperationConfirmationTests` is serialized and mobile-UI gated; English and both Chinese fixtures compare row anchoring against window-centered arrowless popovers, action order, animated transitions and post-dismissal action timing. It uses temporary windows and restores their predecessor; these are not a real destructive business-operation run.
- `SSHPTYChannelLifecycleWireTests` requires `TERMIND_PTY_LIFECYCLE_FIXTURE` with the Python SSH peer. The peer deliberately leaves exec CLOSE unacknowledged. Tests observe transport closure after explicit disconnect and owner release, and prove a retained SFTP sibling survives PTY release until the final subsystem closes. These are opt-in local wire fixtures, not arbitrary-server coverage.

## Fixture design rules

1. **Inject at the owner boundary.** Use `MobileAppDependencies.testing`, in-memory repositories, `MemoryHostSecretStore`, a responder closure, or a protocol test client to replace I/O while retaining the production coordinator/model. Do not duplicate production policy inside a mock.
2. **Keep fixtures isolated.** Create a unique `UserDefaults` suite and remove its persistent domain in `defer`; use a UUID-named temporary directory/file and delete it in `defer`. In-memory containers must be newly created when isolation matters.
3. **Make adverse timing controllable.** Actor-backed harnesses should count opens, prompts, disconnects, active work, and release signals. This lets a test assert cancellation, coalescing, or teardown deterministically instead of sleeping against a real network.
4. **Assert both state and prohibited side effects.** For security and persistence, verify not only a successful configuration or migration but also that the Vault, original bytes, secret store, prompt queue, or connection count did not change when policy forbids it.
5. **Test boundaries, not file names.** A regression belongs beside the narrowest suite with authority over its observable contract. Add a higher-level target test when framework correctness alone cannot prove platform assembly, lifecycle, or UI behavior.

## UI and visible-window policy

Offscreen layout and logic tests remain ordinary tests. A macOS test that **presents a window or takes application focus** (including Dock actions, external authentication and Launch Services alerts) must opt in with `.requiresVisibleWindow` on its suite or individual test. The trait is a Swift Testing `ConditionTrait`: it enables the test only when the test host sees `TERMIND_WINDOW_TESTS=1`; otherwise that test is skipped. For example, `ChooserInteractionTests` is gated as a suite because it makes its window key, whereas individual integration tests may carry the trait without skipping their offscreen neighbors. Do not mark all rendering tests as visible-window tests: `TFMTests/KnowledgeToolRenderingTests.swift` is serialized without `.requiresVisibleWindow`, whereas `TFMTests/MemorySettingsRenderingTests.swift` explicitly opts in. There is currently **no checked-in macOS or mobile Pro paywall rendering test file**; do not route regressions to `TFMTests/ProPaywallRenderingTests` or `TFITests/ProPaywallRenderingTests`. Conversely, creating a key window or changing focus requires the gate even if the test does not save a screenshot.

Run a named visible-window suite only when its interaction contract changed, for example:

```sh
TEST_RUNNER_TERMIND_WINDOW_TESTS=1 xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test -only-testing:TFMTests/ChooserInteractionTests
```


### Pro paywall: distinguish entitlement state, SDK adapter, and rendering gaps

The desktop `ProPaywallView` and mobile `MobileProView` mount RevenueCatUI `PaywallView` when `ProAccessController.usesRevenueCat` is true, show loading and unavailable alternatives, and pass data-only `ProPaywallState` fields (`pro`, `manage`, `state`, `family`, `dated`, localized `date`) as remote paywall custom variables. They forward purchase/restore start, completion, cancellation and failure to the controller; purchase completion refreshes access while suppressing RevenueCat's immediate dismissal so the account variant remains visible. Neither view renders a shared `ProPaywallContent` or builds a shared offer presentation. The RevenueCatUI dashboard owns the appearance; changing its actual mobile/desktop layout requires new targeted rendering coverage.

`FrameworkTests/ProPaywallStateTests.swift` verifies the shared data contract: lifetime access has no expiry or manage action; purchased versus family-shared subscription ownership and renewal flags determine management and remote state codes; trial and grace retain access, retry/expired/revoked do not; unverified access does not unlock. `FrameworkTests/RevenueCatCommerceTests.swift` constructs synthetic decoded `CustomerInfo` and a fake `ProPurchaseService`. It checks the configured entitlement alone grants access, a stale cached active flag cannot prolong expiry, grace has its own deadline, refunds/unverified information cannot unlock, and test-store keys cannot silently enable production. Controller tests drive update streams, overlapping refreshes, errors and remote paywall completion: a newer update must beat an older response, concurrent refreshes share a request, and completion updates access without dismissing the paywall. These are not RevenueCatUI layout or live checkout tests.



## Change-to-regression matrix

| Change type | Primary regression seam | Required behavior to protect |
| --- | --- | --- |
| Framework dependency or data-owner change | `ArchitectureBoundaryTests` plus affected framework suite | Respect each module's import/construction rules; no app import from shared code, local shadow of guarded AgentKit types, or SwiftData model/repository outside Persistence. |
| SwiftData schema, migration, or durable agent record | Persistence compatibility/replay fixtures; `PersistentStoreLockTests` and `DatabaseStartupGuardTests` for macOS store access | Old stores open, records retain intended values, interrupted timing remains recoverable, and deletes clean backing rows; another instance cannot open or migrate a locked disk store. |
| Hardware-key metadata, Vault wire format, or mobile key editor | `WebAuthnVaultMetadataTests` plus `MobileVaultFeatureTests`; opt-in mobile hardware editor rendering only when interaction changes | External hardware metadata works without Keychain, failed writes preserve state, V44 software keys survive V45, and mobile drafts keep private material out of Vault records. |
| Assistant message-boundary edits or replacement provenance | Agent persistence/replay, conversation operations/controller, composer and mobile Assistant fixtures | Same-run prefix and graph survive, suffix backing is removed, staging adopts once, chronology remains stable, live/restore agree, and late retired writes cannot resurrect history. |
| CloudKit format, upload scheduling, conflict or recovery behavior | Shared lifecycle, coordinator-safety, physical-deletion and on-disk safety fixtures | Unsupported IDs never upload, compatible peers progress, restrictions survive retry/reopen, and failed reconciliation cannot unblock data; stale deletion acknowledgements cannot erase a new incarnation. |
| Notification authorization or synced preferences | `NotificationPreferencesTests` and affected platform settings tests | Concurrent initial authorization is coalesced, disabled/bell-only settings avoid unwanted permission, failed load does not use defaults, remote updates do not echo, and V40 preferences survive V41 migration/reopen. |
| Terminal Find cancellation, retained query, SFTP filter, or search during connection journeys | Always-on `TerminalFindControllerTests`, then opt-in `MobileTerminalSearchIntegrationTests` | Repeated dismissal ends once, native dismissal avoids terminal focus, empty queries stay presented, retained queries reopen, and journey overlays do not replace search or the SSH terminal. |
| Mobile workspace/conversation switchers or lifecycle menus | Opt-in `MobileWorkspaceMenuTests` | Opened/dormant ordering, unread-state updates, destructive action semantics and conditional Close Others remain correct in native menus. |
| Ghostty touch menu customization | Offscreen `MobileTerminalUploadMenuTests` and desktop `TerminalContextMenuTests`; external fork validation after checkout initialization | Editing/Upload/AutoFill order and live availability hold; app tests do not establish fork touch-selection mechanics. |
| Metrics keyboard-interactive navigation or native layout | Shared Metrics journey/prompt tests, then narrowly filtered native Metrics journey suite | Prompt ownership survives navigation/size changes, secure challenge stays inline, single connection submits answers, and key-window runs are deliberate, serialized and nonparallel. |
| SSH credentials, prompts, host trust, or agent authentication | Authentication and interaction-policy fixtures | Ephemeral secrets stay ephemeral, prompt scope/order/coalescing is correct, forbidden work stays noninteractive, and secrets are invalidated after use. |
| SSH/SFTP transfer scheduling or pane/session teardown | `SFTPTransferContextTests` with a controlled channel harness | Concurrency bounds hold, background transfer ownership survives UI teardown, cancellation cleans up, and fallback does not invite interaction. |
| Mobile workspace, scene, restoration, or background lifecycle | `MobileAppTests`, `MobileWorkspaceStoreTests`, and `MobileBackgroundControllerTests` | State is shared or local at the intended scope, external sessions remain ephemeral, restoration is safe, leases retire once, and callbacks cannot revive retired state. |
| Mobile cards or visual presentation | `MobileCardTests` for layout policy plus focused rendering/key-window suite if needed | Container width/accessibility layout and stable heights work offscreen; shared UIKit presentation is opted in and serialized. |
| Tool approval, transcript cards, or presenter metadata | `AgentToolPresentationTests` and affected platform rendering suites | Registry IDs stay unique, legacy/restored detail agrees, and structured detail, preview and copy behavior survive. |
| MCP upload ticket, stream, or HTTP route | `MCPUploadTests` plus affected server/session suite | Authenticated tickets remain scoped; offset/digest/commit and cancellation/cleanup state remain correct through loopback HTTP. |
| Pro paywall status, commerce adapter, catalog or layout | `ProPaywallStateTests` and `RevenueCatCommerceTests`; add focused UI coverage for either platform's layout | Entitlement gates, management variables, refresh ordering and catalog metadata remain correct; no checked-in paywall rendering or live checkout fixture establishes remote dashboard layout, translated copy or button interaction. |
| macOS rendering or focus behavior | Focused offscreen test plus `.requiresVisibleWindow` suite when needed | Offscreen rendering remains default; tests that present windows or take focus are explicitly opted in. |

## Execution strategy

Start with the smallest deterministic regression named in the matrix (for example, `-only-testing:TFMTests/ArchitectureBoundaryTests` for an import move, `-only-testing:FrameworkTests/CloudSyncSafetyTests` for a quarantine change, `-only-testing:FrameworkTests/PersistenceCompatibilityTests` for a schema change, or `-only-testing:TFITests/MobileSettingsPortTests` for mobile preference propagation); then run the affected product target using the resolved package graph. Add physical-deletion, lifecycle and disk-reopen suites when changing CloudKit handoff or recovery. Do not enable window, mobile key-window gates for ordinary framework tests. The default macOS entrypoint runs macOS and shared Swift tests:

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test
```

For assistant edit, restore and accounting changes, begin with these ordinary suites (no native-window opt-in):

```sh
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test -only-testing:FrameworkTests/AgentReplayPersistenceTests -only-testing:FrameworkTests/AssistantConversationOperationsTests -only-testing:FrameworkTests/AssistantExecutionControllerTests -only-testing:TFMTests/AgentPersistenceTests -only-testing:TFMTests/ChatComposerStateTests -only-testing:TFMTests/AgentTokenUsageTests
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test -only-testing:TFMTests/AppLanguageTests -only-testing:TFMTests/WorkspaceCloseConfirmationTests -only-testing:TFMTests/SheetApplicationTerminationTests -only-testing:TFMTests/AppTerminationTests
xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile test -only-testing:TFMTests/RemoteSessionAuthenticationContinuationTests
```

Filter further to the named test method for the first regression iteration. For real sheet focus and native Quit reachability, deliberately enable the host's `TERMIND_WINDOW_TESTS` gate:

```sh
TEST_RUNNER_TERMIND_WINDOW_TESTS=1 xcodebuild -project Termind.xcodeproj -scheme TFM -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO test -only-testing:TFMTests/SheetQuitInteractionTests
```

A skipped opt-in case is not a validated native interaction; verify the test host receives the flag. For mobile changes, build/test the `TFI` scheme against an installed iPhone or iPad simulator. Keep ordinary framework tests separate from key-window opt-ins. For example, run `-only-testing:FrameworkTests/TerminalFindControllerTests` without a UI environment flag first, then deliberately opt in to the native search suite:

```sh
TEST_RUNNER_TERMIND_MOBILE_UI_TESTS=1 xcodebuild -project Termind.xcodeproj -scheme TFI -destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO test -only-testing:TFITests/MobileTerminalSearchIntegrationTests
```

Replace `<SIMULATOR-UDID>` with an installed simulator's identifier. Use the same narrow invocation for `TFITests/MobileWorkspaceMenuTests`, `TFITests/MobileEditorToolbarTests`, or `TFITests/MobileHardwareKeyEditorRenderingTests` when their interaction contract changes. `AGENTS.md` documents the `TEST_RUNNER_TERMIND_MOBILE_UI_TESTS` invocation convention; the suites read `TERMIND_MOBILE_UI_TESTS` in the test host. The checked-in `TFI.xcscheme` includes TFITests and FrameworkTests and uses launch-scheme arguments/environment, but contains **no explicit environment-forwarding entry** for this flag. In Xcode, set `TERMIND_MOBILE_UI_TESTS=1` in the test action environment; verify host visibility if an intended opted-in run skips.

Serialization is suite-local, not permission to run all native suites concurrently. Keep `-parallel-testing-enabled NO` and narrow filters: the currently ungated picker-toolbar and Metrics journey tests need an intentional narrow nonparallel run or a new gate before a default full-suite run is quiet. Retain `-onlyUsePackageVersionsFromResolvedFile`: validation should use the revisions in `Package.resolved`, not silently resolve a different dependency graph. Run strict formatting for Swift changes:

```sh
xcrun swift-format lint --strict --recursive Frameworks TFM TFI FrameworkTests TFMTests TFITests TermindMCPBridge
```

This page complements [System Boundaries and Dependency Ownership](../architecture/system-boundaries.md), [Assistant, Agent Runtime, Skills, and Memory](../concepts/agent-runtime-and-assistant.md), and [Build, Validation, Localization, and Dependency Release Operations](../operations/build-test-and-release.md). The operational page defines the full build and release commands; this page defines what a focused regression must prove before those broader checks are meaningful.

## History split and per-kind evolution

`HistorySyncTests` exercises native CloudKit fields and optional-field removal, independent History/Device selection even in the shared zone, terminal tombstones, ignoring retired Vault importer state, retry after a failed initial fetch, and restoring a missing Device projection without rewriting its journal version. The V35 migration test independently verifies that the retired importer checkpoint is dropped. History sync verifies structured Logging without raw record/account data and treats expected cancellation as lifecycle control; use `CloudSyncLifecycleTests` for overlapping explicit and automatic fetch readiness. `SyncRecordEvolutionTests` freezes literal V1 Host bytes and exercises a test-only Host V3 reader/writer while other kinds remain V1, malformed and unknown formats, throwing encoders, and aggregate status. Persistence tests additionally migrate and reopen V31/V34/V35 stores into the current V50 schema and prepare History state after the fixed V28 fixture migration. These are local protocol and transaction tests, not evidence of deployed schemas or signed-client delivery.

`SessionHistoryTests` verifies snapshot merging, close rejection of late loads and historical store migration after removal of durable command/SFTP history. `SFTPHistoryTests` verifies per-session isolation and late transfer callback rejection. `TailscaleSyncSafetyTests`, `TailscaleHostIdentityTests` and `TailscaleProfileCleanupTests` cover managed identity boundaries, sync exclusion and durable cleanup retry.
