import Foundation

nonisolated enum CommandRisk: Int, Comparable, Sendable, CaseIterable {
    case safe = 0
    case caution = 1
    case destructive = 2

    nonisolated static func < (lhs: CommandRisk, rhs: CommandRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .safe: String(localized: "Read-only")
        case .caution: String(localized: "Modifies state")
        case .destructive: String(localized: "Destructive")
        }
    }

    var symbol: String {
        switch self {
        case .safe: "eye"
        case .caution: "exclamationmark.triangle"
        case .destructive: "exclamationmark.octagon.fill"
        }
    }
}

nonisolated struct RiskAssessment: Sendable, Hashable {
    var risk: CommandRisk
    /// Human-readable justifications, shown under the command card so the user
    /// can see *why* something was flagged rather than trusting a bare badge.
    var reasons: [String]

    /// Destructive commands always require a second confirmation. Caution
    /// commands require one click. Safe commands may be one-click-run if the
    /// user opted into that in Settings.
    var requiresSecondConfirmation: Bool { risk == .destructive }
}

/// Classifies a shell command by how much damage running it could do.
///
/// This runs entirely on the client and deliberately does **not** ask the model
/// to rate its own suggestion — a model that is wrong about a command is also
/// likely to be wrong about how dangerous it is. It is advisory input to the UI,
/// never an authorisation: the user still clicks.
///
/// Design rule: **fail closed.** An unrecognised command is `.caution`, never
/// `.safe`. Being wrong in the safe direction just costs an extra click; being
/// wrong in the other direction costs a production database.
nonisolated enum CommandRiskClassifier {

    // MARK: - Public entry point

    static func assess(_ command: String) -> RiskAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RiskAssessment(risk: .safe, reasons: [])
        }

        var risk = CommandRisk.safe
        var reasons: [String] = []

        func merge(_ assessment: RiskAssessment) {
            risk = max(risk, assessment.risk)
            for reason in assessment.reasons where !reasons.contains(reason) {
                reasons.append(reason)
            }
        }

        func raise(_ level: CommandRisk, _ reason: String) {
            merge(RiskAssessment(risk: level, reasons: [reason]))
        }

        if isForkBomb(trimmed) {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Matches a fork-bomb pattern.")]
            )
        }

        for statement in splitStatements(trimmed) {
            let stages = splitPipeline(statement)

            // A download piped into an interpreter executes arbitrary remote
            // code. Neither half looks dangerous alone, so this has to be
            // checked across the pipeline rather than per-command.
            if let reason = pipeToInterpreterReason(stages) {
                raise(.destructive, reason)
            }

            for stage in stages {
                merge(assessSingle(stage))
            }

            if let assessment = redirectionAssessment(statement) {
                merge(assessment)
            }
        }

        return RiskAssessment(risk: risk, reasons: reasons)
    }

    // MARK: - Single command

    private static func assessSingle(_ stage: String) -> RiskAssessment {
        var tokens = tokenize(stage)
        // Strip leading `FOO=bar` environment assignments so `LANG=C rm -rf x`
        // is still read as an `rm`.
        while let first = tokens.first, isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }
        guard var head = tokens.first else {
            return RiskAssessment(risk: .safe, reasons: [])
        }

        var reasons: [String] = []
        var floor = CommandRisk.safe

        // `sudo` / `doas` — never safe, and reclassify what follows.
        if head == "sudo" || head == "doas" {
            floor = .caution
            reasons.append(String(localized: "Runs with elevated privileges."))
            tokens.removeFirst()
            while let next = tokens.first, next.hasPrefix("-") { tokens.removeFirst() }
            guard let newHead = tokens.first else {
                return RiskAssessment(risk: floor, reasons: reasons)
            }
            head = newHead
        }

        // Normalise `/usr/bin/rm` and `./script.sh`.
        let name = String(head.split(separator: "/").last ?? Substring(head))
        let args = Array(tokens.dropFirst())

        if let specific = specificRule(name: name, args: args) {
            reasons.append(contentsOf: specific.reasons)
            return RiskAssessment(risk: max(floor, specific.risk), reasons: reasons)
        }

        if destructiveCommands.contains(name) {
            reasons.append(String(localized: "`\(name)` can irreversibly destroy data or state."))
            return RiskAssessment(risk: .destructive, reasons: reasons)
        }

        if cautionCommands.contains(name) {
            reasons.append(String(localized: "`\(name)` changes system or file state."))
            return RiskAssessment(risk: max(floor, .caution), reasons: reasons)
        }

        if readOnlyCommands.contains(name) {
            return RiskAssessment(risk: floor, reasons: reasons)
        }

        // Fail closed.
        reasons.append(String(localized: "`\(name)` is not a recognised read-only command."))
        return RiskAssessment(risk: max(floor, .caution), reasons: reasons)
    }

    /// Rules where the verdict depends on the arguments, not just the command.
    private static func specificRule(name: String, args: [String]) -> RiskAssessment? {
        let flags = args.filter { $0.hasPrefix("-") }
        let joinedFlags = flags.joined()

        switch name {
        case "rm":
            let recursive = joinedFlags.contains("r") || joinedFlags.contains("R")
            let forced = joinedFlags.contains("f")
            if recursive || forced {
                let targetsRoot = args.contains { $0 == "/" || $0.hasPrefix("/*") }
                if targetsRoot {
                    return RiskAssessment(
                        risk: .destructive,
                        reasons: [String(localized: "Recursive delete targeting the filesystem root.")]
                    )
                }
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Recursive or forced delete — no undo, no trash.")]
                )
            }
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Deletes files permanently.")]
            )

        case "find":
            if args.contains("-delete") {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "`find -delete` removes every match.")]
                )
            }
            if args.contains("-exec") || args.contains("-execdir") || args.contains("-ok") {
                return RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "`find -exec` runs a command per match.")]
                )
            }
            return RiskAssessment(risk: .safe, reasons: [])

        case "chmod", "chown", "chgrp":
            if joinedFlags.contains("R") {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Recursive ownership or permission change.")]
                )
            }
            return RiskAssessment(
                risk: .caution,
                reasons: [String(localized: "Changes file ownership or permissions.")]
            )

        case "sed":
            if joinedFlags.contains("i") {
                return RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "`sed -i` edits files in place.")]
                )
            }
            return RiskAssessment(risk: .safe, reasons: [])

        case "fdisk", "parted", "gdisk":
            if flags.contains("-l") || args.contains("--list") {
                return RiskAssessment(risk: .safe, reasons: [])
            }
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Interactive partition editor.")]
            )

        case "git":
            guard let sub = args.first(where: { !$0.hasPrefix("-") }) else {
                return RiskAssessment(risk: .safe, reasons: [])
            }
            switch sub {
            case "status", "log", "diff", "show", "blame":
                return RiskAssessment(risk: .safe, reasons: [])
            case "branch", "fetch":
                return RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "Updates or may update local Git references.")]
                )
            case "remote":
                let operation = args.drop(while: { $0 != sub }).dropFirst()
                    .first(where: { !$0.hasPrefix("-") })
                if operation == nil || operation == "show" || operation == "get-url" {
                    return RiskAssessment(risk: .safe, reasons: [])
                }
                return RiskAssessment(risk: .caution, reasons: [])
            case "stash":
                let operation = args.drop(while: { $0 != sub }).dropFirst()
                    .first(where: { !$0.hasPrefix("-") })
                if operation == "list" || operation == "show" {
                    return RiskAssessment(risk: .safe, reasons: [])
                }
                return RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "Changes the working tree or stash.")]
                )
            case "push":
                if args.contains("--force") || args.contains("-f") || args.contains("--force-with-lease") {
                    return RiskAssessment(
                        risk: .destructive,
                        reasons: [String(localized: "Force push can overwrite remote history.")]
                    )
                }
                return RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "Publishes commits to a remote.")]
                )
            case "reset":
                if args.contains("--hard") {
                    return RiskAssessment(
                        risk: .destructive,
                        reasons: [String(localized: "`git reset --hard` discards uncommitted work.")]
                    )
                }
                return RiskAssessment(risk: .caution, reasons: [])
            case "clean":
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "`git clean` deletes untracked files.")]
                )
            default:
                return RiskAssessment(risk: .caution, reasons: [])
            }

        case "systemctl", "service":
            let sub = args.first { !$0.hasPrefix("-") } ?? ""
            if sub == "status" || sub == "list-units" || sub == "show" || sub == "cat" {
                return RiskAssessment(risk: .safe, reasons: [])
            }
            if sub == "stop" || sub == "disable" || sub == "mask" {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Stops or disables a running service.")]
                )
            }
            return RiskAssessment(
                risk: .caution,
                reasons: [String(localized: "Changes service state.")]
            )

        case "docker", "podman":
            let sub = args.first { !$0.hasPrefix("-") } ?? ""
            switch sub {
            case "ps", "images", "logs", "inspect", "stats", "version", "info", "top":
                return RiskAssessment(risk: .safe, reasons: [])
            case "rm", "rmi", "prune", "kill":
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Removes containers, images, or volumes.")]
                )
            case "system":
                if args.contains("prune") {
                    return RiskAssessment(
                        risk: .destructive,
                        reasons: [String(localized: "`docker system prune` reclaims and deletes broadly.")]
                    )
                }
                return RiskAssessment(risk: .caution, reasons: [])
            default:
                return RiskAssessment(risk: .caution, reasons: [])
            }

        case "kubectl":
            let sub = args.first { !$0.hasPrefix("-") } ?? ""
            switch sub {
            case "get", "describe", "logs", "explain", "top", "version", "config":
                return RiskAssessment(risk: .safe, reasons: [])
            case "delete":
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Deletes cluster resources.")]
                )
            default:
                return RiskAssessment(risk: .caution, reasons: [])
            }

        case "kill", "pkill", "killall":
            if joinedFlags.contains("9") {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "SIGKILL gives the process no chance to clean up.")]
                )
            }
            return RiskAssessment(
                risk: .caution,
                reasons: [String(localized: "Signals a running process.")]
            )

        case "rsync":
            if args.contains("--delete") || args.contains("--delete-after") {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "`rsync --delete` removes files missing from the source.")]
                )
            }
            return RiskAssessment(risk: .caution, reasons: [])

        case "journalctl":
            if args.contains(where: { $0.hasPrefix("--vacuum") }) {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "Vacuuming permanently drops journal history.")]
                )
            }
            return RiskAssessment(risk: .safe, reasons: [])

        case "tar":
            if joinedFlags.contains("x") {
                return RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "Extraction writes files, possibly overwriting.")]
                )
            }
            return RiskAssessment(risk: .safe, reasons: [])

        case "crontab":
            if joinedFlags.contains("r") {
                return RiskAssessment(
                    risk: .destructive,
                    reasons: [String(localized: "`crontab -r` erases the crontab with no prompt.")]
                )
            }
            if joinedFlags.contains("l") {
                return RiskAssessment(risk: .safe, reasons: [])
            }
            return RiskAssessment(risk: .caution, reasons: [])

        default:
            return nil
        }
    }

    // MARK: - Pipelines and redirection

    private static func pipeToInterpreterReason(_ stages: [String]) -> String? {
        guard stages.count > 1 else { return nil }
        let fetchers: Set<String> = ["curl", "wget", "fetch"]
        let interpreters: Set<String> = [
            "sh", "bash", "zsh", "fish", "dash", "python", "python3", "perl", "ruby", "node",
        ]

        let heads = stages.map { stage -> String in
            let raw = tokenize(stage).first ?? ""
            return String(raw.split(separator: "/").last ?? Substring(raw))
        }
        guard let firstHead = heads.first, fetchers.contains(firstHead) else { return nil }
        guard heads.dropFirst().contains(where: { interpreters.contains($0) }) else { return nil }
        return String(
            localized: "Pipes downloaded content straight into an interpreter — this executes untrusted remote code.")
    }

    private static func redirectionAssessment(_ statement: String) -> RiskAssessment? {
        guard let target = redirectTarget(statement) else { return nil }
        if target == "/dev/null" { return nil }
        if target.hasPrefix("/dev/sd") || target.hasPrefix("/dev/disk") || target.hasPrefix("/dev/nvme") {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Writes directly to a block device.")]
            )
        }
        return RiskAssessment(
            risk: .caution,
            reasons: [String(localized: "Overwrites `\(target)`.")]
        )
    }

    /// Finds the target of a truncating `>` redirect, ignoring `>>` appends,
    /// `2>&1` duplications, and anything inside quotes.
    private static func redirectTarget(_ statement: String) -> String? {
        let chars = Array(statement)
        var i = 0
        var quoteState = QuoteState()
        while i < chars.count {
            let c = chars[i]
            if quoteState.consume(c) {
                i += 1
                continue
            }
            if c == ">" && !quoteState.isQuoted {
                if i + 1 < chars.count && chars[i + 1] == ">" {
                    i += 2
                    continue
                }
                if i + 1 < chars.count && chars[i + 1] == "&" {
                    i += 2
                    continue
                }
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                var target = ""
                while j < chars.count, chars[j] != " ", chars[j] != ";", chars[j] != "|" {
                    target.append(chars[j])
                    j += 1
                }
                return target.isEmpty ? nil : target
            }
            i += 1
        }
        return nil
    }

    /// Catches `:(){ :|:& };:` and its renamed variants (`bomb(){ bomb|bomb& }`)
    /// by looking for a function that pipes itself into itself in the background.
    private static func isForkBomb(_ command: String) -> Bool {
        let squeezed = command.filter { !$0.isWhitespace }
        guard let parenRange = squeezed.range(of: "(){") else { return false }
        let name = String(squeezed[squeezed.startIndex..<parenRange.lowerBound])
        guard !name.isEmpty else { return false }
        return squeezed.contains("\(name)|\(name)&")
    }

    // MARK: - Lexing

    /// Splits on `;`, `&&`, `||`, and newlines, respecting quotes.
    private static func splitStatements(_ command: String) -> [String] {
        splitRespectingQuotes(command, separators: [";", "&&", "||", "\n"])
    }

    /// Splits a statement into pipeline stages on `|`, respecting quotes and
    /// leaving `||` alone (already handled by `splitStatements`).
    private static func splitPipeline(_ statement: String) -> [String] {
        splitRespectingQuotes(statement, separators: ["|"])
    }

    private static func splitRespectingQuotes(_ input: String, separators: [String]) -> [String] {
        var results: [String] = []
        var current = ""
        var quoteState = QuoteState()
        let chars = Array(input)
        let longestSeparatorsFirst = separators.sorted { $0.count > $1.count }
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if quoteState.consume(c) {
                current.append(c)
                i += 1
                continue
            }

            if !quoteState.isQuoted {
                var matched: String?
                for separator in longestSeparatorsFirst {
                    let end = i + separator.count
                    if end <= chars.count, String(chars[i..<end]) == separator {
                        matched = separator
                        break
                    }
                }
                if let sep = matched {
                    results.append(current)
                    current = ""
                    i += sep.count
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        results.append(current)

        let trimmedResults = results.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmedResults.filter { !$0.isEmpty }
    }

    /// `FOO=bar` — a non-empty name of shell-identifier characters before an `=`.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<equals]
        guard !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func tokenize(_ stage: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoteState = QuoteState()

        for c in stage {
            if quoteState.consume(c) { continue }
            if c.isWhitespace && !quoteState.isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(c)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private struct QuoteState {
        private var isInSingleQuotes = false
        private var isInDoubleQuotes = false

        var isQuoted: Bool { isInSingleQuotes || isInDoubleQuotes }

        /// Updates the quote context and reports whether `character` was a quote
        /// delimiter. Callers decide whether the delimiter belongs in output.
        mutating func consume(_ character: Character) -> Bool {
            if character == "'" && !isInDoubleQuotes {
                isInSingleQuotes.toggle()
                return true
            }
            if character == "\"" && !isInSingleQuotes {
                isInDoubleQuotes.toggle()
                return true
            }
            return false
        }
    }

    // MARK: - Tables

    /// Commands that only read. Anything not listed here is treated as at least
    /// `.caution`, so this list being incomplete is safe — it just means an
    /// extra click.
    private static let readOnlyCommands: Set<String> = [
        "ls", "ll", "cat", "bat", "less", "more", "head", "tail", "df", "du",
        "ps", "top", "htop", "btop", "free", "uptime", "uname", "whoami", "id",
        "pwd", "date", "hostname", "which", "whereis", "type", "file", "stat",
        "wc", "sort", "uniq", "cut", "tr", "column", "jq", "yq", "awk",
        "grep", "egrep", "fgrep", "rg", "ag", "tree", "env", "printenv",
        "echo", "printf", "dmesg", "lsof", "netstat", "ss", "ip", "ifconfig",
        "ping", "traceroute", "dig", "nslookup", "host", "arp", "route",
        "md5sum", "sha1sum", "sha256sum", "cksum", "diff", "cmp", "basename",
        "dirname", "realpath", "readlink", "groups", "last", "w", "who",
        "lsblk", "blkid", "mount", "vmstat", "iostat", "sar", "nproc",
        "nvidia-smi", "sensors", "lscpu", "lsmem", "lspci", "lsusb", "true", "false",
    ]

    private static let cautionCommands: Set<String> = [
        "mv", "cp", "ln", "mkdir", "touch", "install", "tee", "truncate",
        "apt", "apt-get", "yum", "dnf", "pacman", "apk", "brew", "npm", "pnpm",
        "yarn", "pip", "pip3", "gem", "cargo", "go", "make", "cmake", "ninja",
        "ssh-keygen", "ssh-copy-id", "scp", "sftp", "unzip", "gunzip", "gzip",
        "zip", "xz", "bzip2", "curl", "wget", "nano", "vim", "vi", "emacs",
        "export", "source", "alias", "unalias", "usermod", "groupadd",
        "systemd-run", "nohup", "screen", "tmux", "at", "batch", "renice",
        "mysql", "psql", "redis-cli", "mongosh", "sqlite3", "terraform",
        "ansible", "ansible-playbook", "helm", "git-lfs",
    ]

    private static let destructiveCommands: Set<String> = [
        "dd", "mkfs", "mkfs.ext4", "mkfs.xfs", "mkfs.btrfs", "shred", "wipefs",
        "userdel", "groupdel", "deluser", "delgroup", "reboot", "shutdown",
        "halt", "poweroff", "init", "swapoff", "umount", "iptables", "nft",
        "ufw", "firewall-cmd", "setenforce", "chroot", "mkswap", "losetup",
        "vgremove", "lvremove", "pvremove", "zpool", "zfs",
    ]
}
