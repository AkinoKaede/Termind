import CSSH2
import Darwin
import Foundation

nonisolated struct SSHHostKeyObservation: Hashable, Sendable {
    var hostname: String
    var port: Int
    var algorithm: SSHKeyAlgorithm
    var fingerprint: String

    var identity: SSHHostKeyIdentity {
        SSHHostKeyIdentity(algorithm: algorithm, fingerprint: fingerprint)
    }
}

nonisolated struct SSHHostKeyIdentity: Hashable, Sendable {
    var algorithm: SSHKeyAlgorithm
    var fingerprint: String
}

nonisolated struct SSHHostKeyPrompt: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case firstUse
        case additionalKey(trustedKeyCount: Int)
    }

    var observation: SSHHostKeyObservation
    var kind: Kind
}

nonisolated enum SSHCredentials: Sendable {
    case password(String)
    case privateKey(privateKey: String, publicKey: String?, passphrase: String?)
    case secureEnclave(credential: SecureEnclaveKeyCredential, publicKey: String)
}

nonisolated extension StoredSSHKeyCredential {
    func sshCredential(
        publicKey: String, passphraseOverride: String? = nil
    ) -> SSHCredentials {
        switch self {
        case .software(let secret):
            .privateKey(
                privateKey: secret.privateKey,
                publicKey: publicKey.isEmpty ? nil : publicKey,
                passphrase: passphraseOverride ?? secret.passphrase
            )
        case .secureEnclave(let credential):
            .secureEnclave(credential: credential, publicKey: publicKey)
        }
    }
}

/// Everything a non-interactive SSH operation needs after the store has
/// resolved a host's Identity and loaded its secrets from Keychain.
nonisolated struct SSHConnectionConfiguration: Sendable {
    var hostID: Host.ID
    var host: String
    var port: Int
    var username: String
    var credentials: [SSHCredentials]
    var expectedHostKeys: Set<SSHHostKeyIdentity>
    var proxy: SSHTransportProxy?
    /// Root jump first. The destination itself is represented above.
    var jumps: [SSHRouteHopConfiguration] = []
}

/// Saved credentials that could be loaded for one Identity, plus any failures
/// that should be shown if none of the remaining credentials authenticate.
nonisolated struct SSHCredentialResolution: Sendable {
    var credentials: [SSHCredentials]
    var failures: [String]
    var hasConfiguredCredential: Bool
    var requiredPassphraseKeyID: SSHKeyRef.ID?
}

nonisolated enum TermindSSHError: LocalizedError, Sendable {
    case socket(String)
    case proxy(String)
    case route(String)
    case routeHost(
        hostID: Host.ID, authentication: Bool, serverChallenge: Bool,
        hostKey: Bool, message: String
    )
    case library(String)
    case authenticationFailed(String)
    case hostKeyChanged(expected: [String], received: String)
    case missingCredential
    case keyPassphraseRequired
    case missingUsername
    case untrustedHost
    case mismatchedHostKey
    case disconnected

    var errorDescription: String? {
        switch self {
        case .socket(let message), .proxy(let message), .route(let message),
            .library(let message), .authenticationFailed(let message):
            message
        case .routeHost(_, _, _, _, let message): message
        case .hostKeyChanged(let expected, let received):
            String(
                localized:
                    "The host key changed. Expected one of \(expected.joined(separator: ", ")), received \(received)."
            )
        case .missingCredential: String(localized: "The selected identity has no usable password or private key.")
        case .keyPassphraseRequired: String(localized: "Enter the Passphrase for the selected key.")
        case .missingUsername: String(localized: "The selected host has no login username.")
        case .untrustedHost: String(localized: "Connect to this host once before exporting a key to it.")
        case .mismatchedHostKey: String(localized: "The saved host key no longer matches this host.")
        case .disconnected: String(localized: "The SSH connection closed.")
        }
    }

    var shouldRequestAuthentication: Bool {
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, let authentication, _, _, _) = self { return authentication }
        return false
    }

    var isServerAuthenticationChallenge: Bool {
        if case .authenticationFailed = self { return true }
        if case .routeHost(_, _, let serverChallenge, _, _) = self {
            return serverChallenge
        }
        return false
    }

    var routeHostID: Host.ID? {
        guard case .routeHost(let id, _, _, _, _) = self else { return nil }
        return id
    }

    var shouldRequestHostKey: Bool {
        guard case .routeHost(_, _, _, let hostKey, _) = self else { return false }
        return hostKey
    }

    var isHostKeyChanged: Bool {
        if case .hostKeyChanged = self { return true }
        return false
    }

    var isRetryableForwardingFailure: Bool {
        switch self {
        case .socket, .library, .disconnected: true
        case .proxy, .route, .routeHost, .authenticationFailed, .hostKeyChanged,
            .missingCredential, .keyPassphraseRequired, .missingUsername,
            .untrustedHost, .mismatchedHostKey:
            false
        }
    }
}

