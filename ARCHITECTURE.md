# Termind architecture

Termind intentionally remains one application target and one unit-test target.
Directories describe dependency boundaries even though Swift does not enforce
them as separate modules.

## Dependency direction

- `Domain` contains platform-independent values and rules.
- `Application` contains repositories, feature state, use cases, events, and
  service protocols.
- `Infrastructure` implements persistence, security, SSH, SFTP, and LLM clients.
- `Features` contains SwiftUI presentation and sends intents to Application.
- `Platform/macOS` contains AppKit adapters.
- `App` constructs dependencies and owns application/window lifetimes.

Domain must not import SwiftUI, SwiftData, AppKit, Ghostty, CSSH2, or OpenSSL.
Views must not construct network clients, access SwiftData/Keychain directly, or
coordinate cross-domain cleanup. Runtime side effects belong to application
services and durable outbox handlers.

## State lifetimes

- Repository snapshots are application-wide and shared by every window.
- A window owns one top-level shell, quick-open, and context-panel state.
- The shell always starts with two pinned routes: `Vault`, then `Assistant`. Dynamic
  tabs after them are SSH/SFTP Workspaces only.
- Vault owns its navigation column, including quick-connect Recents, and routes
  for Hosts, Keychain, Snippets, Welcome, and Host Editor. These routes never
  enter the Workspace deck.
- Known Hosts management belongs to the Host Editor draft for both new and
  existing Hosts. Context-panel Host details are read-only.
- Assistant owns its conversation list through `AssistantLibraryModel`; conversations are
  not panes and do not participate in Workspace drag, split, close, or reconnect
  lifecycles.
- A workspace owns only SSH/SFTP panes plus its session-scoped assistant
  conversation. Workspace content is full width and has no left sidebar.
- Session models own live SSH/SFTP resources and terminal/file-browser state.
- Settings is a native singleton macOS `Settings` scene, outside window routing.

Repository data is persistent truth. Runtime connection state is kept in a
connection registry and is never persisted onto domain records.
