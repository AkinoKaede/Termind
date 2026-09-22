# Files

- [Settings, Vault, Metrics, and Cloud Sync Workflow](settings-and-cloud-sync.md) - How Termind independently synchronizes Vault, Settings, and Metrics through CloudKit, including lifecycle gates, durable journals, account and environment transitions, conflict handling, and AI-secret upload authorization.
- [SFTP Transfer, Scheduling, and External Edit Workflow](sftp-transfer-and-external-edit.md) - How SFTP browser operations become scheduled transfers, choose an SSH topology, resolve conflicts and resume safely, and support explicit external-file editing without durable staging or replay.
- [SSH, Telnet, Trust, and Workspace Session Lifecycle](ssh-session-lifecycle.md) - Traces how Termind prepares SSH and Telnet connections, routes them through proxies and jump hosts, authorizes server identity, consumes credentials, and retires or restores live workspace sessions.
