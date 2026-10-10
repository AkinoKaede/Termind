# Files

- [Desktop Drag and Drop](desktop-drag-and-drop.md) - Native desktop workspace and pane layout dragging, including drop routing, cancellation, and deferred ownership transfer to a new window. Distinguishes these moves from pane file drops and Assistant conversation reordering.
- [File Drag and Drop](file-drag-and-drop.md) - How desktop file URLs and private drag payloads are validated and dispatched to terminal path insertion, SSH/SFTP uploads, or remote copies, alongside mobile and other file-drop destinations.
- [Port Forwarding Pool and Dispatch](port-forwarding-pool-and-dispatch.md) - Trace app-owned forwarding requests through Host-scoped intent, feature-owned authentication, pooled SSH flow dispatch, silent recovery, and lifecycle cleanup.
- [Settings and Cloud Sync](settings-and-cloud-sync.md) - Settings mutation and persistence, device-local desktop language selection, and app-wide ownership of CloudKit synchronization, journals, recovery, and secret boundaries.
- [SFTP Transfer, Scheduling, and External Edit Workflow](sftp-transfer-and-external-edit.md) - How browser SFTP jobs are scheduled and resumed, how Agent SFTP leases reuse authenticated SSH connections, and how MCP uploads and external edits remain separate workflows.
- [SSH session lifecycle](ssh-session-lifecycle.md) - Traces host selection, one-shot SSH preparation, routed trust and authentication, transport ownership, and desktop and mobile workspace teardown. Distinguishes window sessions from app-owned Agent connections and mobile restoration intent.
