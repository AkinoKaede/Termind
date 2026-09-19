# Settings sync release checks

Master iCloud and Vault/Metrics/Settings selections currently default on (`SettingsKey`); existing explicit choices
survive upgrades. Categories/account state remain independent and Pro-gated. Architecture, local-only fields and
journal rules: [ARCHITECTURE.md](ARCHITECTURE.md). Build success does not establish CloudKit production deployment.

## CloudKit deployment

Private container `iCloud.com.akinokaede.termind`; validate Development schema and deploy to Production:

| Category | Zone | Record type | Subscription |
| --- | --- | --- | --- |
| Settings | `TermindAIConfigurationV1` | `AIConfigurationItem` | `termind-ai-configuration-v1-changes` |
| SFTP settings | same | `SFTPPreferencesItem` | same |
| Metrics | `TermindMetricsV1` | `MetricsItem` | `termind-metrics-v1-changes` |

Vault envelope: integer `formatVersion`, `counter`, `isDeleted`; string `kind`, `entityID`, `writerID`, `payloadHash`;
date `modifiedAt`; bytes `payload`; asset `payloadAsset`. No public database access. Compatibility zone/subscription/
format stay unchanged; SFTP's distinct type lets older clients ignore it before decoding.

**Unverified prerequisite:** the last recorded `xcrun cktool get-teams` check (2026-09-19) had no management token.
Local tests did not prove Production deployment or signed-device delivery. Recheck credentials/deployment at release.

## Signed-device matrix

Use two Macs and an iPhone/iPad on one Apple account, then exercise an account switch:

- Add/edit/delete providers, roles, MCP clients, skills and terminal configuration. Include offline edits, independent
  category/master pause/resume, delayed Keychain delivery, key rotation and Pro expiration.
- Account switch must merge before upload; category choices/account bindings must remain independent.
- Theme/custom terminal text/shell integration should update existing windows. Font family/size/follow-theme-size remain
  **device-local**; distinguish local controls from fonts authored inside synced theme/custom text. Conversations,
  approval mode and local MCP listener enablement/port/tools/token must not sync.
- Before removing an old synchronized MCP token's iCloud Keychain copy, verify the local migrated token works.
- Metrics order/pause/disk/network choices cross platforms; records arriving before their Vault Hosts remain hidden.
- Confirm published privacy policy version/effective date matches the actual release, not an old prepared date.

### SFTP limits

V21 imports existing local limits once (including 3/2); missing values default 15/5. Ranges: global 1–100,
per-host 1–min(50, global). Both travel together as `v1/sftp/default`; transfer jobs/bytes are never settings records.
Deploy `SFTPPreferencesItem` **before** clients upload it.

Change 15/5 → 100/50, close Settings and verify the other device's queue adopts limits without interrupting active
transfers. Repeat offline, category/master paused then resumed; include a device retaining 3/2 and an older client
still syncing existing types.

## Historical verification limits

The 2026-09-19 implementation passed TFI full, iPad focused and TFM focused checks plus multilingual visual/format/
localization checks. The initial full macOS run was not green: schema/timeout issues passed focused fixes, while
StoreKit/Agent/Metrics/field/forwarding failures remained outside scope. No complete macOS pass, production schema
or real delivery was established by that record. Rerun current release checks with pinned dependencies.
