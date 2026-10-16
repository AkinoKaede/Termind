import Foundation
import TermindApplication
import TermindDomain

public nonisolated struct SSHHostMACAddressResolver: HostMACAddressResolving {
    private let coordinator: RemoteConnectionCoordinator
    public init(coordinator: RemoteConnectionCoordinator) { self.coordinator = coordinator }

    public func resolve(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws
        -> [HostMACAddressCandidate]
    {
        var request = request
        request.configuration.beforeConnect = nil
        request.permitsAgentForwarding = false
        let connection = try await coordinator.connectConnection(using: request, progress: progress)
        do {
            var candidates: [HostMACAddressCandidate] = []
            for command in [Self.unixCommand, Self.windowsCommand] {
                try Task.checkCancellation()
                let result = try await connection.execute(
                    command, workingDirectory: nil, stdin: nil, timeout: 10, outputLimit: 16 * 1024, onOutput: nil)
                candidates = Self.parse(result.stdout)
                if !candidates.isEmpty { break }
            }
            await connection.disconnect()
            return candidates
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    static func parse(_ output: String) -> [HostMACAddressCandidate] {
        var seen: Set<MACAddress> = []
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2,
                let address = MACAddress(String(fields[1]).trimmingCharacters(in: .whitespaces)),
                seen.insert(address).inserted
            else { return nil }
            let name = String(fields[0]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return .init(interface: name, address: address)
        }
    }

    static let unixCommand = """
        sh -c 'if [ "$(uname -s)" = Darwin ]; then
          /usr/sbin/networksetup -listallhardwareports | awk \
        "/^Device: / {dev=\\$2} /^Ethernet Address: / {if(dev ~ /^en[0-9]+$/) print dev \\"|\\" \\$3}"
        else
          for d in /sys/class/net/*; do
            [ -e "$d/device" ] || continue
            [ "$(cat "$d/type" 2>/dev/null)" = 1 ] || continue
            printf "%s|%s\\n" "${d##*/}" "$(cat "$d/address")"
          done
        fi'
        """
    static let windowsCommand: String = {
        // EncodedCommand works with either cmd.exe or PowerShell as OpenSSH's default shell.
        let script = """
            Get-NetAdapter -Physical | Where-Object { $_.MacAddress } | ForEach-Object \
            { $_.Name + '|' + $_.MacAddress }
            """
        let bytes = script.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
        return "powershell.exe -NoProfile -NonInteractive -EncodedCommand " + Data(bytes).base64EncodedString()
    }()
}
