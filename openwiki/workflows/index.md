# Files

- [Desktop Drag and Drop](desktop-drag-and-drop.md) - Desktop managed-card drag lifecycle, full-size previews, insertion placeholders, and the boundary between presentation and reorder persistence. Also covers native workspace and pane dragging, cancellation, and deferred window ownership transfer.
- [File Drag and Drop](file-drag-and-drop.md) - External file and image drop routing across desktop and mobile surfaces, including payload classification, attachment imports, staged uploads, cancellation, and failure handling.
- [Forwarding Pool and Dispatch Lifecycle](port-forwarding-pool-and-dispatch.md) - Trace explicit forwarding Start through Host access checks, primary authentication, pooled TCP flow dispatch, auxiliary connection recovery, and teardown.
- [Settings and Cloud Sync Workflow](settings-and-cloud-sync.md) - Settings mutation and persistence, device-local desktop language selection, and app-wide ownership of CloudKit synchronization, journals, recovery, and secret boundaries.
- [SFTP Transfers and External Editing](sftp-transfer-and-external-edit.md) - How browser SFTP jobs are scheduled and resumed, how Agent SFTP leases reuse authenticated SSH connections, and how MCP uploads and external edits remain separate workflows.
- [SSH Session Lifecycle](ssh-session-lifecycle.md) - Traces host selection, one-shot SSH preparation, routed trust and authentication, transport ownership, and desktop and mobile workspace teardown. Distinguishes window sessions from app-owned Agent connections and mobile restoration intent.