/// Installs a small cwd-reporting hook before remote output reaches Ghostty.
/// The probe, its echo, and the installation command stay inside this state
/// machine; only the login banner and the final integrated prompt are emitted.
nonisolated struct RemoteShellIntegrationBootstrap: Sendable {
    nonisolated struct Update: Sendable {
        var command: Data?
        var visibleOutput: Data?
        var isComplete = false
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

    let token: String
    let startCommand: Data
    private var deadline: UInt64
    private var phase: Phase = .probing
    private var buffer = Data()
    private var preservedOutput = Data()
    private var lastActivity: UInt64?
    private var userDidWrite = false
    private var installationStartedLate = false

    init(
        token: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.token = token
        startCommand = Data(
            " printf '\\n__TRMD_%s_SHELL__%s__\\n' '\(token)' \"$SHELL\"\n".utf8
        )
        deadline = now + Self.responseTimeout
    }

    mutating func noteUserInput() {
        userDidWrite = true
    }

    mutating func receive(
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
    mutating func poll(
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Update {
        switch phase {
        case .probing where now >= deadline:
            let visible = cleanBufferedOutput()
            phase = .scanningForLateProbe
            lastActivity = nil
            return Update(visibleOutput: visible)
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
            return Update(visibleOutput: visible, isComplete: true)
        case .installing where now >= deadline:
            let visible =
                installationStartedLate
                ? outputAfterLastLineBreak(in: buffer)
                : cleanBufferedOutput()
            finish()
            return Update(visibleOutput: visible, isComplete: true)
        case .probing, .installing, .complete:
            return Update()
        }
    }

    /// Explicit cancellation is kept for connection teardown and focused unit
    /// tests. Production timeout handling uses `poll` so late output remains
    /// eligible for filtering.
    mutating func cancel() -> Data {
        let visible = cleanBufferedOutput()
        finish()
        return visible
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
            preservedOutput = outputBeforeCommand(
                in: Data(buffer[..<prefixRange.lowerBound])
            )
        }
        let shellPath = String(
            decoding: buffer[shellStart..<terminatorRange.lowerBound], as: UTF8.self
        )
        let shell = shellPath.split(separator: "/").last.map(String.init)?.lowercased()
        let suffix = Data(buffer[buffer.index(after: lineEnd)...])
        buffer.removeAll(keepingCapacity: false)

        guard let command = installationCommand(for: shell), !(isLate && userDidWrite) else {
            var visible = preservedOutput
            visible.append(suffix)
            finish()
            return Update(visibleOutput: visible, isComplete: true)
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
        finish()
        return Update(visibleOutput: visible, isComplete: true)
    }

    private mutating func scanForLateProbe(now: UInt64) -> Update {
        let echo = Data(startCommand.dropFirst().dropLast())
        let marker = Data("__TRMD_\(token)_SHELL__".utf8)
        let targets = [echo, marker]

        if let match = earliestMatch(of: targets, in: buffer) {
            var suppressionStart = match.range.lowerBound
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
            isComplete: update.isComplete
        )
    }

    private mutating func cleanBufferedOutput() -> Data {
        var visible = preservedOutput
        if visible.isEmpty { visible = outputBeforeCommand(in: buffer) }
        let suffix = outputAfterLastLineBreak(in: buffer)
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
        let boundary = data.range(of: echo)?.lowerBound ?? data.endIndex
        let prefix = data[..<boundary]
        guard let lineEnd = prefix.lastIndex(of: 0x0A) else { return Data() }
        return Data(prefix[...lineEnd])
    }

    private func installationCommand(for shell: String?) -> Data? {
        let marker = "builtin printf '\\n__TRMD_%s_DONE__\\n' '\(token)'"
        let command: String
        switch shell {
        case "bash":
            command =
                " __termind_uri_path() { builtin local s=\"$1\" out= c hex i LC_ALL=C; for ((i=0;i<${#s};i++)); do c=${s:i:1}; case \"$c\" in [a-zA-Z0-9.~_/-]) out+=\"$c\";; *) builtin printf -v hex '%%%02X' \"'$c\"; out+=\"$hex\";; esac; done; builtin printf %s \"$out\"; }; __termind_report_cwd() { builtin printf '\\e]7;file://localhost%s\\a' \"$(__termind_uri_path \"$PWD\")\"; }; if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == \"declare -a \"* ]]; then PROMPT_COMMAND+=(__termind_report_cwd); else PROMPT_COMMAND=\"${PROMPT_COMMAND:+$PROMPT_COMMAND; }__termind_report_cwd\"; fi; \(marker); __termind_report_cwd\n"
        case "zsh":
            command =
                " function __termind_uri_path { builtin local s=\"$1\" out= c hex i; builtin local LC_ALL=C; for ((i=1;i<=${#s};i++)); do c=${s[i]}; case \"$c\" in [a-zA-Z0-9.~_/-]) out+=\"$c\";; *) builtin printf -v hex '%%%02X' \"'$c\"; out+=\"$hex\";; esac; done; builtin printf %s \"$out\"; }; function __termind_report_cwd { builtin printf '\\e]7;file://localhost%s\\a' \"$(__termind_uri_path \"$PWD\")\"; }; autoload -Uz add-zsh-hook; add-zsh-hook precmd __termind_report_cwd; add-zsh-hook chpwd __termind_report_cwd; \(marker); __termind_report_cwd\n"
        case "fish":
            command =
                " function __termind_report_cwd --on-variable PWD; printf '\\e]7;file://localhost%s\\a' (string escape --style=url $PWD); end; printf '\\n__TRMD_%s_DONE__\\n' '\(token)'; __termind_report_cwd\n"
        default:
            return nil
        }
        return Data(command.utf8)
    }
}

actor SSHSessionActor {
    typealias OutputHandler = @Sendable (Data) -> Void
    typealias ExitHandler = @Sendable (Result<Int32, TermindSSHError>) -> Void

    private let worker: SSHSessionWorker

    init(output: @escaping OutputHandler, exit: @escaping ExitHandler) {
        worker = SSHSessionWorker(output: output, exit: exit)
    }

    static func discoverHostKey(
        hostID: Host.ID, host: String, port: Int, proxy: SSHTransportProxy? = nil,
        jumps: [SSHRouteHopConfiguration] = [],
        timeout: TimeInterval = 15,
        progress: SSHRouteProgressHandler? = nil
    ) async throws
        -> SSHHostKeyObservation
    {
        try await SSHSessionWorker.discoverHostKey(
            hostID: hostID, host: host, port: port, proxy: proxy, jumps: jumps,
            timeout: timeout, progress: progress
        )
    }

    /// Appends a public key to a remote account's `authorized_keys`, unless the
    /// exact line is already present. The key travels over the channel's stdin,
    /// never as shell syntax, so a comment on the key cannot become a command.
    static func installAuthorizedKey(
        _ publicKey: String, using configuration: SSHConnectionConfiguration
    ) async throws {
        try await SSHSessionWorker.installAuthorizedKey(
            publicKey, using: configuration
        )
    }

    func connect(
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
        try await worker.connect(
            hostID: hostID, host: host, port: port, username: username,
            credentials: credentials, expectedHostKeys: expectedHostKeys,
            proxy: proxy, jumps: jumps,
            shellIntegrationEnabled: shellIntegrationEnabled,
            columns: columns, rows: rows, progress: progress
        )
    }

    func write(_ data: Data) {
        worker.write(data)
    }

    func resize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        worker.resize(
            columns: columns, rows: rows,
            widthPixels: widthPixels, heightPixels: heightPixels
        )
    }

    func disconnect() {
        worker.disconnect()
    }
}

nonisolated final class SSHSessionWorker: @unchecked Sendable {
    private static let initialization: Void = {
        precondition(libssh2_init(0) == 0, "libssh2 initialization failed")
    }()

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.session")
    private let output: SSHSessionActor.OutputHandler
    private let exit: SSHSessionActor.ExitHandler

    private var socket: Int32 = -1
    private var routeTransport: SSHRoutedSocket?
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var pumpTimer: (any DispatchSourceTimer)?
    private var pendingWrites = Data()
    private var shellIntegration: RemoteShellIntegrationBootstrap?
    private var didReportExit = false

    init(output: @escaping SSHSessionActor.OutputHandler, exit: @escaping SSHSessionActor.ExitHandler) {
        _ = Self.initialization
        self.output = output
        self.exit = exit
    }

    static func discoverHostKey(
        hostID: Host.ID, host: String, port: Int, proxy: SSHTransportProxy?,
        jumps: [SSHRouteHopConfiguration], timeout: TimeInterval,
        progress: SSHRouteProgressHandler?
    ) async throws
        -> SSHHostKeyObservation
    {
        _ = initialization
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var transport: SSHRoutedSocket?
                var session: OpaquePointer?
                do {
                    transport = try SSHRoutedSocket.open(
                        host: host, port: port, proxy: proxy,
                        jumps: jumps, timeout: timeout, progress: progress
                    )
                    progress?(.connecting(hostID))
                    guard let created = libssh2_session_init_ex(nil, nil, nil, nil) else {
                        throw TermindSSHError.library("Unable to create an SSH session.")
                    }
                    session = created
                    libssh2_session_set_blocking(created, 1)
                    guard let transport,
                        libssh2_session_handshake(created, transport.socket) == 0
                    else {
                        throw sessionError(created, prefix: "SSH handshake failed")
                    }
                    continuation.resume(returning: try observation(host: host, port: port, session: created))
                } catch {
                    continuation.resume(throwing: error)
                }
                if let session {
                    _ = libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "probe complete", "")
                    _ = libssh2_session_free(session)
                }
                transport?.close()
            }
        }
    }

    static func installAuthorizedKey(
        _ publicKey: String, using configuration: SSHConnectionConfiguration
    ) async throws {
        _ = initialization
        let normalized = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("\n"), !normalized.contains("\r") else {
            throw TermindSSHError.library("The public key is not a single OpenSSH key line.")
        }

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try installAuthorizedKeyBlocking(
                        normalized, using: configuration
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// A short-lived exec channel rather than a PTY. The fixed script creates
    /// the OpenSSH directory with restrictive permissions and performs an exact
    /// line check before appending, making repeated exports idempotent.
    private static func installAuthorizedKeyBlocking(
        _ publicKey: String, using configuration: SSHConnectionConfiguration
    ) throws {
        var transport: SSHRoutedSocket?
        var session: OpaquePointer?
        var channel: OpaquePointer?
        defer {
            if let channel {
                _ = libssh2_channel_send_eof(channel)
                _ = libssh2_channel_close(channel)
                _ = libssh2_channel_free(channel)
            }
            if let session {
                _ = libssh2_session_disconnect_ex(
                    session, SSH_DISCONNECT_BY_APPLICATION, "Termind completed key export", ""
                )
                _ = libssh2_session_free(session)
            }
            transport?.close()
        }

        transport = try SSHRoutedSocket.open(
            host: configuration.host, port: configuration.port,
            proxy: configuration.proxy, jumps: configuration.jumps, timeout: 20
        )
        guard let created = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw TermindSSHError.library("Unable to create an SSH session.")
        }
        session = created
        libssh2_session_set_blocking(created, 1)
        guard let transport,
            libssh2_session_handshake(created, transport.socket) == 0
        else {
            throw sessionError(created, prefix: "SSH handshake failed")
        }

        let observed = try observation(
            host: configuration.host, port: configuration.port, session: created
        )
        try validateHostKey(observed, expected: configuration.expectedHostKeys)
        try authenticate(
            username: configuration.username,
            credentials: configuration.credentials,
            session: created
        )

        guard
            let opened = libssh2_channel_open_ex(
                created, "session", 7, 2 * 1024 * 1024, 32 * 1024, nil, 0
            )
        else {
            throw sessionError(created, prefix: "Unable to open SSH channel")
        }
        channel = opened

        let command =
            #"umask 077; dir="$HOME/.ssh"; file="$dir/authorized_keys"; mkdir -p "$dir" && touch "$file" && chmod 700 "$dir" && chmod 600 "$file" && IFS= read -r key && { LC_ALL=C grep -Fqx -- "$key" "$file" || printf '%s\n' "$key" >> "$file"; }"#
        let started = command.withCString { commandBuffer in
            libssh2_channel_process_startup(
                opened, "exec", 4, commandBuffer, UInt32(command.utf8.count)
            )
        }
        guard started == 0 else {
            throw sessionError(created, prefix: "Unable to start authorized_keys update")
        }

        let input = Data((publicKey + "\n").utf8)
        try input.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            var offset = 0
            while offset < bytes.count {
                let written = libssh2_channel_write_ex(
                    opened, 0, base.advanced(by: offset), bytes.count - offset
                )
                guard written > 0 else {
                    throw sessionError(created, prefix: "Unable to send the public key")
                }
                offset += written
            }
        }
        guard libssh2_channel_send_eof(opened) == 0 else {
            throw sessionError(created, prefix: "Unable to finish the public-key upload")
        }
        _ = libssh2_channel_wait_eof(opened)

        let standardError = readAll(from: opened, stream: 1)
        let status = libssh2_channel_get_exit_status(opened)
        guard status == 0 else {
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TermindSSHError.library(
                detail.isEmpty
                    ? "The remote authorized_keys update exited with status \(status)."
                    : "The remote authorized_keys update failed: \(detail)"
            )
        }
    }

    private static func readAll(from channel: OpaquePointer, stream: Int32) -> String {
        var data = Data()
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        while true {
            let count = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(Data(bytes: buffer, count: count))
        }
        return String(decoding: data, as: UTF8.self)
    }

    func connect(
        hostID: Host.ID, host: String, port: Int, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>, proxy: SSHTransportProxy?,
        jumps: [SSHRouteHopConfiguration],
        shellIntegrationEnabled: Bool,
        columns: UInt16, rows: UInt16,
        progress: SSHRouteProgressHandler?
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    cleanup()
                    routeTransport = try SSHRoutedSocket.open(
                        host: host, port: port, proxy: proxy,
                        jumps: jumps, timeout: 20, progress: progress
                    )
                    progress?(.connecting(hostID))
                    guard let routeTransport else { throw TermindSSHError.disconnected }
                    socket = routeTransport.socket
                    guard let created = libssh2_session_init_ex(nil, nil, nil, nil) else {
                        throw TermindSSHError.library("Unable to create an SSH session.")
                    }
                    session = created
                    libssh2_session_set_blocking(created, 1)
                    guard libssh2_session_handshake(created, socket) == 0 else {
                        throw Self.sessionError(created, prefix: "SSH handshake failed")
                    }
                    let observed = try Self.observation(host: host, port: port, session: created)
                    try Self.validateHostKey(observed, expected: expectedHostKeys)
                    progress?(.authenticating(hostID))
                    try Self.authenticate(username: username, credentials: credentials, session: created)
                    progress?(.authenticated(hostID))
                    guard
                        let opened = libssh2_channel_open_ex(
                            created, "session", 7,
                            2 * 1024 * 1024,
                            32 * 1024, nil, 0
                        )
                    else {
                        throw Self.sessionError(created, prefix: "Unable to open SSH channel")
                    }
                    channel = opened
                    let pty = libssh2_channel_request_pty_ex(
                        opened, "xterm-256color", 14, nil, 0,
                        Int32(columns), Int32(rows), 0, 0
                    )
                    guard pty == 0 else { throw Self.sessionError(created, prefix: "PTY request failed") }
                    guard libssh2_channel_process_startup(opened, "shell", 5, nil, 0) == 0 else {
                        throw Self.sessionError(created, prefix: "Remote shell request failed")
                    }
                    libssh2_session_set_blocking(created, 0)
                    libssh2_keepalive_config(created, 1, 20)
                    didReportExit = false
                    if shellIntegrationEnabled {
                        let bootstrap = RemoteShellIntegrationBootstrap()
                        pendingWrites.append(bootstrap.startCommand)
                        shellIntegration = bootstrap
                    }
                    startPump()
                    progress?(.connected(hostID))
                    continuation.resume()
                } catch {
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            if var integration = shellIntegration {
                integration.noteUserInput()
                shellIntegration = integration
            }
            pendingWrites.append(data)
            pump()
        }
    }

    func resize(columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32) {
        guard columns > 0, rows > 0 else { return }
        queue.async { [self] in
            guard let channel else { return }
            _ = libssh2_channel_request_pty_size_ex(
                channel, Int32(columns), Int32(rows),
                Int32(clamping: widthPixels), Int32(clamping: heightPixels)
            )
        }
    }

    func disconnect() {
        queue.async { [self] in
            cleanup()
        }
    }

    static func authenticate(
        username: String, credentials: [SSHCredentials], session: OpaquePointer
    ) throws {
        let methods = try authenticationMethods(username: username, session: session)
        // Asking for the method list sends SSH's `none` authentication request.
        // Servers that need no credential accept it there and report the
        // session as authenticated without another userauth call.
        if libssh2_userauth_authenticated(session) == 1 { return }
        var attempted = false
        var secureEnclaveError: (any Error)?
        for credentials in credentials {
            switch credentials {
            case .password(let password):
                if methods.contains("password") {
                    attempted = true
                    let result = username.withCString { user in
                        password.withCString { password in
                            libssh2_userauth_password_ex(
                                session, user, UInt32(username.utf8.count),
                                password, UInt32(strlen(password)), nil
                            )
                        }
                    }
                    if result == 0 { return }
                }
                if methods.contains("keyboard-interactive") {
                    attempted = true
                    if keyboardInteractive(
                        username: username, password: password, session: session
                    ) == 0 {
                        return
                    }
                }
            case .privateKey(let privateKey, let publicKey, let passphrase):
                guard methods.contains("publickey") else { continue }
                attempted = true
                let result = username.withCString { user in
                    privateKey.withCString { privateBuffer in
                        let call: (UnsafePointer<CChar>?) -> Int32 = { publicBuffer in
                            if let passphrase {
                                return passphrase.withCString { passphraseBuffer in
                                    libssh2_userauth_publickey_frommemory(
                                        session, user, username.utf8.count,
                                        publicBuffer, publicKey?.utf8.count ?? 0,
                                        privateBuffer, privateKey.utf8.count, passphraseBuffer
                                    )
                                }
                            }
                            return libssh2_userauth_publickey_frommemory(
                                session, user, username.utf8.count,
                                publicBuffer, publicKey?.utf8.count ?? 0,
                                privateBuffer, privateKey.utf8.count, nil
                            )
                        }
                        return publicKey?.withCString(call) ?? call(nil)
                    }
                }
                if result == 0 { return }
            case .secureEnclave(let credential, let publicKey):
                guard methods.contains("publickey") else { continue }
                guard let publicBlob = SecureEnclaveKey.publicBlob(from: publicKey) else {
                    secureEnclaveError = TermindSSHError.library(
                        "The Secure Enclave key has an invalid SSH public key."
                    )
                    continue
                }
                attempted = true
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
                if result == 0 { return }
                secureEnclaveError = signer.error
            }
        }
        if let secureEnclaveError {
            throw TermindSSHError.authenticationFailed(secureEnclaveError.localizedDescription)
        }
        let available = methods.sorted().joined(separator: ", ")
        let prefix =
            attempted
            ? "SSH authentication failed"
            : "No configured credential matches the server methods (\(available))"
        throw TermindSSHError.authenticationFailed(
            Self.sessionErrorMessage(session, prefix: prefix)
        )
    }

    private static func authenticationMethods(
        username: String, session: OpaquePointer
    ) throws -> Set<String> {
        let pointer = username.withCString { user in
            libssh2_userauth_list(session, user, UInt32(username.utf8.count))
        }
        guard let pointer else {
            if libssh2_userauth_authenticated(session) == 1 { return [] }
            throw Self.sessionError(
                session, prefix: "Unable to read SSH authentication methods"
            )
        }
        let bytes = UnsafeBufferPointer(start: pointer, count: strlen(pointer))
            .map { UInt8(bitPattern: $0) }
        return Set(String(decoding: bytes, as: UTF8.self).split(separator: ",").map(String.init))
    }

    private static func keyboardInteractive(
        username: String, password: String, session: OpaquePointer
    ) -> Int32 {
        let box = Unmanaged.passRetained(SSHKeyboardPassword(password))
        let abstract = libssh2_session_abstract(session)
        abstract?.pointee = box.toOpaque()
        defer {
            abstract?.pointee = nil
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(12), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.pump() }
        pumpTimer = timer
        timer.resume()
    }

    private func pump() {
        guard let session, let channel else { return }
        var buffer = [CChar](repeating: 0, count: 32 * 1024)
        while true {
            let count = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if count > 0 {
                deliverOutput(Data(bytes: buffer, count: count))
            } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                break
            } else {
                reportExit(.failure(Self.sessionError(session, prefix: "SSH read failed")))
                cleanup()
                return
            }
        }

        if var integration = shellIntegration {
            let update = integration.poll()
            shellIntegration = update.isComplete ? nil : integration
            applyShellIntegrationUpdate(update)
        }

        while !pendingWrites.isEmpty {
            let written = pendingWrites.withUnsafeBytes { bytes -> Int in
                guard let address = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                return libssh2_channel_write_ex(channel, 0, address, bytes.count)
            }
            if written > 0 {
                pendingWrites.removeFirst(written)
            } else if written == LIBSSH2_ERROR_EAGAIN {
                break
            } else {
                reportExit(.failure(Self.sessionError(session, prefix: "SSH write failed")))
                cleanup()
                return
            }
        }

        var next = Int32(0)
        _ = libssh2_keepalive_send(session, &next)
        if libssh2_channel_eof(channel) == 1 {
            let status = libssh2_channel_get_exit_status(channel)
            reportExit(.success(status))
            cleanup()
        }
    }

    private func reportExit(_ result: Result<Int32, TermindSSHError>) {
        guard !didReportExit else { return }
        didReportExit = true
        exit(result)
    }

    private func deliverOutput(_ data: Data) {
        guard var integration = shellIntegration else {
            output(data)
            return
        }
        let update = integration.receive(data)
        shellIntegration = update.isComplete ? nil : integration
        applyShellIntegrationUpdate(update)
    }

    private func applyShellIntegrationUpdate(
        _ update: RemoteShellIntegrationBootstrap.Update
    ) {
        if let command = update.command {
            pendingWrites.append(command)
        }
        if let visibleOutput = update.visibleOutput, !visibleOutput.isEmpty {
            output(visibleOutput)
        }
    }

    private func cleanup() {
        pumpTimer?.cancel()
        pumpTimer = nil
        pendingWrites.removeAll(keepingCapacity: false)
        shellIntegration = nil
        if let channel {
            _ = libssh2_channel_send_eof(channel)
            _ = libssh2_channel_close(channel)
            _ = libssh2_channel_free(channel)
            self.channel = nil
        }
        if let session {
            _ = libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Termind closed the session", "")
            _ = libssh2_session_free(session)
            self.session = nil
        }
        if socket >= 0 {
            socket = -1
        }
        routeTransport?.close()
        routeTransport = nil
    }

    static func observation(host: String, port: Int, session: OpaquePointer) throws
        -> SSHHostKeyObservation
    {
        guard let hash = libssh2_hostkey_hash(session, Int32(LIBSSH2_HOSTKEY_HASH_SHA256)) else {
            throw sessionError(session, prefix: "The server did not provide a host-key fingerprint")
        }
        let digest = Data(bytes: hash, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
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
            throw sessionError(session, prefix: "The server provided an unsupported host-key type")
        }
        return SSHHostKeyObservation(
            hostname: host, port: port, algorithm: algorithm,
            fingerprint: "SHA256:\(digest)"
        )
    }

    static func validateHostKey(
        _ observed: SSHHostKeyObservation, expected: Set<SSHHostKeyIdentity>
    ) throws {
        guard expected.contains(observed.identity) else {
            throw TermindSSHError.hostKeyChanged(
                expected: Set(expected.map(\.fingerprint)).sorted(),
                received: observed.fingerprint
            )
        }
    }

    static func sessionError(_ session: OpaquePointer, prefix: String) -> TermindSSHError {
        .library(sessionErrorMessage(session, prefix: prefix))
    }

    private static func sessionErrorMessage(_ session: OpaquePointer, prefix: String) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length = Int32(0)
        let code = libssh2_session_last_error(session, &message, &length, 0)
        let detail = message.map { String(cString: $0) } ?? "libssh2 error \(code)"
        return "\(prefix): \(detail)"
    }

    private static func openSocket(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw TermindSSHError.socket(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var lastError = String(localized: "Connection failed")
        while let info = cursor?.pointee {
            let candidate = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if candidate >= 0 {
                var yes: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
                var interval = timeval(
                    tv_sec: Int(timeout),
                    tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
                )
                setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
                do {
                    try connectSocket(
                        candidate, address: info.ai_addr,
                        addressLength: info.ai_addrlen, timeout: timeout
                    )
                    return candidate
                } catch {
                    lastError = error.localizedDescription
                }
                Darwin.close(candidate)
            }
            cursor = info.ai_next
        }
        throw TermindSSHError.socket(lastError)
    }

    private static func connectSocket(
        _ socket: Int32, address: UnsafePointer<sockaddr>,
        addressLength: socklen_t, timeout: TimeInterval
    ) throws {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TermindSSHError.socket(String(cString: strerror(errno)))
        }
        defer { _ = fcntl(socket, F_SETFL, flags) }

        if Darwin.connect(socket, address, addressLength) == 0 { return }
        guard errno == EINPROGRESS else {
            throw TermindSSHError.socket(String(cString: strerror(errno)))
        }

        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(
            min(Double(Int32.max), max(1, timeout * 1_000))
        )
        let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
        if pollResult == 0 {
            throw TermindSSHError.socket(String(localized: "Connection timed out."))
        }
        guard pollResult > 0 else {
            throw TermindSSHError.socket(String(cString: strerror(errno)))
        }

        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0 else {
            throw TermindSSHError.socket(String(cString: strerror(errno)))
        }
        guard socketError == 0 else {
            throw TermindSSHError.socket(String(cString: strerror(socketError)))
        }
    }
}

private nonisolated final class SecureEnclaveSigner: @unchecked Sendable {
    let credential: SecureEnclaveKeyCredential
    var error: (any Error)?

    init(credential: SecureEnclaveKeyCredential) {
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

private nonisolated final class SSHKeyboardPassword: @unchecked Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }
}

private nonisolated func sshKeyboardInteractiveResponse(
    _ name: UnsafePointer<CChar>?, _ nameLength: Int32,
    _ instruction: UnsafePointer<CChar>?, _ instructionLength: Int32,
    _ promptCount: Int32,
    _ prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    _ responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) {
    guard promptCount > 0, let responses, let opaque = abstract?.pointee else { return }
    let password = Unmanaged<SSHKeyboardPassword>.fromOpaque(opaque)
        .takeUnretainedValue().value
    for index in 0..<Int(promptCount) {
        responses[index].text = password.withCString(Darwin.strdup)
        responses[index].length = UInt32(password.utf8.count)
    }
}
