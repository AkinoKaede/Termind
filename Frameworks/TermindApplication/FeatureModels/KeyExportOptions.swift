// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated struct KeyExportOptions: Equatable, Sendable {
    public var directory: String
    public var filename: String
    public var script: String

    public init(directory: String = ".ssh", filename: String = "authorized_keys", script: String) {
        self.directory = directory
        self.filename = filename
        self.script = script
    }

    public var isValid: Bool {
        !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !filename.contains("/") && !filename.contains("\\") && ![".", ".."].contains(filename)
            && !directory.contains("\0") && !filename.contains("\0") && !script.contains("\0")
    }

    public static func defaultScript(keyName: String) -> String {
        let name = keyName.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(
            separator: " "
        )
        .filter { !$0.isNewline && $0 != "\0" }
        let comment = RemoteShellCommand.escapeArgument("# \(name) Key by Termind")
        return """
            set -eu
            umask 077
            mkdir -p -- "$1"
            touch -- "$1/$2"
            chmod 700 "$1"
            chmod 600 "$1/$2"
            if ! LC_ALL=C grep -Fqx -- "$3" "$1/$2"; then
                if [ -s "$1/$2" ]; then printf '\\n' >> "$1/$2"; fi
                printf '%s\\n%s\\n' \(comment) "$3" >> "$1/$2"
            fi
            """
    }
}

public nonisolated protocol KeyExportSession: Sendable {
    func install(publicKey: String, options: KeyExportOptions) async throws
    func disconnect() async
}

public nonisolated struct KeyExportServices: Sendable {
    public let derivePublicKey: @Sendable (SSHKeyRef, SSHResolvedKeyCredential, SSHSecret?) async throws -> String
    public let connect: @Sendable (SSHConnectionRequest, SSHRouteProgressHandler?) async throws -> any KeyExportSession

    public init(
        derivePublicKey: @escaping @Sendable (SSHKeyRef, SSHResolvedKeyCredential, SSHSecret?) async throws -> String,
        connect:
            @escaping @Sendable (SSHConnectionRequest, SSHRouteProgressHandler?) async throws -> any KeyExportSession
    ) {
        self.derivePublicKey = derivePublicKey
        self.connect = connect
    }
}
