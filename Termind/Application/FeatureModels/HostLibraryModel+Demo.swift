import Foundation

// MARK: - Demo data

extension HostLibraryModel {
    /// Seed data for P0, so the sidebar and workspace list can be exercised before any
    /// persistence or networking exists.
    static func demo() -> HostLibraryModel {
        let production = HostGroup(name: "Production", sortIndex: 0)
        let staging = HostGroup(name: "Staging", sortIndex: 1)
        let homelab = HostGroup(name: "Homelab", sortIndex: 2)
        let edge = HostGroup(name: "Edge", parentID: production.id, sortIndex: 0)

        let now = Date(timeIntervalSinceReferenceDate: 776_000_000)

        let personalKey = SSHKeyRef(
            label: "Personal", algorithm: .ed25519,
            fingerprint: "SHA256:9pKQ2vC0nJ7hR4mXbL1sT8yWfE3dA6uZgN5qOiVxHkM",
            credentialRef: "termind.key.personal"
        )
        let workKey = SSHKeyRef(
            label: "Work (no sync)", algorithm: .ecdsa256,
            fingerprint: "SHA256:3tBn8xLpQ2wZ7yKvR1mHcE9dS4fJ6uA0gT5iNqOxVbY",
            credentialRef: "termind.key.work",
            storage: .thisDevice
        )

        // Built before the hosts, because a host now references its login by id.
        // One of each shape, so all four combinations of the two secrets are on
        // screen at P0: key only, key *and* password, password only, neither.
        let deploy = Identity(
            name: "Deploy", username: "deploy", keyID: personalKey.id,
            notes: "Production web tier", lastUsedAt: now
        )
        let postgres = Identity(
            name: "Postgres admin", username: "postgres",
            credentialRef: "termind.password.postgres", keyID: workKey.id,
            notes: "Key to get in, password for sudo",
            lastUsedAt: now.addingTimeInterval(-7_200)
        )
        let consoleRoot = Identity(
            name: "Console root", username: "root",
            credentialRef: "termind.password.console-root",
            notes: "Out-of-band only"
        )
        let unfinished = Identity(
            name: "New admin", username: "admin",
            notes: "No secret chosen yet"
        )

        // Half the fleet is left without an identity on purpose, so the "not set
        // yet" state is visible at P0 instead of first appearing in the field.
        //
        // No host carries `lastUsedAt`, for the same reason. A fresh install has
        // no connection history, so Recents starts empty and the sidebar shows
        // its placeholder; seeding a history here put that empty state out of
        // reach and told a first launch it had already been on production.
        // `AppModel.open` fills the list the moment anything is opened.
        let hosts: [Host] = [
            Host(
                name: "web-01", host: "10.0.1.5", identityID: deploy.id,
                groupID: production.id, tags: ["nginx", "prod"], colorTag: .red,
                sortIndex: 0
            ),
            Host(
                name: "web-02", host: "10.0.1.6", identityID: deploy.id,
                groupID: production.id, tags: ["nginx", "prod"], colorTag: .red,
                sortIndex: 1
            ),
            Host(
                name: "db-primary", host: "10.0.2.10", identityID: postgres.id,
                groupID: production.id, tags: ["postgres"], colorTag: .purple,
                sortIndex: 2
            ),
            Host(
                name: "cdn-edge-tokyo", host: "203.0.113.7", port: 2222, identityID: consoleRoot.id,
                groupID: edge.id, tags: ["varnish", "apac"], colorTag: .orange,
                sortIndex: 0
            ),
            Host(
                name: "staging-app", host: "staging.internal",
                groupID: staging.id, tags: ["staging"], colorTag: .yellow,
                sortIndex: 0
            ),
            Host(
                name: "nas", host: "192.168.1.20",
                groupID: homelab.id, tags: ["zfs"], colorTag: .teal, sortIndex: 0
            ),
            Host(
                name: "pi-hole", host: "192.168.1.21",
                groupID: homelab.id, tags: ["dns"], colorTag: .green, sortIndex: 1
            ),
            Host(
                name: "scratch-box", host: "172.16.0.9",
                sortIndex: 0
            ),
        ]

        let diagnostics = SnippetPackage(name: "Diagnostics", sortIndex: 0)
        let webOperations = SnippetPackage(
            name: "Web Operations", parentID: diagnostics.id, sortIndex: 0
        )
        let snippets = [
            Snippet(
                title: "Disk usage by directory", body: "du -sh /* | sort -h",
                packageID: diagnostics.id, targetHostIDs: [hosts[0].id],
                sortIndex: 0
            ),
            Snippet(
                title: "Top memory consumers", body: "ps aux --sort=-%mem | head -20",
                packageID: diagnostics.id,
                targetHostIDs: [hosts[0].id, hosts[1].id],
                sortIndex: 1
            ),
            Snippet(
                title: "Tail nginx errors", body: "tail -f /var/log/nginx/error.log",
                packageID: webOperations.id,
                targetHostIDs: [hosts[0].id, hosts[1].id],
                sortIndex: 0
            ),
            Snippet(title: "Listening ports", body: "ss -tulpn", sortIndex: 3),
        ]

        let knownHosts = [
            KnownHostEntry(
                hostname: "10.0.1.5", algorithm: .ed25519,
                fingerprint: "SHA256:kL9mR2xQ7vB4nT1yC6dW8sF3jH0aP5uZeG2iXoNbVrM",
                addedAt: now.addingTimeInterval(-2_592_000)
            ),
            KnownHostEntry(
                hostname: "10.0.2.10", algorithm: .ed25519,
                fingerprint: "SHA256:7wQxN3bV9cL2mK8pR1tY6sD4fG0hJ5uZaE2iXoBnVrT",
                addedAt: now.addingTimeInterval(-1_209_600)
            ),
            KnownHostEntry(
                hostname: "203.0.113.7", port: 2222, algorithm: .ecdsa256,
                fingerprint: "SHA256:2mF8sK1pQ7xR4vB9nL3yT6wC0dH5jA2uZgE7iOxNbVr",
                addedAt: now.addingTimeInterval(-604_800)
            ),
            // One deliberately broken pin, so the warning state is visible at P0
            // instead of first appearing the day it matters.
            KnownHostEntry(
                hostname: "staging.internal", algorithm: .rsa,
                fingerprint: "SHA256:5vT2nB8xQ1mL7kR4pW9yC3sD6fH0jG5uZaE8iXoNbVr",
                addedAt: now.addingTimeInterval(-15_552_000),
                isMismatched: true
            ),
        ]

        let web01 = hosts[0]
        let db = hosts[2]
        let portForwardings = [
            PortForwardingRule(
                hostID: db.id, kind: .local, bindPort: 5432,
                targetHost: "localhost", targetPort: 5432, label: "Postgres"
            ),
            PortForwardingRule(
                hostID: web01.id, kind: .dynamic, bindPort: 1080,
                label: "SOCKS proxy"
            ),
        ]

        // A queue with one of each state, so Batch Startup, progress, and the
        // failure row can all be checked without a server.
        let sftpTransfers = [
            SFTPTransfer(
                hostID: web01.id, direction: .upload,
                localPath: "~/Builds/termind-1.0.tar.gz", remotePath: "/srv/releases/termind-1.0.tar.gz",
                byteCount: 48_312_320, transferredBytes: 21_495_808, state: .running,
                queuedAt: now.addingTimeInterval(-120)
            ),
            SFTPTransfer(
                hostID: db.id, direction: .download,
                localPath: "~/Downloads/dump-2026-08-21.sql", remotePath: "/var/backups/dump-2026-08-21.sql",
                byteCount: 1_073_741_824, state: .queued,
                queuedAt: now.addingTimeInterval(-90)
            ),
            SFTPTransfer(
                hostID: web01.id, direction: .upload,
                localPath: "~/Config/nginx.conf", remotePath: "/etc/nginx/nginx.conf",
                byteCount: 8_192, state: .failed(String(localized: "Permission denied")),
                queuedAt: now.addingTimeInterval(-3_600)
            ),
            SFTPTransfer(
                hostID: db.id, direction: .download,
                localPath: "~/Logs/pg.log", remotePath: "/var/log/postgresql/pg.log",
                byteCount: 2_097_152, transferredBytes: 2_097_152, state: .completed,
                queuedAt: now.addingTimeInterval(-7_200)
            ),
        ]

        let store = HostLibraryModel(
            hosts: hosts,
            groups: [production, staging, homelab, edge],
            keys: [personalKey, workKey],
            identities: [deploy, postgres, consoleRoot, unfinished],
            snippets: snippets,
            snippetPackages: [diagnostics, webOperations],
            portForwardings: portForwardings,
            sftpTransfers: sftpTransfers,
            knownHosts: knownHosts
        )

        // A spread of connection states so the sidebar, workspace list, and status bar
        // can be checked against every dot color without a server.
        store.setStatus(.connected, for: web01.id)
        store.setStatus(.connecting, for: db.id)
        if let staging = hosts.first(where: { $0.name == "staging-app" }) {
            store.setStatus(.failed("Connection refused"), for: staging.id)
        }

        return store
    }
}
