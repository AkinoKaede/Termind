import Foundation
import TermindApplication
import TermindDomain

nonisolated struct SSHKeyExportSession: KeyExportSession {
    let connection: any SSHConnectionProtocol

    func install(publicKey: String, options: KeyExportOptions) async throws {
        let command = try Self.command(publicKey: publicKey, options: options)
        let result = try await connection.execute(
            command, workingDirectory: nil, stdin: nil, timeout: 20, outputLimit: 64 * 1024, onOutput: nil)
        guard result.exitCode == 0 else {
            throw TermindSSHError.library(
                String(localized: "The export script exited with status \(result.exitCode).")
                    + "\n" + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func disconnect() async { await connection.disconnect() }

    static func command(publicKey: String, options: KeyExportOptions) throws -> String {
        guard options.isValid else { throw CocoaError(.coderInvalidValue) }
        let key = try SSHKeyMaterial.publicMaterial(publicKey).publicKey
        let launcher = """
            case "$1" in
                /*) directory=$1 ;;
                '~') directory=$HOME ;;
                '~/'*) directory="$HOME/${1#??}" ;;
                *) directory="$HOME/$1" ;;
            esac
            exec sh -c "$4" termind-key-export "$directory" "$2" "$3"
            """
        return "sh -c "
            + [launcher, "termind-key-export", options.directory, options.filename, key, options.script]
            .map(RemoteShellCommand.escapeArgument).joined(separator: " ")
    }

    static func derivePublicKey(
        key: SSHKeyRef, credential: SSHResolvedKeyCredential, passphrase: SSHSecret?
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            defer {
                credential.clearSecrets()
                passphrase?.clear()
            }
            guard case .software(let privateKey, let saved) = credential else {
                throw TermindSSHError.missingCredential
            }
            let password = passphrase ?? saved
            let passwordText = try password?.withUnsafeCStringAndConsume { bytes, _ in String(cString: bytes) }
            return try privateKey.withUnsafeCStringAndConsume { bytes, _ in
                try SSHKeyMaterial.inspect(
                    privateKey: String(cString: bytes), passphrase: passwordText, comment: key.label
                ).publicKey
            }
        }.value
    }
}
