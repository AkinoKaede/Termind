# Settings sync release verification

Settings sync ships disabled by default under the Settings checkbox. Vault keeps
its existing zone and record type. Settings retains the first AI-sync zone and
record identifiers for compatibility. No AgentKit dependency update is required.

V13 entity names/defaults are frozen. V14 adds Terminal preferences. The repair
was verified against an isolated copy of the installed V13 database: migration
to V14 succeeded, SQLite integrity was valid, and every preexisting table kept
its row count. The live database was subsequently observed at V14 with valid
integrity.

Before shipping the app and privacy policy 1.4 together:

- In `iCloud.com.akinokaede.termind`, create/validate the Development
  `AIConfigurationItem` record type, then deploy its schema to Production. Use the same
  field types as `VaultItem`: `formatVersion`, `counter`, and `isDeleted` are
  integers; `kind`, `entityID`, `writerID`, and `payloadHash` are strings;
  `modifiedAt` is a date; `payload` is bytes; `payloadAsset` is an asset.
  The private custom zone is `TermindAIConfigurationV1`; subscription ID is
  `termind-ai-configuration-v1-changes`. No public database access is needed.
- Test two signed Macs using the same Apple account: add/edit/delete a provider,
  role, MCP client, skill and Terminal configuration; exercise offline edits,
  master/category pause and resume, delayed Keychain arrival and key rotation.
- Switch one Mac's iCloud account and confirm that settings upload waits for the
  merge action. Verify that the other category's selection and account state are
  independent. Repeat with the master disabled and after Pro expiration.
- Check light/dark themes, fonts, custom terminal text and shell-integration
  changes on existing windows; ensure conversations and approval mode stay local.
- Match the privacy policy effective date to the actual release date before
  publishing the website. The prepared date is September 10, 2026.

The implementation environment did not have a CloudKit management token
(`cktool get-teams` reported that none was available). Production schema
validation/deployment and two-Mac delivery verification require that environment
access; local tests do not establish real iCloud delivery.
