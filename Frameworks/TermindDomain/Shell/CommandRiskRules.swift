import Foundation

nonisolated enum CommandRiskRules {
    static let kubernetesGlobalValueOptions: Set<String> = [
        "--as", "--as-group", "--cache-dir", "--certificate-authority", "--client-certificate", "--client-key",
        "--cluster", "--context", "--kubeconfig", "--namespace", "-n", "--password", "--profile",
        "--profile-output", "--request-timeout", "--server", "--tls-server-name", "--token", "--user",
        "--username",
    ]

    static func isKnown(_ name: String) -> Bool {
        readOnlyCommands.contains(name) || cautionCommands.contains(name) || destructiveCommands.contains(name)
            || argumentSensitiveCommands.contains(name)
    }

    static func isStandaloneHelpOrVersionRequest(_ args: [String]) -> Bool {
        args == ["--help"] || args == ["--version"]
    }

    static func classify(name: String, args: [String]) -> RiskAssessment {
        if destructiveCommands.contains(name) { return destructive(name) }
        if cautionCommands.contains(name) { return caution(name) }
        if readOnlyCommands.contains(name) { return .safe }

        switch name {
        case "rm": return classifyRemove(args)
        case "find": return classifyFind(args)
        case "chmod", "chown", "chgrp": return classifyPermissions(args)
        case "awk": return caution(name)
        case "sort":
            return hasFlag(args, ["-o", "--output", "--compress-program"]) ? caution(name) : .safe
        case "tree", "diff": return hasFlag(args, ["-o", "--output"]) ? caution(name) : .safe
        case "rg": return hasFlag(args, ["--pre"]) ? caution(name) : .safe
        case "uniq": return operands(args).count > 1 ? caution(name) : .safe
        case "blkid": return hasFlag(args, ["-w", "--garbage-collect"]) ? caution(name) : .safe
        case "sed": return classifySed(args)
        case "yq": return hasFlag(args, ["-i", "--inplace", "--in-place"]) ? caution(name) : .safe
        case "xxd": return classifyXXD(args)
        case "tar": return classifyTar(args)
        case "date": return hasFlag(args, ["-s", "--set"]) ? caution(name) : .safe
        case "hostname": return classifyHostname(args)
        case "mount": return classifyMount(args)
        case "dmesg": return classifyDmesg(args)
        case "systemctl": return classifySystemctl(args)
        case "service": return classifyService(args)
        case "journalctl": return classifyJournalctl(args)
        case "timedatectl", "hostnamectl", "localectl", "loginctl", "resolvectl", "networkctl":
            return classifySystemUtility(name, args)
        case "ip", "bridge", "tc": return classifyIPFamily(name, args)
        case "ifconfig": return classifyIfconfig(args)
        case "route": return classifyRoute(args)
        case "arp": return classifyARP(args)
        case "ethtool": return classifyEthtool(args)
        case "nvidia-smi": return classifyNvidiaSMI(args)
        case "sensors": return hasFlag(args, ["-s", "--set"]) ? caution(name) : .safe
        case "sysctl": return classifySysctl(args)
        case "swapon": return classifySwapon(args)
        case "ulimit": return classifyUlimit(args)
        case "fdisk", "parted", "gdisk": return classifyPartitionEditor(name, args)
        case "zfs", "zpool": return classifyZFS(name, args)
        case "diskutil": return classifyDiskutil(args)
        case "defaults": return classifyDefaults(args)
        case "launchctl": return classifyLaunchctl(args)
        case "losetup": return classifyLosetup(args)
        case "iptables", "ip6tables", "nft", "ufw", "firewall-cmd": return classifyFirewall(name, args)
        case "kill", "pkill", "killall": return classifyKill(name, args)
        case "rsync": return classifyRsync(args)
        case "crontab": return classifyCrontab(args)
        case "git": return classifyGit(args)
        case "git-lfs": return classifyGitLFS(args)
        case "gh", "glab": return classifyHostedGit(name, args)
        case "docker", "podman", "nerdctl": return classifyContainerCLI(name, args)
        case "docker-compose", "podman-compose": return classifyCompose(name, args)
        case "kubectl", "oc": return classifyKubernetes(name, args)
        case "helm": return classifyHelm(args)
        case "terraform", "tofu": return classifyTerraform(name, args)
        case "ansible", "ansible-playbook", "ansible-vault": return caution(name)
        case "ansible-config", "ansible-doc", "ansible-inventory", "ansible-lint": return .safe
        case "aws", "az", "gcloud": return classifyCloudCLI(name, args)
        case "apt", "apt-get", "apt-cache", "dpkg", "rpm", "yum", "dnf", "pacman", "apk", "zypper",
            "snap", "flatpak", "brew", "softwareupdate", "pkg":
            return classifySystemPackageManager(name, args)
        case "npm", "pnpm", "yarn", "bun", "pip", "pip3", "pipx", "gem", "cargo", "go":
            return classifyDevelopmentTool(name, args)
        case "psql", "mysql", "sqlite3", "mongosh": return classifyDatabaseClient(name, args)
        case "pg_dump": return classifyDump(args, name: name, outputFlags: ["-f", "--file"])
        case "mysqldump": return classifyDump(args, name: name, outputFlags: ["-r", "--result-file"])
        case "mysqladmin": return classifyMySQLAdmin(args)
        case "redis-cli": return classifyRedis(args)
        case "supervisorctl", "pm2": return classifyProcessManager(name, args)
        case "nginx", "apachectl", "apache2ctl", "httpd", "haproxy", "caddy":
            return classifyServerBinary(name, args)
        case "command", "builtin":
            return args.contains("-v") || args.contains("-V") ? .safe : caution(name)
        default:
            return RiskAssessment(
                risk: .caution,
                reasons: [String(localized: "`\(name)` is not a recognised read-only command.")]
            )
        }
    }

    static func operands(_ args: [String], valueOptions: Set<String> = []) -> [String] {
        var result: [String] = []
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let argument = args[index]
            if argument == "--" {
                optionsEnded = true
                index += 1
                continue
            }
            if !optionsEnded, argument.hasPrefix("-"), argument != "-" {
                let option = String(argument.split(separator: "=", maxSplits: 1).first ?? Substring(argument))
                if valueOptions.contains(option), !argument.contains("=") { index += 2 } else { index += 1 }
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    // MARK: - Core commands

    private static func classifyRemove(_ args: [String]) -> RiskAssessment {
        let targetsRoot = args.contains { $0 == "/" || $0.hasPrefix("/*") }
        if targetsRoot {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Recursive delete targeting the filesystem root.")]
            )
        }
        return RiskAssessment(
            risk: .destructive,
            reasons: [String(localized: "Deletes files permanently.")]
        )
    }

    private static func classifyFind(_ args: [String]) -> RiskAssessment {
        if args.contains("-delete") {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "`find -delete` removes every match.")]
            )
        }
        if args.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
            return RiskAssessment(
                risk: .caution,
                reasons: [String(localized: "`find -exec` runs a command per match.")]
            )
        }
        if args.contains(where: { ["-fprint", "-fprint0", "-fprintf", "-fls"].contains($0) }) {
            return caution("find")
        }
        return .safe
    }

    private static func classifyPermissions(_ args: [String]) -> RiskAssessment {
        if shortFlags(args).contains("R") {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Recursive ownership or permission change.")]
            )
        }
        return RiskAssessment(
            risk: .caution,
            reasons: [String(localized: "Changes file ownership or permissions.")]
        )
    }

    private static func classifySed(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-i", "--in-place"]) { return caution("sed") }
        let scripts = operands(args)
        let dangerousScript = scripts.contains { script in
            let trimmed = script.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("e ") || trimmed.hasPrefix("w ") || trimmed.contains(";e ")
                || trimmed.contains(";w ") || trimmed.hasSuffix("/e") || trimmed.contains("/e;")
                || trimmed.range(
                    of: #"(^|[;{}[:space:]0-9,$])([ew])([[:space:]]|$)"#,
                    options: .regularExpression
                ) != nil
                || trimmed.range(of: #"/[gpimI0-9]*[ew]([;[:space:]]|$)"#, options: .regularExpression)
                    != nil
        }
        return dangerousScript ? caution("sed") : .safe
    }

    private static func classifyXXD(_ args: [String]) -> RiskAssessment {
        guard hasFlag(args, ["-r", "--revert"]) else { return .safe }
        return operands(args).count > 1 ? caution("xxd") : .safe
    }

    private static func classifyTar(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["--delete"]) { return destructive("tar") }
        if hasFlag(args, ["-I", "--use-compress-program"])
            || args.contains(where: { $0.hasPrefix("--checkpoint-action=exec") })
        {
            return caution("tar")
        }
        var flags = shortFlags(args)
        if let oldStyle = args.first, !oldStyle.hasPrefix("-"), oldStyle.allSatisfy({ $0.isLetter }) {
            flags.formUnion(oldStyle)
        }
        if flags.contains("t") || hasFlag(args, ["--list"]) { return .safe }
        if flags.contains("x") || hasFlag(args, ["--extract", "--get"]) { return caution("tar") }
        if !flags.isDisjoint(with: ["c", "r", "u", "A"])
            || hasFlag(
                args, ["--create", "--append", "--update", "--concatenate"])
        {
            return caution("tar")
        }
        return caution("tar")
    }

    private static func classifyHostname(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-F", "--file"]) { return caution("hostname") }
        return operands(args).isEmpty ? .safe : caution("hostname")
    }

    private static func classifyMount(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-a", "--all"]) { return caution("mount") }
        if args.isEmpty || (operands(args).isEmpty && hasFlag(args, ["-l", "--show-labels"])) { return .safe }
        return operands(args).isEmpty ? .safe : caution("mount")
    }

    private static func classifyDmesg(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-C", "-c", "--clear", "--read-clear"]) { return destructive("dmesg") }
        if hasFlag(args, ["-D", "-E", "-n", "--console-off", "--console-on", "--console-level"]) {
            return caution("dmesg")
        }
        return .safe
    }

    // MARK: - Services, networking, and storage

    private static func classifySystemctl(_ args: [String]) -> RiskAssessment {
        let actions = operands(args, valueOptions: ["--host", "--machine", "--root", "--image", "--type", "--state"])
        let action = actions.first ?? "list-units"
        let safe: Set<String> = [
            "list-units", "list-automounts", "list-paths", "list-sockets", "list-timers", "is-active",
            "is-enabled", "is-failed", "status", "show", "cat", "help", "list-dependencies", "list-unit-files",
            "is-system-running", "get-default", "show-environment", "list-jobs", "list-machines",
        ]
        let destructiveActions: Set<String> = ["stop", "disable", "mask", "kill", "cancel", "revert"]
        if safe.contains(action) { return .safe }
        if destructiveActions.contains(action) {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Stops, disables, or removes service state.")]
            )
        }
        return caution("systemctl")
    }

    private static func classifyService(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["--status-all", "-e"]) { return .safe }
        let words = operands(args)
        guard words.count > 1 else { return caution("service") }
        let action = words[1]
        if ["status", "check", "describe"].contains(action) { return .safe }
        if ["stop", "disable", "delete", "remove"].contains(action) { return destructive("service") }
        return caution("service")
    }

    private static func classifyJournalctl(_ args: [String]) -> RiskAssessment {
        if args.contains(where: { $0.hasPrefix("--vacuum") }) { return destructive("journalctl") }
        if hasFlag(args, ["--rotate", "--flush", "--sync", "--relinquish-var"]) { return caution("journalctl") }
        return .safe
    }

    private static func classifySystemUtility(_ name: String, _ args: [String]) -> RiskAssessment {
        let words = operands(args)
        let action = words.first ?? ""
        let safeByName: [String: Set<String>] = [
            "timedatectl": ["", "status", "show", "timesync-status", "show-timesync"],
            "hostnamectl": ["", "status", "show"],
            "localectl": [
                "", "status", "list-locales", "list-keymaps", "list-x11-keymap-models", "list-x11-keymap-layouts",
            ],
            "loginctl": [
                "", "list-sessions", "session-status", "show-session", "list-users", "user-status", "show-user",
                "list-seats", "seat-status", "show-seat",
            ],
            "resolvectl": ["", "status", "query", "statistics", "show-cache"],
            "networkctl": ["", "list", "status", "lldp", "label"],
        ]
        let destructiveActions: Set<String> = [
            "terminate-session", "terminate-user", "kill-session", "kill-user", "power-off", "reboot", "stop",
            "down", "delete",
        ]
        if safeByName[name]?.contains(action) == true { return .safe }
        if destructiveActions.contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyIPFamily(_ name: String, _ args: [String]) -> RiskAssessment {
        let words = operands(args, valueOptions: ["-b", "-rc", "-n", "-netns"])
        if words.isEmpty { return .safe }
        let destructiveActions: Set<String> = ["delete", "del", "flush", "destroy", "down"]
        let cautionActions: Set<String> = ["add", "set", "change", "replace", "append", "prepend", "up"]
        if words.contains(where: destructiveActions.contains) { return destructive(name) }
        if words.contains(where: cautionActions.contains) {
            if words.contains("show") || words.contains("list") || words.contains("get") { return .safe }
            return caution(name)
        }
        return .safe
    }

    private static func classifyIfconfig(_ args: [String]) -> RiskAssessment {
        let words = operands(args)
        if words.count <= 1 { return .safe }
        if words.contains(where: { ["down", "destroy", "delete", "-alias"].contains($0) }) {
            return destructive("ifconfig")
        }
        return caution("ifconfig")
    }

    private static func classifyRoute(_ args: [String]) -> RiskAssessment {
        let words = operands(args)
        guard let action = words.first else { return .safe }
        if ["show", "get", "monitor"].contains(action) { return .safe }
        if ["delete", "del", "flush"].contains(action) { return destructive("route") }
        return caution("route")
    }

    private static func classifyARP(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-d", "--delete"]) { return destructive("arp") }
        if hasFlag(args, ["-s", "--set", "-f", "--file"]) { return caution("arp") }
        return .safe
    }

    private static func classifyEthtool(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["--reset"]) { return destructive("ethtool") }
        let setters: Set<String> = [
            "-s", "--change", "-A", "--pause", "-a", "-C", "--coalesce", "-E", "--change-eeprom", "-G",
            "--set-ring", "-K", "--features", "-L", "--set-channels", "-N", "--config-nfc", "-P",
            "--set-permaddr", "-Q", "--set-priv-flags", "-U", "--config-ntuple", "-X", "--set-rxfh-indir",
            "-p", "--identify", "-r", "--negotiate", "-t", "--test",
        ]
        return args.contains(where: setters.contains) ? caution("ethtool") : .safe
    }

    private static func classifyNvidiaSMI(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-r", "--gpu-reset", "--reset-ecc-errors"]) { return destructive("nvidia-smi") }
        let settingPrefixes = [
            "-ac", "-c", "-lgc", "-pl", "-pm", "-rac", "-rgc", "--persistence-mode",
            "--applications-clocks", "--power-limit", "--compute-mode", "--lock-", "--gom", "--ecc-config",
            "--mig-config", "--gpu-target-temp", "--reset-gpu-clocks",
        ]
        if args.contains(where: { argument in settingPrefixes.contains(where: argument.hasPrefix) }) {
            return caution("nvidia-smi")
        }
        return .safe
    }

    private static func classifySysctl(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-w", "--write"]) || args.contains(where: { !$0.hasPrefix("-") && $0.contains("=") }) {
            return caution("sysctl")
        }
        return .safe
    }

    private static func classifySwapon(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-s", "--show", "--summary"]) && operands(args).isEmpty { return .safe }
        return caution("swapon")
    }

    private static func classifyUlimit(_ args: [String]) -> RiskAssessment {
        if args.isEmpty || args == ["-a"] { return .safe }
        let values = operands(args)
        return values.isEmpty ? .safe : caution("ulimit")
    }

    private static func classifyPartitionEditor(_ name: String, _ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-l", "--list", "--print", "-p"]) || args.contains("print") { return .safe }
        return destructive(name)
    }

    private static func classifyZFS(_ name: String, _ args: [String]) -> RiskAssessment {
        let action = operands(args).first ?? ""
        let safe: Set<String> = [
            "list", "get", "status", "history", "events", "holds", "userspace", "groupspace", "version",
        ]
        let destructiveActions: Set<String> = [
            "destroy", "remove", "detach", "offline", "export", "clear", "release", "rollback",
        ]
        if safe.contains(action) {
            if name == "zpool", hasFlag(args, ["-c"]) { return caution(name) }
            return .safe
        }
        if destructiveActions.contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyDiskutil(_ args: [String]) -> RiskAssessment {
        let action = operands(args).first ?? "list"
        if ["list", "info", "activity", "listFilesystems", "apfs", "verifyDisk", "verifyVolume"].contains(action) {
            if action != "apfs" || args.contains(where: { ["list", "listSnapshots"].contains($0) }) { return .safe }
        }
        let containsDestructiveOperation = args.contains {
            let lowered = $0.lowercased()
            return lowered.contains("erase") || lowered.contains("delete") || lowered.contains("remove")
        }
        if containsDestructiveOperation
            || ["partitionDisk", "zeroDisk", "randomDisk", "secureErase", "unmount", "unmountDisk"].contains(action)
        {
            return destructive("diskutil")
        }
        return caution("diskutil")
    }

    private static func classifyDefaults(_ args: [String]) -> RiskAssessment {
        let action = operands(args).first ?? ""
        if ["", "read", "find", "domains", "currentHost"].contains(action) { return .safe }
        if action == "delete" { return destructive("defaults") }
        return caution("defaults")
    }

    private static func classifyLaunchctl(_ args: [String]) -> RiskAssessment {
        let action = operands(args).first ?? "list"
        if ["list", "print", "print-disabled", "dumpstate", "procinfo", "blame", "help", "version"].contains(action) {
            return .safe
        }
        if ["bootout", "unload", "remove", "stop", "kill", "disable"].contains(action) {
            return destructive("launchctl")
        }
        return caution("launchctl")
    }

    private static func classifyLosetup(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-d", "-D", "--detach", "--detach-all"]) { return destructive("losetup") }
        if hasFlag(args, ["-a", "-l", "-j", "--all", "--list", "--associated"]) { return .safe }
        return caution("losetup")
    }

    private static func classifyFirewall(_ name: String, _ args: [String]) -> RiskAssessment {
        if name == "nft", operands(args).first == "list" { return .safe }
        if name == "ufw", ["status", "show", "version"].contains(operands(args).first ?? "status") { return .safe }
        if name == "firewall-cmd",
            args.contains(where: {
                $0 == "--state" || $0.hasPrefix("--get-") || $0.hasPrefix("--list-") || $0.hasPrefix("--query-")
            })
        {
            return .safe
        }
        if ["iptables", "ip6tables"].contains(name),
            hasFlag(args, ["-L", "-S", "-C", "--list", "--list-rules", "--check"])
        {
            return .safe
        }
        return destructive(name)
    }

    private static func classifyKill(_ name: String, _ args: [String]) -> RiskAssessment {
        if shortFlags(args).contains("9") || args.contains("-KILL") || args.contains("--signal=KILL") {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "SIGKILL gives the process no chance to clean up.")]
            )
        }
        return caution(name)
    }

    private static func classifyRsync(_ args: [String]) -> RiskAssessment {
        if args.contains(where: { $0 == "--delete" || $0.hasPrefix("--delete-") }) { return destructive("rsync") }
        return caution("rsync")
    }

    private static func classifyCrontab(_ args: [String]) -> RiskAssessment {
        if shortFlags(args).contains("r") { return destructive("crontab") }
        if shortFlags(args).contains("l") { return .safe }
        return caution("crontab")
    }

    // MARK: - Source control and hosted development

    private static func classifyGit(_ args: [String]) -> RiskAssessment {
        let words = operands(args, valueOptions: ["-C", "-c", "--git-dir", "--work-tree", "--namespace"])
        guard let action = words.first else { return .safe }
        let safe: Set<String> = [
            "status", "log", "diff", "show", "blame", "grep", "rev-parse", "rev-list", "ls-files", "ls-tree",
            "cat-file", "for-each-ref", "describe", "shortlog", "name-rev", "count-objects", "verify-commit",
            "verify-tag", "show-ref", "merge-base", "range-diff", "version", "help",
        ]
        if safe.contains(action) { return .safe }
        if action == "branch" { return classifyGitBranch(args) }
        if action == "config" {
            if hasFlag(args, ["-l", "--list", "--get", "--get-all", "--get-regexp", "--show-origin", "--show-scope"]) {
                return .safe
            }
            return caution("git config")
        }
        if action == "tag" {
            if hasFlag(args, ["-d", "--delete"]) { return destructive("git tag") }
            if words.count == 1 || hasFlag(args, ["-l", "--list", "--contains", "--merged", "--no-merged"]) {
                return .safe
            }
            return caution("git tag")
        }
        if action == "remote" {
            let operation = words.dropFirst().first
            return operation == nil || ["show", "get-url"].contains(operation!) ? .safe : caution("git remote")
        }
        if action == "stash" {
            let operation = words.dropFirst().first ?? "push"
            if ["list", "show"].contains(operation) { return .safe }
            if ["drop", "clear"].contains(operation) { return destructive("git stash") }
            return caution("git stash")
        }
        if action == "push" {
            if hasFlag(args, ["-f", "--force", "--force-with-lease", "--mirror", "--delete"]) {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Force push can overwrite remote history.")]
                )
            }
            return caution("git push")
        }
        if action == "reset", hasFlag(args, ["--hard", "--merge", "--keep"]) { return destructive("git reset") }
        if action == "clean" || action == "restore" || (action == "checkout" && args.contains("--")) {
            return destructive("git \(action)")
        }
        if action == "reflog", words.dropFirst().contains(where: { ["delete", "expire"].contains($0) }) {
            return destructive("git reflog")
        }
        if action == "worktree", words.dropFirst().contains(where: { ["remove", "prune"].contains($0) }) {
            return destructive("git worktree")
        }
        return caution("git \(action)")
    }

    private static func classifyGitBranch(_ args: [String]) -> RiskAssessment {
        if hasFlag(args, ["-d", "-D", "--delete"]) { return destructive("git branch") }
        let flags = shortFlags(args)
        let words = operands(args)
        if words.count == 1 || flags.contains("a") || flags.contains("r") || flags.contains("l")
            || hasFlag(args, ["--list", "--show-current", "--contains", "--merged", "--no-merged"])
        {
            return .safe
        }
        return caution("git branch")
    }

    private static func classifyGitLFS(_ args: [String]) -> RiskAssessment {
        let action = operands(args).first ?? "env"
        if ["env", "ls-files", "status", "version", "help", "locks"].contains(action) { return .safe }
        if ["prune", "uninstall"].contains(action) { return destructive("git-lfs") }
        return caution("git-lfs")
    }

    private static func classifyHostedGit(_ name: String, _ args: [String]) -> RiskAssessment {
        let words = operands(args, valueOptions: ["-R", "--repo", "--hostname"])
        let readActions: Set<String> = ["list", "view", "status", "diff", "checks", "watch", "browse", "search"]
        let destructiveActions: Set<String> = ["delete", "remove", "purge"]
        if words.contains(where: destructiveActions.contains) { return destructive(name) }
        if words.contains(where: readActions.contains) { return .safe }
        return caution(name)
    }

    // MARK: - Containers, clusters, and infrastructure

    private static func classifyContainerCLI(_ name: String, _ args: [String]) -> RiskAssessment {
        let words = operands(
            args,
            valueOptions: [
                "--config", "--context", "-H", "--host", "-l", "--log-level", "--tlscacert", "--tlscert",
                "--tlskey",
            ])
        guard let action = words.first else { return .safe }
        let safe: Set<String> = [
            "ps", "images", "logs", "inspect", "stats", "version", "info", "top", "search", "events", "port",
            "diff", "history",
        ]
        let destructiveActions: Set<String> = ["rm", "rmi", "prune", "kill", "stop", "remove"]
        if safe.contains(action) { return .safe }
        if destructiveActions.contains(action) { return destructive(name) }
        if let objectAction = words.dropFirst().first {
            if ["ls", "list", "inspect", "logs", "stats", "top", "history"].contains(objectAction) { return .safe }
            if ["rm", "remove", "prune", "kill", "stop", "down"].contains(objectAction) {
                return destructive(name)
            }
        }
        return caution(name)
    }

    private static func classifyCompose(_ name: String, _ args: [String]) -> RiskAssessment {
        let action = operands(args, valueOptions: ["-f", "--file", "-p", "--project-name", "--profile"]).first ?? ""
        if ["config", "images", "logs", "ls", "ps", "top", "version"].contains(action) { return .safe }
        if ["down", "kill", "rm", "stop"].contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyKubernetes(_ name: String, _ args: [String]) -> RiskAssessment {
        let words = operands(args, valueOptions: kubernetesGlobalValueOptions)
        guard let action = words.first else { return .safe }
        let safe: Set<String> = [
            "get", "describe", "logs", "explain", "top", "version", "api-resources", "api-versions", "cluster-info",
            "events", "diff",
        ]
        if safe.contains(action) { return .safe }
        if action == "auth", words.dropFirst().first == "can-i" { return .safe }
        if action == "config" {
            let operation = words.dropFirst().first ?? "view"
            if ["view", "get-contexts", "current-context"].contains(operation) { return .safe }
            if operation == "unset" { return destructive("\(name) config") }
            return caution("\(name) config")
        }
        if action == "rollout" {
            let operation = words.dropFirst().first ?? "status"
            if ["status", "history"].contains(operation) { return .safe }
            return caution("\(name) rollout")
        }
        if ["delete", "drain"].contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyHelm(_ args: [String]) -> RiskAssessment {
        let words = operands(
            args,
            valueOptions: [
                "--kube-context", "--kubeconfig", "--namespace", "-n", "--registry-config", "--repository-cache",
                "--repository-config",
            ])
        let action = words.first ?? "help"
        if ["list", "status", "history", "get", "show", "search", "template", "lint", "version", "env", "verify"]
            .contains(action)
        {
            if hasFlag(args, ["--post-renderer"]) { return caution("helm") }
            return .safe
        }
        if ["uninstall", "delete"].contains(action) { return destructive("helm") }
        return caution("helm")
    }

    private static func classifyTerraform(_ name: String, _ args: [String]) -> RiskAssessment {
        let words = operands(args)
        let action = words.first ?? "help"
        if ["version", "show", "output", "providers", "graph", "validate", "modules", "metadata"].contains(action) {
            return .safe
        }
        if action == "plan" { return hasFlag(args, ["-out", "--out"]) ? caution(name) : .safe }
        if action == "fmt" { return hasFlag(args, ["-check", "--check"]) ? .safe : caution(name) }
        if action == "state" {
            let operation = words.dropFirst().first ?? "list"
            if ["list", "show", "pull"].contains(operation) { return .safe }
            if operation == "rm" { return destructive("\(name) state") }
            return caution("\(name) state")
        }
        if action == "workspace" {
            let operation = words.dropFirst().first ?? "show"
            if ["list", "show"].contains(operation) { return .safe }
            if operation == "delete" { return destructive("\(name) workspace") }
            return caution("\(name) workspace")
        }
        if action == "destroy" || action == "force-unlock" || (action == "apply" && args.contains("-destroy")) {
            return destructive(name)
        }
        return caution(name)
    }

    // MARK: - Packages, cloud CLIs, databases, and services

    private static func classifySystemPackageManager(_ name: String, _ args: [String]) -> RiskAssessment {
        if name == "dpkg" {
            if hasFlag(args, ["-l", "-s", "-L", "-S", "--list", "--status", "--listfiles", "--search", "--verify"]) {
                return .safe
            }
            if hasFlag(args, ["-r", "-P", "--remove", "--purge"]) { return destructive(name) }
            return caution(name)
        }
        if name == "rpm" {
            if shortFlags(args).contains("q") || hasFlag(args, ["--query", "--verify", "-V"]) { return .safe }
            if shortFlags(args).contains("e") || hasFlag(args, ["--erase"]) { return destructive(name) }
            return caution(name)
        }
        if name == "softwareupdate" {
            if hasFlag(args, ["-l", "--list", "--history"]) { return .safe }
            return caution(name)
        }
        if name == "pacman", shortFlags(args).contains("Q") { return .safe }
        let action = operands(args).first ?? ""
        let safe: Set<String> = [
            "list", "show", "search", "info", "query", "policy", "depends", "rdepends", "repolist", "check",
            "check-update", "audit", "outdated", "why", "uses", "leaves", "config", "doctor",
        ]
        let destructiveActions: Set<String> = ["remove", "uninstall", "delete", "purge", "autoremove", "erase"]
        if name == "apt-cache", action != "gencaches" { return .safe }
        if safe.contains(action) { return .safe }
        if destructiveActions.contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyDevelopmentTool(_ name: String, _ args: [String]) -> RiskAssessment {
        if name == "go", args.first == "env" {
            return hasFlag(args, ["-w", "-u"]) ? caution(name) : .safe
        }
        let action = operands(args).first ?? ""
        if action == "audit", operands(args).contains("fix") { return caution(name) }
        let safe: Set<String> = [
            "list", "ls", "show", "info", "view", "search", "outdated", "audit", "why", "explain", "tree",
            "metadata", "freeze", "check", "index", "doc", "env", "version", "help",
        ]
        let destructiveActions: Set<String> = ["uninstall", "remove", "rm", "erase", "purge"]
        if safe.contains(action) { return .safe }
        if destructiveActions.contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyCloudCLI(_ name: String, _ args: [String]) -> RiskAssessment {
        let valueOptions: Set<String> = [
            "--profile", "--region", "--endpoint-url", "--output", "--query", "--project", "--account",
            "--subscription",
            "--configuration",
        ]
        let words = operands(args, valueOptions: valueOptions)
        if words.isEmpty { return .safe }
        let readVerbs: Set<String> = [
            "list", "ls", "show", "describe", "get", "head", "query", "scan", "search", "inspect", "status",
            "version", "info", "whoami", "get-value", "get-iam-policy", "test-iam-permissions",
        ]
        let destructiveVerbs: Set<String> = [
            "delete", "remove", "rm", "purge", "destroy", "terminate", "stop", "disable", "revoke", "deallocate",
        ]
        func matches(_ word: String, verbs: Set<String>) -> Bool {
            verbs.contains(word) || verbs.contains(where: { word.hasPrefix("\($0)-") })
        }
        if args.contains("--delete") || words.contains(where: { matches($0, verbs: destructiveVerbs) }) {
            return destructive(name)
        }
        if words.contains(where: { matches($0, verbs: readVerbs) }) { return .safe }
        return caution(name)
    }

    private static func classifyDatabaseClient(_ name: String, _ args: [String]) -> RiskAssessment {
        if name == "psql", hasFlag(args, ["-l", "--list"]), !hasFlag(args, ["-c", "--command", "-f", "--file"]) {
            return .safe
        }
        if name == "sqlite3", args.contains("-readonly") {
            let commands = operands(args).dropFirst()
            if !commands.isEmpty,
                commands.allSatisfy({
                    $0.hasPrefix(".schema") || $0.hasPrefix(".tables") || $0.hasPrefix(".indexes")
                })
            {
                return .safe
            }
        }
        if let statement = embeddedStatement(args), containsDestructiveSQL(statement) { return destructive(name) }
        return caution(name)
    }

    private static func classifyDump(_ args: [String], name: String, outputFlags: Set<String>) -> RiskAssessment {
        hasFlag(args, outputFlags) ? caution(name) : .safe
    }

    private static func classifyMySQLAdmin(_ args: [String]) -> RiskAssessment {
        let action =
            operands(args, valueOptions: ["-h", "--host", "-P", "--port", "-u", "--user", "-p", "--password"])
            .first ?? "status"
        if ["ping", "status", "version", "processlist", "variables", "extended-status"].contains(action) {
            return .safe
        }
        if ["drop", "shutdown", "kill"].contains(action) { return destructive("mysqladmin") }
        return caution("mysqladmin")
    }

    private static func classifyRedis(_ args: [String]) -> RiskAssessment {
        let words = operands(
            args,
            valueOptions: [
                "-h", "-p", "-s", "-a", "--user", "--pass", "-n", "--dbnum", "--cluster", "--latency-history",
            ])
        let action = words.first?.uppercased() ?? "PING"
        let operation = words.dropFirst().first?.uppercased()
        let safe: Set<String> = [
            "PING", "INFO", "DBSIZE", "GET", "MGET", "EXISTS", "TYPE", "TTL", "PTTL", "SCAN", "SSCAN", "HSCAN",
            "ZSCAN", "KEYS", "RANDOMKEY", "STRLEN", "GETRANGE", "HGET", "HGETALL", "HLEN", "LRANGE", "LLEN",
            "SMEMBERS", "SCARD", "ZRANGE", "ZCARD", "ROLE", "TIME", "CLIENT", "COMMAND",
        ]
        let destructiveActions: Set<String> = [
            "DEL", "UNLINK", "FLUSHALL", "FLUSHDB", "SHUTDOWN", "REPLICAOF", "SLAVEOF",
        ]
        if action == "CLIENT" {
            if operation.map({ ["KILL", "PAUSE", "UNBLOCK"].contains($0) }) == true {
                return destructive("redis-cli")
            }
            if operation.map({ ["LIST", "INFO", "GETNAME", "ID", "TRACKINGINFO"].contains($0) }) == true {
                return .safe
            }
            return caution("redis-cli")
        }
        if action == "CONFIG" { return operation == "GET" ? .safe : caution("redis-cli") }
        if safe.contains(action) { return .safe }
        if destructiveActions.contains(action) { return destructive("redis-cli") }
        return caution("redis-cli")
    }

    private static func classifyProcessManager(_ name: String, _ args: [String]) -> RiskAssessment {
        let action = operands(args).first ?? "status"
        let safe: Set<String> = [
            "status", "list", "ls", "pid", "version", "describe", "info", "logs", "jlist", "prettylist", "monit",
        ]
        let destructiveActions: Set<String> = ["stop", "delete", "remove", "kill", "shutdown", "uninstall"]
        if safe.contains(action) { return .safe }
        if destructiveActions.contains(action) { return destructive(name) }
        return caution(name)
    }

    private static func classifyServerBinary(_ name: String, _ args: [String]) -> RiskAssessment {
        if args.contains(where: { ["stop", "graceful-stop"].contains($0) }) { return destructive(name) }
        if name == "nginx", args.contains("-s"), args.contains(where: { ["stop", "quit"].contains($0) }) {
            return destructive(name)
        }
        if name == "nginx", hasFlag(args, ["-t", "-T", "-V", "-v"]) { return .safe }
        if ["apachectl", "apache2ctl", "httpd"].contains(name),
            args.contains(where: { ["configtest", "-t", "-S", "-V", "-v"].contains($0) })
        {
            return .safe
        }
        if name == "haproxy", hasFlag(args, ["-c", "-vv", "-v"]) { return .safe }
        if name == "caddy",
            ["validate", "adapt", "version", "list-modules", "environ"].contains(operands(args).first ?? "")
        {
            return .safe
        }
        return caution(name)
    }

    // MARK: - Shared helpers

    private static func caution(_ displayName: String) -> RiskAssessment {
        RiskAssessment(
            risk: .caution,
            reasons: [String(localized: "`\(displayName)` changes system, file, or external state.")]
        )
    }

    private static func destructive(_ displayName: String) -> RiskAssessment {
        RiskAssessment(
            risk: .destructive,
            reasons: [String(localized: "`\(displayName)` can irreversibly destroy data or state.")]
        )
    }

    private static func hasFlag(_ args: [String], _ names: Set<String>) -> Bool {
        args.contains { argument in
            names.contains(argument)
                || names.contains(String(argument.split(separator: "=", maxSplits: 1).first ?? Substring(argument)))
                || names.contains(where: { name in
                    name.count == 2 && name.hasPrefix("-") && !name.hasPrefix("--")
                        && argument.hasPrefix("-") && !argument.hasPrefix("--")
                        && argument.dropFirst().contains(name.last!)
                })
        }
    }

    private static func shortFlags(_ args: [String]) -> Set<Character> {
        Set(
            args.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }
                .flatMap { $0.dropFirst().prefix { $0 != "=" } }
        )
    }

    private static func embeddedStatement(_ args: [String]) -> String? {
        let options: Set<String> = ["-c", "--command", "-e", "--execute", "--eval"]
        for (index, argument) in args.enumerated() {
            if let equals = argument.firstIndex(of: "="), options.contains(String(argument[..<equals])) {
                return String(argument[argument.index(after: equals)...])
            }
            if options.contains(argument), args.indices.contains(index + 1) { return args[index + 1] }
        }
        return nil
    }

    private static func containsDestructiveSQL(_ statement: String) -> Bool {
        let pattern = #"(?i)\b(DROP|TRUNCATE|DELETE|FLUSH|SHUTDOWN)\b"#
        return statement.range(of: pattern, options: .regularExpression) != nil
    }

    private static let readOnlyCommands: Set<String> = [
        "ls", "ll", "cat", "bat", "less", "more", "head", "tail", "df", "du", "ps", "top", "htop", "btop",
        "free", "uptime", "uname", "whoami", "id", "pwd", "which", "whereis", "type", "file", "stat", "wc",
        "cut", "tr", "column", "jq", "grep", "egrep", "fgrep", "ag", "printenv", "echo",
        "printf", "lsof", "netstat", "ss", "ping", "traceroute", "dig", "nslookup", "host", "md5sum", "sha1sum",
        "sha256sum", "cksum", "cmp", "basename", "dirname", "realpath", "readlink", "groups", "last", "w", "who",
        "lsblk", "vmstat", "iostat", "sar", "nproc", "lscpu", "lsmem", "lspci", "lsusb", "true", "false", "test",
        "[", "pgrep", "pidof", "pstree", "mpstat", "pidstat", "findmnt", "getconf", "locale", "getent",
        "iptables-save", "ip6tables-save",
        "sestatus", "getenforce", "lsattr", "lsns", "dpkg-query", "zcat", "zgrep", "zless", "bzcat", "tac", "nl",
        "rev", "fold", "expand", "unexpand", "paste", "join", "comm", "seq", "numfmt", "base64", "strings", "od",
        "hexdump", "arch", "pvs", "vgs", "lvs", "pvdisplay", "vgdisplay", "lvdisplay", "pg_isready", "mongostat",
        "mongotop", "mysqlshow",
    ]

    private static let cautionCommands: Set<String> = [
        "mv", "cp", "ln", "mkdir", "touch", "install", "tee", "make", "cmake", "ninja", "ssh-keygen",
        "ssh-copy-id", "scp", "sftp", "unzip", "gunzip", "gzip", "zip", "xz", "bzip2", "curl", "wget", "fetch",
        "http", "https", "xh", "nano", "vim", "vi", "emacs", "export", "source", ".", "alias", "unalias",
        "usermod", "groupadd", "systemd-run", "screen", "tmux", "at", "batch", "renice", "createdb", "pg_restore",
        "mongoexport", "mongodump", "mongoimport", "mongorestore", "vgcreate", "lvcreate", "pvcreate", "vgextend",
        "lvextend", "resize2fs",
    ]

    private static let destructiveCommands: Set<String> = [
        "dd", "mkfs", "mkfs.ext4", "mkfs.xfs", "mkfs.btrfs", "shred", "wipefs", "truncate", "userdel", "groupdel",
        "deluser", "delgroup", "reboot", "shutdown", "halt", "poweroff", "init", "swapoff", "umount", "setenforce",
        "chroot", "mkswap", "vgremove", "lvremove", "pvremove", "dropdb", "iptables-restore", "ip6tables-restore",
    ]

    private static let argumentSensitiveCommands: Set<String> = [
        "rm", "find", "chmod", "chown", "chgrp", "awk", "sort", "tree", "diff", "rg", "uniq", "blkid", "sed",
        "yq", "xxd", "tar", "date", "hostname",
        "mount", "dmesg", "systemctl", "service", "journalctl", "timedatectl", "hostnamectl", "localectl", "loginctl",
        "resolvectl", "networkctl", "ip", "bridge", "tc", "ifconfig", "route", "arp", "ethtool", "nvidia-smi",
        "sensors", "sysctl", "swapon", "ulimit", "fdisk", "parted", "gdisk", "zfs", "zpool", "diskutil", "defaults",
        "launchctl", "losetup", "iptables", "ip6tables", "nft", "ufw", "firewall-cmd", "kill", "pkill", "killall",
        "rsync", "crontab", "git", "git-lfs", "gh", "glab", "docker", "podman", "nerdctl", "docker-compose",
        "podman-compose", "kubectl", "oc", "helm", "terraform", "tofu", "ansible", "ansible-playbook",
        "ansible-vault", "ansible-config", "ansible-doc", "ansible-inventory", "ansible-lint", "aws", "az", "gcloud",
        "apt", "apt-get", "apt-cache", "dpkg", "rpm", "yum", "dnf", "pacman", "apk", "zypper", "snap",
        "flatpak", "brew", "softwareupdate", "pkg", "npm", "pnpm", "yarn", "bun", "pip", "pip3", "pipx", "gem",
        "cargo", "go", "psql", "mysql", "sqlite3", "mongosh", "pg_dump", "mysqldump", "mysqladmin", "redis-cli",
        "supervisorctl", "pm2", "nginx", "apachectl", "apache2ctl", "httpd", "haproxy", "caddy", "command", "builtin",
        "sudo", "doas", "env", "exec", "nice", "ionice", "timeout", "stdbuf", "setsid", "nohup", "watch", "busybox",
        "toybox", "xargs", "parallel", "eval", "sh", "bash", "zsh", "dash", "fish", "ksh", "ssh",
    ]
}
