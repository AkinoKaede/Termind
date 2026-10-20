// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated enum CommandRiskEngine {
    private static let maximumCommandLength = 32_768
    private static let maximumRecursionDepth = 8

    static func assess(_ command: String) -> RiskAssessment {
        assess(command, depth: 0)
    }

    private static func assess(_ command: String, depth: Int) -> RiskAssessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .safe }
        guard trimmed.count <= maximumCommandLength, depth <= maximumRecursionDepth else {
            return RiskAssessment(
                risk: .caution,
                reasons: [String(localized: "Command analysis exceeded the supported complexity limit.")]
            )
        }
        if isForkBomb(trimmed) {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Matches a fork-bomb pattern.")]
            )
        }

        let parsed = ShellCommandSyntax.parse(trimmed)
        var result = RiskAssessment.safe
        if parsed.isAmbiguous {
            result.merge(
                RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "Contains shell syntax that cannot be proven read-only.")]
                ))
        }

        for substitution in parsed.substitutions {
            result.merge(assess(substitution, depth: depth + 1))
        }
        for pipeline in parsed.pipelineGroups where downloadsIntoInterpreter(pipeline) {
            result.merge(
                RiskAssessment(
                    risk: .destructive,
                    reasons: [
                        String(
                            localized:
                                "Pipes downloaded content straight into an interpreter — this executes untrusted remote code."
                        )
                    ]
                ))
        }
        for command in parsed.commands {
            result.merge(assessSingle(command, depth: depth))
        }
        for redirection in parsed.redirections {
            result.merge(redirectionAssessment(redirection))
        }
        return result
    }

    private static func assessSingle(_ command: String, depth: Int) -> RiskAssessment {
        let tokenized = ShellCommandSyntax.tokenize(command)
        var tokens = tokenized.values
        var result = RiskAssessment.safe
        if tokenized.isAmbiguous {
            result.merge(
                RiskAssessment(
                    risk: .caution,
                    reasons: [String(localized: "Contains shell syntax that cannot be proven read-only.")]
                ))
        }
        while let first = tokens.first, ShellCommandSyntax.isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }
        guard let head = tokens.first else { return result }
        let name = ShellCommandSyntax.executableName(head)
        let args = Array(tokens.dropFirst())

        if CommandRiskRules.isKnown(name), CommandRiskRules.isStandaloneHelpOrVersionRequest(args) {
            return result
        }

        if let control = controlBody(name: name, args: args) {
            result.merge(assess(control, depth: depth + 1))
            return result
        }

        if let wrapped = wrappedCommand(name: name, args: args) {
            result.merge(wrapped.floor)
            guard let child = wrapped.child, !child.isEmpty else { return result }
            result.merge(assess(child, depth: depth + 1))
            return result
        }

        result.merge(CommandRiskRules.classify(name: name, args: args))

        if name == "find" {
            for child in findExecutedCommands(args) {
                result.merge(assess(child, depth: depth + 1))
            }
        } else if ["docker", "podman", "nerdctl"].contains(name), let child = containerExecCommand(args) {
            result.merge(assess(child, depth: depth + 1))
        } else if ["kubectl", "oc"].contains(name), let child = kubernetesExecCommand(args) {
            result.merge(assess(child, depth: depth + 1))
        }
        return result
    }

    private static func controlBody(name: String, args: [String]) -> String? {
        let commandIntroducers: Set<String> = ["if", "then", "elif", "while", "until", "do", "else", "!"]
        guard commandIntroducers.contains(name), !args.isEmpty else { return nil }
        return args.joined(separator: " ")
    }

    private static func wrappedCommand(name: String, args: [String]) -> WrappedCommand? {
        switch name {
        case "sudo":
            let child = childAfterOptions(
                args,
                flags: ["-A", "-b", "-E", "-e", "-H", "-i", "-K", "-k", "-n", "-P", "-S", "-s", "-V"],
                valueOptions: ["-C", "-D", "-g", "-h", "-p", "-R", "-r", "-T", "-t", "-U", "-u"]
            )
            return WrappedCommand(
                child: child?.joined(separator: " "),
                floor: RiskAssessment(
                    risk: .caution, reasons: [String(localized: "Runs with elevated privileges.")])
            )
        case "doas":
            let child = childAfterOptions(args, flags: ["-L", "-n", "-s"], valueOptions: ["-C", "-u"])
            return WrappedCommand(
                child: child?.joined(separator: " "),
                floor: RiskAssessment(
                    risk: .caution, reasons: [String(localized: "Runs with elevated privileges.")])
            )
        case "env":
            if let splitIndex = args.firstIndex(where: {
                $0 == "-S" || $0 == "--split-string" || $0.hasPrefix("--split-string=")
            }) {
                let option = args[splitIndex]
                let splitCommand: String
                if let equals = option.firstIndex(of: "=") {
                    splitCommand = String(option[option.index(after: equals)...])
                } else if args.indices.contains(splitIndex + 1) {
                    splitCommand = args[splitIndex + 1]
                } else {
                    return WrappedCommand(child: nil, floor: .ambiguous)
                }
                return WrappedCommand(child: splitCommand, floor: .safe)
            }
            guard
                var child = childAfterOptions(
                    args,
                    flags: ["-0", "-i", "--ignore-environment", "--null"],
                    valueOptions: ["-C", "-S", "-u", "--chdir", "--split-string", "--unset"]
                )
            else {
                return WrappedCommand(child: nil, floor: .ambiguous)
            }
            while let first = child.first, ShellCommandSyntax.isEnvironmentAssignment(first) {
                child.removeFirst()
            }
            return WrappedCommand(child: child.joined(separator: " "), floor: .safe)
        case "command", "builtin":
            if args.contains("-v") || args.contains("-V") { return nil }
            let child = childAfterOptions(args, flags: ["-p"], valueOptions: [])
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "exec":
            let child = childAfterOptions(args, flags: ["-c", "-l"], valueOptions: ["-a"])
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "nice":
            let child = childAfterOptions(
                args, flags: [], valueOptions: ["-n", "--adjustment"], acceptsNumericFlags: true)
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "ionice":
            let targetsExistingProcess = args.contains(where: {
                ["-p", "-P", "-u", "--pid", "--pgid", "--uid"].contains($0)
                    || $0.hasPrefix("--pid=") || $0.hasPrefix("--pgid=") || $0.hasPrefix("--uid=")
            })
            if targetsExistingProcess {
                let changesPriority = args.contains(where: {
                    ["-c", "-n", "--class", "--classdata"].contains($0)
                        || $0.hasPrefix("--class=") || $0.hasPrefix("--classdata=")
                })
                return WrappedCommand(child: nil, floor: changesPriority ? .ambiguous : .safe)
            }
            let child = childAfterOptions(
                args,
                flags: ["-t", "--ignore", "--classdata", "-h"],
                valueOptions: ["-c", "-n", "-p", "-P", "-u", "--class", "--classdata", "--pid", "--pgid", "--uid"]
            )
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "timeout":
            guard
                var remaining = childAfterOptions(
                    args,
                    flags: ["--foreground", "--preserve-status", "-v", "--verbose"],
                    valueOptions: ["-k", "-s", "--kill-after", "--signal"]
                ), !remaining.isEmpty
            else {
                return WrappedCommand(child: nil, floor: .ambiguous)
            }
            remaining.removeFirst()
            return WrappedCommand(child: remaining.joined(separator: " "), floor: .safe)
        case "stdbuf":
            let child = childAfterOptions(
                args, flags: [], valueOptions: ["-e", "-i", "-o", "--error", "--input", "--output"])
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "setsid":
            let child = childAfterOptions(
                args, flags: ["-c", "-f", "-w", "--ctty", "--fork", "--wait"], valueOptions: [])
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "nohup":
            let child = childAfterOptions(args, flags: [], valueOptions: [])
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "watch":
            let child = childAfterOptions(
                args,
                flags: [
                    "-b", "-d", "-e", "-g", "-t", "-x", "--beep", "--differences", "--errexit", "--chgexit",
                    "--no-title", "--exec",
                ],
                valueOptions: ["-n", "-p", "--interval", "--precise"]
            )
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "busybox", "toybox":
            let child = childAfterOptions(args, flags: [], valueOptions: [])
            return WrappedCommand(child: child?.joined(separator: " "), floor: .safe)
        case "xargs":
            let child = childAfterOptions(
                args,
                flags: ["-0", "-p", "-r", "-t", "-x", "--null", "--no-run-if-empty", "--verbose"],
                valueOptions: [
                    "-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "--arg-file", "--delimiter",
                    "--eof", "--replace", "--max-lines", "--max-args", "--max-procs", "--max-chars",
                ]
            )
            return WrappedCommand(child: child?.joined(separator: " ") ?? "echo", floor: .safe)
        case "parallel":
            let child = childAfterOptions(
                args,
                flags: ["-k", "--keep-order", "--line-buffer", "--will-cite"],
                valueOptions: ["-j", "-S", "--jobs", "--sshlogin", "--tagstring"]
            )
            return WrappedCommand(child: child?.joined(separator: " "), floor: .ambiguous)
        case "eval":
            return WrappedCommand(child: args.joined(separator: " "), floor: .safe)
        case "sh", "bash", "zsh", "dash", "fish", "ksh":
            guard
                let commandIndex = args.firstIndex(where: { argument in
                    argument == "-c"
                        || (argument.hasPrefix("-") && !argument.hasPrefix("--") && argument.dropFirst().contains("c"))
                }), args.indices.contains(commandIndex + 1)
            else {
                return WrappedCommand(child: nil, floor: .ambiguous)
            }
            return WrappedCommand(child: args[commandIndex + 1], floor: .safe)
        case "ssh":
            guard
                var remaining = childAfterOptions(
                    args,
                    flags: [
                        "-4", "-6", "-A", "-a", "-C", "-f", "-G", "-g", "-K", "-k", "-M", "-N", "-n", "-q", "-s", "-T",
                        "-t", "-V", "-v", "-X", "-x", "-Y", "-y",
                    ],
                    valueOptions: [
                        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m",
                        "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
                    ]
                ), !remaining.isEmpty
            else {
                return WrappedCommand(child: nil, floor: .remote)
            }
            remaining.removeFirst()
            return WrappedCommand(child: remaining.joined(separator: " "), floor: .remote)
        default:
            return nil
        }
    }

    private static func childAfterOptions(
        _ args: [String],
        flags: Set<String>,
        valueOptions: Set<String>,
        acceptsNumericFlags: Bool = false
    ) -> [String]? {
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--" { return Array(args.dropFirst(index + 1)) }
            guard argument.hasPrefix("-"), argument != "-" else { return Array(args.dropFirst(index)) }
            if acceptsNumericFlags, Int(argument) != nil {
                index += 1
                continue
            }
            let optionName = String(argument.split(separator: "=", maxSplits: 1).first ?? Substring(argument))
            if flags.contains(optionName) {
                index += 1
                continue
            }
            if valueOptions.contains(optionName) {
                index += argument.contains("=") ? 1 : 2
                if index > args.count { return nil }
                continue
            }
            if argument.hasPrefix("-"), !argument.hasPrefix("--") {
                let optionCharacters = Array(argument.dropFirst())
                var consumed = false
                for (offset, character) in optionCharacters.enumerated() {
                    let shortOption = "-\(character)"
                    if flags.contains(shortOption) { continue }
                    if valueOptions.contains(shortOption) {
                        index += offset == optionCharacters.count - 1 ? 2 : 1
                        if index > args.count { return nil }
                        consumed = true
                        break
                    }
                    return nil
                }
                if consumed { continue }
                index += 1
                continue
            }
            return nil
        }
        return []
    }

    private static func findExecutedCommands(_ args: [String]) -> [String] {
        var commands: [String] = []
        var index = 0
        while index < args.count {
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(args[index]) else {
                index += 1
                continue
            }
            let start = index + 1
            var end = start
            while end < args.count, args[end] != ";", args[end] != "+" { end += 1 }
            if start < end { commands.append(args[start..<end].joined(separator: " ")) }
            index = max(end + 1, start)
        }
        return commands
    }

    private static func containerExecCommand(_ args: [String]) -> String? {
        guard let execIndex = args.firstIndex(of: "exec") else { return nil }
        let execArguments = Array(args.dropFirst(execIndex + 1))
        guard
            var remaining = childAfterOptions(
                execArguments,
                flags: ["-d", "--detach", "-i", "--interactive", "--privileged", "-t", "--tty"],
                valueOptions: ["-e", "--env", "--env-file", "--detach-keys", "-u", "--user", "-w", "--workdir"]
            ), !remaining.isEmpty
        else {
            return nil
        }
        remaining.removeFirst()
        return remaining.joined(separator: " ")
    }

    private static func kubernetesExecCommand(_ args: [String]) -> String? {
        let words = CommandRiskRules.operands(args, valueOptions: CommandRiskRules.kubernetesGlobalValueOptions)
        guard words.first == "exec", let separator = args.firstIndex(of: "--"), args.indices.contains(separator + 1)
        else {
            return nil
        }
        return args.dropFirst(separator + 1).joined(separator: " ")
    }

    private static func redirectionAssessment(_ redirection: ShellOutputRedirection) -> RiskAssessment {
        let target = redirection.target
        let harmlessTargets: Set<String> = [
            "/dev/null", "/dev/stdout", "/dev/stderr", "/dev/fd/1", "/dev/fd/2", "/proc/self/fd/1",
            "/proc/self/fd/2",
        ]
        if harmlessTargets.contains(target) { return .safe }
        if target.hasPrefix("/dev/") || target.hasPrefix("/proc/") || target.hasPrefix("/sys/") {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Writes directly to a device or kernel control path.")]
            )
        }
        if redirection.mode == .force {
            return RiskAssessment(
                risk: .destructive,
                reasons: [String(localized: "Force-overwrites `\(target)`.")]
            )
        }
        return RiskAssessment(
            risk: .caution,
            reasons: [String(localized: "Writes to `\(target)`.")]
        )
    }

    private static func downloadsIntoInterpreter(_ stages: [String]) -> Bool {
        guard stages.count > 1, let first = effectiveExecutable(in: stages[0]) else { return false }
        let fetchers: Set<String> = ["curl", "wget", "fetch", "http", "https", "xh"]
        let interpreters: Set<String> = [
            "sh", "bash", "zsh", "fish", "dash", "ksh", "python", "python3", "perl", "ruby", "node",
            "php", "lua", "Rscript", "deno", "bun", "pwsh",
        ]
        guard fetchers.contains(first) else { return false }
        return stages.dropFirst().contains { stage in
            effectiveExecutable(in: stage).map(interpreters.contains) == true
        }
    }

    private static func effectiveExecutable(in command: String) -> String? {
        var tokens = ShellCommandSyntax.tokenize(command).values
        while let first = tokens.first, ShellCommandSyntax.isEnvironmentAssignment(first) { tokens.removeFirst() }
        var iterations = 0
        while let first = tokens.first, iterations < maximumRecursionDepth {
            let name = ShellCommandSyntax.executableName(first)
            guard ["sudo", "doas", "env", "command", "exec", "nice", "stdbuf", "setsid", "nohup"].contains(name),
                let wrapped = wrappedCommand(name: name, args: Array(tokens.dropFirst())),
                let child = wrapped.child
            else {
                return name
            }
            tokens = ShellCommandSyntax.tokenize(child).values
            iterations += 1
        }
        return tokens.first.map(ShellCommandSyntax.executableName)
    }

    private static func isForkBomb(_ command: String) -> Bool {
        let squeezed = command.filter { !$0.isWhitespace }
        guard let parenRange = squeezed.range(of: "(){") else { return false }
        let name = String(squeezed[squeezed.startIndex..<parenRange.lowerBound])
        return !name.isEmpty && squeezed.contains("\(name)|\(name)&")
    }

    private struct WrappedCommand {
        var child: String?
        var floor: RiskAssessment
    }
}

nonisolated extension RiskAssessment {
    static var safe: RiskAssessment { RiskAssessment(risk: .safe, reasons: []) }

    static var ambiguous: RiskAssessment {
        RiskAssessment(
            risk: .caution,
            reasons: [String(localized: "Contains shell syntax that cannot be proven read-only.")]
        )
    }

    static var remote: RiskAssessment {
        RiskAssessment(
            risk: .caution,
            reasons: [String(localized: "Runs a command on another host.")]
        )
    }

    mutating func merge(_ other: RiskAssessment) {
        risk = max(risk, other.risk)
        for reason in other.reasons where !reasons.contains(reason) { reasons.append(reason) }
    }
}
