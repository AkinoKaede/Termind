import CSSH2
import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// Installs a small cwd-reporting hook before remote output reaches Ghostty.
/// The probe, its echo, and the installation command stay inside this state
/// machine; only the login banner and the final integrated prompt are emitted.
public nonisolated struct RemoteShellIntegrationBootstrap: Sendable {
    enum Diagnostic: Sendable, Equatable {
        enum TimeoutStage: String, Sendable {
            case lateProbe = "late_probe"
            case installation
        }

        enum SkipReason: String, Sendable {
            case unsupportedShell = "unsupported_shell"
            case userInput = "user_input"
        }

        case probeDelayed
        case installed(late: Bool, homeResolved: Bool, systemInfoAvailable: Bool)
        case skipped(SkipReason)
        case timedOut(stage: TimeoutStage, late: Bool)
    }

    public nonisolated struct Update: Sendable {
        public var command: Data?
        public var visibleOutput: Data?
        public var isComplete = false
        public var integrationInstalled = false
        public var shell: String?
        public var systemInfo: RemoteSystemInfo?
        public var homeDirectory: String?
        public var historySource: ShellHistorySource?
        public var homeResolutionUnavailable = false
        var diagnostic: Diagnostic?
    }

    private enum Phase: Sendable {
        case probing
        case scanningForLateProbe
        case suppressingLateProbe
        case installing
        case complete
    }

    private static let responseTimeout: UInt64 = 3_000_000_000
    private static let quietTimeout: UInt64 = 500_000_000

    public let token: String
    public let startCommand: Data
    private let charset: RemoteCharset
    private var deadline: UInt64
    private var phase: Phase = .probing
    private var buffer = Data()
    private var preservedOutput = Data()
    private var lastActivity: UInt64?
    private var userDidWrite = false
    private var installationStartedLate = false
    private var detectedShell: String?
    private var detectedSystemInfo: RemoteSystemInfo?

    private var probeEchoMarker: Data {
        Data("__TRMD_\(token)_PROBE__".utf8)
    }

    public init(
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        charset: RemoteCharset = .utf8,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.token = token
        self.charset = charset
        // The POSIX helper reads os-release as inert assignment text instead of
        // sourcing it. Its output precedes the shell marker, so a missing `sh`
        // still leaves the original shell-only bootstrap path usable.
        // Put a token near the start of the line so the bootstrap echo can still
        // be recognized when zsh or fish redraws the remaining command with
        // syntax-highlighting escape sequences. `true` accepts the inert token
        // in all supported shells and produces no output.
        var probeCommand = " command true '__TRMD_\(token)_PROBE__'; "
        probeCommand += "command sh -c 'f=; did=; dlike=; dver=; "
        probeCommand += "[ -r /etc/os-release ] && f=/etc/os-release; "
        probeCommand += "[ -z \"$f\" ] && [ -r /usr/lib/os-release ] && f=/usr/lib/os-release; "
        probeCommand += "if [ -n \"$f\" ]; then while IFS= read -r line; do case \"$line\" in "
        probeCommand += "ID=*) did=${line#ID=} ;; ID_LIKE=*) dlike=${line#ID_LIKE=} ;; "
        probeCommand += "VERSION_ID=*) dver=${line#VERSION_ID=} ;; esac; "
        probeCommand += "done < \"$f\"; fi; kn=$(uname -s 2>/dev/null); "
        probeCommand += "kr=$(uname -r 2>/dev/null); ka=$(uname -m 2>/dev/null); "
        probeCommand += "printf \"\\n__TRMD_%s_SYSTEM__%s|%s|%s|%s|%s|%s__\\n\" "
        probeCommand += "\"$1\" \"$did\" \"$dlike\" \"$dver\" \"$kn\" \"$kr\" \"$ka\"' sh '\(token)'; "
        probeCommand += "printf '\\n__TRMD_%s_SHELL__%s__\\n' '\(token)' \"$SHELL\"\n"
        startCommand = Data(probeCommand.utf8)
        deadline = now + Self.responseTimeout
    }

    public mutating func noteUserInput() {
        userDidWrite = true
    }

    public mutating func receive(
        _ data: Data, now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Update {
        guard phase != .complete else {
            return Update(visibleOutput: data, isComplete: true)
        }
        buffer.append(data)
        switch phase {
        case .probing:
            return receiveProbe(now: now, isLate: false)
        case .scanningForLateProbe:
            return scanForLateProbe(now: now)
        case .suppressingLateProbe:
            lastActivity = now
            return receiveProbe(now: now, isLate: true)
        case .installing:
            return receiveInstallation()
        case .complete:
            return Update(visibleOutput: data, isComplete: true)
        }
    }

    /// Advances time-dependent bootstrap work. The first probe timeout restores
    /// the terminal but deliberately keeps a streaming signature scanner alive:
    /// a slow remote may echo the probe only after the UI is interactive again.
    public mutating func poll(
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Update {
        switch phase {
        case .probing where now >= deadline:
            let isEchoingProbe = buffer.range(of: probeEchoMarker) != nil
            let visible = cleanBufferedOutput()
            phase = isEchoingProbe ? .suppressingLateProbe : .scanningForLateProbe
            if isEchoingProbe { deadline = now + Self.responseTimeout }
            lastActivity = nil
            return Update(
                visibleOutput: visible, homeResolutionUnavailable: true,
                diagnostic: .probeDelayed
            )
        case .scanningForLateProbe:
            guard let lastActivity, now >= lastActivity + Self.quietTimeout,
                !buffer.isEmpty
            else { return Update() }
            let visible = buffer
            buffer.removeAll(keepingCapacity: false)
            self.lastActivity = nil
            return Update(visibleOutput: visible)
        case .suppressingLateProbe:
            guard
                now >= deadline
                    || lastActivity.map({ now >= $0 + Self.quietTimeout }) == true
            else { return Update() }
            let visible = outputAfterLastLineBreak(in: buffer)
            finish()
            return Update(
                visibleOutput: visible, isComplete: true,
                diagnostic: .timedOut(stage: .lateProbe, late: true)
            )
        case .installing where now >= deadline:
            let visible =
                installationStartedLate
                ? outputAfterLastLineBreak(in: buffer)
                : cleanBufferedOutput()
            finish()
            return Update(
                visibleOutput: visible, isComplete: true,
                diagnostic: .timedOut(stage: .installation, late: installationStartedLate)
            )
        case .probing, .installing, .complete:
            return Update()
        }
    }

    private mutating func receiveProbe(now: UInt64, isLate: Bool) -> Update {
        let prefix = Data("__TRMD_\(token)_SHELL__".utf8)
        guard let prefixRange = buffer.range(of: prefix) else { return Update() }
        let shellStart = prefixRange.upperBound
        let terminator = Data("__".utf8)
        guard
            let terminatorRange = buffer.range(
                of: terminator, in: shellStart..<buffer.endIndex
            ),
            let lineEnd = buffer[terminatorRange.upperBound...].firstIndex(of: 0x0A)
        else { return Update() }

        if !isLate {
            preservedOutput = removingSystemInfoMarker(
                from: outputBeforeCommand(
                    in: Data(buffer[..<prefixRange.lowerBound])
                )
            )
        }
        let shellBytes = Data(buffer[shellStart..<terminatorRange.lowerBound])
        let shellPath =
            (try? RemoteCharsetStreamConverter.decode(shellBytes, charset: charset))
            ?? String(decoding: shellBytes, as: UTF8.self)
        let shell = shellPath.split(separator: "/").last.map(String.init)?.lowercased()
        detectedShell = shell
        detectedSystemInfo = parseSystemInfo(in: buffer)
        let suffix = Data(buffer[buffer.index(after: lineEnd)...])
        buffer.removeAll(keepingCapacity: false)

        guard let command = installationCommand(for: shell) else {
            var visible = preservedOutput
            visible.append(suffix)
            finish()
            return Update(
                visibleOutput: visible, isComplete: true, shell: detectedShell,
                systemInfo: detectedSystemInfo,
                diagnostic: .skipped(.unsupportedShell)
            )
        }
        guard !(isLate && userDidWrite) else {
            var visible = preservedOutput
            visible.append(suffix)
            finish()
            return Update(
                visibleOutput: visible, isComplete: true, shell: detectedShell,
                systemInfo: detectedSystemInfo,
                diagnostic: .skipped(.userInput)
            )
        }
        phase = .installing
        installationStartedLate = isLate
        deadline = now + Self.responseTimeout
        lastActivity = nil
        return Update(command: command)
    }

    private mutating func receiveInstallation() -> Update {
        let marker = Data("__TRMD_\(token)_DONE__".utf8)
        guard let markerRange = buffer.range(of: marker),
            let lineEnd = buffer[markerRange.upperBound...].firstIndex(of: 0x0A)
        else { return Update() }

        var visible = preservedOutput
        visible.append(Data(buffer[buffer.index(after: lineEnd)...]))
        let homeDirectory = parseHomeDirectory(in: buffer)
        let historySource = parseHistorySource(in: buffer)
        finish()
        return Update(
            visibleOutput: visible, isComplete: true,
            integrationInstalled: true, shell: detectedShell,
            systemInfo: detectedSystemInfo,
            homeDirectory: homeDirectory, historySource: historySource,
            diagnostic: .installed(
                late: installationStartedLate, homeResolved: homeDirectory != nil,
                systemInfoAvailable: detectedSystemInfo != nil
            )
        )
    }

    private func parseHistorySource(in data: Data) -> ShellHistorySource? {
        guard let shell = detectedShell.flatMap(ShellHistorySource.Shell.init(rawValue:)) else { return nil }
        let prefix = Data("__TRMD_\(token)_HISTORY__".utf8)
        guard let start = data.range(of: prefix)?.upperBound,
            let end = data[start...].firstIndex(of: 0x0A)
        else { return nil }
        var payload = Data(data[start..<end])
        if payload.last == 0x0D { payload.removeLast() }
        let path = RemoteCommandEventFilter.decodePercentEncoded(payload, charset: charset)
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return ShellHistorySource(shell: shell, path: path)
    }

    private mutating func parseHomeDirectory(in data: Data) -> String? {
        let prefix = Data("__TRMD_\(token)_HOME__".utf8)
        guard let prefixRange = data.range(of: prefix),
            let lineEnd = data[prefixRange.upperBound...].firstIndex(of: 0x0A)
        else { return nil }
        var payload = Data(data[prefixRange.upperBound..<lineEnd])
        if payload.last == 0x0D { payload.removeLast() }
        let decoded = RemoteCommandEventFilter.decodePercentEncoded(payload, charset: charset)
        guard
            decoded.hasPrefix("/"),
            !decoded.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.newlines.contains($0)
            })
        else { return nil }
        return decoded
    }

    private mutating func parseSystemInfo(in data: Data) -> RemoteSystemInfo? {
        let prefix = Data("__TRMD_\(token)_SYSTEM__".utf8)
        guard let prefixRange = data.range(of: prefix),
            let lineEnd = data[prefixRange.upperBound...].firstIndex(of: 0x0A)
        else { return nil }

        var payload = Data(data[prefixRange.upperBound..<lineEnd])
        if payload.last == 0x0D { payload.removeLast() }
        guard payload.count >= 2, payload.suffix(2).elementsEqual(Data("__".utf8))
        else { return nil }
        payload.removeLast(2)
        let fields =
            (try? RemoteCharsetStreamConverter.decode(payload, charset: charset))
            ?? String(decoding: payload, as: UTF8.self)
        return RemoteSystemInfo(probeFields: fields)
    }

    private func removingSystemInfoMarker(from data: Data) -> Data {
        let prefix = Data("__TRMD_\(token)_SYSTEM__".utf8)
        guard let prefixRange = data.range(of: prefix),
            let lineEnd = data[prefixRange.upperBound...].firstIndex(of: 0x0A)
        else { return data }
        var result = Data(data[..<prefixRange.lowerBound])
        result.append(Data(data[data.index(after: lineEnd)...]))
        return result
    }

    private mutating func scanForLateProbe(now: UInt64) -> Update {
        let echo = Data(startCommand.dropFirst().dropLast())
        let marker = Data("__TRMD_\(token)_SHELL__".utf8)
        let targets = [echo, probeEchoMarker, marker]

        if let match = earliestMatch(of: targets, in: buffer) {
            var suppressionStart: Data.Index
            if match.targetIndex == 1 {
                suppressionStart = startOfLine(containing: match.range.lowerBound, in: buffer)
            } else {
                suppressionStart = match.range.lowerBound
            }
            if match.targetIndex == 0, suppressionStart > buffer.startIndex {
                let preceding = buffer.index(before: suppressionStart)
                if buffer[preceding] == 0x20 { suppressionStart = preceding }
            }
            let visible = Data(buffer[..<suppressionStart])
            buffer = Data(buffer[suppressionStart...])
            phase = .suppressingLateProbe
            lastActivity = now
            deadline = now + Self.responseTimeout

            let probe = receiveProbe(now: now, isLate: true)
            return mergingVisible(visible, into: probe)
        }

        var retainedCount = longestSuffixMatchingPrefix(of: targets, in: buffer)
        if retainedCount > 0, buffer.count > retainedCount {
            let retainedStart = buffer.index(buffer.endIndex, offsetBy: -retainedCount)
            let preceding = buffer.index(before: retainedStart)
            if buffer[preceding] == 0x20 { retainedCount += 1 }
        }
        let visibleEnd = buffer.index(buffer.endIndex, offsetBy: -retainedCount)
        let visible = Data(buffer[..<visibleEnd])
        buffer = Data(buffer[visibleEnd...])
        lastActivity = buffer.isEmpty ? nil : now
        return Update(visibleOutput: visible.isEmpty ? nil : visible)
    }

    private func earliestMatch(of targets: [Data], in data: Data)
        -> (range: Range<Data.Index>, targetIndex: Int)?
    {
        targets.enumerated().compactMap { index, target in
            data.range(of: target).map { (range: $0, targetIndex: index) }
        }.min { lhs, rhs in lhs.range.lowerBound < rhs.range.lowerBound }
    }

    private func longestSuffixMatchingPrefix(of targets: [Data], in data: Data) -> Int {
        let maximum = targets.map(\.count).max() ?? 0
        guard !data.isEmpty, maximum > 1 else { return 0 }
        for count in stride(from: min(data.count, maximum - 1), through: 1, by: -1) {
            if targets.contains(where: { target in
                target.count >= count && data.suffix(count).elementsEqual(target.prefix(count))
            }) {
                return count
            }
        }
        return 0
    }

    private func mergingVisible(_ visible: Data, into update: Update) -> Update {
        guard !visible.isEmpty else { return update }
        var combined = visible
        if let following = update.visibleOutput { combined.append(following) }
        return Update(
            command: update.command, visibleOutput: combined,
            isComplete: update.isComplete,
            integrationInstalled: update.integrationInstalled,
            shell: update.shell, systemInfo: update.systemInfo,
            homeDirectory: update.homeDirectory, historySource: update.historySource,
            homeResolutionUnavailable: update.homeResolutionUnavailable,
            diagnostic: update.diagnostic
        )
    }

    private mutating func cleanBufferedOutput() -> Data {
        var visible = preservedOutput
        if visible.isEmpty { visible = outputBeforeCommand(in: buffer) }
        let suffix: Data
        if let markerRange = buffer.range(of: probeEchoMarker),
            buffer[markerRange.upperBound...].firstIndex(of: 0x0A) == nil
        {
            // The line editor has drawn the probe but the shell has not yet
            // accepted the line. Keeping the unfinished line would reveal it.
            suffix = Data()
        } else {
            suffix = outputAfterLastLineBreak(in: buffer)
        }
        if !suffix.isEmpty { visible.append(suffix) }
        buffer.removeAll(keepingCapacity: false)
        preservedOutput.removeAll(keepingCapacity: false)
        return visible
    }

    private func outputAfterLastLineBreak(in data: Data) -> Data {
        guard let lineEnd = data.lastIndex(of: 0x0A),
            data.index(after: lineEnd) < data.endIndex
        else { return Data() }
        return Data(data[data.index(after: lineEnd)...])
    }

    private mutating func finish() {
        phase = .complete
        buffer.removeAll(keepingCapacity: false)
        preservedOutput.removeAll(keepingCapacity: false)
        lastActivity = nil
    }

    private func outputBeforeCommand(in data: Data) -> Data {
        let echo = Data(startCommand.dropLast())
        let boundary: Data.Index
        if let echoRange = data.range(of: echo) {
            boundary = echoRange.lowerBound
        } else if let markerRange = data.range(of: probeEchoMarker) {
            boundary = startOfLine(containing: markerRange.lowerBound, in: data)
        } else {
            boundary = data.endIndex
        }
        let prefix = data[..<boundary]
        guard let lineEnd = prefix.lastIndex(of: 0x0A) else { return Data() }
        return Data(prefix[...lineEnd])
    }

    private func startOfLine(containing index: Data.Index, in data: Data) -> Data.Index {
        data[..<index].lastIndex(of: 0x0A).map { data.index(after: $0) }
            ?? data.startIndex
    }

    private func installationCommand(for shell: String?) -> Data? {
        let marker =
            "builtin printf '\\n__TRMD_%s_HOME__%s\\n' '\(token)' \"$(__termind_encode \"$HOME\")\"; builtin printf '\\n__TRMD_%s_DONE__\\n' '\(token)'"
        let historyMarker =
            "__termind_history_path=\"${HISTFILE-}\"; if [[ -n \"$__termind_history_path\" && \"$__termind_history_path\" != /* ]]; then __termind_history_path=\"$PWD/$__termind_history_path\"; fi; builtin printf '\\n__TRMD_%s_HISTORY__%s\\n' '\(token)' \"$(__termind_encode \"$__termind_history_path\")\"; unset __termind_history_path; "
        let command: String
        switch shell {
        case "bash":
            // The fallback DEBUG trap also observes commands run by PROMPT_COMMAND.
            // Keep capture closed around the existing prompt hooks, then report
            // the saved user-command status only after those hooks finish.
            command =
                [
                    " if [[ \"${__termind_integration_token:-}\" != \"\(token)\" ]]; then",
                    "__termind_integration_token=\"\(token)\";",
                    "__termind_encode() { builtin local s=\"$1\" out= c hex i LC_ALL=C; for ((i=0;i<${#s};i++)); do c=${s:i:1}; case \"$c\" in [a-zA-Z0-9.~_/-]) out+=\"$c\";; *) builtin printf -v hex '%%%02X' \"'$c\"; out+=\"$hex\";; esac; done; builtin printf %s \"$out\"; };",
                    "__termind_report_cwd() { builtin printf '\\e]7;file://localhost%s\\a' \"$(__termind_encode \"$PWD\")\"; };",
                    "__termind_report_prompt() { builtin local status=$? duration=0; if (( $# > 0 )); then status=$1; fi; if [[ -n \"${__termind_command_active:-}\" ]]; then if (( SECONDS >= ${__termind_command_started_seconds:-0} )); then duration=$(( (SECONDS - __termind_command_started_seconds) * 1000 )); fi; builtin printf '\\e]777;TermindCommandFinished=\(token);%s;%s\\a' \"$status\" \"$duration\"; builtin unset __termind_command_active __termind_command_started_seconds; fi; __termind_report_cwd; builtin printf '\\e]777;TermindPrompt=\(token)\\a'; __termind_command_ready=1; return \"$status\"; };",
                    "__termind_prompt_begin() { __termind_prompt_status=$?; __termind_command_ready=0; return \"$__termind_prompt_status\"; };",
                    "__termind_prompt_end() { builtin local status=\"${__termind_prompt_status:-$?}\"; builtin unset __termind_prompt_status; __termind_report_prompt \"$status\"; };",
                    "__termind_report_command() { builtin local status=$? cmd=\"${1:-}\"; case \"$cmd\" in __termind_*) return \"$status\";; esac; [[ \"${__termind_command_ready:-0}\" == 1 ]] || return \"$status\"; __termind_command_ready=0; [[ -n \"${__termind_busy:-}\" ]] && return \"$status\"; __termind_busy=1; if [[ -z \"$cmd\" ]]; then cmd=\"$(builtin fc -ln -0)\"; cmd=\"${cmd#\"${cmd%%[![:space:]]*}\"}\"; fi; if [[ -n \"$cmd\" ]]; then builtin printf '\\e]777;TermindCommand=\(token);%s\\a' \"$(__termind_encode \"$cmd\")\"; __termind_command_active=1; __termind_command_started_seconds=$SECONDS; fi; builtin unset __termind_busy; return \"$status\"; };",
                    "__termind_get_trap() { builtin local -a terms; builtin eval \"terms=( $(builtin trap -p \"${1:-DEBUG}\") )\"; builtin printf %s \"${terms[2]:-}\"; };",
                    "__termind_compose_draft() { builtin printf '\\e]777;TermindDraft=\(token);%s\\a' \"$(__termind_encode \"$READLINE_LINE\")\"; };",
                    "__termind_compose_clear() { READLINE_LINE=; READLINE_POINT=0; };",
                    "for __termind_map in emacs-standard vi-insertion vi-command; do builtin bind -m \"$__termind_map\" -x '\"\\e[777;1~\":__termind_compose_draft'; builtin bind -m \"$__termind_map\" -x '\"\\e[777;2~\":__termind_compose_clear'; done;",
                    "builtin unset __termind_map;",
                    "if [[ -n \"${bash_preexec_imported:-}\" ]]; then",
                    "[[ \" ${preexec_functions[*]} \" == *\" __termind_report_command \"* ]] || preexec_functions+=(__termind_report_command);",
                    "[[ \" ${precmd_functions[*]} \" == *\" __termind_report_prompt \"* ]] || precmd_functions=(__termind_report_prompt \"${precmd_functions[@]}\");",
                    "else",
                    "__termind_debug_trap=\"$(__termind_get_trap DEBUG)\";",
                    "if [[ \"$__termind_debug_trap\" != *\"__termind_report_command\"* ]]; then if [[ -n \"$__termind_debug_trap\" ]]; then builtin trap \"$__termind_debug_trap\"$'\\n''__termind_report_command \"$BASH_COMMAND\"' DEBUG; else builtin trap '__termind_report_command \"$BASH_COMMAND\"' DEBUG; fi; fi;",
                    "if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == \"declare -a \"* ]]; then",
                    "[[ \" ${PROMPT_COMMAND[*]} \" == *\" __termind_prompt_begin \"* ]] || PROMPT_COMMAND=(__termind_prompt_begin \"${PROMPT_COMMAND[@]}\" __termind_prompt_end);",
                    "elif [[ \"${PROMPT_COMMAND:-}\" != *\"__termind_prompt_begin\"* ]]; then",
                    "PROMPT_COMMAND=\"__termind_prompt_begin\"$'\\n'\"${PROMPT_COMMAND:-}\"$'\\n'\"__termind_prompt_end\";",
                    "fi;",
                    "fi;",
                    "fi;",
                    "\(historyMarker)\(marker);",
                    "__termind_report_prompt",
                ].joined(separator: " ") + "\n"
        case "zsh":
            // Unlike bash, zsh reserves `status` as a read-only special parameter.
            // Assigning it aborts this function and the remaining prompt hooks.
            command =
                " if [[ \"${__termind_integration_token:-}\" != \"\(token)\" ]]; then typeset -g __termind_integration_token=\"\(token)\"; function __termind_encode { builtin local s=\"$1\" out= c hex i; builtin local LC_ALL=C; for ((i=1;i<=${#s};i++)); do c=${s[i]}; case \"$c\" in [a-zA-Z0-9.~_/-]) out+=\"$c\";; *) builtin printf -v hex '%%%02X' \"'$c\"; out+=\"$hex\";; esac; done; builtin printf %s \"$out\"; }; function __termind_report_cwd { builtin printf '\\e]7;file://localhost%s\\a' \"$(__termind_encode \"$PWD\")\"; }; function __termind_report_prompt { builtin local command_status=$? duration=0; if [[ -n \"${__termind_command_active:-}\" ]]; then if (( SECONDS >= ${__termind_command_started_seconds:-0} )); then duration=$(( (SECONDS - __termind_command_started_seconds) * 1000 )); fi; builtin printf '\\e]777;TermindCommandFinished=\(token);%s;%s\\a' \"$command_status\" \"$duration\"; unset __termind_command_active __termind_command_started_seconds; fi; __termind_report_cwd; builtin printf '\\e]777;TermindPrompt=\(token)\\a'; return \"$command_status\"; }; function __termind_report_command { builtin printf '\\e]777;TermindCommand=\(token);%s\\a' \"$(__termind_encode \"$1\")\"; typeset -g __termind_command_active=1; typeset -g __termind_command_started_seconds=$SECONDS; }; function __termind_compose_draft { builtin printf '\\e]777;TermindDraft=\(token);%s\\a' \"$(__termind_encode \"$BUFFER\")\"; zle redisplay; }; function __termind_compose_clear { BUFFER=; CURSOR=0; zle redisplay; }; zle -N __termind_compose_draft; zle -N __termind_compose_clear; for __termind_map in emacs viins vicmd; do bindkey -M $__termind_map '\\e[777;1~' __termind_compose_draft 2>/dev/null; bindkey -M $__termind_map '\\e[777;2~' __termind_compose_clear 2>/dev/null; done; unset __termind_map; autoload -Uz add-zsh-hook; (( ${preexec_functions[(Ie)__termind_report_command]} )) || add-zsh-hook preexec __termind_report_command; precmd_functions=(__termind_report_prompt ${precmd_functions:#__termind_report_prompt}); (( ${chpwd_functions[(Ie)__termind_report_cwd]} )) || add-zsh-hook chpwd __termind_report_cwd; fi; \(historyMarker)\(marker); __termind_report_prompt\n"
        case "fish":
            command =
                " if not set -q __termind_integration_token; or test \"$__termind_integration_token\" != \"\(token)\"; set -g __termind_integration_token \"\(token)\"; function __termind_report_cwd --on-variable PWD; printf '\\e]7;file://localhost%s\\a' (string escape --style=url $PWD); end; function __termind_report_prompt --on-event fish_prompt; __termind_report_cwd; printf '\\e]777;TermindPrompt=\(token)\\a'; end; function __termind_report_command --on-event fish_preexec; printf '\\e]777;TermindCommand=\(token);%s\\a' (string escape --style=url -- $argv[1]); set -g __termind_command_active 1; end; function __termind_report_finished --on-event fish_postexec; set -l command_status $status; set -l command_duration $CMD_DURATION; if set -q __termind_command_active; printf '\\e]777;TermindCommandFinished=\(token);%s;%s\\a' $command_status $command_duration; set -e __termind_command_active; end; end; function __termind_compose_draft; set -l encoded (string escape --style=url -- (commandline)); printf '\\e]777;TermindDraft=\(token);%s\\a' \"$encoded\"; end; function __termind_compose_clear; commandline -r ''; commandline -C 0; end; for __termind_map in default insert visual; bind -M $__termind_map \\e'[777;1~' __termind_compose_draft 2>/dev/null; bind -M $__termind_map \\e'[777;2~' __termind_compose_clear 2>/dev/null; end; set -e __termind_map; end; set -l __termind_hname fish; if set -q fish_history; set __termind_hname \"$fish_history\"; end; set -l __termind_hbase \"$HOME/.local/share\"; if set -q XDG_DATA_HOME; and test -n \"$XDG_DATA_HOME\"; set __termind_hbase \"$XDG_DATA_HOME\"; end; set -l __termind_hpath ''; if test -n \"$__termind_hname\"; set __termind_hpath \"$__termind_hbase/fish/$__termind_hname\"_history; end; printf '\\n__TRMD_%s_HISTORY__%s\\n' '\(token)' (string escape --style=url -- \"$__termind_hpath\"); set -e __termind_hname __termind_hbase __termind_hpath; printf '\\n__TRMD_%s_HOME__%s\\n' '\(token)' (string escape --style=url $HOME); printf '\\n__TRMD_%s_DONE__\\n' '\(token)'; __termind_report_prompt\n"
        default:
            return nil
        }
        return Data(command.utf8)
    }
}

