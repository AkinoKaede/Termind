# Files

- [Port Forwarding: Multi-Connection Pool and Flow Dispatch](port-forwarding-pool-and-dispatch.md) - Trace forwarding rules through Host-scoped intent, primary and auxiliary SSH workers, local/SOCKS socket dispatch, remote-listener ownership, bounded flow pumps, silent recovery, and ordered teardown.
- [Settings, Vault, Metrics, and Cloud Sync Workflow](settings-and-cloud-sync.md) - How Termind independently synchronizes Vault, Settings, and Metrics through CloudKit, including lifecycle gates, durable journals, account and environment transitions, conflict handling, and AI-secret upload authorization.
- [SFTP Transfer, Scheduling, and External Edit Workflow](sftp-transfer-and-external-edit.md) - How browser SFTP jobs are scheduled and resumed, how Agent SFTP leases reuse authenticated SSH connections, and how MCP uploads and external edits remain separate workflows.
- [SSH, Telnet, Trust, and Workspace Session Lifecycle](ssh-session-lifecycle.md) - Traces how Termind prepares SSH and Telnet connections, routes them through proxies and jump hosts, authorizes server identity, consumes credentials, and retires or restores live workspace sessions.
