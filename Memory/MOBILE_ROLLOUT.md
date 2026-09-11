# Mobile rollout status

## Implemented

- Shared Vault and AI configuration models and persistence, SSH/SFTP transports,
  Keychain adapters, StoreKit access, metrics sampling, and a SwiftUI presentation target.
- Four iPhone navigation destinations: Vault, Workspaces, Assistant, Settings. Metrics is a separate Vault entry; iPad retains Vault, Metrics, Workspaces, Assistant, Settings in its sidebar. No mobile workspace composition or workspace-attached Assistant.
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
- SFTP browsing, recursive multi-item picker/drag upload with desktop-equivalent conflict handling, download,
  rename, permission editing, directory creation and deletion; SSH terminals accept Pro-gated file/folder drops
  into the Shell Integration working directory. Upload preparation and queue notices stay in the current workspace.
  Mobile SSH also exposes the shared Command Generator from its More menu, reads the live shell draft, and inserts
  the validated command without executing it. The app-wide shared transfer queue provides cancellation and
  current-launch history; metrics cards; independent streaming chat with persisted history; provider configuration
  and Pro purchase presentation.

- Key generation (including supported Secure Enclave devices), encrypted key import,
  metadata/certificate editing, and key/identity deletion. File parsing and generation
  run off MainActor, and secrets stay in the shared secret store.
- SSH folder/known_hosts bulk import remains desktop-only. The mobile import screen and entry were removed at user request; individual private-key and certificate file imports remain supported.
- Port forwarding management uses the shared runtime and transactional rule updates.
- Host deletion uses the shared outbox runner, including interrupted-job recovery on startup.
- iOS Keychain sharing entitlement and localized Face ID usage description are configured.

## Remaining from the full plan

The full mobile port is not complete. Do not describe the current implementation as feature parity.

- Port complete shared Assistant tool registration, approval/user-input/secret presentation,
  SSH/SFTP agent tools, Skills, MCP/Web Search settings and speech input.
  The current mobile runtime intentionally registers no tools.
- Continue broader desktop SwiftUI view reuse and complete Assistant settings/tool execution beyond provider/model configuration.
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

## Terminal, sync and AI configuration continuation — 2026-09-11

Implemented shared CloudKit coordinators, Settings transaction/journal, terminal preferences,
command history and provider connection fields. Mobile uses the synced configuration store,
preserving Skills/MCP records and unresolved references. Defaults match desktop: Pro-gated
master/Vault enabled, Settings opt-in. Both categories pause in background and resume with
foreground/entitlement reconciliation. APNs registration and CloudKit signing are configured;
signing files are now `TFI/TFI.entitlements` and `TFM/TFM.entitlements`.

Mobile Terminal has light/dark theme catalogs, font controls, custom Ghostty text, integration,
search and per-host history. The remote-title preference is deliberately absent from its UI.
Search queries/surfaces survive navigation; historical commands paste without an added newline.
Provider forms support empty model lists, endpoint derivation and explicit keep/replace/clear
key intent; failed secret/configuration writes keep drafts and attempt credential rollback.
Model discovery is cancellable, adds selected candidates only, and ignores stale responses.
Roles and chat pickers use shared fallback rules. Runtime tools remain intentionally absent.

Verification in this continuation:

- iOS simulator builds and 25 mobile plus 26 shared tests passed, including 16 new regression tests.
- Full macOS run executed 1,123 tests and reported 9 issues in existing Agent approval,
  user-input deadline and cancellation tests; all 26 shared tests passed separately.
- Focused rerun still reproduced two existing AgentApprovalQueueTests failures. A catalog
  check also caught newly auto-extracted, previously untranslated mobile strings; these
  translations have now been supplied; 68 focused macOS feature/language tests passed afterward.
- iPhone Terminal preferences and iPad English/Chinese, light/dark settings and provider forms inspected. iPad rotation preserved drafts and cancel required discard confirmation.
- Connected-device inventory reports the paired iPhone and iPad unavailable. Real SSH,
  external-keyboard hardware, background/lock and signed Mac/iOS CloudKit delivery remain
  unverified. Production schema deployment was not attempted. AgentKit and Ghostty pins unchanged.

### Follow-up navigation and desktop parity

Vault replaces Welcome on both mobile layouts. iPhone's Metrics tab is replaced by Workspaces;
Metrics gets its own Vault section above the other three library links. Transfers moves into
Workspaces. iPad places Metrics immediately below Vault in its sidebar. Host rows connect SSH
on tap and use long-press menus. macOS Navigator now labels its workspace group “Workspaces”.

Metrics reuses desktop instruments, system panels and the complete shared monitor/Journey
state, with shared credential and host-key forms. At >=700 points, details display status and
processes side by side; narrow layouts use a two-icon switch. Keychain order/defaults and
certificate import align with macOS. Identity notes have no mobile editor. Port forwarding
is staged inside the host editor, with explicit runtime actions only for saved rules. Mobile
SSH folder import was removed, while individual key/certificate import remains.