/// Removes authenticated command-report OSC sequences before output reaches
/// Ghostty and emits their decoded payloads separately. The session token makes
/// ordinary OSC output in a remote program ineligible to forge local history.
public nonisolated struct RemoteCommandEventFilter: Sendable {
    public static let maximumPayloadBytes = 64 * 1024

    public nonisolated enum Event: Sendable, Equatable {
        case commandStarted(String)
        case commandFinished(Int32, duration: TimeInterval?)
        case promptReady
        case draft(String)
    }

    public nonisolated struct Update: Sendable {
        public var visibleOutput = Data()
        public var events: [Event] = []
    }

    private let commandPrefix: Data
    private let commandFinishedPrefix: Data
    private let promptPrefix: Data
    private let draftPrefix: Data
    private let charset: RemoteCharset
    private var buffer = Data()

    public init(token: String, charset: RemoteCharset = .utf8) {
        commandPrefix = Data("\u{1B}]777;TermindCommand=\(token);".utf8)
        commandFinishedPrefix = Data("\u{1B}]777;TermindCommandFinished=\(token);".utf8)
        promptPrefix = Data("\u{1B}]777;TermindPrompt=\(token)".utf8)
        draftPrefix = Data("\u{1B}]777;TermindDraft=\(token);".utf8)
        self.charset = charset
    }

    public mutating func receive(_ data: Data) -> Update {
        buffer.append(data)
        var update = Update()
        while let match = earliestMarker() {
            let marker = match.range
            if marker.lowerBound > buffer.startIndex {
                update.visibleOutput.append(buffer[..<marker.lowerBound])
            }
            guard let end = buffer[marker.upperBound...].firstIndex(of: 0x07) else {
                if buffer.distance(from: marker.upperBound, to: buffer.endIndex)
                    > Self.maximumPayloadBytes
                {
                    // A forged or truncated authenticated marker must not retain
                    // the terminal stream forever. Drop the malformed frame and
                    // resume with the next received bytes.
                    buffer.removeAll(keepingCapacity: false)
                } else {
                    buffer = Data(buffer[marker.lowerBound...])
                }
                return update
            }
            let payload = Data(buffer[marker.upperBound..<end])
            guard payload.count <= Self.maximumPayloadBytes else {
                buffer = Data(buffer[buffer.index(after: end)...])
                continue
            }
            switch match.kind {
            case .command:
                let command = Self.decodePercentEncoded(payload, charset: charset)
                if !command.isEmpty {
                    update.events.append(.commandStarted(command))
                }
            case .commandFinished:
                let fields = String(decoding: payload, as: UTF8.self)
                    .split(separator: ";", omittingEmptySubsequences: false)
                if let statusText = fields.first, fields.count <= 2,
                    let status = Int32(statusText), (0...255).contains(status)
                {
                    let duration =
                        fields.count == 2
                        ? Self.duration(milliseconds: fields[1])
                        : nil
                    update.events.append(.commandFinished(status, duration: duration))
                }
            case .prompt:
                guard payload.isEmpty else { break }
                update.events.append(.promptReady)
            case .draft:
                update.events.append(.draft(Self.decodePercentEncoded(payload, charset: charset)))
            }
            buffer = Data(buffer[buffer.index(after: end)...])
        }

        let retained = longestSuffixMatchingPrefix()
        let visibleEnd = buffer.index(buffer.endIndex, offsetBy: -retained)
        update.visibleOutput.append(buffer[..<visibleEnd])
        buffer = Data(buffer[visibleEnd...])
        return update
    }

    private func longestSuffixMatchingPrefix() -> Int {
        let prefixes = [commandPrefix, commandFinishedPrefix, promptPrefix, draftPrefix]
        guard !buffer.isEmpty else { return 0 }
        let maximum = prefixes.map(\.count).max() ?? 0
        guard maximum > 1 else { return 0 }
        for count in stride(from: min(buffer.count, maximum - 1), through: 1, by: -1) {
            if prefixes.contains(where: {
                $0.count >= count && buffer.suffix(count).elementsEqual($0.prefix(count))
            }) {
                return count
            }
        }
        return 0
    }

    private enum MarkerKind { case command, commandFinished, prompt, draft }

    private func earliestMarker() -> (range: Range<Data.Index>, kind: MarkerKind)? {
        let candidates: [(Range<Data.Index>, MarkerKind)] = [
            buffer.range(of: commandPrefix).map { ($0, .command) },
            buffer.range(of: commandFinishedPrefix).map { ($0, .commandFinished) },
            buffer.range(of: promptPrefix).map { ($0, .prompt) },
            buffer.range(of: draftPrefix).map { ($0, .draft) },
        ].compactMap { $0 }
        return candidates.min { $0.0.lowerBound < $1.0.lowerBound }
    }

    public static func decodePercentEncoded(_ data: Data, charset: RemoteCharset = .utf8) -> String {
        let bytes = Array(data)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x25, index + 2 < bytes.count,
                let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2])
            {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        let decodedData = Data(decoded)
        return (try? RemoteCharsetStreamConverter.decode(decodedData, charset: charset))
            ?? String(decoding: decodedData, as: UTF8.self)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func duration(milliseconds text: Substring) -> TimeInterval? {
        guard let milliseconds = UInt64(text), milliseconds <= 31_536_000_000 else {
            return nil
        }
        return Double(milliseconds) / 1_000
    }
}

