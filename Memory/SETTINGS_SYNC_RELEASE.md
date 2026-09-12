# Settings sync release verification

Settings sync ships off by default; Vault and Metrics are selected, Settings is
opt-in. Vault keeps its existing protocol, Settings keeps its original AI-sync
identifiers, and no AgentKit bump is required. V13 names/defaults are frozen; V14
adds Terminal preferences. Migration of a copied installed V13 store preserved row
counts and SQLite integrity, and the live store was observed healthy at V14.

## CloudKit deployment

In private container `iCloud.com.akinokaede.termind`, create/validate Development
schemas and deploy them to Production:

| Category | Zone | Record type | Subscription |
| --- | --- | --- | --- |
| Settings | `TermindAIConfigurationV1` | `AIConfigurationItem` | `termind-ai-configuration-v1-changes` |
| Metrics | `TermindMetricsV1` | `MetricsItem` | `termind-metrics-v1-changes` |

Both record types use the Vault envelope: integer `formatVersion`, `counter`,
`isDeleted`; string `kind`, `entityID`, `writerID`, `payloadHash`; date
`modifiedAt`; bytes `payload`; asset `payloadAsset`. No public database access
is needed.

The implementation environment had no CloudKit management token
(`cktool get-teams` found none), so local tests do not establish production schema
deployment or real delivery.

## Signed-device release checks

- On two Macs with one Apple account, add/edit/delete providers, roles, MCP clients,
  skills, and Terminal configuration; include offline edits, category/master pause
  and resume, delayed Keychain delivery, and key rotation.
- Switch one Mac's iCloud account and ensure upload waits for merge. Confirm each
  category's selection/account state is independent; repeat with master sync off and
  after Pro expiration.
- Confirm theme/font/custom terminal/shell-integration changes reach existing
  windows, while conversations and approval mode remain local.
- Give each Mac different local MCP listener enablement, port, tools, and token.
  Verify independence and verify an old synchronized token locally before removing
  its iCloud Keychain copy.
- Across signed macOS/iOS devices, verify Metrics order, pause state, and disk/network
  filters. A Metrics record received before its Vault Host must stay hidden until the
  Host arrives.
- Release privacy policy 1.5 with the app and replace its prepared September 12,
  2026 effective date with the actual publication date.
