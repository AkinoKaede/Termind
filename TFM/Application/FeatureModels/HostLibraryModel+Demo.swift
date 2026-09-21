import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

// MARK: - Demo data

extension HostLibraryModel {
    /// Seed data for P0, so the sidebar and workspace list can be exercised before any
    /// persistence or networking exists.
    static func demo(language: AppLanguage = .english) -> HostLibraryModel {
        func text(_ en: String, _ zhHans: String, _ zhHant: String) -> String {
            switch language {
            case .simplifiedChinese: zhHans
            case .traditionalChinese: zhHant
            case .system, .english: en
            }
        }
        func distribution(_ id: String) -> DetectedDistribution {
            guard let distribution = DetectedDistribution(id: id) else {
                preconditionFailure("Invalid bundled Demo distribution: \(id)")
            }
            return distribution
        }

        let production = HostGroup(name: text("Production", "生产环境", "正式環境"), sortIndex: 0)
        let staging = HostGroup(name: text("Staging", "预发布环境", "測試環境"), sortIndex: 1)
        let homelab = HostGroup(name: text("Homelab", "家庭实验室", "家庭實驗室"), sortIndex: 2)
        let edge = HostGroup(
            name: text("Edge", "边缘节点", "邊緣節點"), parentID: production.id, sortIndex: 0
        )

        let now = Date(timeIntervalSinceReferenceDate: 776_000_000)

        let personalKey = SSHKeyRef(
            label: text("Personal", "个人", "個人"), algorithm: .ed25519,
            fingerprint: "SHA256:9pKQ2vC0nJ7hR4mXbL1sT8yWfE3dA6uZgN5qOiVxHkM",
            credentialRef: "termind.key.personal", colorTag: .blue
        )
        let workKey = SSHKeyRef(
            label: text("Work (no sync)", "工作（不同步）", "工作（不同步）"), algorithm: .ecdsa256,
            fingerprint: "SHA256:3tBn8xLpQ2wZ7yKvR1mHcE9dS4fJ6uA0gT5iNqOxVbY",
            credentialRef: "termind.key.work",
            storage: .thisDevice, colorTag: .purple
        )

        // Built before the hosts, because a host now references its login by id.
        // One of each shape, so all four combinations of the two secrets are on
        // screen at P0: key only, key *and* password, password only, neither.
        let deploy = Identity(
            name: text("Deploy", "部署账号", "部署帳號"), username: "deploy", keyID: personalKey.id,
            notes: text("Production web tier", "生产环境 Web 层", "正式環境 Web 層"),
            lastUsedAt: now, colorTag: .green
        )
        let postgres = Identity(
            name: text("Postgres admin", "Postgres 管理员", "Postgres 管理員"), username: "postgres",
            credentialRef: "termind.password.postgres", keyID: workKey.id,
            notes: text("Key to get in, password for sudo", "使用密钥登录，密码用于 sudo", "使用金鑰登入，密碼用於 sudo"),
            lastUsedAt: now.addingTimeInterval(-7_200), colorTag: .orange
        )
        let consoleRoot = Identity(
            name: text("Console root", "控制台 root", "主控台 root"), username: "root",
            credentialRef: "termind.password.console-root",
            notes: text("Out-of-band only", "仅限带外管理", "僅限頻外管理"), colorTag: .red
        )
        let unfinished = Identity(
            name: text("New admin", "新管理员", "新增管理員"), username: "admin",
            notes: text("No secret chosen yet", "尚未选择凭据", "尚未選擇認證資訊")
        )

        // Half the fleet is left without an identity on purpose, so the "not set
        // yet" state is visible at P0 instead of first appearing in the field.
        //
        // A fresh install has no connection history, so Recents starts empty and the sidebar shows
        // its placeholder; seeding a history here put that empty state out of
        // reach and told a first launch it had already been on production.
        // `AppModel.open` fills the list the moment anything is opened.
        let hosts: [Host] = [
            Host(
                name: "web-01", host: "10.0.1.5", identityID: deploy.id,
                groupID: production.id, tags: ["nginx", "prod"], colorTag: .red,
                detectedDistribution: distribution("ubuntu"),
                sortIndex: 0
            ),
            Host(
                name: "web-02", host: "10.0.1.6", identityID: deploy.id,
                groupID: production.id, tags: ["nginx", "prod"], colorTag: .red,
                detectedDistribution: distribution("debian"),
                sortIndex: 1
            ),
            Host(
                name: "db-primary", host: "10.0.2.10", identityID: postgres.id,
                groupID: production.id, tags: ["postgres"], colorTag: .purple,
                detectedDistribution: distribution("rocky"),
                sortIndex: 2
            ),
            Host(
                name: "cdn-edge-tokyo", host: "203.0.113.7", port: 2222, identityID: consoleRoot.id,
                groupID: edge.id, tags: ["varnish", "apac"], colorTag: .orange,
                detectedDistribution: distribution("alpine"),
                sortIndex: 0
            ),
            Host(
                name: "staging-app", host: "staging.internal",
                groupID: staging.id, tags: ["staging"], colorTag: .yellow,
                detectedDistribution: distribution("fedora"),
                sortIndex: 0
            ),
            Host(
                name: "nas", host: "192.168.1.20",
                groupID: homelab.id, tags: ["zfs"], colorTag: .teal,
                detectedDistribution: distribution("nixos"), sortIndex: 0
            ),
            Host(
                name: "pi-hole", host: "192.168.1.21",
                groupID: homelab.id, tags: ["dns"], colorTag: .green,
                detectedDistribution: distribution("raspberrypios"), sortIndex: 1
            ),
            Host(
                name: "scratch-box", host: "172.16.0.9",
                detectedDistribution: distribution("opensuse-tumbleweed"),
                sortIndex: 0
            ),
        ]

        let diagnostics = SnippetPackage(
            name: text("Diagnostics", "诊断", "診斷"), sortIndex: 0
        )
        let webOperations = SnippetPackage(
            name: text("Web Operations", "Web 运维", "Web 維運"),
            parentID: diagnostics.id, sortIndex: 0
        )
        let snippets = [
            Snippet(
                title: text("Disk usage by directory", "按目录查看磁盘占用", "依目錄查看磁碟用量"),
                body: "du -sh /* | sort -h",
                packageID: diagnostics.id, targetHostIDs: [hosts[0].id],
                sortIndex: 0
            ),
            Snippet(
                title: text("Top memory consumers", "内存占用最高的进程", "記憶體用量最高的程序"),
                body: "ps aux --sort=-%mem | head -20",
                packageID: diagnostics.id,
                targetHostIDs: [hosts[0].id, hosts[1].id],
                sortIndex: 1
            ),
            Snippet(
                title: text("Tail nginx errors", "持续查看 Nginx 错误", "持續查看 Nginx 錯誤"),
                body: "tail -f /var/log/nginx/error.log",
                packageID: webOperations.id,
                targetHostIDs: [hosts[0].id, hosts[1].id],
                sortIndex: 0
            ),
            Snippet(
                title: text("Listening ports", "监听中的端口", "監聽中的連接埠"),
                body: "ss -tulpn", sortIndex: 3
            ),
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
            KnownHostEntry(
                hostname: "staging.internal", algorithm: .rsa,
                fingerprint: "SHA256:5vT2nB8xQ1mL7kR4pW9yC3sD6fH0jG5uZaE8iXoNbVr",
                addedAt: now.addingTimeInterval(-15_552_000)
            ),
        ]

        let web01 = hosts[0]
        let db = hosts[2]
        let portForwardings = [
            PortForwardingRule(
                hostID: db.id, kind: .local, bindPort: 5432,
                targetHost: "localhost", targetPort: 5432,
                label: text("Postgres", "Postgres 数据库", "Postgres 資料庫")
            ),
            PortForwardingRule(
                hostID: web01.id, kind: .dynamic, bindPort: 1080,
                label: text("SOCKS proxy", "SOCKS 代理", "SOCKS Proxy")
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
                byteCount: 8_192,
                state: .failed(text("Permission denied", "权限被拒绝", "權限遭拒")),
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
            store.setStatus(
                .failed(text("Connection refused", "连接被拒绝", "連線遭拒")), for: staging.id
            )
        }

        return store
    }
}