public actor SSHPTYChannel {
    public typealias OutputHandler = @Sendable (Data) -> Void
    public typealias ExitHandler = @Sendable (Result<Int32, TermindSSHError>) -> Void
    public typealias ShellIntegrationHandler = @Sendable (SSHShellIntegrationEvent) -> Void
    public typealias EnvironmentRejectionHandler = @Sendable ([String]) -> Void

    private nonisolated let worker: SSHPTYChannelWorker
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    private let agentForwardingFactory: SSHAgentForwardingFactory?
    private var environmentVariables: [HostEnvironmentVariable] = []
    private var environmentRejection: EnvironmentRejectionHandler = { _ in }

    public init(
        output: @escaping OutputHandler, exit: @escaping ExitHandler,
        shellIntegration: @escaping ShellIntegrationHandler = { _ in },
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        agentForwardingFactory: SSHAgentForwardingFactory? = nil,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-pty-channel"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) {
        self.keyboardInteractive = keyboardInteractive
        self.agentForwardingFactory = agentForwardingFactory
        worker = SSHPTYChannelWorker(
            output: output, exit: exit, shellIntegrationHandler: shellIntegration, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy)
    }

    /// Appends a named public key to a remote account's `authorized_keys`, unless
    /// the exact key line is already present. The generated comment and key travel
    /// over the PTY Channel's stdin, never as shell syntax.
    public static func installAuthorizedKey(
        _ publicKey: String, named keyName: String,
        using configuration: SSHConnectionConfiguration,
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) async throws {
        try await installAuthorizedKey(
            publicKey, named: keyName, using: SSHConnectionRequest(configuration: configuration),
            maxSessionsPolicy: maxSessionsPolicy)
    }

    public static func installAuthorizedKey(
        _ publicKey: String, named keyName: String, using request: SSHConnectionRequest,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-key-install"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) async throws {
        try await installAuthorizedKeys(
            [SSHAuthorizedKeyInstall(publicKey: publicKey, name: keyName)],
            using: request, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy
        )
    }

    public static func installAuthorizedKeys(
        _ keys: [SSHAuthorizedKeyInstall], using request: SSHConnectionRequest,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-key-install"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) async throws {
        try await SSHConnectionOpener.installAuthorizedKeys(
            keys, using: request, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy)
    }

    public func connect(
        hostID: Host.ID,
        host: String,
        port: Int,
        username: String,
        credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>,
        proxy: SSHTransportProxy? = nil,
        jumps: [SSHRouteHopConfiguration] = [],
        shellIntegrationEnabled: Bool = true,
        columns: UInt16,
        rows: UInt16,
        progress: SSHRouteProgressHandler? = nil
    ) async throws {
        let configuration = SSHConnectionConfiguration(
            hostID: hostID, host: host, port: port,
            username: username, credentials: credentials,
            expectedHostKeys: expectedHostKeys, proxy: proxy, jumps: jumps
        )
        try await connect(
            using: SSHConnectionRequest(configuration: configuration),
            shellIntegrationEnabled: shellIntegrationEnabled,
            columns: columns, rows: rows, progress: progress
        )
    }

    public func connect(
        using request: SSHConnectionRequest,
        shellIntegrationEnabled: Bool = true,
        columns: UInt16,
        rows: UInt16,
        progress: SSHRouteProgressHandler? = nil
    ) async throws {
        defer { request.configuration.clearSecrets() }
        var request = request.withKeyboardInteractiveFallback(keyboardInteractive)
        request.agentForwarding = try await agentForwardingFactory?(request)
        try await worker.connect(
            using: request,
            environmentVariables: environmentVariables,
            environmentRejection: environmentRejection,
            shellIntegrationEnabled: shellIntegrationEnabled,
            columns: columns, rows: rows, progress: progress
        )
    }

    public func configureEnvironment(
        _ variables: [HostEnvironmentVariable],
        rejection: @escaping EnvironmentRejectionHandler = { _ in }
    ) {
        environmentVariables = variables
        environmentRejection = rejection
    }

    public func write(_ data: Data) {
        worker.write(data)
    }

    /// Opens an SFTP subsystem Channel on the PTY Channel's authenticated connection.
    /// This is a fallback only: callers must first attempt their ordinary
    /// independent SFTP connection.
    public func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        try await worker.openSFTPChannel()
    }

    public func executeHistoryRead(_ command: String, outputLimit: Int) async throws -> SSHExecResult {
        let cancellation = TransferCancellationToken()
        return try await withTaskCancellationHandler {
            try await worker.executeHistoryRead(command, outputLimit: outputLimit, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func historySource() async throws -> ShellHistorySource? {
        try await worker.historySource()
    }

    public func resize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        worker.resize(
            columns: columns, rows: rows,
            widthPixels: widthPixels, heightPixels: heightPixels
        )
    }

    public func disconnect() async { await worker.disconnect() }
}

nonisolated final class SSHPTYChannelWorker: @unchecked Sendable {
    private static let initialization: Void = {
        precondition(libssh2_init(0) == 0, "libssh2 initialization failed")
    }()

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.pty-channel")
    private let output: SSHPTYChannel.OutputHandler
    private let exit: SSHPTYChannel.ExitHandler
    private let shellIntegrationHandler: SSHPTYChannel.ShellIntegrationHandler
    private let logger: Logging.Logger
    private let maxSessionsPolicy: SSHMaxSessionsPolicy

    private var connection: SSHAuthenticatedConnection?
    private var ptyChannel: OpaquePointer?
    private var hostID: Host.ID?
    private var charset: RemoteCharset = .utf8
    private var pumpTimer: (any DispatchSourceTimer)?
    private var buffer: SSHConnectionBuffer?
    private var channelBudget: SSHChannelBudget?
    private var ptyChannelLease: SSHChannelLease?
    private var socketEvents: SSHSocketEvents?
    private let pendingWrites = SSHByteQueue(chunkSize: 32_700)
    private var ptyResize = SSHPTYResizeState()
    private var shellIntegration: RemoteShellIntegrationBootstrap?
    private var shellIntegrationLifecycleLogger: RemoteShellIntegrationLifecycleLogger
    private var commandEventFilter: RemoteCommandEventFilter?
    private var inputConverter: RemoteCharsetStreamConverter?
    private var outputConverter: RemoteCharsetStreamConverter?
    private var workingDirectoryFilter: RemoteOSC7CharsetFilter?
    private var didReportExit = false
    private var sftpChannelOwner: SSHMultiplexedSFTPChannelOwner!
    private var execChannelOwner: SSHMultiplexedExecChannelOwner!
    private var detectedHistorySource: ShellHistorySource?

    init(
        output: @escaping SSHPTYChannel.OutputHandler,
        exit: @escaping SSHPTYChannel.ExitHandler,
        shellIntegrationHandler: @escaping SSHPTYChannel.ShellIntegrationHandler,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-pty-channel"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) {
        _ = Self.initialization
        self.output = output
        self.exit = exit
        self.shellIntegrationHandler = shellIntegrationHandler
        self.logger = logger
        shellIntegrationLifecycleLogger = RemoteShellIntegrationLifecycleLogger(logger: logger)
        self.maxSessionsPolicy = maxSessionsPolicy
        execChannelOwner = SSHMultiplexedExecChannelOwner(
            queue: queue, logger: logger, requestsAgentForwarding: false,
            context: { [weak self] in
                guard let self, let connection = self.connection, let buffer = self.buffer,
                    let channelBudget = self.channelBudget
                else { return nil }
                return .init(
                    connection: connection, buffer: buffer, channelBudget: channelBudget,
                    charset: self.charset, hostID: self.hostID)
            },
            schedulePump: { [weak self] in self?.pump() },
            connectionFailed: { [weak self] error in
                guard let self else { return }
                self.reportExit(.failure((error as? TermindSSHError) ?? .disconnected))
                self.cleanup()
            },
            didCloseLastChannel: { [weak self] in
                guard let self, self.ptyChannel == nil, self.sftpChannelOwner.isEmptyOnQueue else { return }
                self.cleanup()
            })
        sftpChannelOwner = SSHMultiplexedSFTPChannelOwner(
            queue: queue,
            context: { [weak self] in
                guard let self, let connection = self.connection,
                    let buffer = self.buffer,
                    let channelBudget = self.channelBudget
                else { return nil }
                return .init(
                    connection: connection, buffer: buffer,
                    channelBudget: channelBudget, charset: self.charset)
            },
            updateEvents: { [weak self] session, buffer in
                self?.updateSharedConnectionEvents(session: session, buffer: buffer)
            },
            didCloseLastChannel: { [weak self] in
                guard let self, self.ptyChannel == nil, self.execChannelOwner.isEmptyOnQueue else { return }
                self.cleanup()
            })
    }

    /// Opens a byte transport, handshakes, validates the host key, and authenticates —
    /// the identical prologue every non-PTY entry point needs before it can open
    /// a Channel. On any failure it frees what it created and rethrows, so a
    /// caller only owns the resulting connection once it has been handed one.
    ///
    /// The connection's libssh2 handle is left in blocking mode. Callers that want the
    /// non-blocking pump switch it themselves once their Channel is running.
    public static func openAuthenticatedConnection(
        using configuration: SSHConnectionConfiguration,
        timeout: TimeInterval,
        progress: SSHRouteProgressHandler? = nil,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-authentication")
    ) throws -> SSHAuthenticatedConnection {
        _ = initialization
        defer { configuration.clearSecrets() }
        guard configuration.network == nil, configuration.tailscaleNodeID == nil else {
            throw TailscaleConfigurationError.unavailable
        }
        let operationID = UUID().uuidString.lowercased()
        var logger = logger
        logger[metadataKey: "operation_id"] = "\(operationID)"
        logger.info(
            "ssh.authentication.started",
            metadata: [
                "host_id": RemoteLogging.hostID(configuration.hostID), "operation_id": "\(operationID)",
                "protocol": "ssh", "stage": "opening",
            ])
        var transport: SSHRoutedSocket?
        var session: OpaquePointer?
        do {
            let opened = try SSHRoutedSocket.open(
                host: configuration.host, port: configuration.port,
                proxy: configuration.proxy, jumps: configuration.jumps,
                timeout: timeout, progress: progress, logger: logger
            )
            transport = opened
            progress?(.connecting(configuration.hostID))
            guard let created = libssh2_session_init_ex(nil, nil, nil, nil) else {
                throw TermindSSHError.library("Unable to create an SSH session.")
            }
            session = created
            libssh2_session_set_blocking(created, 1)
            try performHandshake(
                created, socket: opened.socket,
                peer: SSHSocketConnector.peerDescription(
                    socket: opened.socket,
                    fallbackHost: configuration.host,
                    port: configuration.port
                ),
                timeout: timeout
            )
            let observed = try observation(
                host: configuration.host, port: configuration.port, session: created
            )
            try validateHostKey(observed, expected: configuration.expectedHostKeys)
            progress?(.authenticating(configuration.hostID))
            let authentication = try authenticate(
                username: configuration.username,
                credentials: configuration.credentials,
                session: created, logger: logger
            )
            progress?(.authenticated(configuration.hostID))
            logger.info(
                "ssh.authentication.completed",
                metadata: [
                    "authentication": "\(authentication)", "host_id": RemoteLogging.hostID(configuration.hostID),
                    "operation_id": "\(operationID)", "outcome": "success", "protocol": "ssh",
                    "stage": "authenticated",
                ])
            return SSHAuthenticatedConnection(
                byteTransport: opened, libssh2Session: created)
        } catch {
            logger.error(
                "ssh.authentication.failed",
                metadata: [
                    "error_code": RemoteLogging.errorCode(error),
                    "host_id": RemoteLogging.hostID(configuration.hostID), "operation_id": "\(operationID)",
                    "outcome": "failure", "protocol": "ssh", "stage": "authentication",
                ])
            if let session { _ = libssh2_session_free(session) }
            transport?.close()
            throw error
        }
    }

    public static func openAuthenticatedConnection(
        using request: SSHConnectionRequest,
        timeout: TimeInterval,
        progress: SSHRouteProgressHandler? = nil,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-authentication")
    ) async throws -> SSHAuthenticatedConnection {
        let operationID = UUID().uuidString.lowercased()
        var logger = logger
        logger[metadataKey: "operation_id"] = "\(operationID)"
        logger[metadataKey: "host_id"] = RemoteLogging.hostID(request.configuration.hostID)
        let authenticationLogger = logger
        let request = request.enforcingInteractionPolicy()
        var resolvedConfiguration = request.configuration
        if let nodeID = resolvedConfiguration.tailscaleNodeID {
            guard let network = resolvedConfiguration.network, resolvedConfiguration.jumps.isEmpty else {
                throw TailscaleConfigurationError.unavailable
            }
            resolvedConfiguration.expectedHostKeys = try await network.hostKeys(stableNodeID: nodeID)
            guard !resolvedConfiguration.expectedHostKeys.isEmpty else { throw TailscaleConfigurationError.unavailable }
        }
        let configuration = resolvedConfiguration
        defer { configuration.clearSecrets() }
        logger.info(
            "ssh.authentication.started",
            metadata: [
                "host_id": RemoteLogging.hostID(configuration.hostID), "operation_id": "\(operationID)",
                "protocol": "ssh", "stage": "opening",
            ])
        let transport = try await SSHRoutedSocket.open(
            host: configuration.host, port: configuration.port,
            proxy: configuration.proxy, jumps: configuration.jumps,
            timeout: timeout, progress: progress,
            authorizeHostKey: request.authorizeHostKey,
            network: configuration.network,
            keyboardInteractive: request.keyboardInteractive,
            securityKeySigning: request.securityKeySigning,
            interactionPolicy: request.interactionPolicy,
            hostKeyConstraints: request.hostKeyConstraints, logger: logger
        )
        let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.authenticated-opening")
        let exchange = SSHKeyboardInteractiveExchange(
            configuration: configuration, handler: request.keyboardInteractive,
            securityKeySigning: request.securityKeySigning, allowsUserInteraction: request.interactionPolicy == .allowed
        )
        let state = SSHAuthenticatedOpeningState(transport: transport)
        return try await withTaskCancellationHandler {
            do {
                progress?(.connecting(configuration.hostID))
                let observed = try await queue.perform {
                    try state.begin(
                        configuration: configuration, timeout: timeout
                    )
                }
                let requiredApproval = !configuration.expectedHostKeys.contains(observed.identity)
                let authentication: String
                if configuration.tailscaleNodeID != nil, configuration.network != nil {
                    guard configuration.expectedHostKeys.contains(observed.identity) else {
                        throw TailscaleConfigurationError.hostKeyMismatch
                    }
                    progress?(.authenticating(configuration.hostID))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(600))
                    var presentedBanners: Set<String> = []
                    let approvalConnectionID = UUID()
                    while true {
                        try Task.checkCancellation()
                        let step = try await queue.perform {
                            try state.authenticateTailscale(username: configuration.username)
                        }
                        if step.authenticated { break }
                        if let banner = step.banner, !banner.isEmpty, presentedBanners.insert(banner).inserted {
                            guard request.interactionPolicy == .allowed, let present = request.keyboardInteractive
                            else {
                                throw SSHInteractionRequired()
                            }
                            _ = try await present(
                                SSHKeyboardInteractiveChallenge(
                                    connectionID: approvalConnectionID, hostID: configuration.hostID,
                                    hostname: configuration.host, port: configuration.port,
                                    username: configuration.username,
                                    round: presentedBanners.count, name: "", instruction: banner, prompts: [],
                                    isTailscaleApproval: true))
                        }
                        guard ContinuousClock.now < deadline else { throw TailscaleConfigurationError.approvalTimedOut }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    progress?(.authenticated(configuration.hostID))
                    authentication = "tailscale"
                } else {
                    try await authorizeHostKey(
                        hostID: configuration.hostID, observed: observed,
                        expected: configuration.expectedHostKeys,
                        constraint: request.hostKeyConstraints[configuration.hostID],
                        authorizer: request.authorizeHostKey
                    )
                    try Task.checkCancellation()
                    authentication = try await queue.perform {
                        try state.authenticate(
                            configuration: configuration,
                            afterHostKeyApproval: requiredApproval,
                            progress: progress, keyboardInteractive: exchange, logger: authenticationLogger
                        )
                    }
                }
                let result = try await queue.perform { try state.takeResult() }
                logger.info(
                    "ssh.authentication.completed",
                    metadata: [
                        "authentication": "\(authentication)",
                        "host_id": RemoteLogging.hostID(configuration.hostID), "operation_id": "\(operationID)",
                        "outcome": "success", "protocol": "ssh", "stage": "authenticated",
                    ])
                return result
            } catch {
                logger.error(
                    "ssh.authentication.failed",
                    metadata: [
                        "error_code": RemoteLogging.errorCode(error),
                        "host_id": RemoteLogging.hostID(configuration.hostID), "operation_id": "\(operationID)",
                        "outcome": "failure", "protocol": "ssh", "stage": "authentication",
                    ])
                await queue.perform { state.cleanup() }
                throw error
            }
        } onCancel: {
            exchange.cancel()
            state.cancel()
            queue.async { state.cleanup() }
        }
    }

    public static func installAuthorizedKey(
        _ publicKey: String, named keyName: String,
        using request: SSHConnectionRequest,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-key-install"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) async throws {
        try await installAuthorizedKeys(
            [SSHAuthorizedKeyInstall(publicKey: publicKey, name: keyName)],
            using: request, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy
        )
    }

    public static func installAuthorizedKeys(
        _ keys: [SSHAuthorizedKeyInstall],
        using request: SSHConnectionRequest,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-key-install"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) async throws {
        let connection = SSHConnection(logger: logger, maxSessionsPolicy: maxSessionsPolicy)
        try await installAuthorizedKeys(keys, using: request, connection: connection)
    }

    static func installAuthorizedKeys(
        _ keys: [SSHAuthorizedKeyInstall],
        using request: SSHConnectionRequest,
        connection: any SSHConnectionProtocol
    ) async throws {
        guard !keys.isEmpty else { return }
        let inputs = try keys.map {
            try authorizedKeyInstallInput(publicKey: $0.publicKey, keyName: $0.name)
        }
        do {
            try await connection.connect(using: request)
            let command =
                #"umask 077; dir="$HOME/.ssh"; file="$dir/authorized_keys"; mkdir -p "$dir" && touch "$file" && chmod 700 "$dir" && chmod 600 "$file" && IFS= read -r comment && IFS= read -r key && { LC_ALL=C grep -Fqx -- "$key" "$file" || printf '%s\n%s\n' "$comment" "$key" >> "$file"; }"#
            for input in inputs {
                let result = try await connection.execute(
                    command, workingDirectory: nil, stdin: .plain(input), timeout: 20,
                    outputLimit: 64 * 1024, onOutput: nil)
                guard result.exitCode == 0 else {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw TermindSSHError.library(
                        detail.isEmpty
                            ? "The remote authorized_keys update exited with status \(result.exitCode)."
                            : "The remote authorized_keys update failed: \(detail)")
                }
            }
            await connection.disconnect()
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    public static func authorizedKeyInstallInput(publicKey: String, keyName: String) throws -> Data {
        let normalizedKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalizedKey.isEmpty, !normalizedKey.contains("\n"),
            !normalizedKey.contains("\r")
        else {
            throw TermindSSHError.library("The public key is not a single OpenSSH key line.")
        }

        let printableName = keyName.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
        let normalizedName =
            printableName
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let safeName = normalizedName.isEmpty ? "Key" : normalizedName
        return Data(("# \(safeName) Key by Termind\n\(normalizedKey)\n").utf8)
    }

    public func connect(
        using request: SSHConnectionRequest,
        environmentVariables: [HostEnvironmentVariable],
        environmentRejection: @escaping SSHPTYChannel.EnvironmentRejectionHandler,
        shellIntegrationEnabled: Bool,
        columns: UInt16, rows: UInt16,
        progress: SSHRouteProgressHandler?
    ) async throws {
        let generation = try await queue.perform { [self] in
            // Preserve a viewport received before this worker's first connect,
            // but never carry another connection's pending request forward.
            var nextResize = ptyResize
            let generation = nextResize.beginConnection(columns: columns, rows: rows)
            cleanup()
            ptyResize = nextResize
            return generation
        }
        let encodedEnvironment = try environmentVariables.map { variable in
            (
                variable.variable,
                try RemoteCharsetStreamConverter.encode(variable.variable, charset: request.configuration.charset),
                try RemoteCharsetStreamConverter.encode(variable.value, charset: request.configuration.charset)
            )
        }
        do {
            let channelBudget = maxSessionsPolicy.makeBudget()
            let ptyChannelLease = try await channelBudget.acquire()
            let openedConnection = try await Self.openAuthenticatedConnection(
                using: request, timeout: 20, progress: progress, logger: logger
            )
            try await queue.perform { [self] in
                guard ptyResize.generation == generation, let size = ptyResize.requestedSize else {
                    ptyChannelLease.release()
                    channelBudget.close()
                    openedConnection.close()
                    throw CancellationError()
                }
                connection = openedConnection
                hostID = request.configuration.hostID
                charset = request.configuration.charset
                inputConverter = try RemoteCharsetStreamConverter(
                    charset: request.configuration.charset, direction: .encoding)
                outputConverter = try RemoteCharsetStreamConverter(
                    charset: request.configuration.charset, direction: .decoding)
                workingDirectoryFilter = RemoteOSC7CharsetFilter(charset: request.configuration.charset)
                self.channelBudget = channelBudget
                self.ptyChannelLease = ptyChannelLease
                let created = openedConnection.libssh2Session
                guard
                    let openedChannel = libssh2_channel_open_ex(
                        created, "session", 7,
                        2 * 1024 * 1024,
                        32 * 1024, nil, 0
                    )
                else {
                    throw Self.connectionError(created, prefix: "Unable to open SSH PTY Channel")
                }
                ptyChannel = openedChannel
                if let provider = request.agentForwarding {
                    let transport = openedConnection.installBuffer(deferIO: true)
                    transport.agentChannels = SSHAgentChannels(provider: provider, queue: queue) { [weak self] in
                        self?.pump()
                    }
                    libssh2_session_callback_set2(
                        created, LIBSSH2_CALLBACK_AUTHAGENT,
                        unsafeBitCast(SSHAgentChannels.callback, to: (@convention(c) () -> Void).self))
                    guard libssh2_channel_request_auth_agent(openedChannel) == 0 else {
                        throw Self.connectionError(created, prefix: "Agent Forwarding request failed")
                    }
                }
                let pty = libssh2_channel_request_pty_ex(
                    openedChannel, "xterm-256color", 14, nil, 0,
                    Int32(size.columns), Int32(size.rows),
                    Int32(clamping: size.widthPixels), Int32(clamping: size.heightPixels)
                )
                guard pty == 0 else { throw Self.connectionError(created, prefix: "PTY request failed") }
                ptyResize.didCreatePTY(size: size)
                var rejectedVariables: [String] = []
                for environmentVariable in encodedEnvironment {
                    let result = environmentVariable.1.withUnsafeBytes { variable in
                        environmentVariable.2.withUnsafeBytes { value in
                            libssh2_channel_setenv_ex(
                                openedChannel,
                                variable.baseAddress?.assumingMemoryBound(to: CChar.self),
                                UInt32(environmentVariable.1.count),
                                value.baseAddress?.assumingMemoryBound(to: CChar.self),
                                UInt32(environmentVariable.2.count))
                        }
                    }
                    if result == LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED {
                        rejectedVariables.append(environmentVariable.0)
                    } else if result != 0 {
                        throw Self.connectionError(created, prefix: "SSH environment request failed")
                    }
                }
                if !rejectedVariables.isEmpty { environmentRejection(rejectedVariables) }
                guard libssh2_channel_process_startup(openedChannel, "shell", 5, nil, 0) == 0 else {
                    throw Self.connectionError(created, prefix: "Remote shell request failed")
                }
                buffer = openedConnection.installBuffer()
                libssh2_session_set_blocking(created, 0)
                libssh2_keepalive_config(created, 1, 20)
                didReportExit = false
                shellIntegrationLifecycleLogger.begin(
                    hostID: request.configuration.hostID,
                    enabled: shellIntegrationEnabled
                )
                if shellIntegrationEnabled {
                    let bootstrap = RemoteShellIntegrationBootstrap(charset: request.configuration.charset)
                    pendingWrites.append(bootstrap.startCommand)
                    commandEventFilter = RemoteCommandEventFilter(
                        token: bootstrap.token, charset: request.configuration.charset)
                    shellIntegration = bootstrap
                }
                startPump()
                progress?(.connected(request.configuration.hostID))
            }
            try Task.checkCancellation()
        } catch {
            await queue.perform { [self] in
                guard ptyResize.generation == generation else { return }
                cleanup()
            }
            throw error
        }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            if var integration = shellIntegration {
                integration.noteUserInput()
                shellIntegration = integration
            }
            let converted = (try? inputConverter?.convert(data).data) ?? data
            if !converted.isEmpty { pendingWrites.append(converted) }
            pump()
        }
    }

    public func resize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        guard columns > 0, rows > 0 else { return }
        queue.async { [self] in
            ptyResize.request(
                SSHPTYSize(columns: columns, rows: rows, widthPixels: widthPixels, heightPixels: heightPixels)
            )
            pump()
        }
    }

    public func disconnect() async { await queue.perform { self.closeTerminalSession() } }

    public static func authenticate(
        username: String, credentials: [SSHCredentials], session: OpaquePointer,
        keyboardInteractive: SSHKeyboardInteractiveExchange? = nil, socket: Int32 = -1,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-authentication")
    ) throws -> String {
        var methods = try authenticationMethods(username: username, session: session)
        // Asking for the method list sends SSH's `none` authentication request.
        // Servers that need no credential accept it there and report the
        // session as authenticated without another userauth call.
        if libssh2_userauth_authenticated(session) == 1 { return "none" }
        var attempted = false
        var lastMethod = "none"
        var secureEnclaveError: (any Error)?
        var lastFailure: String?
        var remaining = credentials
        var attemptedInteractive = false
        var skippedInteractiveCredential = false
        while true {
            guard
                let index = remaining.firstIndex(where: { credential in
                    switch credential {
                    case .password: methods.contains("password")
                    case .privateKey, .securityKey, .secureEnclave, .interactionRequired:
                        methods.contains("publickey")
                    }
                })
            else {
                guard !attemptedInteractive, methods.contains("keyboard-interactive"), let keyboardInteractive else {
                    break
                }
                attempted = true
                attemptedInteractive = true
                lastMethod = "keyboard_interactive"
                let result = Self.keyboardInteractive(
                    username: username, exchange: keyboardInteractive, session: session, socket: socket
                )
                try keyboardInteractive.checkCancellation()
                if let error = keyboardInteractive.error { throw error }
                if result == 0 { return lastMethod }
                lastFailure = connectionErrorMessage(session, prefix: "SSH authentication failed", fallbackCode: result)
                methods = try authenticationMethods(username: username, session: session)
                if libssh2_userauth_authenticated(session) == 1 { return lastMethod }
                continue
            }
            try keyboardInteractive?.checkCancellation()
            let credential = remaining.remove(at: index)
            switch credential {
            case .password(let password):
                if methods.contains("password") {
                    attempted = true
                    lastMethod = "password"
                    let result = try username.withCString { user in
                        try password.withUnsafeCStringAndConsume { password, passwordLength in
                            libssh2_userauth_password_ex(
                                session, user, UInt32(username.utf8.count),
                                password, UInt32(passwordLength), nil
                            )
                        }
                    }
                    if result == 0 { return lastMethod }
                    lastFailure = connectionErrorMessage(
                        session, prefix: "SSH authentication failed", fallbackCode: result)
                }
            case .privateKey(let privateKey, let publicKey, let passphrase, _):
                guard methods.contains("publickey") else { continue }
                attempted = true
                lastMethod = "public_key"
                let result = try username.withCString { user in
                    try privateKey.withUnsafeCStringAndConsume { privateBuffer, privateKeyLength in
                        let call: (UnsafePointer<CChar>?) throws -> Int32 = { publicBuffer in
                            if let passphrase {
                                return try passphrase.withUnsafeCStringAndConsume { passphraseBuffer, _ in
                                    libssh2_userauth_publickey_frommemory(
                                        session, user, username.utf8.count,
                                        publicBuffer, publicKey?.utf8.count ?? 0,
                                        privateBuffer, privateKeyLength, passphraseBuffer
                                    )
                                }
                            }
                            return libssh2_userauth_publickey_frommemory(
                                session, user, username.utf8.count,
                                publicBuffer, publicKey?.utf8.count ?? 0,
                                privateBuffer, privateKeyLength, nil
                            )
                        }
                        return try publicKey?.withCString(call) ?? call(nil)
                    }
                }
                if result == 0 { return lastMethod }
                lastFailure = connectionErrorMessage(session, prefix: "SSH authentication failed", fallbackCode: result)
            case .securityKey(let credential, let name):
                guard let keyboardInteractive else { throw SSHInteractionRequired() }
                attempted = true
                lastMethod = "security_key"
                let publicBlob = try WebAuthnSSH.publicBlob(credential)
                let signer = SecurityKeySigner(
                    credential: credential, keyName: name, exchange: keyboardInteractive, logger: logger)
                logger.info("ssh.security_key.started", metadata: ["stage": "public_key_offer"])
                var abstract: UnsafeMutableRawPointer? = Unmanaged.passUnretained(signer).toOpaque()
                let timeout = libssh2_session_get_timeout(session)
                defer { libssh2_session_set_timeout(session, timeout) }
                let result = username.withCString { user in
                    publicBlob.withUnsafeBytes { bytes in
                        libssh2_userauth_publickey_signed(
                            session, user,
                            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count,
                            securityKeySignCallback, &abstract)
                    }
                }
                try keyboardInteractive.checkCancellation()
                if result != 0 {
                    var metadata: Logging.Logger.Metadata = [
                        "stage": "\(signer.stage)", "libssh2_code": "\(result)",
                        "error_code": signer.error.map(RemoteLogging.errorCode) ?? "libssh2_authentication_failed",
                    ]
                    if let error = signer.error as NSError? {
                        metadata["native_error_domain"] = "\(error.domain)"
                        metadata["native_error_code"] = "\(error.code)"
                    }
                    logger.error("ssh.security_key.failed", metadata: metadata)
                } else {
                    logger.info("ssh.security_key.completed", metadata: ["stage": "authenticated"])
                }
                if let error = signer.error { throw error }
                if result == 0 { return lastMethod }
                if result == LIBSSH2_ERROR_AUTHENTICATION_FAILED, signer.stage == "public_key_offer" {
                    lastFailure = connectionErrorMessage(
                        session,
                        prefix: String(
                            localized:
                                "The server rejected the username or public key. Check the login user and the key in authorized_keys."
                        ), fallbackCode: result)
                } else {
                    lastFailure = connectionErrorMessage(
                        session, prefix: "SSH authentication failed", fallbackCode: result)
                }
            case .secureEnclave(let credential, let publicKey, _):
                guard methods.contains("publickey") else { continue }
                guard let publicBlob = SecureEnclaveKey.publicBlob(from: publicKey) else {
                    secureEnclaveError = TermindSSHError.library(
                        "The Secure Enclave key has an invalid SSH public key."
                    )
                    continue
                }
                attempted = true
                lastMethod = "secure_enclave"
                let signer = SecureEnclaveSigner(credential: credential)
                var abstract: UnsafeMutableRawPointer? = Unmanaged.passUnretained(signer).toOpaque()
                let result = username.withCString { user in
                    publicBlob.withUnsafeBytes { bytes in
                        libssh2_userauth_publickey(
                            session,
                            user,
                            bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            bytes.count,
                            secureEnclaveSignCallback,
                            &abstract
                        )
                    }
                }
                // A cancelled/failed system signing prompt must never fall through to another credential.
                if let error = signer.error { throw error }
                if result == 0 { return lastMethod }
                lastFailure = connectionErrorMessage(session, prefix: "SSH authentication failed", fallbackCode: result)
            case .interactionRequired:
                skippedInteractiveCredential = true
            }
            methods = try authenticationMethods(username: username, session: session)
            if libssh2_userauth_authenticated(session) == 1 { return lastMethod }
        }
        if skippedInteractiveCredential { throw SSHInteractionRequired() }
        if let secureEnclaveError {
            throw TermindSSHError.authenticationFailed(secureEnclaveError.localizedDescription)
        }
        let available = methods.sorted().joined(separator: ", ")
        let prefix =
            attempted
            ? "SSH authentication failed"
            : "No configured credential matches the server methods (\(available))"
        throw TermindSSHError.authenticationFailed(
            lastFailure ?? Self.connectionErrorMessage(session, prefix: prefix)
        )
    }

    public static func authenticate(
        username: String, credentials: [SSHCredentials],
        session: OpaquePointer, afterHostKeyApproval: Bool,
        keyboardInteractive: SSHKeyboardInteractiveExchange? = nil, socket: Int32 = -1,
        logger: Logging.Logger = ApplicationLogger.disabled("termind.ssh-authentication")
    ) throws -> String {
        do {
            return try authenticate(
                username: username, credentials: credentials,
                session: session, keyboardInteractive: keyboardInteractive, socket: socket, logger: logger
            )
        } catch {
            if error is CancellationError || keyboardInteractive?.error != nil { throw error }
            let code = libssh2_session_last_errno(session)
            if afterHostKeyApproval,
                code == LIBSSH2_ERROR_SOCKET_DISCONNECT
                    || code == LIBSSH2_ERROR_SOCKET_RECV
                    || code == LIBSSH2_ERROR_TIMEOUT
                    || code == LIBSSH2_ERROR_SOCKET_TIMEOUT
            {
                throw TermindSSHError.library(
                    String(
                        localized:
                            "The server closed the SSH connection while waiting for host-key approval. Retry to connect using the accepted key."
                    ) + " [libssh2 \(code)]"
                )
            }
            throw error
        }
    }

    private static func authenticationMethods(
        username: String, session: OpaquePointer
    ) throws -> Set<String> {
        let pointer = username.withCString { user in
            libssh2_userauth_list(session, user, UInt32(username.utf8.count))
        }
        guard let pointer else {
            if libssh2_userauth_authenticated(session) == 1 { return [] }
            throw Self.connectionError(
                session, prefix: "Unable to read SSH authentication methods"
            )
        }
        let bytes = UnsafeBufferPointer(start: pointer, count: strlen(pointer))
            .map { UInt8(bitPattern: $0) }
        return Set(String(decoding: bytes, as: UTF8.self).split(separator: ",").map(String.init))
    }

    private static func keyboardInteractive(
        username: String, exchange: SSHKeyboardInteractiveExchange, session: OpaquePointer, socket: Int32
    ) -> Int32 {
        let callback = SSHKeyboardInteractiveCallback(exchange: exchange, session: session, socket: socket)
        let box = Unmanaged.passRetained(callback)
        let abstract = libssh2_session_abstract(session)
        let previous = abstract?.pointee
        let timeout = libssh2_session_get_timeout(session)
        abstract?.pointee = box.toOpaque()
        defer {
            abstract?.pointee = previous
            libssh2_session_set_timeout(session, timeout)
            box.release()
        }
        return username.withCString { user in
            libssh2_userauth_keyboard_interactive_ex(
                session, user, UInt32(username.utf8.count), sshKeyboardInteractiveResponse
            )
        }
    }

    private func startPump() {
        pumpTimer?.cancel()
        socketEvents?.cancel()
        guard let connection else { return }
        socketEvents = SSHSocketEvents(socket: connection.byteTransport.socket, queue: queue) {
            [weak self] in self?.pump()
        }
        socketEvents?.update(read: true, write: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Timer advances shell-integration deadlines and keepalive only; data
        // throughput is readiness-driven by `socketEvents`.
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.pump() }
        pumpTimer = timer
        timer.resume()
    }

    private func pump() {
        guard let connection, let buffer else { return }
        let session = connection.libssh2Session
        let socket = connection.byteTransport.socket
        let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
        buffer.beginPass(deadline: deadline)
        do { try buffer.flush(socket: socket) } catch {
            reportExit(.failure(Self.connectionError(session, prefix: "SSH transport write failed")))
            cleanup()
            return
        }
        if buffer.isBackpressured {
            socketEvents?.update(read: false, write: true)
            return
        }
        execChannelOwner.wakeAllOnQueue()
        let execProgress = execChannelOwner.advanceOnQueue(
            deadline: min(
                deadline, DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds / 4))
        guard self.connection != nil else { return }
        if execProgress { queue.async { [weak self] in self?.pump() } }
        var agentProgress =
            buffer.agentChannels?.advance(
                deadline: min(
                    deadline, DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds / 2),
                permitsIO: { !buffer.isBackpressured }) ?? false
        if let ptyChannel {
            let resizeResult = ptyResize.flush { size in
                libssh2_channel_request_pty_size_ex(
                    ptyChannel, Int32(size.columns), Int32(size.rows),
                    Int32(clamping: size.widthPixels), Int32(clamping: size.heightPixels)
                )
            }
            if resizeResult != 0, resizeResult != LIBSSH2_ERROR_EAGAIN {
                var metadata: Logger.Metadata = [
                    "error_code": "library", "protocol": "ssh", "stage": "pty_resize",
                ]
                if let hostID { metadata["host_id"] = RemoteLogging.hostID(hostID) }
                logger.error("ssh.pty_resize.failed", metadata: metadata)
                ptyResize.discardFailedRequest()
            }
            // Continue other I/O on EAGAIN: window-change may itself be waiting
            // for a previously blocked channel write or window adjustment.
            var buffer = [CChar](repeating: 0, count: 32 * 1024)
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let count = libssh2_channel_read_ex(ptyChannel, 0, &buffer, buffer.count)
                if count > 0 {
                    deliverOutput(Data(bytes: buffer, count: count))
                } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                    break
                } else {
                    reportExit(.failure(Self.connectionError(session, prefix: "SSH read failed")))
                    cleanup()
                    return
                }
            }

            if var integration = shellIntegration {
                let update = integration.poll()
                shellIntegration = update.isComplete ? nil : integration
                applyShellIntegrationUpdate(update)
            }

            while !pendingWrites.isEmpty && DispatchTime.now().uptimeNanoseconds < deadline {
                let written = pendingWrites.withFirstBytes { bytes -> Int in
                    guard let address = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                    return libssh2_channel_write_ex(ptyChannel, 0, address, bytes.count)
                }
                if written > 0 {
                    pendingWrites.consume(written)
                } else if written == LIBSSH2_ERROR_EAGAIN {
                    break
                } else {
                    reportExit(.failure(Self.connectionError(session, prefix: "SSH write failed")))
                    cleanup()
                    return
                }
            }
        }

        agentProgress =
            (buffer.agentChannels?.advance(deadline: deadline, permitsIO: { !buffer.isBackpressured }) ?? false)
            || agentProgress
        if agentProgress { queue.async { [weak self] in self?.pump() } }
        var next = Int32(0)
        let keepalive = libssh2_keepalive_send(session, &next)
        if keepalive < 0, keepalive != LIBSSH2_ERROR_EAGAIN {
            reportExit(.failure(Self.connectionError(session, prefix: "SSH keepalive failed")))
            cleanup()
            return
        }
        if let ptyChannel, libssh2_channel_eof(ptyChannel) == 1 {
            let status = libssh2_channel_get_exit_status(ptyChannel)
            reportExit(.success(status))
            closeTerminalSession()
            return
        }
        do { try buffer.flush(socket: socket) } catch {
            reportExit(.failure(Self.connectionError(session, prefix: "SSH transport write failed")))
            cleanup()
            return
        }
        let directions = libssh2_session_block_directions(session)
        socketEvents?.update(
            read: !buffer.isBackpressured,
            write: buffer.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
    }

    private func reportExit(_ result: Result<Int32, TermindSSHError>) {
        guard !didReportExit else { return }
        didReportExit = true
        exit(result)
    }

    private func deliverOutput(_ data: Data) {
        guard var integration = shellIntegration else {
            deliverIntegratedOutput(data)
            return
        }
        let update = integration.receive(data)
        shellIntegration = update.isComplete ? nil : integration
        applyShellIntegrationUpdate(update)
    }

    private func applyShellIntegrationUpdate(
        _ update: RemoteShellIntegrationBootstrap.Update
    ) {
        if let diagnostic = update.diagnostic, let hostID {
            shellIntegrationLifecycleLogger.record(diagnostic, hostID: hostID)
        }
        if let command = update.command {
            pendingWrites.append(command)
        }
        if let source = update.historySource { detectedHistorySource = source }
        if update.integrationInstalled {
            shellIntegrationHandler(
                .available(
                    shell: update.shell ?? "unknown", systemInfo: update.systemInfo,
                    homeDirectory: update.homeDirectory
                )
            )
        } else {
            if let systemInfo = update.systemInfo {
                shellIntegrationHandler(.systemInfo(systemInfo))
            }
            if update.homeResolutionUnavailable || update.isComplete {
                shellIntegrationHandler(.homeResolutionUnavailable)
            }
        }
        if let visibleOutput = update.visibleOutput, !visibleOutput.isEmpty {
            deliverIntegratedOutput(visibleOutput)
        }
    }

    private func deliverIntegratedOutput(_ data: Data) {
        guard var commandEventFilter else {
            emitConvertedOutput(data)
            return
        }
        let update = commandEventFilter.receive(data)
        self.commandEventFilter = commandEventFilter
        if !update.visibleOutput.isEmpty { emitConvertedOutput(update.visibleOutput) }
        for event in update.events {
            switch event {
            case .commandStarted(let command):
                shellIntegrationHandler(.commandStarted(command))
            case .commandFinished(let status, let duration):
                shellIntegrationHandler(.commandFinished(status, duration: duration))
            case .promptReady:
                shellIntegrationHandler(.promptReady)
            case .draft(let draft):
                shellIntegrationHandler(.draft(draft))
            }
        }
    }

    private func emitConvertedOutput(_ data: Data) {
        do {
            var filteredData = data
            if var filter = workingDirectoryFilter {
                let filtered = filter.receive(data)
                workingDirectoryFilter = filter
                filteredData = filtered.data
            }
            let converted =
                try outputConverter?.convert(filteredData)
                ?? .init(data: filteredData, rejectedInput: false)
            if !converted.data.isEmpty { output(converted.data) }
        } catch {
            output(data)
        }
    }

    private func finishCharsetOutput() {
        guard let outputConverter else { return }
        do {
            if var filter = workingDirectoryFilter {
                let remainder = filter.finish()
                workingDirectoryFilter = filter
                if !remainder.isEmpty {
                    let prefix = try outputConverter.convert(remainder)
                    if !prefix.data.isEmpty { output(prefix.data) }
                }
            }
            let converted = try outputConverter.finish()
            if !converted.data.isEmpty { output(converted.data) }
        } catch {}
    }

    private func closeTerminalSession() {
        execChannelOwner.cancelAllOnQueue()
        detectedHistorySource = nil
        buffer?.agentChannels?.shutdown()
        finishCharsetOutput()
        pendingWrites.removeAll()
        ptyResize.reset()
        if let hostID { shellIntegrationLifecycleLogger.sessionEnded(hostID: hostID) }
        shellIntegration = nil
        commandEventFilter = nil
        inputConverter = nil
        outputConverter = nil
        workingDirectoryFilter = nil
        hostID = nil
        if let ptyChannel {
            _ = libssh2_channel_send_eof(ptyChannel)
            _ = libssh2_channel_close(ptyChannel)
            _ = libssh2_channel_free(ptyChannel)
            self.ptyChannel = nil
            ptyChannelLease?.release()
            ptyChannelLease = nil
        }
        if sftpChannelOwner.isEmptyOnQueue, execChannelOwner.isEmptyOnQueue {
            cleanup()
        } else {
            queue.async { [weak self] in self?.pump() }
        }
    }

    private func cleanup() {
        buffer?.agentChannels?.shutdown()
        pumpTimer?.cancel()
        pumpTimer = nil
        let connection = connection
        self.connection = nil
        pendingWrites.removeAll()
        ptyResize.reset()
        if let hostID { shellIntegrationLifecycleLogger.sessionEnded(hostID: hostID) }
        shellIntegration = nil
        commandEventFilter = nil
        inputConverter = nil
        outputConverter = nil
        workingDirectoryFilter = nil
        hostID = nil
        if let ptyChannel {
            _ = libssh2_channel_send_eof(ptyChannel)
            _ = libssh2_channel_close(ptyChannel)
            _ = libssh2_channel_free(ptyChannel)
            self.ptyChannel = nil
        }
        execChannelOwner.closeAllOnQueue(error: CancellationError())
        detectedHistorySource = nil
        sftpChannelOwner.closeAllOnQueue()
        ptyChannelLease?.release()
        ptyChannelLease = nil
        channelBudget?.close()
        channelBudget = nil
        buffer = nil
        if let socketEvents {
            socketEvents.cancel { connection?.close() }
            self.socketEvents = nil
        } else {
            connection?.close()
        }
    }

    public static func observation(host: String, port: Int, session: OpaquePointer) throws
        -> SSHHostKeyObservation
    {
        guard let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw connectionError(session, prefix: "The server did not provide a host-key fingerprint")
        }
        let digest = Data(bytes: hash, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let legacyMD5Fingerprint = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_MD5)).map {
            Data(bytes: $0, count: 16)
        }
        var length = 0
        var type = Int32(LIBSSH2_HOSTKEY_TYPE_UNKNOWN)
        _ = libssh2_session_hostkey(session, &length, &type)
        let algorithm: SSHKeyAlgorithm
        switch type {
        case LIBSSH2_HOSTKEY_TYPE_RSA: algorithm = .rsa
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: algorithm = .ecdsa256
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: algorithm = .ecdsa384
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: algorithm = .ecdsa521
        case LIBSSH2_HOSTKEY_TYPE_ED25519: algorithm = .ed25519
        default:
            throw connectionError(session, prefix: "The server provided an unsupported host-key type")
        }
        return SSHHostKeyObservation(
            hostname: host, port: port, algorithm: algorithm,
            fingerprint: "SHA256:\(digest)", legacyMD5Fingerprint: legacyMD5Fingerprint
        )
    }

    public static func validateHostKey(
        _ observed: SSHHostKeyObservation, expected: Set<SSHHostKeyIdentity>
    ) throws {
        guard expected.contains(observed.identity) else {
            throw TermindSSHError.hostKeyChanged(
                expected: Set(expected.map(\.fingerprint)).sorted(),
                received: observed.fingerprint
            )
        }
    }

    public static func authorizeHostKey(
        hostID: Host.ID, observed: SSHHostKeyObservation,
        expected: Set<SSHHostKeyIdentity>, constraint: SSHHostKeyConstraint? = nil,
        authorizer: SSHHostKeyAuthorizer?
    ) async throws {
        let constraintMatched: Bool
        if let constraint {
            guard constraint.matches(observed) else { throw TermindSSHError.mismatchedHostKey }
            constraintMatched = true
        } else {
            constraintMatched = false
        }
        if expected.contains(observed.identity) { return }
        // A provisional fingerprint is an additional constraint, never an
        // override for an existing, conflicting Known Hosts record.
        if constraintMatched, !expected.isEmpty { throw TermindSSHError.mismatchedHostKey }
        if let authorizer {
            let decision = try await authorizer(
                SSHHostKeyChallenge(
                    hostID: hostID, observation: observed,
                    expectedHostKeys: expected,
                    provisionalConstraintMatched: constraintMatched
                )
            )
            guard decision == .accept else { throw CancellationError() }
            return
        }
        if expected.isEmpty { throw TermindSSHError.untrustedHost }
        throw TermindSSHError.hostKeyChanged(
            expected: expected.map(\.fingerprint).sorted(),
            received: observed.fingerprint
        )
    }

    public static func performHandshake(
        _ session: OpaquePointer, socket: Int32,
        peer: String, timeout: TimeInterval = 20
    ) throws {
        let started = ContinuousClock.now
        errno = 0
        libssh2_session_set_timeout(
            session, max(1, Int(timeout * 1_000))
        )
        let result = libssh2_session_handshake(session, socket)
        let systemError = errno == 0 ? nil : errno
        guard result == 0 else {
            var message: UnsafeMutablePointer<CChar>?
            var length = Int32(0)
            _ = libssh2_session_last_error(session, &message, &length, 0)
            let detail = message.map { String(cString: $0) } ?? ""
            let elapsed = started.duration(to: .now).components
            let milliseconds = max(
                0,
                Int(elapsed.seconds) * 1_000
                    + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            )
            let phase: SSHHandshakeFailure.Phase =
                detail.localizedCaseInsensitiveContains("banner")
                ? .identification
                : detail.localizedCaseInsensitiveContains("key")
                    ? .keyExchange : .unknown
            let kind: SSHHandshakeFailure.Kind
            switch result {
            case LIBSSH2_ERROR_SOCKET_DISCONNECT:
                kind = .peerClosed
            case LIBSSH2_ERROR_BANNER_RECV:
                kind = .invalidIdentification
            case LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_SOCKET_TIMEOUT:
                kind = .timedOut
            case LIBSSH2_ERROR_SOCKET_RECV
            where systemError == EAGAIN || systemError == EWOULDBLOCK
                || systemError == ETIMEDOUT:
                kind = .timedOut
            case LIBSSH2_ERROR_SOCKET_RECV:
                kind = .receiveFailed
            default:
                kind = .other
            }
            throw TermindSSHError.handshake(
                SSHHandshakeFailure(
                    code: result, systemError: systemError, kind: kind,
                    phase: phase,
                    elapsedMilliseconds: milliseconds, peer: peer
                )
            )
        }
    }

    public static func connectionError(_ session: OpaquePointer, prefix: String) -> TermindSSHError {
        .library(connectionErrorMessage(session, prefix: prefix))
    }

    private static func connectionErrorMessage(
        _ session: OpaquePointer, prefix: String, fallbackCode: Int32? = nil
    ) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length = Int32(0)
        let code = libssh2_session_last_error(session, &message, &length, 0)
        let detail = message.map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = detail.flatMap { $0.isEmpty ? nil : $0 } ?? "libssh2 error \(fallbackCode ?? code)"
        return "\(prefix): \(reason) [libssh2 \(fallbackCode ?? code)]"
    }

}

