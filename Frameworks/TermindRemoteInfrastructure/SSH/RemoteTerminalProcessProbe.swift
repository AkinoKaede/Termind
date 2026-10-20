// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

/// Read-only OS evidence. An argv session name is never proof of a client's current endpoint.
nonisolated struct RemoteTerminalProcessProbe {
    struct Client: Equatable {
        let backend: SessionPersistenceBackendID
        let process: String
        let started: String
        let endpoint: String?

        var identity: String { process + ":" + started }
    }

    let execute: RemoteSessionCommandExecutor

    func isOrdinaryShell(terminal: String) async throws -> Bool {
        let result = try await execute(Self.ordinaryShellCommand(terminal: terminal))
        return result.exitCode == 0 && !result.truncated && result.stdout == "TERMIND_ORDINARY_SHELL\n"
    }

    static func ordinaryShellCommand(terminal: String) throws -> String {
        guard RemoteTmuxClientIdentity.validTerminal(terminal) else { throw TerminalRuntimeError.invalidResponse }
        return """
            export LC_ALL=C
            tty=\(try RemoteMultiplexerCommands.quote(String(terminal.dropFirst("/dev/".count))))
            rows=$(ps -t "$tty" -o pid= -o pgid= -o tpgid= -o tty= -o comm= | head -c 65537) || exit 79
            [ "${#rows}" -le 65536 ] || exit 79
            printf '%s\\n' "$rows" | awk -v tty="$tty" '
                NF != 5 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 != tty {
                    invalid=1; next
                }
                $2 == $3 && $3 > 0 {
                    count++
                    name=$5; sub(/^.*\\//,"",name); sub(/^-/,"",name)
                    if (name ~ /^(sh|dash|ksh|ksh93|bash|zsh|fish|csh|tcsh)$/) shells++
                }
                END {
                    if (!invalid && count == 1 && shells == 1) print "TERMIND_ORDINARY_SHELL"
                    else exit 79
                }'
            """
    }

    func inspect(terminal: String) async throws -> Client? {
        let result = try await execute(Self.command(terminal: terminal))
        guard result.exitCode == 0, !result.truncated else { throw TerminalRuntimeError.unsupported }
        return try Self.parse(result.stdout)
    }

    static func command(terminal: String) throws -> String {
        guard RemoteTmuxClientIdentity.validTerminal(terminal) else { throw TerminalRuntimeError.invalidResponse }
        let names = SessionPersistenceBackendID.supported.map(\.rawValue).joined(separator: "|")
        return """
            export LC_ALL=C
            \(RemoteMultiplexerCommands.utilities)
            tty=\(try RemoteMultiplexerCommands.quote(String(terminal.dropFirst("/dev/".count))))
            rows=$(ps -t "$tty" -o pid= -o pgid= -o tpgid= -o comm=) || exit 79
            clients=$(printf '%s\\n' "$rows" | awk '
                $2 == $3 && $3 > 0 {
                    name=$4; sub(/^.*\\//,"",name); sub(/:$/,"",name)
                    if (name ~ /^(\(names))$/) print name "|" $1
                }')
            if [ -z "$clients" ]; then printf 'NONE\\n'; exit 0; fi
            [ "$(printf '%s\\n' "$clients" | wc -l | tr -d ' ')" = 1 ] || { printf 'AMBIGUOUS\\n'; exit 0; }
            kind=${clients%|*}; client=${clients#*|}
            started=$(process_start "$client")
            [ -n "$started" ] || exit 79
            printf 'M|%s|%s|%s\\n' "$kind" "$client" "$(hex "$started")"
            if command -v ss >/dev/null 2>&1; then
                sockets=$(ss -xnpH 2>/dev/null | head -c 262145)
                printf 'S|%s\\n' "$(hex "$sockets")"
            elif [ "$(uname -s)" = Linux ] && command -v python3 >/dev/null 2>&1; then
                endpoint=$(python3 - "$client" 2>/dev/null <<'TERMIND_SOCKET_DIAG'
            \(linuxSocketDiagnostic)
            TERMIND_SOCKET_DIAG
                ) || endpoint=
                printf 'P|%s\\n' "$endpoint"
            elif [ "$(uname -s)" = Darwin ] && command -v lsof >/dev/null 2>&1; then
                pids=$(ps -u "$(id -u)" -o pid= -o comm= | awk -v kind="$kind" '
                    {name=$2; sub(/^.*\\//,"",name); if(name==kind) {if(p!="") p=p ","; p=p $1}} END {print p}')
                sockets=$(lsof -nP -a -p "$pids" -U -F pdfn 2>/dev/null | head -c 262145)
                printf 'L|%s\\n' "$(hex "$sockets")"
            else
                printf 'S|\\n'
            fi
            [ "$(process_start "$client")" = "$started" ] || exit 79
            printf 'DONE\\n'
            """
    }

    static func parse(_ text: String) throws -> Client? {
        if text == "NONE\n" { return nil }
        guard text != "AMBIGUOUS\n" else { throw TerminalRuntimeError.invalidResponse }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 4, lines[2] == "DONE", lines[3].isEmpty else {
            throw TerminalRuntimeError.invalidResponse
        }
        let meta = lines[0].components(separatedBy: "|")
        guard meta.count == 4, meta[0] == "M",
            SessionPersistenceBackendID.supported.contains(.init(rawValue: meta[1])),
            UInt64(meta[2]).map({ $0 > 1 }) == true,
            lines[1].hasPrefix("S|") || lines[1].hasPrefix("L|") || lines[1].hasPrefix("P|")
        else { throw TerminalRuntimeError.invalidResponse }
        let started = try RemoteMultiplexerCommands.unhex(meta[3])
        guard !started.isEmpty, started.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw TerminalRuntimeError.invalidResponse
        }
        let evidence = try RemoteMultiplexerCommands.unhex(String(lines[1].dropFirst(2)), limit: 262144)
        let endpoint: String?
        if lines[1].hasPrefix("P|") {
            endpoint = RemoteMultiplexerCommands.validPath(evidence) ? evidence : nil
        } else {
            endpoint =
                lines[1].hasPrefix("S|")
                ? linuxEndpoint(evidence, process: meta[2]) : darwinEndpoint(evidence, process: meta[2])
        }
        return Client(backend: .init(rawValue: meta[1]), process: meta[2], started: started, endpoint: endpoint)
    }

    /// Linux exposes UNIX peers through SOCK_DIAG, not /proc/net/unix. Use the
    /// standard library when iproute2 is absent, without installing remote helpers.
    static let linuxSocketDiagnostic = #"""
        import os, socket, struct, sys

        owned = set()
        for entry in os.scandir("/proc/" + sys.argv[1] + "/fd"):
            try:
                link = os.readlink(entry.path)
                if link.startswith("socket:[") and link.endswith("]"):
                    owned.add(int(link[8:-1]))
            except (OSError, ValueError):
                pass
        if not owned:
            sys.exit(0)
        request = struct.pack("=BBHIIIII", socket.AF_UNIX, 0, 0, 0xffffffff, 0, 5, 0xffffffff, 0xffffffff)
        header = struct.pack("=IHHII", 16 + len(request), 20, 0x301, 1, 0)
        peers = {}
        with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 4) as channel:
            channel.settimeout(0.5)
            channel.bind((0, 0))
            channel.sendto(header + request, (0, 0))
            done = False
            total = 0
            while not done:
                data, _, flags, sender = channel.recvmsg(65536)
                total += len(data)
                if flags & socket.MSG_TRUNC or total > 1048576 or sender[0] != 0:
                    sys.exit(1)
                offset = 0
                while offset < len(data):
                    length, kind, flags, seq, _ = struct.unpack_from("=IHHII", data, offset)
                    if length < 16 or offset + length > len(data) or seq != 1 or flags & 0x10:
                        sys.exit(1)
                    end = offset + length
                    if kind == 3:
                        done = True
                    elif kind == 2:
                        sys.exit(1)
                    elif kind == 20:
                        family, _, _, _, inode, _, _ = struct.unpack_from("=BBBBIII", data, offset + 16)
                        if family != socket.AF_UNIX:
                            sys.exit(1)
                        peer, path = None, b""
                        attribute = offset + 32
                        while attribute < end:
                            size, tag = struct.unpack_from("=HH", data, attribute)
                            if size < 4 or attribute + size > end:
                                sys.exit(1)
                            value = data[attribute + 4:attribute + size]
                            if tag == 0:
                                path = value.rstrip(b"\0")
                            elif tag == 2:
                                peer, = struct.unpack("=I", value)
                            attribute += (size + 3) & ~3
                        peers[inode] = (peer, path)
                    offset += (length + 3) & ~3
        paths = set()
        for inode in owned:
            peer, _ = peers.get(inode, (None, b""))
            reciprocal, path = peers.get(peer, (None, b""))
            if reciprocal == inode and path.startswith(b"/"):
                paths.add(path)
        if len(paths) == 1:
            print(paths.pop().hex())
        """#

    static func linuxEndpoint(_ text: String, process: String) -> String? {
        struct Socket {
            let local: String
            let peer: String
            let path: String
            let owner: Bool
        }
        let sockets: [Socket] = text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 8, fields[0] == "u_str", fields[1] == "ESTAB",
                UInt64(fields[5]) != nil, UInt64(fields[7]) != nil
            else { return nil }
            return Socket(
                local: fields[5], peer: fields[7], path: fields[4],
                owner: fields.dropFirst(8).joined().contains("pid=\(process),"))
        }
        var paths: Set<String> = []
        for client in sockets where client.owner {
            for peer in sockets where peer.local == client.peer && peer.peer == client.local {
                if RemoteMultiplexerCommands.validPath(peer.path) { paths.insert(peer.path) }
            }
        }
        return paths.count == 1 ? paths.first : nil
    }

    static func darwinEndpoint(_ text: String, process: String) -> String? {
        struct Socket {
            let process: String
            let device: String
            let name: String
        }
        var sockets: [Socket] = []
        var pid = ""
        var device = ""
        var name = ""
        func append() {
            if !device.isEmpty, !name.isEmpty { sockets.append(.init(process: pid, device: device, name: name)) }
            device = ""
            name = ""
        }
        for line in text.split(separator: "\n") {
            switch line.first {
            case "p":
                append()
                pid = String(line.dropFirst())
            case "f": append()
            case "d": device = String(line.dropFirst())
            case "n": name = String(line.dropFirst())
            default: break
            }
        }
        append()
        var paths: Set<String> = []
        for client in sockets where client.process == process {
            guard let arrow = client.name.range(of: "->") else { continue }
            let peerDevice = String(client.name[arrow.upperBound...])
            for peer in sockets where peer.device == peerDevice {
                let path = peer.name.components(separatedBy: "->")[0]
                if RemoteMultiplexerCommands.validPath(path) { paths.insert(path) }
            }
        }
        return paths.count == 1 ? paths.first : nil
    }

    static func guardClient(_ client: Client, terminal: String) throws -> String {
        """
        [ "$(process_start '\(client.process)')" = \(try RemoteMultiplexerCommands.quote(client.started)) ] || exit 79
        [ "/dev/$(ps -p '\(client.process)' -o tty= | tr -d ' ')" = \(try RemoteMultiplexerCommands.quote(terminal)) ] || exit 79
        groups=$(ps -p '\(client.process)' -o pgid= -o tpgid=) || exit 79
        set -- $groups
        [ "$#" = 2 ] && [ "$1" = "$2" ] && [ "$1" -gt 0 ] || exit 79
        """
    }
}