Settings now has App as its own page, and Sync below AI. The redundant Live Activities
settings section was removed; activity startup/restoration is automatic for workspaces and
continues to respect OS authorization. Shared app-language settings take effect on relaunch.
Phone tabs remain available in landscape; iPad uses a collapsible sidebar.

Follow-up verification:
- iOS: 29 mobile tests and 28 shared tests passed, including certificate-file validation,
  default key generation options, navigation/breakpoint rules and shared Metrics credential/
  temporary-trust continuation without persisting secrets or trust.
- macOS: 127 targeted tests across 14 suites passed, covering architecture, language, sync,
  terminal history/themes, Journey, Metrics lifecycle/presentation/interaction, snapshots,
  key-file import and SSH certificates.
- A full 1,124-test macOS run reported existing Agent timing/native-popover issues plus a
  brittle new source-format assertion; that assertion and the shared fake-process fixture
  were corrected, and the relevant targeted suites then passed. Final full-run status follows.


Final macOS regression (2026-09-11): all 1,124 app tests were executed. Six issues remain
in the preexisting AgentApprovalQueueTests/AgentUserInputTests timing cases; architecture,
Metrics interaction/presentation, connection forms, localization and the other suites passed.
All 28 shared tests passed. These results do not establish a green full macOS suite.
Logs: `/tmp/termind-mac-port-final.log`, `/tmp/termind-mac-nav-focused.log`.

Final visual review on iPhone confirmed the separate Metrics section in Vault, four bottom
tabs, absence of bulk SSH import, forwarding nested in the host editor, leading-aligned
forwarding Name with trailing address/port fields, and Settings ordered App/Terminal/AI/Sync.
The standalone App page shows appearance, language, versions and support; no Live Activities
settings are exposed. Earlier iPad bilingual/theme/rotation checks remain recorded above.

Final iOS verification: 29 mobile and 28 shared tests passed after the complete navigation,
App/Sync settings, credential parity and persistent Journey-overlay changes. Log:
`/tmp/termind-ios-port-complete.log`. Strict Swift formatting, `git diff --check`, and
`Scripts/check-zh-localization.sh` passed. No dependency pins or cloud schemas were changed.

## Command Generator and local upload parity — 2026-09-11

Mobile SSH now owns the same guarded draft-read/generate/bracketed-paste lifecycle as desktop and exposes it from
the workspace More menu. Local upload selection and URL drops share the desktop batch planner across SSH and SFTP,
including recursive folders, conflict preflight, and replace/skip/keep-both resolution.

The iOS simulator run passed all 221 tests. Command Generator, Broadcast Input, and SFTP focused macOS tests passed.
The full macOS run executed 1,176 tests and reported three unrelated failures: two known Agent timing cases passed on
immediate focused rerun, while the existing ArchitectureBoundary source assertion still expects the App icon `app`
despite the current uncommitted mobile settings source using `app.badge`. Both app builds, strict Swift formatting,
Simplified Chinese localization checks, and `git diff --check` passed.

## Ordered mobile Shell Integration delivery — 2026-09-11

The original mobile Command Generator tests invoked `receiveShellEvent` directly and therefore did not verify the
production callback hop from the SSH worker to MainActor. Mobile SSH now places Shell Integration and transport-exit
callbacks in one session-scoped ordered stream. Closing, reconnecting, or expiring a session terminates its consumer,
so a late callback cannot reorder prompt readiness or mutate a replacement session.

Six focused mobile Command Generator tests passed, including background callback delivery, command completion,
disabled-integration transport configuration, and stale-event isolation across an exit and replacement connection.
The 43 focused macOS Shell Integration, Command History, and Broadcast Input tests also passed. The full iOS run
passed 232 of 233 tests; the remaining failure is in the concurrently edited MobileCard key-color test and is
unrelated to SSH or Command Generator. Simulator, macOS, and signed physical-iPad target builds passed. Live SSH
verification on the device remains pending.

Physical-device diagnosis then confirmed that the affected bash host had Shell Integration enabled, a detected
remote distribution, and authenticated command history. After the first readiness correction, tapping Generate
Command produced an unfinished History row containing the draft itself. This identified the actual cancellation:
bash's DEBUG fallback treated the internal draft-reading `bind -x` helper as a user command, emitted command-start,
and immediately marked the prompt busy. The fallback now passes `BASH_COMMAND` into the hook and ignores Termind's
own `__termind_*` helpers. Mobile also treats authenticated installation and command completion as prompt boundaries;
duplicate prompt markers are idempotent. Seventeen shared bootstrap tests, including a real bash runtime regression,
and all six focused mobile Command Generator tests passed. The root-cause build was installed and launched on the
connected iPad at 22:30. The affected live bash host then completed Command Generator successfully on that iPad.