nonisolated extension SSHPTYChannelWorker {
    fileprivate func executeHistoryRead(
        _ command: String, outputLimit: Int, cancellation: TransferCancellationToken
    ) async throws -> SSHExecResult {
        try await execChannelOwner.execute(
            command, workingDirectory: nil, stdin: nil, timeout: 10,
            outputLimit: outputLimit, cancellation: cancellation, onOutput: nil, usesLoginShell: false)
    }

    fileprivate func historySource() async throws -> ShellHistorySource? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while true {
            try Task.checkCancellation()
            let (source, pending) = try await queue.perform { [self] in
                guard connection != nil else { throw TermindSSHError.disconnected }
                return (detectedHistorySource, shellIntegration != nil)
            }
            if !pending || source != nil || ContinuousClock.now >= deadline { return source }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    fileprivate func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        try await sftpChannelOwner.openChannel()
    }

    private func updateSharedConnectionEvents(session: OpaquePointer, buffer: SSHConnectionBuffer) {
        let directions = libssh2_session_block_directions(session)
        socketEvents?.update(
            read: !buffer.isBackpressured,
            write: buffer.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
    }

}

private nonisolated final class SSHAuthenticatedOpeningState: @unchecked Sendable {
    private let cancellationLock = NSLock()
    private var cancellableSocket: Int32
    private var transport: SSHRoutedSocket?
    private var session: OpaquePointer?

    init(transport: SSHRoutedSocket) {
        self.transport = transport
        cancellableSocket = transport.socket
    }

    func begin(
        configuration: SSHConnectionConfiguration, timeout: TimeInterval
    ) throws -> SSHHostKeyObservation {
        guard let transport else { throw TermindSSHError.disconnected }
        guard let created = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw TermindSSHError.library("Unable to create an SSH session.")
        }
        session = created
        libssh2_session_set_blocking(created, 1)
        try SSHConnectionOpener.performHandshake(
            created, socket: transport.socket,
            peer: SSHSocketConnector.peerDescription(
                socket: transport.socket,
                fallbackHost: configuration.host,
                port: configuration.port
            ),
            timeout: timeout
        )
        return try SSHConnectionOpener.observation(
            host: configuration.host, port: configuration.port,
            libssh2Session: created
        )
    }

    func authenticate(
        configuration: SSHConnectionConfiguration,
        afterHostKeyApproval: Bool,
        progress: SSHRouteProgressHandler?, keyboardInteractive: SSHKeyboardInteractiveExchange,
        logger: Logging.Logger
    ) throws -> String {
        guard let session else { throw TermindSSHError.disconnected }
        progress?(.authenticating(configuration.hostID))
        let authentication = try SSHConnectionOpener.authenticate(
            username: configuration.username,
            credentials: configuration.credentials,
            libssh2Session: session,
            afterHostKeyApproval: afterHostKeyApproval,
            keyboardInteractive: keyboardInteractive, socket: transport?.socket ?? -1, logger: logger
        )
        progress?(.authenticated(configuration.hostID))
        return authentication
    }

    func authenticateTailscale(username: String) throws -> (authenticated: Bool, banner: String?) {
        guard let session else { throw TermindSSHError.disconnected }
        libssh2_session_set_blocking(session, 0)
        _ = username.withCString { libssh2_userauth_list(session, $0, UInt32(username.utf8.count)) }
        if libssh2_userauth_authenticated(session) != 0 {
            libssh2_session_set_blocking(session, 1)
            return (true, nil)
        }
        let code = libssh2_session_last_errno(session)
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        _ = libssh2_session_last_error(session, &message, &length, 0)
        let failureDetail = message.map { String(cString: $0) }
        var banner: UnsafeMutablePointer<CChar>?
        _ = libssh2_userauth_banner(session, &banner)
        guard code == LIBSSH2_ERROR_EAGAIN else {
            let detail = banner.map { String(cString: $0) } ?? failureDetail
            let reason = String(localized: "Tailscale SSH authentication failed.")
            throw TermindSSHError.authenticationFailed(
                detail.map { "\(reason)\n\($0) [libssh2 \(code)]" } ?? "\(reason) [libssh2 \(code)]")
        }
        return (false, banner.map { String(cString: $0) })
    }

    func takeResult() throws -> SSHAuthenticatedConnection {
        guard let transport, let session else { throw TermindSSHError.disconnected }
        let result = SSHAuthenticatedConnection(
            byteTransport: transport, libssh2Session: session)
        cancellationLock.withLock { cancellableSocket = -1 }
        self.transport = nil
        self.session = nil
        return result
    }

    func cleanup() {
        if let session {
            _ = libssh2_session_disconnect_ex(
                session, SSH_DISCONNECT_BY_APPLICATION,
                "Termind connection cancelled", ""
            )
            _ = libssh2_session_free(session)
            self.session = nil
        }
        cancellationLock.withLock { cancellableSocket = -1 }
        transport?.close()
        transport = nil
    }

    func cancel() {
        cancellationLock.withLock {
            if cancellableSocket >= 0 {
                _ = Darwin.shutdown(cancellableSocket, SHUT_RDWR)
            }
        }
    }
}

private nonisolated final class SecureEnclaveSigner: @unchecked Sendable {
    public let credential: SecureEnclaveKeyCredential
    public var error: (any Error)?

    public init(credential: SecureEnclaveKeyCredential) {
        self.credential = credential
    }
}

private nonisolated let secureEnclaveSignCallback:
    @convention(c) (
        OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        UnsafeMutablePointer<Int>?, UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> Int32 = { _, signature, signatureLength, data, dataLength, abstract in
        guard let opaqueSigner = abstract?.pointee, let data, dataLength > 0 else { return -1 }
        let signer = Unmanaged<SecureEnclaveSigner>.fromOpaque(opaqueSigner).takeUnretainedValue()
        do {
            let signedData = try SecureEnclaveKey.sign(
                Data(bytes: data, count: dataLength), credential: signer.credential
            )
            guard let output = malloc(signedData.count)?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            signedData.copyBytes(to: output, count: signedData.count)
            signature?.pointee = output
            signatureLength?.pointee = signedData.count
            return 0
        } catch {
            signer.error = error
            return -1
        }
    }
