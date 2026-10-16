import Foundation
import TermindApplication
import TermindDomain

/// A bounded, read-only exec operation on the terminal's authenticated connection.
public nonisolated struct RemoteShellHistoryLoader: ShellHistoryLoading {
    public static let maximumFileBytes = 2 * 1024 * 1024
    private let execute: @Sendable (String, Int) async throws -> SSHExecResult
    private let resolveSource: @Sendable () async throws -> ShellHistorySource?
    private let charset: RemoteCharset

    public init(channel: SSHPTYChannel, charset: RemoteCharset) {
        self.init(
            charset: charset,
            resolveSource: { try await channel.historySource() },
            execute: { try await channel.executeHistoryRead($0, outputLimit: $1) })
    }

    public init(channel: SSHPTYChannel, charset: RemoteCharset, context: TerminalShellContext) {
        self.init(
            charset: charset,
            resolveSource: {
                guard let source = context.historySource else { throw TerminalRuntimeError.staleContext }
                return source
            },
            execute: { try await channel.executeHistoryRead($0, outputLimit: $1, context: context) })
    }

    init(
        charset: RemoteCharset,
        resolveSource: @escaping @Sendable () async throws -> ShellHistorySource?,
        execute: @escaping @Sendable (String, Int) async throws -> SSHExecResult
    ) {
        self.charset = charset
        self.resolveSource = resolveSource
        self.execute = execute
    }

    public func load(source: ShellHistorySource?) async throws -> [ShellHistoryRecord] {
        try await withThrowingTaskGroup(of: [ShellHistoryRecord].self) { group in
            group.addTask { try await read(source: source) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TermindSSHError.library("History read timed out.")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    private func read(source: ShellHistorySource?) async throws -> [ShellHistoryRecord] {
        let resolved: ShellHistorySource?
        if let source { resolved = source } else { resolved = try await resolveSource() }
        if resolved?.path == "" { return [] }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let result = try await executeRead(Self.command(source: resolved, token: token))
        guard result.exitCode == 0, !result.stdoutTruncated else {
            throw TermindSSHError.library("History file could not be read.")
        }
        guard let start = result.stdout.range(of: "__TRMD_HISTORY_\(token)__"),
            let lineEnd = result.stdout[start.upperBound...].firstIndex(of: "\n"),
            let end = result.stdout.range(of: "__TRMD_HISTORY_END_\(token)__", range: lineEnd..<result.stdout.endIndex)
        else { throw TermindSSHError.library("History response was incomplete.") }
        let fields = result.stdout[start.upperBound..<lineEnd].split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 2, let size = Int(fields[1]), size >= 0 else {
            throw TermindSSHError.library("History response was invalid.")
        }
        if size == 0 { return [] }
        guard let shell = ShellHistorySource.Shell(rawValue: String(fields[0])),
            var bytes = Data(
                base64Encoded: String(result.stdout[lineEnd..<end.lowerBound]), options: .ignoreUnknownCharacters),
            bytes.count <= Self.maximumFileBytes
        else { throw TermindSSHError.library("History response was invalid.") }
        if shell == .zsh { bytes = Self.unmetafy(bytes) }
        let text = try RemoteCharsetStreamConverter.decode(bytes, charset: charset)
        return Array(
            ShellHistoryParser.parse(text, shell: shell, truncatedStart: size > Self.maximumFileBytes)
                .suffix(HistoryLimits.retainedEntries))
    }

    private func executeRead(_ command: String) async throws -> SSHExecResult {
        // A runtime poll may briefly own the last free channel. Never queue behind the user's PTY.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await execute(command, 3 * 1024 * 1024)
            } catch TerminalRuntimeError.capacityUnavailable where attempt < 2 {
                try await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
            }
        }
        throw TerminalRuntimeError.capacityUnavailable
    }

    static func command(source: ShellHistorySource?, token: String) -> String {
        let shell = source.map { quote($0.shell.rawValue) } ?? "\"${SHELL##*/}\""
        let path =
            source?.path.map { "file=\(quote($0));" }
            ?? #"case "$kind" in bash) file=${HISTFILE-$HOME/.bash_history} ;; zsh) file=${HISTFILE-${ZDOTDIR-$HOME}/.zsh_history} ;; fish) name=${fish_history-fish}; if [ -n "$name" ]; then file=${XDG_DATA_HOME-$HOME/.local/share}/fish/${name}_history; else file=; fi ;; *) file= ;; esac;"#
        // The file is data, never shell source. Base64 preserves zsh metafied and non-UTF-8 bytes
        // across the ordinary exec charset decoder. Framing excludes login/profile chatter.
        return """
            kind=\(shell); \(path)
            if [ -z "$file" ] || [ ! -e "$file" ]; then
              printf '__TRMD_HISTORY_\(token)__%s;0\\n__TRMD_HISTORY_END_\(token)__\\n' "$kind"; exit 0
            fi
            [ -f "$file" ] && [ -r "$file" ] || exit 1
            exec 3< "$file" || exit 1
            size=$(wc -c < "$file") || exit 1
            size=$(printf '%s' "$size" | tr -d '[:space:]')
            printf '__TRMD_HISTORY_\(token)__%s;%s\\n' "$kind" "$size"
            tail -c \(maximumFileBytes) <&3 | base64 || exit 1
            printf '\\n__TRMD_HISTORY_END_\(token)__\\n'
            """
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func unmetafy(_ input: Data) -> Data {
        var output = Data()
        var iterator = input.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x83, let next = iterator.next() { output.append(next ^ 0x20) } else { output.append(byte) }
        }
        return output
    }
}
