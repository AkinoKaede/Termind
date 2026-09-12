# Mobile rollout status

This file records the current mobile baseline, not the implementation chronology.
Do not claim complete desktop feature parity until the outstanding device and
service verification below is finished.

## Current capability

- Shared Vault, Settings, CloudKit journals, StoreKit access, Keychain adapters,
  SSH/SFTP transports, Metrics, presentation components, and deletion outbox.
- iPhone uses Vault, Workspaces, Assistant, Settings; Metrics is inside Vault.
  iPad uses Vault, Metrics, Workspaces, Assistant, Settings. Mobile has no Welcome,
  pane composition, workspace-attached Assistant, or bulk SSH-folder/known_hosts
  import; individual key/certificate imports remain supported.
- One SSH or SFTP session per Workspace, lazy metadata-only restoration, shared
  Connection Journey/recovery, terminal rendering, system keyboard/accessory bar,
  command history/search, Command Generator, and cross-opening SSH/SFTP from a live
  directory. Generated or historical commands paste without automatic execution.
- SFTP list/mutation, recursive picker/drop upload, conflict handling, download,
  permissions, transfers, and Pro-gated SSH drops share desktop policy. Transfers
  use dedicated connections and survive browser closure.
- Key generation/import/edit/delete, including supported Secure Enclave devices;
  port-forward drafts and device-local enabled intent; transactional Host deletion
  and recovery of interrupted cleanup.
- Shared Metrics sampler/Journey/panels. Detail uses two columns at 700 points or a
  compact switch below that width. Monitor secrets and temporary trust are not
  persisted.
- App, Terminal, SFTP, AI, and Sync Settings, including themes/fonts/custom Ghostty
  text, providers/models/roles, Skills, remote MCP, Web Search, and synchronized
  configuration. The local MCP listener and macOS window-title control remain absent.
- Independent persisted Assistant conversations with the shared desktop-independent
  tool registry, approvals/user input/secrets, attachments, and speech input. Runs
  survive page switches but remain bounded by iOS background execution.
- One serialized Live Activity summarizes up to six Workspaces and deep-links
  through validated metadata-only URLs. It never keeps SSH or Agent work alive.
- TFI follows the same layered source vocabulary as TFM. Shared Application owns
  connection recovery, terminal drafts/find, SFTP state ports, Assistant execution,
  and speech coordination; native surfaces/adapters remain in each app.

## Important behavior

- Background expiration closes transports, transfers, samplers, and Agent runs but
  retains Workspace intent; foreground recovery uses normal credentials/trust and
  never replays commands, tool actions, uploads, or approvals.
- Shell-integration and transport-exit callbacks use one generation-scoped ordered
  MainActor stream. Bash ignores Termind's internal `__termind_*` draft helpers;
  authenticated installation/completion are prompt boundaries and duplicate prompt
  markers are harmless.
- Sync operates only while a scene is active and Pro permits it. Remote Host deletion
  closes its sessions, transfers, forwarding, and local history. Active chats retain
  their starting provider/model/credential snapshot.
- iPhone remains tab-based in landscape; iPad uses the split view's width adaptation.
  Editors use explicit-save drafts and preserve unrelated synchronized record kinds.

## Latest recorded verification

- Complete iOS Simulator action: 257 tests passed.
- Both app builds, 58 focused macOS architecture/theme/Journey/terminal-find tests,
  shared policy suites, strict Swift formatting, Simplified Chinese localization,
  and `git diff --check` passed.
- A connected iPad reproduced and then verified the Bash Command Generator fix on a
  live host. Signed physical-iPad target compilation also passed.
- The full macOS action still has the known Keychain-environment, native Metrics
  focus, and Agent timing failures documented in `REFACTOR.md`; focused Agent
  reruns passed. Do not report the full macOS suite as green.

## Still required

- Exercise representative live SSH/SFTP, Live Activity rendering/taps, external
  keyboards, lock/background expiration, and restoration on signed iPhone/iPad.
- Verify signed macOS/iOS CloudKit delivery and StoreKit Sandbox behavior, including
  production schemas, account switching, delayed Keychain delivery, and entitlement
  changes.
- Continue extracting reusable desktop SwiftUI where it reduces duplication without
  crossing the native AppKit/UIKit boundary.
