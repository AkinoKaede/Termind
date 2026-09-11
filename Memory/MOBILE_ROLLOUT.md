# Mobile rollout status

## Implemented

- Shared Vault and AI configuration models and persistence, SSH/SFTP transports,
  Keychain adapters, StoreKit access, metrics sampling, and a SwiftUI presentation target.
- Four iPhone navigation destinations: Welcome/Vault/Workspaces, Metrics, Assistant, Settings.
  iPad retains the sidebar. No mobile workspace composition or workspace-attached Assistant.
- Mobile host, identity, group, snippet and provider forms use sheets; desktop host
  connection fields reuse the same SwiftUI content.
- Independent SSH/SFTP workspace descriptors, reconnect entry points, terminal rendering,
  system keyboard and a SwiftUI accessory bar using Ghostty's sticky modifiers.
- One ActivityKit activity with up to six host system icons and an overflow list link.
  Each icon deep-links to its workspace and reconnects through credential/trust checks.
  Compact/minimal presentations open the focused workspace. The distribution artwork
  is resolved through the same catalog used by the host list and refreshed by shell integration.
- Workspace restoration contains metadata only. Live Activities do not grant execution
  time; the app uses finite background execution and disconnects at expiration.
- SFTP browsing, upload/download, rename, permission editing, directory creation and deletion;
  an app-wide shared transfer queue with cancellation and current-launch history; metrics cards; independent
  streaming chat with persisted history; provider configuration and Pro purchase presentation.

- Key generation (including supported Secure Enclave devices), encrypted key import,
  metadata/certificate editing, and key/identity deletion. File parsing and generation
  run off MainActor, and secrets stay in the shared secret store.
- SSH folder/known_hosts import uses the shared reader and preview model. Missing usernames
  require an explicit edit on iOS; no local process username is substituted. References
  outside granted folders still require explicit file selection.
- Port forwarding management uses the shared runtime and transactional rule updates.
- Host deletion uses the shared outbox runner, including interrupted-job recovery on startup.
- iOS Keychain sharing entitlement and localized Face ID usage description are configured.

## Remaining from the full plan

The full mobile port is not complete. Do not describe the current implementation as feature parity.

- Port complete shared Assistant tool registration, approval/user-input/secret presentation,
  SSH/SFTP agent tools, model discovery/roles, Skills, MCP settings and speech input.
  The current mobile runtime intentionally registers no tools.
- Wire mobile CloudKit Vault/Settings coordinators and CloudKit signing capabilities;
  current mobile data is local, despite using the shared schema and journals.
- Complete terminal preferences, history/search UI and broader desktop SwiftUI view reuse.
- Test live SSH/SFTP, ActivityKit rendering and taps, external keyboards, background/lock
  behavior, CloudKit and StoreKit on signed physical devices. Widget icon routing and
  bounded payload behavior have automated coverage; real-device behavior is unverified.

## Verification so far

- iOS simulator build and tests pass: 15 mobile tests and 20 shared framework tests.
- macOS focused tests pass: 42 tests covering architecture, screenshot fixtures,
  command history and application language.
- Full macOS run executed 1,122 tests. Agent deadline/approval failures passed on a
  focused rerun. DataProtectionKeychainTests still returned OSStatus -25308 and
  MetricsInteractionTests still failed native popover focus/dismissal expectations.
  These failures remain unresolved; do not report the full suite as passing.
- Simplified Chinese localization checks pass. New UI text has translations.
- iPad sidebar and sheet presentation inspected in Simulator. Inspection caught missing
  persistent field labels; the shared form now uses LabeledContent for those fields.

## Continuation verification (2026-09-11)

- 51 macOS tests passed for SSH import, forwarding, repository/outbox behavior and architecture.
- 49 macOS SFTP feature/session/history tests passed after sharing the transfer coordinator
  and Unix permission controls. The permission-grid refactor in REFACTOR.md is verified.
- Mobile tests cover encrypted key generation/import, rejection of a wrong passphrase,
  metadata edits preserving credential references, explicit import usernames, transactional
  forwarding changes, and completion of durable host-deletion cleanup.

- The continuation's full macOS run again executed 1,122 tests and reported 14 issues
  in the previously failing deadline/approval, Keychain (-25308), and native popover suites.
  The full suite is still not green; the focused feature suites above passed.
